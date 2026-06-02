#!/bin/bash
# recall → Obsidian 同期スクリプト (tested)
# SessionEndフックとcronの両方から呼ばれる

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# UTF-8ロケールを明示的に設定（macOSのmvでIllegal byte sequence対策）
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# 依存コマンドの存在確認（macOS前提: stat -f）
for cmd in recall jq python3 shasum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "$(date): Required command '$cmd' not found" >&2
        exit 1
    fi
done

OBSIDIAN_DIR="${SECOND_BRAIN_DIR:?'Error: SECOND_BRAIN_DIR is not set. Set it to your notes directory.'}"
STAGING_DIR="$HOME/.claude/dream-staging"
SYNC_LOG="$HOME/.claude/recall-sync.log"
LOCK_DIR="$HOME/.claude/recall-obsidian-sync.lock"
REDACTION_HELPER="${REDACTION_HELPER:-$SCRIPT_DIR/redact-secrets.py}"
if [ ! -f "$REDACTION_HELPER" ] && [ -f "$PWD/scripts/redact-secrets.py" ]; then
    REDACTION_HELPER="$PWD/scripts/redact-secrets.py"
fi

mkdir -p "$HOME/.claude"

# 引数でセッションIDが渡された場合はそれだけ同期、なければ全セッション
SESSION_ID="${1:-}"

# recall read が失敗した場合にJSONLファイルから直接読む（フォークセッション対応）
read_from_jsonl() {
    local sid="$1"
    local jsonl_dir="$HOME/.claude/projects"

    # セッションIDに対応するJSONLファイルを探す（claude/codex両方を探索）
    local jsonl_file=""
    local find_paths=("$jsonl_dir")
    [ -d "$HOME/.codex/sessions" ] && find_paths+=("$HOME/.codex/sessions")
    jsonl_file=$(find "${find_paths[@]}" -name "${sid}.jsonl" -type f 2>/dev/null | head -1) || true

    if [ -z "$jsonl_file" ]; then
        return 1
    fi

    # JSONLからrecall read互換のJSON構造を生成
    python3 -c "
import json
import sys

sid = sys.argv[1]
jsonl_path = sys.argv[2]

messages = []
first_timestamp = None

with open(jsonl_path, 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue

        rec_type = record.get('type', '')
        rec_sid = record.get('sessionId', '')

        # このセッションIDのuser/assistantメッセージだけ抽出
        if rec_sid != sid:
            continue
        if rec_type not in ('user', 'assistant'):
            continue

        ts = record.get('timestamp', '')
        if first_timestamp is None and ts:
            first_timestamp = ts

        msg = record.get('message', {})
        role = msg.get('role', rec_type)
        content = msg.get('content', '')

        # contentからテキスト部分を抽出
        if isinstance(content, list):
            texts = []
            for item in content:
                if isinstance(item, dict):
                    if item.get('type') == 'text' and 'text' in item:
                        texts.append(item['text'])
                elif isinstance(item, str):
                    texts.append(item)
            text = '\n'.join(texts)
        elif isinstance(content, str):
            text = content
        else:
            text = ''

        # 空のメッセージはスキップ（tool_result等）
        if not text.strip():
            continue

        messages.append({'role': role, 'content': text})

        # #5: メモリ保護（上限2000メッセージ）
        if len(messages) >= 2000:
            break

if not messages:
    sys.exit(1)

# #6: JSONLにはsourceフィールドがないため、ファイルパスの格納ディレクトリで判定
# ~/.claude/projects/ → claude, ~/.codex/sessions/ → codex
source = 'claude'
if '/.codex/' in jsonl_path:
    source = 'codex'

result = {
    'timestamp': first_timestamp or '',
    'source': source,
    'messages': messages
}

print(json.dumps(result, ensure_ascii=False))
" "$sid" "$jsonl_file" 2>/dev/null
}

# 排他ロック取得（TOCTOU脆弱性を最小化）
acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        if [ -d "$LOCK_DIR" ]; then
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || printf '0') ))
            if [ "$lock_age" -gt 300 ]; then
                # rm && mkdirでレースウィンドウを最小化
                if rm -rf "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
                    trap 'rm -rf "$LOCK_DIR"' EXIT
                    return 0
                else
                    return 1
                fi
            else
                return 1
            fi
        fi
        # ロックディレクトリが存在しない（他プロセスが同時に削除した）場合
        return 1
    fi
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
}

