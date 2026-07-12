#!/bin/bash
# Codex セッション → Obsidian 同期スクリプト
# 明示保存、idle sync、daily recovery から呼ばれる

set -euo pipefail

umask 077

resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir
    while [ -L "$source" ]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        case "$source" in
            /*) ;;
            *) source="$dir/$source" ;;
        esac
    done
    cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"

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
TARGET_JSONL="${1:-}"
OBSIDIAN_DIR="${SECOND_BRAIN_DIR:?'Error: SECOND_BRAIN_DIR is not set. Set it to your notes directory.'}"
SYNC_LOG="$HOME/.claude/codex-sync.log"
LOCK_DIR="$HOME/.claude/codex-obsidian-sync.lock"
SID_INDEX="$HOME/.claude/codex-sid-index.tsv"
AI_SECOND_BRAIN_STATE_DIR="${AI_SECOND_BRAIN_STATE_DIR:-$HOME/.claude/ai-second-brain-state}"
SYNC_BUSY_EXIT_CODE="${SYNC_BUSY_EXIT_CODE:-0}"
if [[ ! "$SYNC_BUSY_EXIT_CODE" =~ ^[0-9]+$ ]]; then
    SYNC_BUSY_EXIT_CODE=0
fi
REDACTION_HELPER="${REDACTION_HELPER:-$SCRIPT_DIR/redact-secrets.py}"
if [ ! -f "$REDACTION_HELPER" ] && [ -f "$PWD/scripts/redact-secrets.py" ]; then
    REDACTION_HELPER="$PWD/scripts/redact-secrets.py"
fi
AI_LOG_WRITER="${AI_LOG_WRITER:-$SCRIPT_DIR/ai-log-writer.py}"
if [ ! -f "$AI_LOG_WRITER" ] && [ -f "$PWD/scripts/ai-log-writer.py" ]; then
    AI_LOG_WRITER="$PWD/scripts/ai-log-writer.py"
fi

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

redact_stream() {
    if [ ! -f "$REDACTION_HELPER" ]; then
        printf '%s: Redaction helper not found: %s\n' "$(date)" "$REDACTION_HELPER" >> "$SYNC_LOG"
        return 1
    fi
    REDACTION_AUDIT_LOG="$SYNC_LOG" python3 "$REDACTION_HELPER"
}

redact_value() {
    printf '%s' "$1" | redact_stream
}

ai_log_writer() {
    if [ ! -f "$AI_LOG_WRITER" ]; then
        printf '%s: AI log writer not found: %s\n' "$(date)" "$AI_LOG_WRITER" >> "$SYNC_LOG"
        return 1
    fi
    REDACTION_AUDIT_LOG="$SYNC_LOG" REDACTION_HELPER="$REDACTION_HELPER" python3 "$AI_LOG_WRITER" "$@"
}

ai_log_session_name() {
    python3 -c "
import re, sys
name = re.sub(r'[^A-Za-z0-9_.:-]+', '-', sys.argv[1]).strip('-') or 'session'
print(name[:180])
" "$1"
}

ai_log_month() {
    printf '%s' "${1%-??}"
}

file_sha256() {
    local file="$1"
    printf 'sha256:%s' "$(shasum -a 256 "$file" | awk '{print $1}')"
}

frontmatter_value() {
    local file="$1"
    local key="$2"
    python3 - "$file" "$key" <<'PY'
import json
import sys

path, target_key = sys.argv[1:3]
try:
    lines = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    sys.exit(1)
if not lines or lines[0] != "---":
    sys.exit(1)
for line in lines[1:]:
    if line == "---":
        break
    if not line.startswith(target_key + ":"):
        continue
    raw = line.split(":", 1)[1].strip()
    if raw.startswith('"') and raw.endswith('"'):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            value = raw[1:-1]
    else:
        value = raw.strip("'")
    print(value)
    sys.exit(0)
sys.exit(1)
PY
}

rewrite_raw_classification() {
    local file="$1"
    local record_kind="$2"
    local automation_id="$3"
    local classification_rule="$4"
    python3 - "$file" "$record_kind" "$automation_id" "$classification_rule" <<'PY'
import json
import os
import sys
import tempfile

path, record_kind, automation_id, classification_rule = sys.argv[1:5]
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    lines = handle.readlines()
if not lines or lines[0].rstrip("\n") != "---":
    raise SystemExit(1)

values = {
    "record_kind": json.dumps(record_kind, ensure_ascii=False),
    "automation_id": json.dumps(automation_id, ensure_ascii=False) if automation_id else None,
    "classification_rule": json.dumps(classification_rule, ensure_ascii=False) if classification_rule else None,
}
result = [lines[0]]
seen = set()
closed = False
for line in lines[1:]:
    if not closed and line.rstrip("\n") == "---":
        for key in ("record_kind", "automation_id", "classification_rule"):
            if key not in seen and values[key] is not None:
                result.append(f"{key}: {values[key]}\n")
        result.append(line)
        closed = True
        continue
    if not closed and ":" in line:
        key = line.split(":", 1)[0].strip()
        if key in values:
            seen.add(key)
            if values[key] is not None:
                result.append(f"{key}: {values[key]}\n")
            continue
    result.append(line)
if not closed:
    raise SystemExit(1)

directory = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".classification.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(result)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, path)
    dir_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PY
}

derived_path_for_raw() {
    local raw_file="$1"
    local record_kind="$2"
    python3 - "$OBSIDIAN_DIR" "$raw_file" "$record_kind" <<'PY'
import os
import sys

root, raw_file, record_kind = sys.argv[1:4]
relative = os.path.relpath(os.path.realpath(raw_file), os.path.realpath(root)).replace(os.sep, "/")
if not relative.startswith("AI-Logs/raw/") or not relative.endswith(".md"):
    raise SystemExit(1)
view_root = "AI-Logs/automation" if record_kind == "automation" else "AI-Logs/readable"
print(os.path.join(root, *(view_root + relative[len("AI-Logs/raw"):]).split("/")))
PY
}

is_matching_derived_view() {
    local view_file="$1"
    local raw_file="$2"
    local session_id="$3"
    local expected_raw_hash="$4"
    [ -f "$view_file" ] && [ ! -L "$view_file" ] || return 1
    [ "$(frontmatter_value "$view_file" raw_session_id 2>/dev/null || true)" = "$session_id" ] || return 1
    [ "$(frontmatter_value "$view_file" raw_hash 2>/dev/null || true)" = "$expected_raw_hash" ] || return 1
    local expected_ref
    expected_ref=$(python3 - "$OBSIDIAN_DIR" "$raw_file" <<'PY'
import os
import sys
relative = os.path.relpath(os.path.realpath(sys.argv[2]), os.path.realpath(sys.argv[1])).replace(os.sep, "/")
print(f"[[{relative[:-3]}]]" if relative.endswith(".md") else f"[[{relative}]]")
PY
)
    [ "$(frontmatter_value "$view_file" raw_ref 2>/dev/null || true)" = "$expected_ref" ]
}

is_identity_derived_view() {
    local view_file="$1"
    local raw_file="$2"
    local session_id="$3"
    [ -f "$view_file" ] && [ ! -L "$view_file" ] || return 1
    [ "$(frontmatter_value "$view_file" raw_session_id 2>/dev/null || true)" = "$session_id" ] || return 1
    local expected_ref
    expected_ref=$(python3 - "$OBSIDIAN_DIR" "$raw_file" <<'PY'
import os
import sys
relative = os.path.relpath(os.path.realpath(sys.argv[2]), os.path.realpath(sys.argv[1])).replace(os.sep, "/")
print(f"[[{relative[:-3]}]]" if relative.endswith(".md") else f"[[{relative}]]")
PY
)
    [ "$(frontmatter_value "$view_file" raw_ref 2>/dev/null || true)" = "$expected_ref" ]
}

retire_derived_view() {
    local view_file="$1"
    local session_id="$2"
    local old_record_kind="$3"
    python3 - "$view_file" "$AI_SECOND_BRAIN_STATE_DIR" "$session_id" "$old_record_kind" <<'PY'
import hashlib
import os
import re
import sys
import tempfile

source, state_root, session_id, old_record_kind = sys.argv[1:5]
safe_session = re.sub(r"[^A-Za-z0-9_.:-]+", "-", session_id).strip("-") or "session"
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(source, flags)
try:
    before = os.fstat(fd)
    chunks = []
    while chunk := os.read(fd, 1024 * 1024):
        chunks.append(chunk)
    after = os.fstat(fd)
finally:
    os.close(fd)
identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
if identity_before != identity_after:
    raise SystemExit("derived view changed while being backed up")
data = b"".join(chunks)
digest = hashlib.sha256(data).hexdigest()
backup_dir = os.path.join(state_root, "reclassified-derived", safe_session)
os.makedirs(backup_dir, mode=0o700, exist_ok=True)
destination = os.path.join(backup_dir, f"{old_record_kind}-{digest}.md")
if os.path.exists(destination):
    with open(destination, "rb") as handle:
        if hashlib.sha256(handle.read()).hexdigest() != digest:
            raise SystemExit("existing backup hash mismatch")
else:
    out_fd, tmp_path = tempfile.mkstemp(dir=backup_dir, prefix=".retire.")
    try:
        with os.fdopen(out_fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, destination)
        dir_fd = os.open(backup_dir, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
with open(destination, "rb") as handle:
    if hashlib.sha256(handle.read()).hexdigest() != digest:
        raise SystemExit("backup verification failed")
current = os.stat(source, follow_symlinks=False)
current_identity = (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
if current_identity != identity_after:
    raise SystemExit("derived view changed before retirement")
os.unlink(source)
PY
}

is_ai_logs_raw_file() {
    local file="$1"
    python3 - "$OBSIDIAN_DIR" "$file" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
path = os.path.realpath(sys.argv[2])
raw_root = os.path.join(root, "AI-Logs", "raw")
sys.exit(0 if path.startswith(raw_root + os.sep) else 1)
PY
}

write_readable_log() {
    local raw_json="$1"
    local date_str="$2"
    local title="$3"
    local source_name="$4"
    local source_key="$5"
    local raw_session_id="$6"
    local record_kind="$7"
    local raw_file="$8"
    local omitted_msg_count="$9"
    local automation_id="${10:-}"
    local classification_rule="${11:-}"

    local readable_dir readable_file raw_ref raw_hash tmp_readable readable_meta
    readable_meta=$(python3 - "$OBSIDIAN_DIR" "$raw_file" "$source_key" "$date_str" "$record_kind" <<'PY'
import os
import sys

root, raw_file, source_key, date_str, record_kind = sys.argv[1:6]
root_real = os.path.realpath(root)
raw_real = os.path.realpath(raw_file)
try:
    rel = os.path.relpath(raw_real, root_real).replace(os.sep, "/")
except ValueError:
    rel = ""
if rel.startswith("AI-Logs/raw/") and rel.endswith(".md"):
    raw_stem = rel[:-3]
    view_root = "AI-Logs/automation" if record_kind == "automation" else "AI-Logs/readable"
    readable_rel = view_root + "/" + raw_stem[len("AI-Logs/raw/"):] + ".md"
else:
    session_name = os.path.basename(raw_file[:-3] if raw_file.endswith(".md") else raw_file)
    month = date_str.rsplit("-", 1)[0]
    raw_stem = f"AI-Logs/raw/{source_key}/{month}/{session_name}"
    view_root = "AI-Logs/automation" if record_kind == "automation" else "AI-Logs/readable"
    readable_rel = f"{view_root}/{source_key}/{month}/{session_name}.md"
print(f"[[{raw_stem}]]")
print(os.path.join(root, *readable_rel.split("/")))
PY
)
    raw_ref=$(printf '%s\n' "$readable_meta" | sed -n '1p')
    readable_file=$(printf '%s\n' "$readable_meta" | sed -n '2p')
    readable_dir="$(dirname "$readable_file")"
    raw_hash=$(file_sha256 "$raw_file")

    mkdir -p "$readable_dir"
    tmp_readable=$(mktemp "$readable_dir/.tmp.XXXXXX") || return 1
    if ! printf '%s' "$raw_json" | ai_log_writer readable \
        --date="$date_str" \
        --title="$title" \
        --source="$source_name" \
        --raw-session-id="$raw_session_id" \
        --raw-ref="$raw_ref" \
        --raw-hash="$raw_hash" \
        --record-kind="$record_kind" \
        --automation-id="$automation_id" \
        --classification-rule="$classification_rule" \
        --omitted-msg-count=0 \
        --tag="$source_key" > "$tmp_readable"; then
        rm -f "$tmp_readable" 2>/dev/null || true
        return 1
    fi
    mv -f "$tmp_readable" "$readable_file"
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
            if [[ "$real_cached" == "$real_target/"* ]] && [[ "$real_cached" != "$real_target/AI-Logs/readable/"* ]]; then
                printf '%s' "$cached_path"
                return 0
            fi
        fi
    fi

    # 2. フォールバック: raw/raw-archiveを優先し、readableは検索しない
    python3 -c "
import os, sys

sid = sys.argv[1]
target_dir = sys.argv[2]
# 引用符あり/なし両方にマッチ (recall側は quoted, codex側は unquoted)
target_lines = {'session_id: ' + sid, 'session_id: \"' + sid + '\"'}
real_dir = os.path.realpath(target_dir)
search_roots = [
    (os.path.join(target_dir, 'AI-Logs', 'raw'), True),
    (os.path.join(target_dir, 'AI-Logs', 'raw-archive'), True),
    (target_dir, False),
]
seen = set()

def iter_markdown(root, recursive):
    if not os.path.isdir(root) or os.path.islink(root):
        return
    root_real = os.path.realpath(root)
    if not recursive:
        try:
            names = os.listdir(root)
        except OSError:
            return
        for fname in names:
            if not fname.endswith('.md'):
                continue
            fpath = os.path.join(root, fname)
            real_path = os.path.realpath(fpath)
            if real_path in seen:
                continue
            seen.add(real_path)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            yield fpath
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            dirname
            for dirname in dirnames
            if not os.path.islink(os.path.join(dirpath, dirname))
            and os.path.realpath(os.path.join(dirpath, dirname)) != os.path.join(real_dir, 'AI-Logs', 'readable')
        ]
        for fname in filenames:
            if not fname.endswith('.md'):
                continue
            fpath = os.path.join(dirpath, fname)
            real_path = os.path.realpath(fpath)
            if real_path in seen:
                continue
            seen.add(real_path)
            if os.path.islink(fpath):
                continue
            if not real_path.startswith(root_real + os.sep) and real_path != root_real:
                continue
            yield fpath

for root, recursive in search_roots:
    for fpath in iter_markdown(root, recursive):
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
        if root == target_dir:
            # Legacy compatibility: root direct children were the old storage surface.
            # Nested generated views are intentionally not used for session lookup.
            pass
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

is_shared_ai_log_record() {
    local filepath="$1"
    python3 -c "
import sys

required = {'msg_count', 'last_message_hash', 'transcript_hash'}

try:
    lines = open(sys.argv[1], 'r', encoding='utf-8', errors='replace').read().splitlines()
except (OSError, UnicodeDecodeError):
    sys.exit(1)

if not lines or lines[0] != '---':
    sys.exit(1)

frontmatter_keys = set()
frontmatter_end = None
for idx, line in enumerate(lines[1:], start=1):
    if line == '---':
        frontmatter_end = idx
        break
    if ':' in line:
        frontmatter_keys.add(line.split(':', 1)[0].strip())

if frontmatter_end is None or not required.issubset(frontmatter_keys):
    sys.exit(1)

if any(line.strip() == '## Transcript' for line in lines[frontmatter_end + 1:]):
    sys.exit(0)
sys.exit(1)
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
    if msg.get('omitted'):
        continue
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
	" "$start_index" "$start_q" "$start_a" | redact_stream
}

legacy_aligned_skip_count() {
    local messages_json="$1"
    local existing_file="$2"
    local fallback_skip="${3:-0}"

    printf '%s' "$messages_json" | python3 -c "
import json
import re
import sys

existing_path = sys.argv[1]
fallback = int(sys.argv[2])


def normalize(text):
    text = text.replace('\r\n', '\n').replace('\r', '\n').strip()
    return '\n'.join(line.rstrip() for line in text.split('\n'))


def message_text(message):
    value = message.get('text', message.get('content', ''))
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, dict):
                parts.append(str(item.get('text', '')))
            elif isinstance(item, str):
                parts.append(item)
        return '\n'.join(parts)
    if isinstance(value, str):
        return value
    return str(value)


def legacy_sections(path):
    sections = []
    current = None
    body = []
    in_code = False
    fence = chr(96) * 3
    try:
        lines = open(path, 'r', encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return []
    for line in lines:
        if line.startswith(fence):
            in_code = not in_code
        if not in_code and re.match(r'^## [QA][0-9]+$', line.strip()):
            if current is not None:
                sections.append(normalize('\n'.join(body)))
            current = line.strip()
            body = []
            continue
        if current is not None:
            body.append(line)
    if current is not None:
        sections.append(normalize('\n'.join(body)))
    return [section for section in sections if section]


try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print(fallback)
    sys.exit(0)

messages = data.get('messages', data) if isinstance(data, dict) else data
if not isinstance(messages, list):
    print(fallback)
    sys.exit(0)

targets = legacy_sections(existing_path)
if not targets:
    print(fallback)
    sys.exit(0)

matched = 0
for index, message in enumerate(messages):
    if not isinstance(message, dict) or message.get('omitted'):
        continue
    if message.get('role') not in ('user', 'assistant'):
        continue
    if matched < len(targets) and normalize(message_text(message)) == targets[matched]:
        matched += 1
        if matched == len(targets):
            print(max(index + 1, fallback))
            sys.exit(0)

print(fallback)
" "$existing_file" "$fallback_skip"
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
    local extract_result raw_extract_result filtered_extract_result
    if ! extract_result=$(extract_messages "$jsonl_file"); then
        printf '%s: extract_messages failed for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi
    if [ -z "$extract_result" ]; then
        return 0
    fi
    raw_extract_result="$extract_result"

    local classification detected_record_kind automation_id classification_rule
    if ! classification=$(printf '%s' "$raw_extract_result" | ai_log_writer classify); then
        printf '%s: session classification failed for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi
    detected_record_kind=$(printf '%s' "$classification" | jq -r '.record_kind // "interactive"')
    automation_id=$(printf '%s' "$classification" | jq -r '.automation_id // empty')
    classification_rule=$(printf '%s' "$classification" | jq -r '.classification_rule // empty')

    local session_record_kind
    session_record_kind="${RECORD_KIND:-$detected_record_kind}"
    if [ "$session_record_kind" != "automation" ]; then
        automation_id=""
        classification_rule=""
    fi

    if ! filtered_extract_result=$(printf '%s' "$raw_extract_result" | ai_log_writer filter); then
        printf '%s: ai-log noise filter failed for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi

    local omitted_msg_count
    omitted_msg_count=$(printf '%s' "$filtered_extract_result" | jq -r '.omitted_count // 0')
    if ! [[ "$omitted_msg_count" =~ ^[0-9]+$ ]]; then
        printf '%s: Invalid omitted message count for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi

    local raw_msg_count msg_count
    raw_msg_count=$(printf '%s' "$raw_extract_result" | jq -r '.count')
    msg_count=$(printf '%s' "$filtered_extract_result" | jq -r '.count')
    if ! [[ "$raw_msg_count" =~ ^[0-9]+$ ]] || ! [[ "$msg_count" =~ ^[0-9]+$ ]]; then
        printf '%s: Invalid message count for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
        return 1
    fi

    local messages_json
    messages_json=$(printf '%s' "$filtered_extract_result" | jq -c '.messages')

    # フロントマター範囲限定で既存ファイルを検索
    local existing_file=""
    if ! existing_file=$(find_existing_by_sid "$sid" "$OBSIDIAN_DIR"); then
        printf '%s: find_existing_by_sid failed for sid=%s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    fi

    if [ -z "$existing_file" ] && [ "$raw_msg_count" -eq 0 ]; then
        return 0
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

        if is_shared_ai_log_record "$existing_file"; then
            local existing_title existing_record_kind existing_automation_id existing_classification_rule
            local classification_changed=0 is_raw_record=0 old_raw_hash="" current_view="" current_view_valid=0
            local stale_view="" stale_view_verified=0 stale_record_kind=""
            existing_title=$(frontmatter_value "$existing_file" title 2>/dev/null || printf 'untitled')
            existing_record_kind=$(frontmatter_value "$existing_file" record_kind 2>/dev/null || printf 'interactive')
            existing_automation_id=$(frontmatter_value "$existing_file" automation_id 2>/dev/null || true)
            existing_classification_rule=$(frontmatter_value "$existing_file" classification_rule 2>/dev/null || true)
            if is_ai_logs_raw_file "$existing_file"; then
                is_raw_record=1
                old_raw_hash=$(file_sha256 "$existing_file")
                if [ "$existing_record_kind" != "$session_record_kind" ] \
                    || [ "$existing_automation_id" != "$automation_id" ] \
                    || [ "$existing_classification_rule" != "$classification_rule" ]; then
                    classification_changed=1
                fi
                current_view=$(derived_path_for_raw "$existing_file" "$session_record_kind" || true)
                if [ -n "$current_view" ] && is_matching_derived_view "$current_view" "$existing_file" "$sid" "$old_raw_hash"; then
                    current_view_valid=1
                fi
                if [ "$session_record_kind" = "automation" ]; then
                    stale_record_kind="interactive"
                else
                    stale_record_kind="automation"
                fi
                stale_view=$(derived_path_for_raw "$existing_file" "$stale_record_kind" || true)
                if [ -n "$stale_view" ] && is_identity_derived_view "$stale_view" "$existing_file" "$sid"; then
                    stale_view_verified=1
                fi
            fi

            if [ "$msg_count" -le "$existing_msg_count" ] \
                && [ "$raw_msg_count" -le "$existing_msg_count" ] \
                && [ "$classification_changed" -eq 0 ]; then
                if [ "$is_raw_record" -eq 0 ] || { [ "$current_view_valid" -eq 1 ] && [ ! -e "$stale_view" ]; }; then
                    return 0
                fi
            fi

            if [ "$msg_count" -gt "$existing_msg_count" ] || [ "$raw_msg_count" -gt "$existing_msg_count" ]; then
                tmp_file=$(mktemp "$OBSIDIAN_DIR/.tmp_update.XXXXXX") || return 1
                if ! printf '%s' "$raw_extract_result" | ai_log_writer append \
                    --existing-file "$existing_file" > "$tmp_file"; then
                    printf '%s: Shared append failed for %s\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
                    return 1
                fi
                if cmp -s "$existing_file" "$tmp_file"; then
                    rm -f "$tmp_file" 2>/dev/null || true
                    tmp_file=""
                else
                    if ! mv -f "$tmp_file" "$existing_file"; then
                        printf '%s: Failed to move updated file for %s\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
                        return 1
                    fi
                    tmp_file=""
                    printf '%s: Appended to %s (%s -> %s)\n' "$(date)" "$existing_file" "$existing_msg_count" "$raw_msg_count" >> "$SYNC_LOG"
                fi
            fi

            if [ "$is_raw_record" -eq 1 ]; then
                if [ "$classification_changed" -eq 1 ] \
                    && ! rewrite_raw_classification "$existing_file" "$session_record_kind" "$automation_id" "$classification_rule"; then
                    printf '%s: Failed to reclassify raw log %s\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
                    return 1
                fi
                if ! write_readable_log "$raw_extract_result" "$date_str" "$existing_title" "Codex" "codex" "$sid" "$session_record_kind" "$existing_file" "$omitted_msg_count" "$automation_id" "$classification_rule"; then
                    printf '%s: Failed to update readable log for %s\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
                    return 1
                fi
                if [ "$stale_view_verified" -eq 1 ]; then
                    if ! retire_derived_view "$stale_view" "$sid" "$stale_record_kind"; then
                        printf '%s: Failed to back up stale derived view %s\n' "$(date)" "$stale_view" >> "$SYNC_LOG"
                        return 1
                    fi
                elif [ -n "$stale_view" ] && [ -e "$stale_view" ]; then
                    printf '%s: Refusing to retire unverified stale derived view %s\n' "$(date)" "$stale_view" >> "$SYNC_LOG"
                    return 1
                fi
            fi
            return 0
        fi

        local legacy_messages_json="$messages_json"
        local legacy_new_msg_count="$msg_count"
        local legacy_skip_count="$existing_msg_count"
        if [ "$raw_msg_count" -ne "$msg_count" ]; then
            if [ "$raw_msg_count" -le "$existing_msg_count" ]; then
                return 0
            fi
            local indexed_extract_result
            if ! indexed_extract_result=$(printf '%s' "$raw_extract_result" | ai_log_writer filter --include-omitted); then
                printf '%s: ai-log indexed noise filter failed for %s\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
                return 1
            fi
            legacy_messages_json=$(printf '%s' "$indexed_extract_result" | jq -c '.messages')
            legacy_new_msg_count="$raw_msg_count"
            legacy_skip_count=$(legacy_aligned_skip_count "$legacy_messages_json" "$existing_file" "$existing_msg_count")
        elif [ "$msg_count" -le "$existing_msg_count" ]; then
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
        format_messages_as_markdown "$legacy_messages_json" "$legacy_skip_count" "$q_count" "$a_count" > "$append_tmp"

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
" "$existing_file" "$legacy_new_msg_count" "$append_tmp"; then
                printf '%s: atomic update failed for %s\n' "$(date)" "$existing_file" >> "$SYNC_LOG"
                return 1
            fi
            rm -f "$append_tmp" 2>/dev/null
            append_tmp=""
            printf '%s: Appended to %s (%s -> %s)\n' "$(date)" "$existing_file" "$existing_msg_count" "$legacy_new_msg_count" >> "$SYNC_LOG"
        else
            rm -f "$append_tmp" 2>/dev/null
            append_tmp=""
        fi
        return 0
    fi

    # --- 新規作成 ---

    # タイトル: ユーザーメッセージから意味のある内容を抽出
    local raw_title title
    raw_title=$(printf '%s' "$messages_json" | python3 -c "
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
    if ! title=$(redact_value "$raw_title"); then
        printf '%s: Failed to redact title for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    fi

    local record_kind
    record_kind="$session_record_kind"

    local source_key month session_name raw_dir filename filepath readable_dir
    source_key="codex"
    month=$(ai_log_month "$date_str")
    session_name=$(ai_log_session_name "$sid")
    raw_dir="$OBSIDIAN_DIR/AI-Logs/raw/$source_key/$month"
    readable_dir="$OBSIDIAN_DIR/AI-Logs/readable/$source_key/$month"
    filename="$session_name.md"
    filepath="$raw_dir/$filename"
    mkdir -p "$raw_dir" "$readable_dir"

    tmp_file=$(mktemp "$raw_dir/.tmp.XXXXXX") || {
        printf '%s: Failed to create temp file for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    }

    if ! printf '%s' "$raw_extract_result" | ai_log_writer create \
        --date="$date_str" \
        --title="$title" \
        --source="Codex" \
        --session-id="$sid" \
        --record-kind="$record_kind" \
        --automation-id="$automation_id" \
        --classification-rule="$classification_rule" \
        --preserve-all \
        --omitted-msg-count=0 \
        --tag="codex" > "$tmp_file"; then
        printf '%s: Failed to write temp file for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    fi

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
" "$raw_dir"

    if ! write_readable_log "$raw_extract_result" "$date_str" "$title" "Codex" "$source_key" "$sid" "$record_kind" "$filepath" "$omitted_msg_count" "$automation_id" "$classification_rule"; then
        printf '%s: Failed to write readable file for session %s\n' "$(date)" "$sid" >> "$SYNC_LOG"
        return 1
    fi

    update_sid_index "$sid" "$filepath"
    printf '%s: Created %s -> %s\n' "$(date)" "$sid" "$filepath" >> "$SYNC_LOG"
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
    exit "$SYNC_BUSY_EXIT_CODE"
fi

if [ ! -d "$CODEX_SESSIONS_DIR" ]; then
    printf '%s: Codex sessions directory not found: %s\n' "$(date)" "$CODEX_SESSIONS_DIR" >> "$SYNC_LOG"
    if [ -n "$TARGET_JSONL" ]; then
        exit 1
    fi
    exit 0
fi

sync_fail=0
if [ -n "$TARGET_JSONL" ]; then
    if [ -L "$TARGET_JSONL" ] || [ ! -f "$TARGET_JSONL" ]; then
        printf '%s: Codex session file not found or is symlink: %s\n' "$(date)" "$TARGET_JSONL" >> "$SYNC_LOG"
        exit 1
    fi

    if ! python3 - "$CODEX_SESSIONS_DIR" "$TARGET_JSONL" <<'PY'
import os
import sys

sessions_dir = os.path.realpath(sys.argv[1])
target = os.path.realpath(sys.argv[2])
if target.startswith(sessions_dir + os.sep):
    sys.exit(0)
sys.exit(1)
PY
    then
        printf '%s: Codex session file is outside CODEX_SESSIONS_DIR: %s\n' "$(date)" "$TARGET_JSONL" >> "$SYNC_LOG"
        exit 1
    fi

    sync_session_file "$TARGET_JSONL" || {
        printf '%s: Failed to sync %s\n' "$(date)" "$TARGET_JSONL" >> "$SYNC_LOG"
        sync_fail=1
    }
else
    while IFS= read -r -d '' jsonl_file; do
        sync_session_file "$jsonl_file" || {
            printf '%s: Failed to sync %s (continuing)\n' "$(date)" "$jsonl_file" >> "$SYNC_LOG"
            sync_fail=$((sync_fail + 1))
        }
    done < <(find "$CODEX_SESSIONS_DIR" -name "rollout-*.jsonl" -type f -print0)
fi

if [ "$sync_fail" -gt 0 ]; then
    printf '%s: Codex sync completed with %d failures\n' "$(date)" "$sync_fail" >> "$SYNC_LOG"
    if [ -n "$TARGET_JSONL" ]; then
        exit 1
    fi
else
    printf '%s: Codex sync completed\n' "$(date)" >> "$SYNC_LOG"
fi
