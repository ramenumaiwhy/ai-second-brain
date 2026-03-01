#!/bin/bash
# Codex セッション → Obsidian 同期スクリプト
# Claude Code の Stop hook から呼ばれる

set -euo pipefail

umask 077

# UTF-8ロケール設定（利用可能なものから選択）
_utf8_locale=""
for _loc in en_US.UTF-8 C.UTF-8 POSIX; do
    if locale -a 2>/dev/null | grep -qx "$_loc"; then
        _utf8_locale="$_loc"
        break
    fi
done
export LC_ALL="${_utf8_locale:-C}"
export LANG="${_utf8_locale:-C}"
unset _utf8_locale _loc

# jq, python3 が無ければ即終了
for cmd in jq python3; do
    command -v "$cmd" &>/dev/null || { printf '%s: %s not found, aborting\n' "$(date)" "$cmd" >&2; exit 1; }
done

CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
OBSIDIAN_DIR="${SECOND_BRAIN_DIR:?'Error: SECOND_BRAIN_DIR is not set. Set it to your notes directory.'}"
SYNC_LOG="$HOME/.claude/codex-sync.log"
LOCK_DIR="$HOME/.claude/codex-obsidian-sync.lock"
SID_INDEX="$HOME/.claude/codex-sid-index.tsv"

# 親ディレクトリの存在を保証
mkdir -p "$HOME/.claude"

acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        if [ -d "$LOCK_DIR" ]; then
            local lock_pid_file="$LOCK_DIR/pid"
            if [ -f "$lock_pid_file" ]; then
                # pidファイル形式: "PID:LSTART" (PID再利用対策)
                local lock_info lock_pid lock_lstart
                lock_info=$(cat "$lock_pid_file" 2>/dev/null)
                lock_pid="${lock_info%%:*}"
                lock_lstart="${lock_info#*:}"
                if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                    # lstart未取得時("unknown")はkill -0のみで生存判定
                    if [ "$lock_lstart" = "unknown" ]; then
                        return 1
                    fi
                    local current_lstart
                    current_lstart=$(ps -p "$lock_pid" -o lstart= 2>/dev/null || true)
                    if [ -n "$current_lstart" ] && [ "$current_lstart" = "$lock_lstart" ]; then
                        # 同一プロセスが生存中 → ロック有効
                        return 1
                    fi
                fi
            fi
            # PIDなし or プロセス死亡 or PID再利用 → staleロック回収
            local lock_age
            lock_age=$(python3 -c "
import os, time, sys
try:
    mtime = os.path.getmtime(sys.argv[1])
    print(int(time.time() - mtime))
except OSError:
    print(999)
" "$LOCK_DIR")
            if [ "$lock_age" -gt 300 ]; then
                if rm -rf "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
                    write_pid_file
                    trap 'rm -rf "$LOCK_DIR"' EXIT
                    return 0
                else
                    return 1
                fi
            else
                return 1
            fi
        fi
        return 1
    fi
    write_pid_file
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
}

write_pid_file() {
    local my_lstart
    my_lstart=$(ps -p "$$" -o lstart= 2>/dev/null || true)
    if [ -z "$my_lstart" ]; then
        my_lstart="unknown"
    fi
    printf '%s:%s' "$$" "$my_lstart" > "$LOCK_DIR/pid"
}

truncate_utf8() {
    local str="$1"
    local max_chars="${2:-50}"
    python3 -c "import sys; print(sys.stdin.read().strip()[:int(sys.argv[1])])" "$max_chars" <<< "$str"
}

yaml_escape() {
    local str="$1"
    python3 -c "import sys, json; print(json.dumps(sys.argv[1])[1:-1])" "$str" 2>/dev/null || \
        printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '
}