# UTF-8安全な文字列切り詰め（python3で確実に文字数ベース）
truncate_utf8() {
    local str="$1"
    local max_chars="${2:-50}"
    # .strip()で改行を除去
    python3 -c "import sys; print(sys.stdin.read().strip()[:int(sys.argv[1])])" "$max_chars" <<< "$str"
}

# YAMLエスケープ（ダブルクォート内で安全に - python3でJSON形式エスケープ）
yaml_escape() {
    local str="$1"
    # python3でJSONエスケープ（\, ", 改行, 制御文字を処理）
    # json.dumpsの結果から前後のダブルクォートを除去
    python3 -c "import sys, json; print(json.dumps(sys.argv[1])[1:-1])" "$str" 2>/dev/null || \
        printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '
}

redact_stream() {
    if [ ! -f "$REDACTION_HELPER" ]; then
        echo "$(date): Redaction helper not found: $REDACTION_HELPER" >> "$SYNC_LOG"
        return 1
    fi
    python3 "$REDACTION_HELPER"
}

redact_value() {
    printf '%s' "$1" | redact_stream
}

format_recall_messages_as_markdown() {
    local json="$1"
    local skip_count="${2:-0}"
    local q_count="${3:-0}"
    local a_count="${4:-0}"

    printf '%s' "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
msgs = [m for m in data.get('messages', []) if m.get('role') in ('user', 'assistant')]
skip = int(sys.argv[1])
q = int(sys.argv[2])
a = int(sys.argv[3])
seen = 0
for m in msgs:
    seen += 1
    if seen <= skip:
        continue
    c = m.get('content', '')
    if isinstance(c, list):
        c = '\n'.join(x.get('text', '') if isinstance(x, dict) and x.get('type') == 'text' else (x if isinstance(x, str) else '') for x in c)
    elif not isinstance(c, str):
        c = str(c)
    if m['role'] == 'user':
        q += 1
        print(f'## Q{q}')
    else:
        a += 1
        print(f'## A{a}')
    print(c)
    print()
" "$skip_count" "$q_count" "$a_count" | redact_stream
}

