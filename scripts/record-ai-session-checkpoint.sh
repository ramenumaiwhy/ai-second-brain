#!/bin/bash
# Lightweight checkpoint writer for AI session Stop hooks.

set -euo pipefail

umask 077

STATE_DIR="${AI_SECOND_BRAIN_STATE_DIR:-$HOME/.claude/ai-second-brain-state}"
STATE_FILE="$STATE_DIR/idle-checkpoints.json"
STATE_LOCK_DIR="$STATE_DIR/state.lock"

source_name="${AI_SESSION_SOURCE:-}"
session_id="${AI_SESSION_ID:-${SESSION_ID:-}}"
jsonl_path="${AI_SESSION_JSONL_PATH:-}"

usage() {
    printf 'Usage: %s --source claude|codex --session-id SESSION_ID [--path JSONL_PATH]\n' "$(basename "$0")" >&2
}

write_lock_pid() {
    printf '%s\n' "$$" > "$STATE_LOCK_DIR/pid"
}

acquire_state_lock() {
    local attempts=0 lock_age
    while [ "$attempts" -lt 50 ]; do
        if mkdir "$STATE_LOCK_DIR" 2>/dev/null; then
            write_lock_pid
            trap 'rm -rf "$STATE_LOCK_DIR"' EXIT
            return 0
        fi
        if [ -d "$STATE_LOCK_DIR" ]; then
            lock_age=$(python3 - "$STATE_LOCK_DIR" <<'PY'
import os
import sys
import time

try:
    print(int(time.time() - os.path.getmtime(sys.argv[1])))
except OSError:
    print(0)
PY
)
            if [ "$lock_age" -gt 300 ]; then
                rm -rf "$STATE_LOCK_DIR" 2>/dev/null || true
            fi
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            source_name="$2"
            shift 2
            ;;
        --session-id)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            session_id="$2"
            shift 2
            ;;
        --path)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            jsonl_path="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if { [ -z "$session_id" ] || [ -z "$jsonl_path" ]; } && [ ! -t 0 ]; then
    hook_json=$(cat)
    if [ -n "$hook_json" ]; then
        hook_values=$(printf '%s' "$hook_json" | python3 -c "
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    payload = {}

if isinstance(payload, dict):
    print(payload.get('session_id') or payload.get('sessionId') or '')
    print(payload.get('transcript_path') or payload.get('transcriptPath') or '')
")
        if [ -z "$session_id" ]; then
            session_id=$(printf '%s\n' "$hook_values" | sed -n '1p')
        fi
        if [ -z "$jsonl_path" ]; then
            jsonl_path=$(printf '%s\n' "$hook_values" | sed -n '2p')
        fi
    fi
fi

case "$source_name" in
    claude|codex) ;;
    *)
        usage
        exit 2
        ;;
esac

if [ -z "$session_id" ] || [[ ! "$session_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    printf 'Invalid session id\n' >&2
    exit 2
fi

if [ -n "$jsonl_path" ] && { [ -L "$jsonl_path" ] || [ ! -f "$jsonl_path" ]; }; then
    printf 'Invalid JSONL path: %s\n' "$jsonl_path" >&2
    exit 2
fi

if [ "$source_name" = "claude" ] && [ -n "$jsonl_path" ]; then
    CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    if ! python3 - "$CLAUDE_PROJECTS_DIR" "$jsonl_path" "$session_id" <<'PY'
import json
import os
import sys

root_arg, path_arg, expected_session_id = sys.argv[1:4]
if os.path.islink(root_arg) or not os.path.isdir(root_arg):
    sys.exit(1)
root = os.path.realpath(root_arg)
path = os.path.realpath(path_arg)
try:
    if os.path.commonpath((root, path)) != root or not path.endswith(".jsonl"):
        sys.exit(1)
except ValueError:
    sys.exit(1)

found_session_ids = set()
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for index, line in enumerate(handle):
            if index >= 100:
                break
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            value = event.get("sessionId") or event.get("session_id")
            if value:
                found_session_ids.add(str(value))
except OSError:
    sys.exit(1)
if found_session_ids and found_session_ids != {expected_session_id}:
    sys.exit(1)
PY
    then
        printf 'Claude JSONL path or session metadata is invalid: %s\n' "$jsonl_path" >&2
        exit 2
    fi
fi

if [ "$source_name" = "codex" ] && [ -n "$jsonl_path" ]; then
    CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
    if ! python3 - "$CODEX_SESSIONS_DIR" "$jsonl_path" "$session_id" <<'PY'
import json
import os
import sys

root = os.path.realpath(sys.argv[1])
path = os.path.realpath(sys.argv[2])
expected_session_id = sys.argv[3]
if not path.startswith(root + os.sep) or not path.endswith(".jsonl"):
    sys.exit(1)

found_session_id = ""
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for index, line in enumerate(handle):
            if index >= 100:
                break
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") != "session_meta":
                continue
            payload = event.get("payload")
            if isinstance(payload, dict):
                found_session_id = str(payload.get("id") or "")
            break
except OSError:
    sys.exit(1)
sys.exit(0 if found_session_id == expected_session_id else 1)
PY
    then
        printf 'Codex JSONL path or session metadata is invalid: %s\n' "$jsonl_path" >&2
        exit 2
    fi
fi

mkdir -p "$STATE_DIR"

if ! acquire_state_lock; then
    printf 'Could not acquire checkpoint state lock\n' >&2
    exit 1
fi

python3 - "$STATE_FILE" "$source_name" "$session_id" "$jsonl_path" <<'PY'
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import tempfile
import time

state_file, source, session_id, jsonl_path = sys.argv[1:5]

try:
    with open(state_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    data = {}

if not isinstance(data, dict):
    data = {}

sessions = data.get("sessions")
if not isinstance(sessions, dict):
    sessions = {}

now = int(time.time())
entry = {
    "source": source,
    "session_id": session_id,
    "updated_at": now,
    "updated_at_iso": dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
}
if jsonl_path:
    entry["jsonl_path"] = os.path.realpath(jsonl_path)

sessions[f"{source}:{session_id}"] = entry
data["version"] = 1
data["sessions"] = sessions

directory = os.path.dirname(state_file)
fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".idle-checkpoints.", text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, state_file)
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