# UUID形式のみ許可（8-4-4-4-12 のハイフン区切りhex、棄却方式）
validate_sid() {
    local sid="$1"
    if [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        printf '%s' "$sid"
    fi
}

# YYYY-MM-DD 厳格バリデーション（実日付チェック付き）
validate_date() {
    local d="$1"
    if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # Python で実日付かどうか検証
        if python3 -c "
import datetime, sys
try:
    datetime.date.fromisoformat(sys.argv[1])
    sys.exit(0)
except ValueError:
    sys.exit(1)
" "$d" 2>/dev/null; then
            printf '%s' "$d"
        fi
    fi
}

sanitize_filename() {
    python3 -c "
import re, sys
title = sys.argv[1]
safe = re.sub(r'[\x00-\x1f\x7f]', '', title)
safe = re.sub(r'[<>:\"/\\\\|?*/]', '', safe)
safe = re.sub(r' ', '_', safe)
safe = re.sub(r'_+', '_', safe)
safe = safe.strip('.')
safe = safe[:50]
if not safe or safe in ('.', '..'):
    safe = 'untitled'
print(safe)
" "$1"
}

# JSONL から user/assistant メッセージを抽出（システムコンテキストは除外）
extract_messages() {
    local jsonl_file="$1"
    python3 -c "
import json, sys

messages = []
for line in open(sys.argv[1], 'r', encoding='utf-8', errors='replace'):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue

    if event.get('type') != 'response_item':
        continue

    payload = event.get('payload', {})
    if payload.get('type') != 'message':
        continue

    role = payload.get('role')
    if role not in ('user', 'assistant'):
        continue

    content_parts = payload.get('content', [])
    text_parts = []
    for part in content_parts:
        if isinstance(part, dict) and part.get('type') in ('input_text', 'output_text'):
            text_parts.append(part.get('text', ''))

    text = '\n'.join(text_parts)

    # システムコンテキストを除外
    if role == 'user':
        skip_prefixes = (
            '# AGENTS.md',
            '<INSTRUCTIONS>',
            '<environment_context>',
            '<uploaded_file',
        )
        if any(text.lstrip().startswith(p) for p in skip_prefixes):
            continue

    if text.strip():
        messages.append({'role': role, 'text': text})

print(json.dumps({'count': len(messages), 'messages': messages}, ensure_ascii=False))
" "$jsonl_file"
}

# セッションメタデータを抽出
extract_meta() {
    local jsonl_file="$1"
    python3 -c "
import json, sys

for line in open(sys.argv[1], 'r', encoding='utf-8', errors='replace'):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get('type') == 'session_meta':
        p = event.get('payload', {})
        print(json.dumps({
            'id': p.get('id', ''),
            'timestamp': p.get('timestamp', event.get('timestamp', '')),
            'cwd': p.get('cwd', ''),
            'source': p.get('source', 'unknown'),
        }, ensure_ascii=False))
        break
" "$jsonl_file"
}

# session_id → ファイルパスの検索（インデックスキャッシュ + フォールバック全件走査）
find_existing_by_sid() {
    local sid="$1"
    local target_dir="$2"

    # 1. インデックスから検索（完全一致 + realpath検証）
    if [ -f "$SID_INDEX" ]; then
        local cached_path
        cached_path=$(awk -F'\t' -v sid="$sid" '$1 == sid {print $2; exit}' "$SID_INDEX" 2>/dev/null)
        if [ -n "$cached_path" ] && [ -f "$cached_path" ] && [ ! -L "$cached_path" ]; then
            local real_cached real_target
            real_cached=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$cached_path")
            real_target=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$target_dir")
            if [[ "$real_cached" == "$real_target/"* ]]; then
                printf '%s' "$cached_path"
                return 0
            fi
        fi
    fi

    # 2. フォールバック: 全件走査（フロントマター内 session_id、シンボリックリンク除外）
    python3 -c "
import os, sys

sid = sys.argv[1]
target_dir = sys.argv[2]
# 引用符あり/なし両方にマッチ (recall側は quoted, codex側は unquoted)
target_lines = {'session_id: ' + sid, 'session_id: \"' + sid + '\"'}
real_dir = os.path.realpath(target_dir)

for fname in os.listdir(target_dir):
    if not fname.endswith('.md'):
        continue
    fpath = os.path.join(target_dir, fname)
    if os.path.islink(fpath):
        continue
    if not os.path.realpath(fpath).startswith(real_dir + os.sep):
        continue
    try:
        with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
            in_frontmatter = False
            for line in f:
                line = line.rstrip('\n')
                if line == '---':
                    if not in_frontmatter:
                        in_frontmatter = True
                        continue
                    else:
                        break
                if in_frontmatter and line in target_lines:
                    print(fpath)
                    sys.exit(0)
    except (OSError, UnicodeDecodeError):
        continue
" "$sid" "$target_dir"
}

# インデックスに sid → path を追記
update_sid_index() {
    local sid="$1"
    local filepath="$2"
    printf '%s\t%s\n' "$sid" "$filepath" >> "$SID_INDEX"
}

# フロントマターから msg_count を抽出（欠落/不正/読取エラーなら -1 を返す → 呼び出し側でスキップ判定）
get_frontmatter_msg_count() {
    local filepath="$1"
    python3 -c "
import sys

try:
    count = None
    in_fm = False
    has_frontmatter = False
    fm_closed = False
    for line in open(sys.argv[1], 'r', encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if line == '---':
            if not in_fm:
                in_fm = True
                has_frontmatter = True
                continue
            else:
                fm_closed = True
                break
        if in_fm and line.startswith('msg_count: '):
            try:
                count = int(line.split(': ', 1)[1])
            except ValueError:
                pass
    if not has_frontmatter or not fm_closed or count is None:
        print(-1)
    else:
        print(count)
except (OSError, UnicodeDecodeError):
    print(-1)
" "$filepath"
}

# メッセージJSONを展開してMarkdownテキストを生成（一括処理）
format_messages_as_markdown() {
    local messages_json="$1"
    local start_index="${2:-0}"
    local start_q="${3:-0}"
    local start_a="${4:-0}"
    printf '%s' "$messages_json" | python3 -c "
import json, sys

messages = json.loads(sys.stdin.read())
start = int(sys.argv[1])
q = int(sys.argv[2])
a = int(sys.argv[3])

for msg in messages[start:]:
    role = msg['role']
    text = msg['text']
    if role == 'user':
        q += 1
        print(f'## Q{q}')
        print(text)
        print()
    elif role == 'assistant':
        a += 1
        print(f'## A{a}')
        print(text)
        print()
" "$start_index" "$start_q" "$start_a"
}

sync_session_file() {
    local jsonl_file="$1"
    local append_tmp="" tmp_file=""
    trap '[ -n "$append_tmp" ] && rm -f "$append_tmp" 2>/dev/null; [ -n "$tmp_file" ] && rm -f "$tmp_file" 2>/dev/null; true' RETURN

    local meta
    if ! meta=$(extract_meta "$jsonl_file"); then
        printf '%s: extract_meta failed for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi
    if [ -z "$meta" ]; then
        return 1
    fi

    local sid timestamp
    sid=$(printf '%s' "$meta" | jq -r '.id // empty')
    timestamp=$(printf '%s' "$meta" | jq -r '.timestamp // empty')

    if [ -z "$sid" ] || [ -z "$timestamp" ]; then
        return 1
    fi

    # sidをバリデーション（UUID形式以外は棄却）
    sid=$(validate_sid "$sid")
    if [ -z "$sid" ]; then
        return 1
    fi

    # date_str を厳格バリデーション（YYYY-MM-DD）
    local date_str
    date_str=$(validate_date "$(printf '%s' "$timestamp" | cut -d'T' -f1)")
    if [ -z "$date_str" ]; then
        return 1
    fi

    # メッセージ抽出（{count, messages} 形式）
    local extract_result
    if ! extract_result=$(extract_messages "$jsonl_file"); then
        printf '%s: extract_messages failed for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi
    if [ -z "$extract_result" ]; then
        return 0
    fi

    local msg_count
    msg_count=$(printf '%s' "$extract_result" | jq -r '.count')
    if [ "$msg_count" -eq 0 ]; then
        return 0
    fi

    local messages_json
    messages_json=$(printf '%s' "$extract_result" | jq -c '.messages')

    # フロントマター範囲限定で既存ファイルを検索
    local existing_file=""
    if ! existing_file=$(find_existing_by_sid "$sid" "$OBSIDIAN_DIR"); then
        printf '%s: find_existing_by_sid failed for sid=%s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    fi

    # 差分追記チェック（フロントマターの msg_count ベース）
    if [ -n "$existing_file" ]; then
        # シンボリックリンク除外 + 通常ファイル確認（TOCTOU軽減: O_NOFOLLOW相当のPythonで追記）
        if [ -L "$existing_file" ] || [ ! -f "$existing_file" ]; then
            return 1
        fi

        local existing_msg_count
        existing_msg_count=$(get_frontmatter_msg_count "$existing_file")

        # msg_count 欠落/破損(-1)なら壊れたファイルには触れない
        if [ "$existing_msg_count" -eq -1 ]; then
            printf '%s: Skipping %s (missing/invalid msg_count in frontmatter)\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
            return 0
        fi

        if [ "$msg_count" -le "$existing_msg_count" ]; then
            return 0
        fi

        # 差分追記: 既存ファイルの Q/A 数をカウント（コードブロック内を除外、読取エラー時は0）
        local qa_counts
        qa_counts=$(python3 -c "
import sys, re
try:
    in_code = False
    q_count = 0
    a_count = 0
    fence = chr(96) * 3  # backtick x3
    for line in open(sys.argv[1], 'r', encoding='utf-8', errors='replace'):
        stripped = line.rstrip('\n')
        if stripped.startswith(fence):
            in_code = not in_code
            continue
        if not in_code:
            if re.match(r'^## Q\d+$', stripped):
                q_count += 1
            elif re.match(r'^## A\d+$', stripped):
                a_count += 1
    print(f'{q_count} {a_count}')
except (OSError, UnicodeDecodeError):
    print('0 0')
" "$existing_file")
        local q_count a_count
        q_count="${qa_counts%% *}"
        a_count="${qa_counts##* }"

        # 差分メッセージを一時ファイルに書き出し（巨大セッション対策: シェル変数保持を回避）
        append_tmp=$(mktemp "$OBSIDIAN_DIR/.tmp_append.XXXXXX") || return 1
        format_messages_as_markdown "$messages_json" "$existing_msg_count" "$q_count" "$a_count" > "$append_tmp"

        if [ -s "$append_tmp" ]; then
            # 単一トランザクション: msg_count更新 + 差分追記を1回の tmpfile → os.replace で実行
            if ! python3 -c "
import os, sys, tempfile

path = sys.argv[1]
new_count = sys.argv[2]
append_file = sys.argv[3]

# O_NOFOLLOW で読み込み（TOCTOU防止）
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except OSError:
    sys.exit(1)
with os.fdopen(fd, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

# 追記内容をファイルから読み込み
with open(append_file, 'r', encoding='utf-8', errors='replace') as af:
    append_text = af.read()

# フロントマター内の msg_count を更新
result = []
in_fm = False
fm_closed = False
count_updated = False
for line in lines:
    stripped = line.rstrip('\n')
    if stripped == '---':
        if not in_fm:
            in_fm = True
            result.append(line)
            continue
        else:
            if not count_updated:
                result.append(f'msg_count: {new_count}\n')
            fm_closed = True
            result.append(line)
            continue
    if in_fm and not fm_closed and stripped.startswith('msg_count: '):
        result.append(f'msg_count: {new_count}\n')
        count_updated = True
        continue
    result.append(line)

# 末尾に差分メッセージを追加
result.append(append_text)
if not append_text.endswith('\n'):
    result.append('\n')

# tmpfile → os.replace で単一atomicトランザクション（fsync付き）
dir_name = os.path.dirname(path)
fd_tmp, tmp_path = tempfile.mkstemp(dir=dir_name, prefix='.sync_update_')
try:
    with os.fdopen(fd_tmp, 'wb') as f_tmp:
        f_tmp.write(''.join(result).encode('utf-8'))
        f_tmp.flush()
        os.fsync(f_tmp.fileno())
    os.replace(tmp_path, path)
    # 親ディレクトリ fsync でエントリ永続化
    dir_fd = os.open(dir_name, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
" "$existing_file" "$msg_count" "$append_tmp"; then
                printf '%s: atomic update failed for %s\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
                return 1
            fi
            rm -f "$append_tmp" 2>/dev/null
            append_tmp=""
            printf '%s: Appended to %s (%s -> %s)\n' "$(date)" "$existing_file" "$existing_msg_count" "$msg_count" >> "$SYNC_LOG"
        else
            rm -f "$append_tmp" 2>/dev/null
            append_tmp=""
        fi
        return 0
    fi

    # --- 新規作成 ---

    # タイトル: ユーザーメッセージから意味のある内容を抽出
    local title
    title=$(printf '%s' "$messages_json" | python3 -c "
import json, re, sys

messages = json.loads(sys.stdin.read())

def extract_title(text):
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
        line = re.sub(r'^#+\s*', '', line)  # markdown見出しの # を除去
        if len(line) >= 5:
            return line[:50]
    return None

# ユーザーメッセージから順に試す
for msg in messages:
    if msg.get('role') == 'user':
        t = extract_title(msg['text'])
        if t:
            print(t)
            sys.exit(0)
# フォールバック: 最初のアシスタント応答
for msg in messages:
    if msg.get('role') == 'assistant':
        t = extract_title(msg['text'])
        if t:
            print(t)
            sys.exit(0)
print('untitled')
")

    local safe_title
    safe_title=$(sanitize_filename "$title")

    local short_sid
    short_sid=$(printf '%s' "$sid" | cut -c1-8)
    local filename="${date_str}_${safe_title}_${short_sid}.md"
    local filepath="$OBSIDIAN_DIR/$filename"

    local escaped_title
    escaped_title=$(yaml_escape "$title")

    tmp_file=$(mktemp "$OBSIDIAN_DIR/.tmp.XXXXXX") || {
        printf '%s: Failed to create temp file for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    }

    {
        printf '%s\n' "---"
        printf 'date: %s\n' "$date_str"
        printf 'title: "%s"\n' "$escaped_title"
        printf '%s\n' "source: Codex"
        printf 'session_id: %s\n' "$sid"
        printf 'msg_count: %s\n' "$msg_count"
        printf '%s\n' "tags:"
        printf '%s\n' "  - codex"
        printf '%s\n' "---"
        printf '\n'
        printf '# %s\n' "$(printf '%s' "$title" | tr -d '\n\r')"
        printf '\n'

        format_messages_as_markdown "$messages_json" 0 0 0
    } > "$tmp_file" || {
        printf '%s: Failed to write temp file for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    }

    # fsync でファイル + 親ディレクトリの永続化保証
    python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.fsync(fd)
os.close(fd)
dir_fd = os.open(os.path.dirname(sys.argv[1]), os.O_RDONLY)
os.fsync(dir_fd)
os.close(dir_fd)
" "$tmp_file"

    # 衝突回避: 同名ファイルが既に存在すれば連番サフィックスを付加
    if [ -e "$filepath" ]; then
        local base="${filepath%.md}"
        local n=1
        while [ -e "${base}_${n}.md" ]; do
            n=$((n + 1))
        done
        filepath="${base}_${n}.md"
    fi
    mv "$tmp_file" "$filepath" || {
        printf '%s: Failed to move temp file for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    }
    tmp_file=""

    # mv 後の親ディレクトリ fsync（新しいディレクトリエントリの永続化保証）
    python3 -c "
import os, sys
dir_fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
" "$OBSIDIAN_DIR"

    update_sid_index "$sid" "$filepath"
    printf '%s: Created %s -> %s\n' "$(date)" "$sid" "$(basename "$filepath")" >> "$SYNC_LOG"
}

# --- メイン処理 ---

# 基点ディレクトリのシンボリックリンク検証（mkdir -p より先に実施）
for _check_dir in "$OBSIDIAN_DIR" "$CODEX_SESSIONS_DIR"; do
    if [ -L "$_check_dir" ]; then
        printf '%s: %s is a symlink, aborting\n' "$(date)" "$_check_dir" >> "$SYNC_LOG"
        exit 1
    fi
done

mkdir -p "$OBSIDIAN_DIR"

if ! acquire_lock; then
    printf '%s: Could not acquire lock, another sync is running\n' "$(date)" >> "$SYNC_LOG"
    exit 0
fi

if [ ! -d "$CODEX_SESSIONS_DIR" ]; then
    printf '%s: Codex sessions directory not found: %s\n' "$(date)" "$CODEX_SESSIONS_DIR" >> "$SYNC_LOG"
    exit 0
fi

sync_fail=0
while IFS= read -r -d '' jsonl_file; do
    sync_session_file "$jsonl_file" || {
        printf '%s: Failed to sync %s (continuing)\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        sync_fail=$((sync_fail + 1))
    }
done < <(find "$CODEX_SESSIONS_DIR" -name "rollout-*.jsonl" -type f -print0)

if [ "$sync_fail" -gt 0 ]; then
    printf '%s: Codex sync completed with %d failures\n' "$(date)" "$sync_fail" >> "$SYNC_LOG"
else
    printf '%s: Codex sync completed\n' "$(date)" >> "$SYNC_LOG"
fi