sync_session() {
    local sid="$1"
    local json

    # recall readはフォークセッション等で正常にexit 1を返すため、|| trueで受けてフォールバックへ進む
    json=$(recall read "$sid" 2>/dev/null) || true

    # #3: 非空だが不正JSONの場合もフォールバックへ回す
    if [ -n "$json" ] && ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        echo "$(date): Invalid JSON from recall for session $sid, trying fallback" >> "$SYNC_LOG"
        json=""
    fi

    if [ -z "$json" ]; then
        # recall CLIで読めない場合、JSONLファイルから直接読む（フォークセッション対応）
        # read_from_jsonlはファイル未発見で正常にexit 1を返すため、|| trueで受ける
        json=$(read_from_jsonl "$sid") || true
        if [ -z "$json" ]; then
            echo "$(date): Failed to read session $sid (recall + jsonl fallback)" >> "$SYNC_LOG"
            return 1
        fi
        echo "$(date): Using JSONL fallback for session $sid (recall empty)" >> "$SYNC_LOG"
    else
        # recall read が返したメッセージ数とJSONLのメッセージ数を比較
        # recall read が極端に少ない場合（JONLの半分未満）はJSONLフォールバックを使う
        local recall_msg_count
        recall_msg_count=$(printf '%s' "$json" | jq '(.messages // []) | length' 2>/dev/null) || recall_msg_count=0
        local jsonl_json
        jsonl_json=$(read_from_jsonl "$sid" 2>/dev/null) || true
        if [ -n "$jsonl_json" ]; then
            local jsonl_msg_count
            jsonl_msg_count=$(printf '%s' "$jsonl_json" | jq '(.messages // []) | length' 2>/dev/null) || jsonl_msg_count=0
            if [ "$jsonl_msg_count" -gt 0 ] && [ "$recall_msg_count" -gt 0 ] && \
               [ "$jsonl_msg_count" -ge $((recall_msg_count * 2)) ]; then
                echo "$(date): JSONL has significantly more messages ($jsonl_msg_count) than recall ($recall_msg_count) for session $sid, using JSONL" >> "$SYNC_LOG"
                json="$jsonl_json"
            fi
        fi
    fi

    # 必須フィールドの検証
    local timestamp source
    timestamp=$(printf '%s' "$json" | jq -r '.timestamp // empty')
    source=$(printf '%s' "$json" | jq -r '.source // empty')

    if [ -z "$timestamp" ] || [ -z "$source" ]; then
        echo "$(date): Missing required fields for session $sid" >> "$SYNC_LOG"
        return 1
    fi

    # 日付部分を抽出
    local date_str
    date_str=$(printf '%s' "$timestamp" | cut -d'T' -f1)

    # #1: date_strの厳格検証（パストラバーサル防止）
    if ! [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$(date): Invalid date format '$date_str' for session $sid" >> "$SYNC_LOG"
        return 1
    fi

    # 既存ファイルを検索（YAML front matter内のsession_idのみマッチ、本文誤検知を防止）
    local existing_file=""
    # shellcheck disable=SC2016
    existing_file=$(find "$OBSIDIAN_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | \
        xargs -0 awk -v sid="$sid" '
            FNR==1 { in_fm=0; found=0 }
            FNR==1 && /^---$/ { in_fm=1; next }
            in_fm && /^---$/ { in_fm=0; next }
            in_fm && /^session_id:/ {
                gsub(/^session_id:[ \t]*"?/, ""); gsub(/"?[ \t]*$/, "")
                if ($0 == sid) { print FILENAME; found=1; exit }
            }
        ' 2>/dev/null | head -1) || true

    # メッセージ数を取得（nullセーフ）
    local msg_count
    msg_count=$(printf '%s' "$json" | jq '(.messages // []) | length')
    if ! [[ "$msg_count" =~ ^[0-9]+$ ]]; then
        echo "$(date): Invalid message count for session $sid" >> "$SYNC_LOG"
        return 1
    fi
    if [ "$msg_count" -eq 0 ]; then
        echo "$(date): No messages for session $sid, skipping" >> "$SYNC_LOG"
        return 0
    fi

    # 既存ファイルがある場合 → 差分追記
    if [ -n "$existing_file" ]; then
        # 既存ファイルの Q/A 数をカウント（## Q* と ## A* の行数）
        local existing_qa_count
        existing_qa_count=$(grep -cE '^## [QA][0-9]+' "$existing_file" 2>/dev/null) || true

        # recall側のuser+assistantメッセージ数を算出
        local recall_qa_count
        recall_qa_count=$(printf '%s' "$json" | jq '[(.messages // [])[] | select(.role == "user" or .role == "assistant")] | length')

        # 新しいメッセージがなければスキップ
        if [ "$recall_qa_count" -le "$existing_qa_count" ]; then
            return 0
        fi

        # 差分メッセージを追記（既存のQ/A数以降を出力）
        local skip_count="$existing_qa_count"
        local q_count a_count
        # 既存ファイルから最後のQ/A番号を取得
        q_count=$(grep -cE '^## Q[0-9]+' "$existing_file" 2>/dev/null) || true
        a_count=$(grep -cE '^## A[0-9]+' "$existing_file" 2>/dev/null) || true

        local append_content
        append_content=$(format_recall_messages_as_markdown "$json" "$skip_count" "$q_count" "$a_count") || {
            echo "$(date): ERROR: redacted markdown generation failed during diff-append for session $sid" >> "$SYNC_LOG"
            return 1
        }

        if [ -n "$append_content" ]; then
            # アトミック書き込み: 既存内容+追記を一時ファイルに書いてからmv
            local tmp_append
            tmp_append=$(mktemp "$OBSIDIAN_DIR/.tmp.XXXXXX") || {
                echo "$(date): Failed to create temp file for append" >> "$SYNC_LOG"
                return 1
            }
            cat "$existing_file" > "$tmp_append"
            printf '%s\n' "$append_content" >> "$tmp_append"
            mv -f "$tmp_append" "$existing_file"
            echo "$(date): Appended to $existing_file ($skip_count -> $recall_qa_count messages)" >> "$SYNC_LOG"

            # dream-staging にもコピー（LaunchAgent が iCloud を読めないため）
            mkdir -p "$STAGING_DIR"
            cp -f "$existing_file" "$STAGING_DIR/$(basename "$existing_file")" 2>/dev/null || true
        fi
        return 0
    fi

    # --- 以下、新規作成 ---

    # ユーザーメッセージから意味のある内容を抽出してタイトルにする
    local raw_title title
    raw_title=$(printf '%s' "$json" | python3 -c "
import json, re, sys

data = json.loads(sys.stdin.read())
messages = data.get('messages', [])

def extract_title(text):
    if isinstance(text, list):
        parts = []
        for item in text:
            if isinstance(item, dict) and 'text' in item:
                parts.append(item['text'])
            elif isinstance(item, str):
                parts.append(item)
        text = '\n'.join(parts)
    if not isinstance(text, str):
        return None
    text = text.strip()
    if not text:
        return None
    # XMLタグとその中身を除去（<tag>...</tag> ペア → 空、残った単独タグも除去）
    text = re.sub(r'<([a-zA-Z][\w-]*)(?:\s[^>]*)?>.*?</\1>', '', text, flags=re.DOTALL)
    text = re.sub(r'<[^>]+?>', '', text).strip()
    # システムプロンプト系は丸ごとスキップ
    lower = text.lower()
    skip_starts = ('<user_instructions', '<instructions', '# agents.md',
                   '<environment_context', '<uploaded_file', '---\ntitle:')
    if any(lower.startswith(s) for s in skip_starts):
        return None
    # 定型プレフィックスを含む行を丸ごとスキップ
    skip_line_prefixes = ['Implement the following plan', 'Review the current code changes',
                          'user action', 'user instructions']
    lines = text.split('\n')
    cleaned = []
    for line in lines:
        stripped = line.strip()
        if any(stripped.lower().startswith(p.lower()) for p in skip_line_prefixes):
            continue
        cleaned.append(stripped)
    # 最初の意味のある行を返す
    for line in cleaned:
        if not line or line == '---' or line == '#':
            continue
        line = re.sub(r'^#+\s*', '', line)
        if len(line) >= 5:
            return line[:50]
    return None

# ユーザーメッセージから順に試す
for msg in messages:
    if msg.get('role') == 'user':
        t = extract_title(msg.get('content', ''))
        if t:
            print(t)
            sys.exit(0)
# フォールバック: 最初のアシスタント応答
for msg in messages:
    if msg.get('role') == 'assistant':
        t = extract_title(msg.get('content', ''))
        if t:
            print(t)
            sys.exit(0)
print('untitled')
")
    if ! title=$(redact_value "$raw_title"); then
        echo "$(date): Failed to redact title for session $sid" >> "$SYNC_LOG"
        return 1
    fi

    # ファイル名用にサニタイズ（パストラバーサル防止、python3でUTF-8安全に処理）
    local safe_title
    safe_title=$(python3 -c "
import re
import sys
title = sys.argv[1]
# 制御文字を除去（改行・タブ含む）
safe = re.sub(r'[\x00-\x1f\x7f]', '', title)
# 危険な文字を除去（<>:\"/\\|?*/）
safe = re.sub(r'[<>:\"/\\\\|?*/]', '', safe)
# 空白全般をアンダースコアに（改行・タブ残留防止）
safe = re.sub(r'[\s]+', '_', safe)
# 連続アンダースコアを1つに
safe = re.sub(r'_+', '_', safe)
# 先頭/末尾のドットを除去
safe = safe.strip('.')
# 50文字に切り詰め
safe = safe[:50]
# 空、.、.. ならuntitled
if not safe or safe in ('.', '..'):
    safe = 'untitled'
print(safe)
" "$title")

    # セッションIDの短縮版をファイル名に含めて一意性を保証（レース回避）
    # sidは$1経由で入るため、ファイル名安全な文字のみに制限
    local short_sid
    short_sid=$(printf '%s' "$sid" | tr -dc 'A-Za-z0-9_-' | cut -c1-8)
    # 許可文字が全くない場合のフォールバック（ハッシュで一意性確保）
    if [ -z "$short_sid" ]; then
        short_sid=$(printf '%s' "$sid" | shasum -a 256 | cut -c1-8)
    fi
    local filename="${date_str}_${safe_title}_${short_sid}.md"
    local filepath="$OBSIDIAN_DIR/$filename"

    # source名を整形
    local source_name
    case "$source" in
        claude) source_name="Claude Code" ;;
        codex) source_name="Codex" ;;
        *) source_name="$source" ;;
    esac

    # record_kind の決定: 環境変数 RECORD_KIND 優先、未設定時は source から推定
    local record_kind
    if [ -n "${RECORD_KIND:-}" ]; then
        record_kind="$RECORD_KIND"
    else
        case "$source_name" in
            *ChatGPT*) record_kind="chatgpt" ;;
            *Codex*) record_kind="codex_review" ;;
            *) record_kind="interactive" ;;
        esac
    fi

    # YAMLエスケープしたタイトル
    local escaped_title
    escaped_title=$(yaml_escape "$title")

    # 一時ファイルに書き出してからアトミックにmv（同一FS内で作成）
    local tmp_file
    tmp_file=$(mktemp "$OBSIDIAN_DIR/.tmp.XXXXXX") || {
        echo "$(date): Failed to create temp file for session $sid" >> "$SYNC_LOG"
        return 1
    }

    # エラー時に一時ファイルを確実にクリーンアップ
    trap 'rm -f "$tmp_file" 2>/dev/null' RETURN

    # sourceをYAMLエスケープ
    local escaped_source
    escaped_source=$(yaml_escape "$source")

    {
        # #2: source_name/sidもYAMLエスケープ（インジェクション防止）
        local escaped_source_name
        escaped_source_name=$(yaml_escape "$source_name")
        local escaped_sid
        escaped_sid=$(yaml_escape "$sid")
        echo "---"
        echo "date: $date_str"
        echo "title: \"$escaped_title\""
        echo "source: \"$escaped_source_name\""
        echo "session_id: \"$escaped_sid\""
        local escaped_record_kind
        escaped_record_kind=$(yaml_escape "$record_kind")
        echo "record_kind: \"$escaped_record_kind\""
        echo "tags:"
        echo "  - \"$escaped_source\""
        echo "---"
        echo ""
        printf '# %s\n' "$(printf '%s' "$title" | tr -d '\n\r')"
        echo ""

        format_recall_messages_as_markdown "$json" 0 0 0
    } > "$tmp_file" || {
        echo "$(date): Failed to write temp file for session $sid" >> "$SYNC_LOG"
        return 1
    }

    # アトミックに移動
    mv "$tmp_file" "$filepath" || {
        echo "$(date): Failed to move temp file for session $sid" >> "$SYNC_LOG"
        return 1
    }

    # 成功したらクリーンアップ不要（ファイルは移動済み）
    trap - RETURN

    # dream-staging にもコピー（LaunchAgent が iCloud を読めないため）
    mkdir -p "$STAGING_DIR"
    cp -f "$filepath" "$STAGING_DIR/$filename" 2>/dev/null || true

    echo "$(date): Created $sid -> $filename" >> "$SYNC_LOG"
}

