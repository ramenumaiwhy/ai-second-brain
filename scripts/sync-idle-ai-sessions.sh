#!/bin/bash
# Sync sessions that have been idle since their last lightweight checkpoint.

set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${AI_SECOND_BRAIN_STATE_DIR:-$HOME/.claude/ai-second-brain-state}"
STATE_FILE="$STATE_DIR/idle-checkpoints.json"
SYNC_LOG="${AI_IDLE_SYNC_LOG:-$HOME/.claude/ai-second-brain-idle-sync.log}"
LOCK_DIR="$STATE_DIR/idle-sync.lock"
STATE_LOCK_DIR="$STATE_DIR/state.lock"
IDLE_MIN_AGE_SECONDS="${AI_IDLE_MIN_AGE_SECONDS:-900}"
IDLE_MAX_SESSIONS="${AI_IDLE_MAX_SESSIONS:-20}"
SYNC_RECALL_SCRIPT="${SYNC_RECALL_SCRIPT:-$SCRIPT_DIR/sync-recall-to-obsidian.sh}"
SYNC_CODEX_SCRIPT="${SYNC_CODEX_SCRIPT:-$SCRIPT_DIR/sync-codex-to-obsidian.sh}"

if [[ ! "$IDLE_MIN_AGE_SECONDS" =~ ^[0-9]+$ ]] || [[ ! "$IDLE_MAX_SESSIONS" =~ ^[0-9]+$ ]]; then
    printf 'AI_IDLE_MIN_AGE_SECONDS and AI_IDLE_MAX_SESSIONS must be integers\n' >&2
    exit 2
fi

mkdir -p "$STATE_DIR" "$(dirname "$SYNC_LOG")"

log_line() {
    printf '%s: %s\n' "$(date)" "$*" >> "$SYNC_LOG"
}

write_pid_file() {
    local my_lstart
    my_lstart=$(ps -p "$$" -o lstart= 2>/dev/null || true)
    if [ -z "$my_lstart" ]; then
        my_lstart="unknown"
    fi
    printf '%s:%s\n' "$$" "$my_lstart" > "$LOCK_DIR/pid"
}

lock_info() {
    if [ -f "$LOCK_DIR/pid" ]; then
        head -n 1 "$LOCK_DIR/pid" 2>/dev/null || true
    fi
}

lock_pid() {
    local info
    info=$(lock_info)
    printf '%s' "${info%%:*}"
}

lock_lstart() {
    local info
    info=$(lock_info)
    if [[ "$info" == *:* ]]; then
        printf '%s' "${info#*:}"
    fi
}

pid_matches_lstart() {
    local pid="$1" expected_lstart="$2" current_lstart
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -n "$expected_lstart" ] && [ "$expected_lstart" != "unknown" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    current_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null || true)
    [ -n "$current_lstart" ] && [ "$current_lstart" = "$expected_lstart" ]
}

