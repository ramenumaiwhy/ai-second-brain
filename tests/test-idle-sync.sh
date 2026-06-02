#!/bin/bash
# Regression tests for lightweight Stop-hook checkpoints and idle sync.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECORD_SCRIPT="$REPO_DIR/scripts/record-ai-session-checkpoint.sh"
IDLE_SCRIPT="$REPO_DIR/scripts/sync-idle-ai-sessions.sh"
TEST_DIR=$(mktemp -d /tmp/test-idle-sync-XXXXXX)
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null
}
trap cleanup EXIT

pass() {
    printf '  PASS: %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf '  FAIL: %s\n' "$1"
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected: $expected, got: $actual)"
    fi
}

assert_file_exists() {
    local label="$1" file="$2"
    if [ -f "$file" ]; then
        pass "$label"
    else
        fail "$label (missing: $file)"
    fi
}

json_session_exists() {
    local key="$1"
    python3 - "$TEST_DIR/state/idle-checkpoints.json" "$key" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except OSError:
    sys.exit(1)
sys.exit(0 if sys.argv[2] in data.get("sessions", {}) else 1)
PY
}

json_session_count() {
    python3 - "$TEST_DIR/state/idle-checkpoints.json" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except OSError:
    print(0)
    sys.exit(0)
print(len(data.get("sessions", {})))
PY
}

assert_json_session_exists() {
    local label="$1" key="$2"
    if json_session_exists "$key"; then
        pass "$label"
    else
        fail "$label"
    fi
}

assert_json_session_missing() {
    local label="$1" key="$2"
    if json_session_exists "$key"; then
        fail "$label"
    else
        pass "$label"
    fi
}

line_count() {
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d ' '
    else
        printf '0'
    fi
}

STATE_DIR="$TEST_DIR/state"
STATE_FILE="$STATE_DIR/idle-checkpoints.json"
CALL_LOG="$TEST_DIR/sync-calls.log"
export SYNC_CALL_LOG="$CALL_LOG"

FAKE_RECALL_SYNC="$TEST_DIR/fake-recall-sync.sh"
cat > "$FAKE_RECALL_SYNC" <<'EOF'
#!/bin/bash
printf 'claude\t%s\n' "$1" >> "$SYNC_CALL_LOG"
EOF
chmod +x "$FAKE_RECALL_SYNC"

FAKE_CODEX_SYNC="$TEST_DIR/fake-codex-sync.sh"
cat > "$FAKE_CODEX_SYNC" <<'EOF'
#!/bin/bash
printf 'codex\t%s\n' "$1" >> "$SYNC_CALL_LOG"
EOF
chmod +x "$FAKE_CODEX_SYNC"

echo ""
echo "=== Checkpoint writer ==="

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id claude-session-1

assert_file_exists "state file is created" "$STATE_FILE"
assert_json_session_exists "claude checkpoint is stored" "claude:claude-session-1"
assert_eq "checkpoint writer does not call sync" "0" "$(line_count "$CALL_LOG")"

printf '{"session_id":"stdin-session-1","hook_event_name":"Stop"}' | \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id ""

assert_json_session_exists "checkpoint reads session id from hook stdin" "claude:stdin-session-1"

python3 - "$STATE_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data.get("sessions", {}).pop("claude:stdin-session-1", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
    handle.write("\n")
PY

echo ""
echo "=== Idle threshold ==="

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=999999 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_eq "fresh checkpoint is not synced" "0" "$(line_count "$CALL_LOG")"
assert_json_session_exists "fresh checkpoint stays pending" "claude:claude-session-1"

echo ""
echo "=== Due Claude checkpoint ==="

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_eq "due claude checkpoint is synced once" "1" "$(line_count "$CALL_LOG")"
assert_json_session_missing "synced claude checkpoint is removed" "claude:claude-session-1"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_eq "second idle run does not duplicate claude sync" "1" "$(line_count "$CALL_LOG")"

echo ""
echo "=== Due Codex checkpoint ==="

mkdir -p "$TEST_DIR/codex-sessions"
CODEX_JSONL="$TEST_DIR/codex-sessions/session.jsonl"
touch "$CODEX_JSONL"
REAL_CODEX_JSONL=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$CODEX_JSONL")

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source codex --session-id codex-session-1 --path "$CODEX_JSONL"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_eq "due codex checkpoint is synced once" "2" "$(line_count "$CALL_LOG")"
assert_eq "codex sync receives exact jsonl path" "codex	$REAL_CODEX_JSONL" "$(tail -1 "$CALL_LOG")"
assert_json_session_missing "synced codex checkpoint is removed" "codex:codex-session-1"

echo ""
echo "=== Pathless Codex checkpoint ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
: > "$CALL_LOG"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source codex --session-id codex-no-path

if AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"; then
    CODEX_NO_PATH_EXIT=0
else
    CODEX_NO_PATH_EXIT=$?
fi

assert_eq "pathless codex checkpoint makes idle sync fail" "1" "$CODEX_NO_PATH_EXIT"
assert_eq "pathless codex checkpoint does not call sync" "0" "$(line_count "$CALL_LOG")"
assert_json_session_exists "pathless codex checkpoint stays pending" "codex:codex-no-path"

echo ""
echo "=== Concurrent checkpoint writes ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
for i in $(seq 1 40); do
    AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
        "$RECORD_SCRIPT" --source claude --session-id "parallel-$i" &
done
wait

assert_eq "parallel checkpoints are not lost" "40" "$(json_session_count)"

echo ""
echo "=== Checkpoint updated during sync ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
: > "$CALL_LOG"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id race-session