# メイン処理
# symlink 拒否（書き込み先乗っ取り防止）
if [ -L "$OBSIDIAN_DIR" ]; then
    echo "$(date): $OBSIDIAN_DIR is a symlink, aborting" >> "$SYNC_LOG"
    exit 1
fi
mkdir -p "$OBSIDIAN_DIR"
mkdir -p "$STAGING_DIR"

# ステージングの古いファイル（14日超）をクリーンアップ
find "$STAGING_DIR" -maxdepth 1 -name '*.md' -mtime +14 -delete 2>/dev/null || true

if ! acquire_lock; then
    echo "$(date): Could not acquire lock, another sync is running" >> "$SYNC_LOG"
    exit 0
fi

if [ -n "$SESSION_ID" ]; then
    # 特定セッションだけ同期
    sync_session "$SESSION_ID"
else
    # 全セッションを同期
    recall_output=$(recall list 2>/dev/null) || {
        echo "$(date): Failed to get session list from recall" >> "$SYNC_LOG"
        exit 1
    }

    # JSON形式の検証
    if ! printf '%s' "$recall_output" | jq -e '.sessions' >/dev/null 2>&1; then
        echo "$(date): Invalid JSON from recall list" >> "$SYNC_LOG"
        exit 1
    fi

    # パイプ経由のwhileだとサブシェルになり、jq失敗がサイレントになるため変数展開で処理
    # codexセッションは sync-codex-to-obsidian.sh が担当するので除外
    session_ids=$(printf '%s' "$recall_output" | jq -r '.sessions[] | select(.source != "codex") | .session_id' 2>/dev/null) || {
        echo "$(date): Failed to extract session IDs from recall list" >> "$SYNC_LOG"
        exit 1
    }

    sync_fail=0
    while read -r sid; do
        if [ -n "$sid" ]; then
            sync_session "$sid" || {
                echo "$(date): Failed to sync session $sid (continuing)" >> "$SYNC_LOG"
                sync_fail=$((sync_fail + 1))
            }
        fi
    done <<< "$session_ids"

    echo "$(date): Full sync completed (failures: $sync_fail)" >> "$SYNC_LOG"
fi