release_lock() {
    if [ "$(lock_pid)" = "$$" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}

write_state_lock_pid() {
    printf '%s\n' "$$" > "$STATE_LOCK_DIR/pid"
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_pid_file
        trap release_lock EXIT
        return 0
    fi

    if [ ! -d "$LOCK_DIR" ]; then
        return 1
    fi

    local lock_age
    lock_age=$(python3 - "$LOCK_DIR" <<'PY'
import os
import sys
import time

try:
    print(int(time.time() - os.path.getmtime(sys.argv[1])))
except OSError:
    print(0)
PY
)
    if [ "$lock_age" -le 300 ]; then
        return 1
    fi

    local pid
    pid=$(lock_pid)
    if pid_matches_lstart "$pid" "$(lock_lstart)"; then
        return 1
    fi

    if rm -rf "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
        write_pid_file
        trap release_lock EXIT
        return 0
    fi
    return 1
}

acquire_state_lock() {
    local attempts=0 lock_age
    while [ "$attempts" -lt 50 ]; do
        if mkdir "$STATE_LOCK_DIR" 2>/dev/null; then
            write_state_lock_pid
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

read_due_sessions() {
    python3 - "$STATE_FILE" "$IDLE_MIN_AGE_SECONDS" "$IDLE_MAX_SESSIONS" <<'PY'
from __future__ import annotations

import json
import sys
import time

state_file = sys.argv[1]
min_age = int(sys.argv[2])
max_sessions = int(sys.argv[3])

try:
    with open(state_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    sys.exit(0)

sessions = data.get("sessions", {})
if not isinstance(sessions, dict):
    sys.exit(0)

now = int(time.time())
due: list[tuple[int, int, int, str, str, str]] = []
for key, entry in sessions.items():
    if not isinstance(entry, dict):
        continue
    source = str(entry.get("source", ""))
    session_id = str(entry.get("session_id", ""))
    jsonl_path = str(entry.get("jsonl_path", ""))
    if "\t" in source or "\t" in session_id or "\t" in jsonl_path:
        continue
    try:
        updated_at = int(entry.get("updated_at", 0))
        synced_at = int(entry.get("synced_at", 0))
        last_failed_at = int(entry.get("last_failed_at", 0))
    except (TypeError, ValueError):
        continue
    if source not in {"claude", "codex"} or not session_id:
        continue
    if updated_at <= 0 or synced_at >= updated_at:
        continue
    if now - updated_at >= min_age:
        failed_group = 1 if last_failed_at > 0 else 0
        retry_order = last_failed_at if last_failed_at > 0 else updated_at
        due.append((failed_group, retry_order, updated_at, source, session_id, jsonl_path))

due.sort()
for _failed_group, _retry_order, updated_at, source, session_id, jsonl_path in due[:max_sessions]:
    print(f"{updated_at}\t{source}\t{session_id}\t{jsonl_path}")
PY
}

mark_checkpoint() {
    local expected_updated_at="$1"
    shift
    local source_name="$1"
    local session_id="$2"
    local status="$3"
    local message="${4:-}"

    if ! acquire_state_lock; then
        log_line "Could not acquire checkpoint state lock for $source_name:$session_id"
        return 1
    fi

    local rc
    if python3 - "$STATE_FILE" "$expected_updated_at" "$source_name" "$session_id" "$status" "$message" <<'PY'
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import tempfile
import time

state_file, expected_updated_at, source, session_id, status, message = sys.argv[1:7]
key = f"{source}:{session_id}"
expected_updated_at_int = int(expected_updated_at)

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

entry = sessions.get(key)
if not isinstance(entry, dict):
    sys.exit(0)
try:
    current_updated_at = int(entry.get("updated_at", 0))
except (TypeError, ValueError):
    current_updated_at = 0
if current_updated_at != expected_updated_at_int:
    sys.exit(0)

now = int(time.time())
if status == "synced":
    sessions.pop(key, None)
else:
    entry[f"last_{status}_at"] = now
    entry[f"last_{status}_at_iso"] = dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat().replace("+00:00", "Z")
    if message:
        entry[f"last_{status}"] = message[:200]
    if status == "skipped":
        try:
            entry["synced_at"] = int(entry.get("updated_at", now))
        except (TypeError, ValueError):
            entry["synced_at"] = now
    sessions[key] = entry

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
    then
        rc=0
    else
        rc=$?
    fi
    rm -rf "$STATE_LOCK_DIR" 2>/dev/null || true
    return "$rc"
}

if ! acquire_lock; then
    log_line "Could not acquire idle sync lock"
    exit 0
fi

processed=0
failed=0
skipped=0

while IFS=$'\t' read -r expected_updated_at source_name session_id jsonl_path; do
    [ -n "$expected_updated_at" ] || continue

    case "$source_name" in
        claude)
            if SYNC_BUSY_EXIT_CODE=75 "$SYNC_RECALL_SCRIPT" "$session_id"; then
                mark_checkpoint "$expected_updated_at" "$source_name" "$session_id" synced
                processed=$((processed + 1))
            else
                mark_checkpoint "$expected_updated_at" "$source_name" "$session_id" failed "sync-recall failed"
                failed=$((failed + 1))
            fi
            ;;
        codex)
            if [ -z "$jsonl_path" ]; then
                mark_checkpoint "$expected_updated_at" "$source_name" "$session_id" failed "codex checkpoint has no jsonl_path"
                failed=$((failed + 1))
                continue
            fi
            if SYNC_BUSY_EXIT_CODE=75 "$SYNC_CODEX_SCRIPT" "$jsonl_path"; then
                mark_checkpoint "$expected_updated_at" "$source_name" "$session_id" synced
                processed=$((processed + 1))
            else
                mark_checkpoint "$expected_updated_at" "$source_name" "$session_id" failed "sync-codex failed"
                failed=$((failed + 1))
            fi
            ;;
        *)
            mark_checkpoint "$expected_updated_at" "$source_name" "$session_id" skipped "unknown source"
            skipped=$((skipped + 1))
            ;;
    esac
done < <(read_due_sessions)

log_line "Idle sync completed (processed: $processed, skipped: $skipped, failures: $failed)"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