python3 - "$STATE_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["sessions"]["claude:race-session"]["updated_at"] = 1
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
    handle.write("\n")
PY

FAKE_RECHECKPOINT_SYNC="$TEST_DIR/fake-recheckpoint-sync.sh"
cat > "$FAKE_RECHECKPOINT_SYNC" <<'EOF'
#!/bin/bash
printf 'claude-race\t%s\n' "$1" >> "$SYNC_CALL_LOG"
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR_FOR_FAKE" \
    "$RECORD_SCRIPT_FOR_FAKE" --source claude --session-id "$1"
EOF
chmod +x "$FAKE_RECHECKPOINT_SYNC"

export STATE_DIR_FOR_FAKE="$STATE_DIR"
export RECORD_SCRIPT_FOR_FAKE="$RECORD_SCRIPT"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECHECKPOINT_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_eq "race sync was attempted" "1" "$(line_count "$CALL_LOG")"
assert_json_session_exists "newer checkpoint survives old sync completion" "claude:race-session"

echo ""
echo "=== Delegated sync busy ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
: > "$CALL_LOG"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id busy-session

FAKE_BUSY_SYNC="$TEST_DIR/fake-busy-sync.sh"
cat > "$FAKE_BUSY_SYNC" <<'EOF'
#!/bin/bash
printf 'busy\t%s\t%s\n' "$1" "${SYNC_BUSY_EXIT_CODE:-unset}" >> "$SYNC_CALL_LOG"
exit "${SYNC_BUSY_EXIT_CODE:-0}"
EOF
chmod +x "$FAKE_BUSY_SYNC"

if AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_BUSY_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"; then
    BUSY_EXIT=0
else
    BUSY_EXIT=$?
fi

assert_eq "busy delegated sync makes idle sync fail" "1" "$BUSY_EXIT"
assert_eq "busy delegated sync receives busy exit code" "busy	busy-session	75" "$(tail -1 "$CALL_LOG")"
assert_json_session_exists "busy checkpoint stays pending" "claude:busy-session"

echo ""
echo "=== Live idle sync lock ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR/idle-sync.lock"
: > "$CALL_LOG"
LOCK_LSTART=$(ps -p "$$" -o lstart= 2>/dev/null || true)
printf '%s:%s\n' "$$" "$LOCK_LSTART" > "$STATE_DIR/idle-sync.lock/pid"
python3 - "$STATE_DIR/idle-sync.lock" <<'PY'
import os
import sys
import time

old = time.time() - 600
os.utime(sys.argv[1], (old, old))
PY

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_file_exists "live stale idle lock is preserved" "$STATE_DIR/idle-sync.lock/pid"
assert_eq "live stale idle lock prevents sync" "0" "$(line_count "$CALL_LOG")"

echo ""
echo "=== Reused PID-looking stale lock ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR/idle-sync.lock"
: > "$CALL_LOG"
printf '%s:%s\n' "$$" "Mon Jan  1 00:00:00 2001" > "$STATE_DIR/idle-sync.lock/pid"
python3 - "$STATE_DIR/idle-sync.lock" <<'PY'
import os
import sys
import time

old = time.time() - 600
os.utime(sys.argv[1], (old, old))
PY

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id recovered-lock-session

python3 - "$STATE_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["sessions"]["claude:recovered-lock-session"]["updated_at"] = 1
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
    handle.write("\n")
PY

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_json_session_missing "stale reused-pid-looking lock is recovered" "claude:recovered-lock-session"
assert_eq "sync runs after stale reused-pid-looking lock recovery" "1" "$(line_count "$CALL_LOG")"

echo ""
echo "=== Failed checkpoints do not starve newer checkpoints ==="

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
: > "$CALL_LOG"

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id old-failing-session
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
    "$RECORD_SCRIPT" --source claude --session-id newer-success-session

python3 - "$STATE_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["sessions"]["claude:old-failing-session"]["updated_at"] = 1
data["sessions"]["claude:newer-success-session"]["updated_at"] = 2
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
    handle.write("\n")
PY

FAKE_FAIL_OLD_SYNC="$TEST_DIR/fake-fail-old-sync.sh"
cat > "$FAKE_FAIL_OLD_SYNC" <<'EOF'
#!/bin/bash
if [ "$1" = "old-failing-session" ]; then
    printf 'starve-fail\t%s\n' "$1" >> "$SYNC_CALL_LOG"
    exit 1
fi
printf 'starve-ok\t%s\n' "$1" >> "$SYNC_CALL_LOG"
EOF
chmod +x "$FAKE_FAIL_OLD_SYNC"

if AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
AI_IDLE_MAX_SESSIONS=1 \
SYNC_RECALL_SCRIPT="$FAKE_FAIL_OLD_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"; then
    STARVE_FIRST_EXIT=0
else
    STARVE_FIRST_EXIT=$?
fi

AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_IDLE_SYNC_LOG="$TEST_DIR/idle-sync.log" \
AI_IDLE_MIN_AGE_SECONDS=0 \
AI_IDLE_MAX_SESSIONS=1 \
SYNC_RECALL_SCRIPT="$FAKE_FAIL_OLD_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$IDLE_SCRIPT"

assert_eq "first starvation run records old failure" "1" "$STARVE_FIRST_EXIT"
assert_eq "newer checkpoint is tried after old failure" "starve-ok	newer-success-session" "$(tail -1 "$CALL_LOG")"
assert_json_session_exists "old failed checkpoint stays pending" "claude:old-failing-session"
assert_json_session_missing "newer checkpoint syncs despite older failure" "claude:newer-success-session"

echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
