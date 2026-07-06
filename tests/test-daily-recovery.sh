#!/bin/bash
# Regression tests for bounded daily AI session recovery.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/recover-ai-sessions-daily.sh"
TEST_DIR=$(mktemp -d /tmp/test-daily-recovery-XXXXXX)
PASS=0
FAIL=0
export SECOND_BRAIN_DIR="$TEST_DIR/default-second-brain"
mkdir -p "$SECOND_BRAIN_DIR"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null
}
trap cleanup EXIT

rm -rf "$REPO_DIR/scripts/__pycache__" 2>/dev/null || true

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

assert_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (missing pattern: $pattern)"
    fi
}

assert_not_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq "$pattern" "$file" 2>/dev/null; then
        fail "$label (unexpected pattern: $pattern)"
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

saved_markdown_count() {
    local root="$1"
    find "$root" \( -path "$root/AI-Logs/readable" -prune \) -o -name '*.md' -type f -print 2>/dev/null | wc -l | tr -d ' '
}

saved_grep_count() {
    local pattern="$1" root="$2"
    find "$root" \( -path "$root/AI-Logs/readable" -prune \) -o -name '*.md' -type f -print0 2>/dev/null | \
        xargs -0 grep -l "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

state_value() {
    local path="$1"
    local expression="$2"
    python3 - "$path" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:3]
data = json.load(open(path, encoding="utf-8"))
value = data
for part in expression.split("."):
    value = value[part]
print(value)
PY
}

recent_iso() {
    python3 - <<'PY'
import datetime as dt
print(dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"))
PY
}

old_iso() {
    python3 - <<'PY'
import datetime as dt
print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=30)).isoformat().replace("+00:00", "Z"))
PY
}

recent_days_ago_iso() {
    python3 - "$1" <<'PY'
import datetime as dt
import sys

days = int(sys.argv[1])
print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).isoformat().replace("+00:00", "Z"))
PY
}

set_old_mtime() {
    python3 - "$1" <<'PY'
import os
import sys
import time

old = time.time() - 30 * 86400
os.utime(sys.argv[1], (old, old))
PY
}

set_mtime_offset() {
    python3 - "$1" "$2" <<'PY'
import os
import sys
import time

value = time.time() + int(sys.argv[2])
os.utime(sys.argv[1], (value, value))
PY
}

STATE_DIR="$TEST_DIR/state"
RECOVERY_LOG="$TEST_DIR/recovery.log"
CALL_LOG="$TEST_DIR/sync-calls.log"
TEST_HOME="$TEST_DIR/home"
CODEX_DIR="$TEST_DIR/codex-sessions"
CLAUDE_PROJECTS_DIR="$TEST_HOME/.claude/projects"
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$STATE_DIR" "$TEST_HOME/.claude" "$CODEX_DIR" "$CLAUDE_PROJECTS_DIR" "$MOCK_BIN"

export SYNC_CALL_LOG="$CALL_LOG"

FAKE_RECALL_SYNC="$TEST_DIR/fake-recall-sync.sh"
cat > "$FAKE_RECALL_SYNC" <<'EOF'
#!/bin/bash
printf 'claude\t%s\t%s\n' "$1" "${CLAUDE_SESSION_JSONL_PATH:-}" >> "$SYNC_CALL_LOG"
EOF
chmod +x "$FAKE_RECALL_SYNC"

FAKE_CODEX_SYNC="$TEST_DIR/fake-codex-sync.sh"
cat > "$FAKE_CODEX_SYNC" <<'EOF'
#!/bin/bash
printf 'codex\t%s\n' "$1" >> "$SYNC_CALL_LOG"
EOF
chmod +x "$FAKE_CODEX_SYNC"

RECALL_LIST="$TEST_DIR/recall-list.json"
cat > "$MOCK_BIN/recall" <<'EOF'
#!/bin/bash
if [ "$1" = "list" ]; then
    cat "$MOCK_RECALL_LIST"
    exit 0
fi
if [ "$1" = "read" ] && [ -n "${MOCK_RECALL_READ_JSON:-}" ]; then
    cat "$MOCK_RECALL_READ_JSON"
    exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN/recall"

echo ""
echo "=== Bounded recent recovery ==="

RECENT_TS=$(recent_iso)
OLD_TS=$(old_iso)
cat > "$RECALL_LIST" <<EOF
{
  "sessions": [
    {"session_id": "recall-recent", "source": "claude", "updated_at": "$RECENT_TS"},
    {"session_id": "recall-old", "source": "claude", "updated_at": "$OLD_TS"},
    {"session_id": "recall-codex", "source": "codex", "updated_at": "$RECENT_TS"}
  ]
}
EOF

cat > "$CLAUDE_PROJECTS_DIR/fallback-session.jsonl" <<'EOF'
{"type":"user","sessionId":"fallback-session","message":{"role":"user","content":"transcript-secret-value"}}
EOF

RECENT_CODEX="$CODEX_DIR/rollout-recent.jsonl"
cat > "$RECENT_CODEX" <<'EOF'
{"type":"session_meta","timestamp":"2026-06-02T00:00:00Z","payload":{"id":"123e4567-e89b-12d3-a456-426614174999","timestamp":"2026-06-02T00:00:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"codex transcript secret"}]}}
EOF
REAL_RECENT_CODEX=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$RECENT_CODEX")

OLD_CODEX="$CODEX_DIR/rollout-old.jsonl"
cat > "$OLD_CODEX" <<'EOF'
{"type":"session_meta","timestamp":"2026-06-02T00:00:00Z","payload":{"id":"123e4567-e89b-12d3-a456-426614174888","timestamp":"2026-06-02T00:00:00Z"}}
EOF
set_old_mtime "$OLD_CODEX"

MOCK_RECALL_LIST="$RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_eq "three recent candidates are delegated" "3" "$(line_count "$CALL_LOG")"
assert_contains "recall recent session is delegated" "$CALL_LOG" "claude	recall-recent"
assert_contains "claude jsonl fallback session is delegated" "$CALL_LOG" "claude	fallback-session"
assert_contains "claude jsonl fallback path is delegated" "$CALL_LOG" "$CLAUDE_PROJECTS_DIR/fallback-session.jsonl"
assert_contains "recent codex rollout is delegated" "$CALL_LOG" "codex	$REAL_RECENT_CODEX"
assert_not_contains "old recall session is not delegated" "$CALL_LOG" "recall-old"
assert_not_contains "recall codex source is excluded" "$CALL_LOG" "recall-codex"
assert_not_contains "old codex rollout is not delegated" "$CALL_LOG" "$OLD_CODEX"
assert_file_exists "daily recovery state is written" "$STATE_DIR/daily-recovery.json"
assert_eq "state records lookback days" "2" "$(state_value "$STATE_DIR/daily-recovery.json" "lookback_days")"
assert_eq "state records max sessions" "10" "$(state_value "$STATE_DIR/daily-recovery.json" "max_sessions_per_run")"
assert_eq "state records candidate count" "3" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.candidate_count")"
assert_eq "state records success count" "3" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.succeeded_count")"
assert_contains "report is counts only" "$RECOVERY_LOG" "Daily recovery completed: candidates=3 attempted=3 succeeded=3 failed=0 skipped=0"
assert_not_contains "report omits claude transcript content" "$RECOVERY_LOG" "transcript-secret-value"
assert_not_contains "state omits transcript content" "$STATE_DIR/daily-recovery.json" "transcript-secret-value"

echo ""
echo "=== Max sessions cap ==="

: > "$CALL_LOG"
MOCK_RECALL_LIST="$RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=1 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_eq "max sessions caps delegated work" "1" "$(line_count "$CALL_LOG")"
assert_eq "state records capped candidate count" "1" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.candidate_count")"

echo ""
echo "=== Claude JSONL session id extraction ==="

SESSION_ID_RECALL_LIST="$TEST_DIR/recall-session-id-list.json"
cat > "$SESSION_ID_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
cat > "$CLAUDE_PROJECTS_DIR/agent-not-the-session.jsonl" <<'EOF'
{"type":"user","sessionId":"content-session-id","message":{"role":"user","content":"content session message"}}
EOF
: > "$CALL_LOG"

MOCK_RECALL_LIST="$SESSION_ID_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_contains "claude jsonl content session id is delegated" "$CALL_LOG" "claude	content-session-id"
assert_contains "claude jsonl non-session filename path is delegated" "$CALL_LOG" "$CLAUDE_PROJECTS_DIR/agent-not-the-session.jsonl"

echo ""
echo "=== Claude JSONL filename fallback without session id ==="

NOID_HOME="$TEST_DIR/noid-home"
NOID_STATE_DIR="$TEST_DIR/noid-state"
NOID_OBSIDIAN="$TEST_DIR/noid-obsidian"
NOID_PROJECTS_DIR="$TEST_DIR/noid-claude-projects"
NOID_CODEX_DIR="$TEST_DIR/noid-codex-sessions"
NOID_RECOVERY_LOG="$TEST_DIR/noid-recovery.log"
NOID_RECALL_LIST="$TEST_DIR/noid-recall-list.json"
mkdir -p "$NOID_HOME/.claude" "$NOID_STATE_DIR" "$NOID_OBSIDIAN" "$NOID_PROJECTS_DIR" "$NOID_CODEX_DIR"

cat > "$NOID_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$NOID_PROJECTS_DIR/noid-session.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"hello no id"}}
EOF

if MOCK_RECALL_LIST="$NOID_RECALL_LIST" \
HOME="$NOID_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$NOID_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$NOID_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$NOID_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$NOID_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$NOID_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    NOID_EXIT=0
else
    NOID_EXIT=$?
fi

assert_eq "noid jsonl recovery succeeds" "0" "$NOID_EXIT"
NOID_MD=$(grep -rl "hello no id" "$NOID_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "noid jsonl markdown is written" "$NOID_MD"
assert_contains "noid jsonl filename session id is written" "$NOID_MD" "session_id: \"noid-session\""
assert_contains "noid jsonl transcript is written" "$NOID_MD" "hello no id"

echo ""
echo "=== Claude JSONL filename fallback matches existing bare markdown ==="

NOID_EXISTING_HOME="$TEST_DIR/noid-existing-home"
NOID_EXISTING_STATE_DIR="$TEST_DIR/noid-existing-state"
NOID_EXISTING_OBSIDIAN="$TEST_DIR/noid-existing-obsidian"
NOID_EXISTING_PROJECTS_DIR="$TEST_DIR/noid-existing-claude-projects"
NOID_EXISTING_CODEX_DIR="$TEST_DIR/noid-existing-codex-sessions"
NOID_EXISTING_RECOVERY_LOG="$TEST_DIR/noid-existing-recovery.log"
NOID_EXISTING_RECALL_LIST="$TEST_DIR/noid-existing-recall-list.json"
mkdir -p "$NOID_EXISTING_HOME/.claude" "$NOID_EXISTING_STATE_DIR" "$NOID_EXISTING_OBSIDIAN" \
    "$NOID_EXISTING_PROJECTS_DIR" "$NOID_EXISTING_CODEX_DIR"

cat > "$NOID_EXISTING_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$NOID_EXISTING_OBSIDIAN/existing.md" <<'EOF'
---
date: 2026-06-03
title: "existing"
source: "Claude Code"
session_id: "noid-session"
record_kind: "interactive"
msg_count: 1
last_message_hash: "sha256:x"
transcript_hash: "sha256:y"
tags:
  - "claude"
---

# existing

## Summary

## Decisions

## Next Actions

## Transcript

### User 1

hello no id
EOF

cat > "$NOID_EXISTING_PROJECTS_DIR/noid-session.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"hello no id"}}
EOF

if MOCK_RECALL_LIST="$NOID_EXISTING_RECALL_LIST" \
HOME="$NOID_EXISTING_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$NOID_EXISTING_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$NOID_EXISTING_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$NOID_EXISTING_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$NOID_EXISTING_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$NOID_EXISTING_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    NOID_EXISTING_EXIT=0
else
    NOID_EXISTING_EXIT=$?
fi

assert_eq "noid existing recovery succeeds" "0" "$NOID_EXISTING_EXIT"
assert_eq "noid existing does not create duplicate markdown" "1" "$(saved_markdown_count "$NOID_EXISTING_OBSIDIAN")"
assert_contains "noid existing bare note remains bare" "$NOID_EXISTING_OBSIDIAN/existing.md" "session_id: \"noid-session\""
assert_contains "noid existing stores bare path" "$NOID_EXISTING_STATE_DIR/daily-recovery.json" "noid-session.jsonl"

echo ""
echo "=== Claude JSONL stale existing bare markdown is appended ==="

STALE_EXISTING_HOME="$TEST_DIR/stale-existing-home"
STALE_EXISTING_STATE_DIR="$TEST_DIR/stale-existing-state"
STALE_EXISTING_OBSIDIAN="$TEST_DIR/stale-existing-obsidian"
STALE_EXISTING_PROJECTS_DIR="$TEST_DIR/stale-existing-claude-projects"
STALE_EXISTING_CODEX_DIR="$TEST_DIR/stale-existing-codex-sessions"
STALE_EXISTING_RECOVERY_LOG="$TEST_DIR/stale-existing-recovery.log"
STALE_EXISTING_RECALL_LIST="$TEST_DIR/stale-existing-recall-list.json"
mkdir -p "$STALE_EXISTING_HOME/.claude" "$STALE_EXISTING_STATE_DIR" "$STALE_EXISTING_OBSIDIAN" \
    "$STALE_EXISTING_PROJECTS_DIR" "$STALE_EXISTING_CODEX_DIR"

cat > "$STALE_EXISTING_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

printf '%s' '{"messages":[{"role":"user","content":"stale parent first"}]}' | \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
    python3 "$REPO_DIR/scripts/ai-log-writer.py" create \
    --date=2026-06-03 \
    --title=existing \
    --source="Claude Code" \
    --session-id=stale-session \
    --record-kind=interactive \
    --tag=claude > "$STALE_EXISTING_OBSIDIAN/existing.md"

cat > "$STALE_EXISTING_PROJECTS_DIR/stale-session.jsonl" <<'EOF'
{"type":"user","sessionId":"stale-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"stale parent first"}}
{"type":"assistant","sessionId":"stale-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"assistant","content":"stale parent second"}}
EOF

if MOCK_RECALL_LIST="$STALE_EXISTING_RECALL_LIST" \
HOME="$STALE_EXISTING_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$STALE_EXISTING_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$STALE_EXISTING_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$STALE_EXISTING_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$STALE_EXISTING_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$STALE_EXISTING_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    STALE_EXISTING_EXIT=0
else
    STALE_EXISTING_EXIT=$?
fi

assert_eq "stale existing recovery succeeds" "0" "$STALE_EXISTING_EXIT"
assert_eq "stale existing does not create duplicate markdown" "1" "$(saved_markdown_count "$STALE_EXISTING_OBSIDIAN")"
assert_contains "stale existing appends newer transcript" "$STALE_EXISTING_OBSIDIAN/existing.md" "stale parent second"
assert_contains "stale existing bare note remains bare" "$STALE_EXISTING_OBSIDIAN/existing.md" "session_id: \"stale-session\""

echo ""
echo "=== Claude JSONL legacy bare markdown is appended ==="

LEGACY_EXISTING_HOME="$TEST_DIR/legacy-existing-home"
LEGACY_EXISTING_STATE_DIR="$TEST_DIR/legacy-existing-state"
LEGACY_EXISTING_OBSIDIAN="$TEST_DIR/legacy-existing-obsidian"
LEGACY_EXISTING_PROJECTS_DIR="$TEST_DIR/legacy-existing-claude-projects"
LEGACY_EXISTING_CODEX_DIR="$TEST_DIR/legacy-existing-codex-sessions"
LEGACY_EXISTING_RECOVERY_LOG="$TEST_DIR/legacy-existing-recovery.log"
LEGACY_EXISTING_RECALL_LIST="$TEST_DIR/legacy-existing-recall-list.json"
mkdir -p "$LEGACY_EXISTING_HOME/.claude" "$LEGACY_EXISTING_STATE_DIR" "$LEGACY_EXISTING_OBSIDIAN" \
    "$LEGACY_EXISTING_PROJECTS_DIR" "$LEGACY_EXISTING_CODEX_DIR"

cat > "$LEGACY_EXISTING_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$LEGACY_EXISTING_OBSIDIAN/existing.md" <<'EOF'
---
date: 2026-06-03
title: "legacy"
source: "Claude Code"
session_id: "legacy-session"
tags:
  - "claude"
---

# legacy

## Q1
legacy first question
## Transcript

## A1
legacy first answer

EOF

cat > "$LEGACY_EXISTING_PROJECTS_DIR/legacy-session.jsonl" <<'EOF'
{"type":"user","sessionId":"legacy-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"legacy first question\n## Transcript"}}
{"type":"assistant","sessionId":"legacy-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"assistant","content":"legacy first answer"}}
{"type":"user","sessionId":"legacy-session","timestamp":"2026-06-03T00:00:02Z","message":{"role":"user","content":"legacy second question"}}
{"type":"assistant","sessionId":"legacy-session","timestamp":"2026-06-03T00:00:03Z","message":{"role":"assistant","content":"legacy second answer"}}
EOF

if MOCK_RECALL_LIST="$LEGACY_EXISTING_RECALL_LIST" \
HOME="$LEGACY_EXISTING_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$LEGACY_EXISTING_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$LEGACY_EXISTING_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$LEGACY_EXISTING_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$LEGACY_EXISTING_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$LEGACY_EXISTING_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    LEGACY_EXISTING_EXIT=0
else
    LEGACY_EXISTING_EXIT=$?
fi

assert_eq "legacy existing recovery succeeds" "0" "$LEGACY_EXISTING_EXIT"
assert_eq "legacy existing does not create duplicate markdown" "1" "$(saved_markdown_count "$LEGACY_EXISTING_OBSIDIAN")"
assert_contains "legacy existing appends Q2" "$LEGACY_EXISTING_OBSIDIAN/existing.md" "## Q2"
assert_contains "legacy existing appends A2" "$LEGACY_EXISTING_OBSIDIAN/existing.md" "## A2"
assert_contains "legacy existing appends answer" "$LEGACY_EXISTING_OBSIDIAN/existing.md" "legacy second answer"

echo ""
echo "=== Claude JSONL duplicate session ids keep path-backed candidates ==="

DUPLICATE_SESSION_RECALL_LIST="$TEST_DIR/recall-duplicate-session-list.json"
cat > "$DUPLICATE_SESSION_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR/shared-session/subagents" "$CODEX_DIR"
cat > "$CLAUDE_PROJECTS_DIR/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","message":{"role":"user","content":"parent transcript"}}
EOF
cat > "$CLAUDE_PROJECTS_DIR/shared-session/subagents/agent-child.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","message":{"role":"user","content":"child transcript"}}
EOF
: > "$CALL_LOG"

MOCK_RECALL_LIST="$DUPLICATE_SESSION_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_eq "duplicate claude session id delegates both jsonl files" "2" "$(line_count "$CALL_LOG")"
assert_contains "duplicate parent jsonl path is delegated" "$CALL_LOG" "$CLAUDE_PROJECTS_DIR/shared-session.jsonl"
assert_contains "duplicate subagent jsonl path is delegated" "$CALL_LOG" "$CLAUDE_PROJECTS_DIR/shared-session/subagents/agent-child.jsonl"
assert_eq "duplicate claude session id counts both path candidates" "2" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.candidate_count")"

echo ""
echo "=== Empty Claude JSONL is skipped ==="

EMPTY_CLAUDE_RECALL_LIST="$TEST_DIR/recall-empty-claude-list.json"
cat > "$EMPTY_CLAUDE_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
cat > "$CLAUDE_PROJECTS_DIR/empty-session.jsonl" <<'EOF'
{"type":"permission-mode","permissionMode":"default","sessionId":"empty-session"}
{"type":"hook_success","sessionId":"empty-session","message":{"role":"system","content":"startup only"}}
EOF
: > "$CALL_LOG"

MOCK_RECALL_LIST="$EMPTY_CLAUDE_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_eq "empty claude jsonl is not delegated" "0" "$(line_count "$CALL_LOG")"
assert_eq "empty claude jsonl is not counted as candidate" "0" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.candidate_count")"

echo ""
echo "=== Codex without session meta is skipped ==="

CODEX_EMPTY_RECALL_LIST="$TEST_DIR/recall-codex-empty-list.json"
cat > "$CODEX_EMPTY_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
CODEX_NO_META="$CODEX_DIR/rollout-no-meta.jsonl"
cat > "$CODEX_NO_META" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"no session meta"}]}}
EOF
REAL_CODEX_NO_META=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$CODEX_NO_META")
: > "$CALL_LOG"

MOCK_RECALL_LIST="$CODEX_EMPTY_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_not_contains "codex without session meta is not delegated" "$CALL_LOG" "codex	$REAL_CODEX_NO_META"
assert_eq "codex without session meta is not counted as candidate" "0" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.candidate_count")"

echo ""
echo "=== Max sessions rotates attempted candidates ==="

ROTATE_RECALL_LIST="$TEST_DIR/recall-rotate-list.json"
cat > "$ROTATE_RECALL_LIST" <<EOF
{
  "sessions": [
    {"session_id": "rotate-newer", "source": "claude", "updated_at": "$(recent_iso)"},
    {"session_id": "rotate-older", "source": "claude", "updated_at": "$(recent_days_ago_iso 1)"}
  ]
}
EOF

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
: > "$CALL_LOG"

MOCK_RECALL_LIST="$ROTATE_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=3 \
AI_RECOVERY_MAX_SESSIONS=1 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_contains "first capped run delegates newest candidate" "$CALL_LOG" "claude	rotate-newer"

: > "$CALL_LOG"
MOCK_RECALL_LIST="$ROTATE_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=3 \
AI_RECOVERY_MAX_SESSIONS=1 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_contains "second capped run delegates unattempted candidate" "$CALL_LOG" "claude	rotate-older"

echo ""
echo "=== Updated attempted candidate is retried ==="

UPDATE_RECALL_LIST="$TEST_DIR/recall-update-list.json"
cat > "$UPDATE_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
cat > "$CLAUDE_PROJECTS_DIR/changed-session.jsonl" <<'EOF'
{"type":"user","sessionId":"changed-session","message":{"role":"user","content":"changed first"}}
EOF
cat > "$CLAUDE_PROJECTS_DIR/waiting-session.jsonl" <<'EOF'
{"type":"user","sessionId":"waiting-session","message":{"role":"user","content":"waiting first"}}
EOF
set_mtime_offset "$CLAUDE_PROJECTS_DIR/waiting-session.jsonl" -3600
: > "$CALL_LOG"

MOCK_RECALL_LIST="$UPDATE_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=1 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_contains "first update run delegates changed candidate" "$CALL_LOG" "claude	changed-session"

sleep 1
cat >> "$CLAUDE_PROJECTS_DIR/changed-session.jsonl" <<'EOF'
{"type":"assistant","sessionId":"changed-session","message":{"role":"assistant","content":"changed later"}}
EOF
: > "$CALL_LOG"

MOCK_RECALL_LIST="$UPDATE_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=1 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"

assert_contains "updated attempted candidate is retried before untouched candidate" "$CALL_LOG" "claude	changed-session"
assert_not_contains "untouched unattempted candidate waits behind updated candidate" "$CALL_LOG" "claude	waiting-session"

echo ""
echo "=== Failure is reported ==="

FAIL_RECALL_LIST="$TEST_DIR/recall-fail-list.json"
cat > "$FAIL_RECALL_LIST" <<EOF
{"sessions":[{"session_id":"fail-session","source":"claude","updated_at":"$(recent_iso)"}]}
EOF

FAKE_FAIL_RECALL_SYNC="$TEST_DIR/fake-fail-recall-sync.sh"
cat > "$FAKE_FAIL_RECALL_SYNC" <<'EOF'
#!/bin/bash
printf 'claude-fail\t%s\n' "$1" >> "$SYNC_CALL_LOG"
exit 1
EOF
chmod +x "$FAKE_FAIL_RECALL_SYNC"

rm -rf "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_DIR"
: > "$CALL_LOG"

if MOCK_RECALL_LIST="$FAIL_RECALL_LIST" \
HOME="$TEST_HOME" \
PATH="$MOCK_BIN:$PATH" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$FAKE_FAIL_RECALL_SYNC" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    FAIL_EXIT=0
else
    FAIL_EXIT=$?
fi

assert_eq "failed delegated sync makes recovery fail" "1" "$FAIL_EXIT"
assert_eq "failed run delegates once" "1" "$(line_count "$CALL_LOG")"
assert_eq "state records failure count" "1" "$(state_value "$STATE_DIR/daily-recovery.json" "last_report.failed_count")"
assert_contains "failure report is counts only" "$RECOVERY_LOG" "Daily recovery completed: candidates=1 attempted=1 succeeded=0 failed=1 skipped=0"

echo ""
echo "=== Custom Claude projects dir fallback ==="

CUSTOM_HOME="$TEST_DIR/custom-home"
CUSTOM_STATE_DIR="$TEST_DIR/custom-state"
CUSTOM_OBSIDIAN="$TEST_DIR/custom-obsidian"
CUSTOM_PROJECTS_DIR="$TEST_DIR/custom-claude-projects"
CUSTOM_CODEX_DIR="$TEST_DIR/custom-codex-sessions"
CUSTOM_RECOVERY_LOG="$TEST_DIR/custom-recovery.log"
CUSTOM_RECALL_LIST="$TEST_DIR/custom-recall-list.json"
mkdir -p "$CUSTOM_HOME/.claude" "$CUSTOM_STATE_DIR" "$CUSTOM_OBSIDIAN" "$CUSTOM_PROJECTS_DIR" "$CUSTOM_CODEX_DIR"

cat > "$CUSTOM_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$CUSTOM_PROJECTS_DIR/custom-fallback.jsonl" <<'EOF'
{"type":"user","sessionId":"custom-fallback","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"hello custom fallback"}}
{"type":"assistant","sessionId":"custom-fallback","timestamp":"2026-06-03T00:00:01Z","message":{"role":"assistant","content":"custom fallback answer"}}
{"type":"user","sessionId":"custom-fallback","timestamp":"2026-06-03T00:00:02Z","message":{"role":"user","content":"fresh local extra"}}
EOF

CUSTOM_RECALL_READ="$TEST_DIR/custom-recall-read.json"
cat > "$CUSTOM_RECALL_READ" <<'EOF'
{
  "timestamp": "2026-06-03T00:00:00Z",
  "source": "claude",
  "messages": [
    {"role": "user", "content": "stale recall question"},
    {"role": "assistant", "content": "stale recall answer"}
  ]
}
EOF

if MOCK_RECALL_LIST="$CUSTOM_RECALL_LIST" \
MOCK_RECALL_READ_JSON="$CUSTOM_RECALL_READ" \
HOME="$CUSTOM_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CUSTOM_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$CUSTOM_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$CUSTOM_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$CUSTOM_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$CUSTOM_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    CUSTOM_EXIT=0
else
    CUSTOM_EXIT=$?
fi

assert_eq "custom claude projects dir recovery succeeds" "0" "$CUSTOM_EXIT"
CUSTOM_MD=$(find "$CUSTOM_OBSIDIAN" -name '*.md' -type f -print | head -1)
assert_file_exists "custom fallback markdown is written" "$CUSTOM_MD"
assert_contains "custom fallback session id is written" "$CUSTOM_MD" "session_id: \"custom-fallback\""
assert_contains "custom fallback transcript is written" "$CUSTOM_MD" "hello custom fallback"
assert_contains "custom fallback forces newer local JSONL" "$CUSTOM_MD" "fresh local extra"
assert_not_contains "custom fallback does not use stale recall payload" "$CUSTOM_MD" "stale recall question"
assert_not_contains "custom recovery report omits transcript content" "$CUSTOM_RECOVERY_LOG" "hello custom fallback"

echo ""
echo "=== Claude JSONL snake_case session_id fallback ==="

SNAKE_HOME="$TEST_DIR/snake-home"
SNAKE_STATE_DIR="$TEST_DIR/snake-state"
SNAKE_OBSIDIAN="$TEST_DIR/snake-obsidian"
SNAKE_PROJECTS_DIR="$TEST_DIR/snake-claude-projects"
SNAKE_CODEX_DIR="$TEST_DIR/snake-codex-sessions"
SNAKE_RECOVERY_LOG="$TEST_DIR/snake-recovery.log"
SNAKE_RECALL_LIST="$TEST_DIR/snake-recall-list.json"
mkdir -p "$SNAKE_HOME/.claude" "$SNAKE_STATE_DIR" "$SNAKE_OBSIDIAN" "$SNAKE_PROJECTS_DIR" "$SNAKE_CODEX_DIR"

cat > "$SNAKE_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$SNAKE_PROJECTS_DIR/snake.jsonl" <<'EOF'
{"type":"user","session_id":"snake-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"snake transcript"}}
EOF

if MOCK_RECALL_LIST="$SNAKE_RECALL_LIST" \
HOME="$SNAKE_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$SNAKE_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$SNAKE_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$SNAKE_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$SNAKE_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$SNAKE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    SNAKE_EXIT=0
else
    SNAKE_EXIT=$?
fi

assert_eq "snake_case jsonl recovery succeeds" "0" "$SNAKE_EXIT"
SNAKE_MD=$(find "$SNAKE_OBSIDIAN" -name '*.md' -type f -print | head -1)
assert_file_exists "snake_case markdown is written" "$SNAKE_MD"
assert_contains "snake_case session id is written" "$SNAKE_MD" "session_id: \"snake-session\""
assert_contains "snake_case transcript is written" "$SNAKE_MD" "snake transcript"

echo ""
echo "=== Duplicate Claude JSONL paths write separate markdown ==="

DUP_REAL_HOME="$TEST_DIR/duplicate-real-home"
DUP_REAL_STATE_DIR="$TEST_DIR/duplicate-real-state"
DUP_REAL_OBSIDIAN="$TEST_DIR/duplicate-real-obsidian"
DUP_REAL_PROJECTS_DIR="$TEST_DIR/duplicate-real-claude-projects"
DUP_REAL_CODEX_DIR="$TEST_DIR/duplicate-real-codex-sessions"
DUP_REAL_RECOVERY_LOG="$TEST_DIR/duplicate-real-recovery.log"
DUP_REAL_RECALL_LIST="$TEST_DIR/duplicate-real-recall-list.json"
mkdir -p "$DUP_REAL_HOME/.claude" "$DUP_REAL_STATE_DIR" "$DUP_REAL_OBSIDIAN" \
    "$DUP_REAL_PROJECTS_DIR/shared-session/subagents" "$DUP_REAL_CODEX_DIR"

cat > "$DUP_REAL_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$DUP_REAL_PROJECTS_DIR/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"parent transcript"}}
EOF
cat > "$DUP_REAL_PROJECTS_DIR/shared-session/subagents/agent-child.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"child transcript"}}
EOF

if MOCK_RECALL_LIST="$DUP_REAL_RECALL_LIST" \
HOME="$DUP_REAL_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$DUP_REAL_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$DUP_REAL_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$DUP_REAL_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$DUP_REAL_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$DUP_REAL_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    DUP_REAL_EXIT=0
else
    DUP_REAL_EXIT=$?
fi

assert_eq "duplicate real recovery succeeds" "0" "$DUP_REAL_EXIT"
assert_eq "duplicate real recovery writes two saved markdown files" "2" "$(saved_markdown_count "$DUP_REAL_OBSIDIAN")"
DUP_PARENT_MD=$(grep -rl "parent transcript" "$DUP_REAL_OBSIDIAN" 2>/dev/null | head -1)
DUP_CHILD_MD=$(grep -rl "child transcript" "$DUP_REAL_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "duplicate parent markdown is written" "$DUP_PARENT_MD"
assert_file_exists "duplicate child markdown is written" "$DUP_CHILD_MD"
assert_contains "duplicate parent keeps bare persisted session id" "$DUP_PARENT_MD" "session_id: \"shared-session\""
assert_not_contains "duplicate child uses distinct persisted session id" "$DUP_CHILD_MD" "session_id: \"shared-session\""

echo ""
echo "=== Duplicate Claude JSONL appends stale existing bare markdown ==="

STALE_DUP_HOME="$TEST_DIR/stale-duplicate-home"
STALE_DUP_STATE_DIR="$TEST_DIR/stale-duplicate-state"
STALE_DUP_OBSIDIAN="$TEST_DIR/stale-duplicate-obsidian"
STALE_DUP_PROJECTS_DIR="$TEST_DIR/stale-duplicate-claude-projects"
STALE_DUP_CODEX_DIR="$TEST_DIR/stale-duplicate-codex-sessions"
STALE_DUP_RECOVERY_LOG="$TEST_DIR/stale-duplicate-recovery.log"
STALE_DUP_RECALL_LIST="$TEST_DIR/stale-duplicate-recall-list.json"
mkdir -p "$STALE_DUP_HOME/.claude" "$STALE_DUP_STATE_DIR" "$STALE_DUP_OBSIDIAN" \
    "$STALE_DUP_PROJECTS_DIR/shared-session/subagents" "$STALE_DUP_CODEX_DIR"

cat > "$STALE_DUP_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

printf '%s' '{"messages":[{"role":"user","content":"stale duplicate parent first"}]}' | \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
    python3 "$REPO_DIR/scripts/ai-log-writer.py" create \
    --date=2026-06-03 \
    --title=existing \
    --source="Claude Code" \
    --session-id=shared-session \
    --record-kind=interactive \
    --tag=claude > "$STALE_DUP_OBSIDIAN/existing.md"

cat > "$STALE_DUP_PROJECTS_DIR/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"stale duplicate parent first"}}
{"type":"assistant","sessionId":"shared-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"assistant","content":"stale duplicate parent second"}}
EOF
cat > "$STALE_DUP_PROJECTS_DIR/shared-session/subagents/agent-child.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:02Z","message":{"role":"user","content":"stale duplicate child"}}
EOF

if MOCK_RECALL_LIST="$STALE_DUP_RECALL_LIST" \
HOME="$STALE_DUP_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$STALE_DUP_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$STALE_DUP_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$STALE_DUP_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$STALE_DUP_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$STALE_DUP_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    STALE_DUP_EXIT=0
else
    STALE_DUP_EXIT=$?
fi

assert_eq "stale duplicate recovery succeeds" "0" "$STALE_DUP_EXIT"
assert_eq "stale duplicate keeps bare plus child markdown" "2" "$(saved_markdown_count "$STALE_DUP_OBSIDIAN")"
assert_contains "stale duplicate appends parent transcript" "$STALE_DUP_OBSIDIAN/existing.md" "stale duplicate parent second"
STALE_DUP_CHILD_MD=$(grep -rl "stale duplicate child" "$STALE_DUP_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "stale duplicate child markdown is written" "$STALE_DUP_CHILD_MD"
assert_contains "stale duplicate bare note remains bare" "$STALE_DUP_OBSIDIAN/existing.md" "session_id: \"shared-session\""
assert_not_contains "stale duplicate child uses path persisted id" "$STALE_DUP_CHILD_MD" "session_id: \"shared-session\""

echo ""
echo "=== Duplicate Claude JSONL preserves existing bare markdown ==="

EXISTING_DUP_HOME="$TEST_DIR/existing-duplicate-home"
EXISTING_DUP_STATE_DIR="$TEST_DIR/existing-duplicate-state"
EXISTING_DUP_OBSIDIAN="$TEST_DIR/existing-duplicate-obsidian"
EXISTING_DUP_PROJECTS_DIR="$TEST_DIR/existing-duplicate-claude-projects"
EXISTING_DUP_CODEX_DIR="$TEST_DIR/existing-duplicate-codex-sessions"
EXISTING_DUP_RECOVERY_LOG="$TEST_DIR/existing-duplicate-recovery.log"
EXISTING_DUP_RECALL_LIST="$TEST_DIR/existing-duplicate-recall-list.json"
mkdir -p "$EXISTING_DUP_HOME/.claude" "$EXISTING_DUP_STATE_DIR" "$EXISTING_DUP_OBSIDIAN" \
    "$EXISTING_DUP_PROJECTS_DIR/shared-session/subagents" "$EXISTING_DUP_CODEX_DIR"

cat > "$EXISTING_DUP_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$EXISTING_DUP_OBSIDIAN/existing.md" <<'EOF'
---
date: 2026-06-03
title: "existing"
source: "Claude Code"
session_id: "shared-session"
record_kind: "interactive"
msg_count: 1
last_message_hash: "sha256:x"
transcript_hash: "sha256:y"
tags:
  - "claude"
---

# existing

## Summary

## Decisions

## Next Actions

## Transcript

### User 1

parent transcript
EOF

cat > "$EXISTING_DUP_PROJECTS_DIR/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"parent transcript"}}
EOF
cat > "$EXISTING_DUP_PROJECTS_DIR/shared-session/subagents/agent-child.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"child transcript"}}
EOF

if MOCK_RECALL_LIST="$EXISTING_DUP_RECALL_LIST" \
HOME="$EXISTING_DUP_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$EXISTING_DUP_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$EXISTING_DUP_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$EXISTING_DUP_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$EXISTING_DUP_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$EXISTING_DUP_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    EXISTING_DUP_EXIT=0
else
    EXISTING_DUP_EXIT=$?
fi

assert_eq "existing duplicate recovery succeeds" "0" "$EXISTING_DUP_EXIT"
assert_eq "existing duplicate keeps one bare plus one child markdown" "2" "$(saved_markdown_count "$EXISTING_DUP_OBSIDIAN")"
assert_eq "existing duplicate does not clone parent transcript" "1" "$(saved_grep_count "parent transcript" "$EXISTING_DUP_OBSIDIAN")"
EXISTING_DUP_CHILD_MD=$(grep -rl "child transcript" "$EXISTING_DUP_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "existing duplicate child markdown is written" "$EXISTING_DUP_CHILD_MD"
assert_contains "existing duplicate bare note remains bare" "$EXISTING_DUP_OBSIDIAN/existing.md" "session_id: \"shared-session\""
assert_not_contains "existing duplicate child uses path persisted id" "$EXISTING_DUP_CHILD_MD" "session_id: \"shared-session\""

echo ""
echo "=== Duplicate Claude JSONL single candidate respects existing bare markdown ==="

SINGLE_DUP_HOME="$TEST_DIR/single-duplicate-home"
SINGLE_DUP_STATE_DIR="$TEST_DIR/single-duplicate-state"
SINGLE_DUP_OBSIDIAN="$TEST_DIR/single-duplicate-obsidian"
SINGLE_DUP_PROJECTS_DIR="$TEST_DIR/single-duplicate-claude-projects"
SINGLE_DUP_CODEX_DIR="$TEST_DIR/single-duplicate-codex-sessions"
SINGLE_DUP_RECOVERY_LOG="$TEST_DIR/single-duplicate-recovery.log"
SINGLE_DUP_RECALL_LIST="$TEST_DIR/single-duplicate-recall-list.json"
mkdir -p "$SINGLE_DUP_HOME/.claude" "$SINGLE_DUP_STATE_DIR" "$SINGLE_DUP_OBSIDIAN" \
    "$SINGLE_DUP_PROJECTS_DIR/shared-session/subagents" "$SINGLE_DUP_CODEX_DIR"

cat > "$SINGLE_DUP_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$SINGLE_DUP_OBSIDIAN/existing.md" <<'EOF'
---
date: 2026-06-03
title: "existing"
source: "Claude Code"
session_id: "shared-session"
record_kind: "interactive"
msg_count: 1
last_message_hash: "sha256:x"
transcript_hash: "sha256:y"
tags:
  - "claude"
---

# existing

## Summary

## Decisions

## Next Actions

## Transcript

### User 1

single parent transcript
EOF

cat > "$SINGLE_DUP_PROJECTS_DIR/shared-session/subagents/agent-child.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"single child transcript"}}
EOF

if MOCK_RECALL_LIST="$SINGLE_DUP_RECALL_LIST" \
HOME="$SINGLE_DUP_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$SINGLE_DUP_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$SINGLE_DUP_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$SINGLE_DUP_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$SINGLE_DUP_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$SINGLE_DUP_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    SINGLE_DUP_EXIT=0
else
    SINGLE_DUP_EXIT=$?
fi

assert_eq "single duplicate recovery succeeds" "0" "$SINGLE_DUP_EXIT"
assert_eq "single duplicate keeps bare plus child markdown" "2" "$(saved_markdown_count "$SINGLE_DUP_OBSIDIAN")"
assert_eq "single duplicate does not clone parent transcript" "1" "$(saved_grep_count "single parent transcript" "$SINGLE_DUP_OBSIDIAN")"
assert_eq "single duplicate writes child transcript once" "1" "$(saved_grep_count "single child transcript" "$SINGLE_DUP_OBSIDIAN")"
SINGLE_DUP_CHILD_MD=$(grep -rl "single child transcript" "$SINGLE_DUP_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "single duplicate child markdown is written" "$SINGLE_DUP_CHILD_MD"
assert_contains "single duplicate bare note remains bare" "$SINGLE_DUP_OBSIDIAN/existing.md" "session_id: \"shared-session\""
assert_not_contains "single duplicate child uses path id" "$SINGLE_DUP_CHILD_MD" "session_id: \"shared-session\""

echo ""
echo "=== Duplicate Claude JSONL matches existing bare markdown ==="

EXISTING_MATCH_HOME="$TEST_DIR/existing-match-home"
EXISTING_MATCH_STATE_DIR="$TEST_DIR/existing-match-state"
EXISTING_MATCH_OBSIDIAN="$TEST_DIR/existing-match-obsidian"
EXISTING_MATCH_PROJECTS_DIR="$TEST_DIR/existing-match-claude-projects"
EXISTING_MATCH_CODEX_DIR="$TEST_DIR/existing-match-codex-sessions"
EXISTING_MATCH_RECOVERY_LOG="$TEST_DIR/existing-match-recovery.log"
EXISTING_MATCH_RECALL_LIST="$TEST_DIR/existing-match-recall-list.json"
mkdir -p "$EXISTING_MATCH_HOME/.claude" "$EXISTING_MATCH_STATE_DIR" "$EXISTING_MATCH_OBSIDIAN" \
    "$EXISTING_MATCH_PROJECTS_DIR/project-a" "$EXISTING_MATCH_PROJECTS_DIR/project-b" "$EXISTING_MATCH_CODEX_DIR"

cat > "$EXISTING_MATCH_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$EXISTING_MATCH_OBSIDIAN/existing.md" <<'EOF'
---
date: 2026-06-03
title: "existing"
source: "Claude Code"
session_id: "shared-session"
record_kind: "interactive"
msg_count: 1
last_message_hash: "sha256:x"
transcript_hash: "sha256:y"
tags:
  - "claude"
---

# existing

## Summary

## Decisions

## Next Actions

## Transcript

### User 1

orphan B transcript
EOF

cat > "$EXISTING_MATCH_PROJECTS_DIR/project-a/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"orphan A transcript"}}
EOF
cat > "$EXISTING_MATCH_PROJECTS_DIR/project-b/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"orphan B transcript"}}
EOF

if MOCK_RECALL_LIST="$EXISTING_MATCH_RECALL_LIST" \
HOME="$EXISTING_MATCH_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$EXISTING_MATCH_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$EXISTING_MATCH_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$EXISTING_MATCH_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$EXISTING_MATCH_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$EXISTING_MATCH_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    EXISTING_MATCH_EXIT=0
else
    EXISTING_MATCH_EXIT=$?
fi

assert_eq "existing match recovery succeeds" "0" "$EXISTING_MATCH_EXIT"
assert_eq "existing match keeps one bare plus one new markdown" "2" "$(saved_markdown_count "$EXISTING_MATCH_OBSIDIAN")"
assert_eq "existing match does not clone matched bare transcript" "1" "$(saved_grep_count "orphan B transcript" "$EXISTING_MATCH_OBSIDIAN")"
assert_eq "existing match writes unmatched transcript once" "1" "$(saved_grep_count "orphan A transcript" "$EXISTING_MATCH_OBSIDIAN")"
EXISTING_MATCH_A_MD=$(grep -rl "orphan A transcript" "$EXISTING_MATCH_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "existing match unmatched markdown is written" "$EXISTING_MATCH_A_MD"
assert_contains "existing match bare note remains bare" "$EXISTING_MATCH_OBSIDIAN/existing.md" "session_id: \"shared-session\""
assert_not_contains "existing match unmatched markdown uses path id" "$EXISTING_MATCH_A_MD" "session_id: \"shared-session\""
assert_contains "existing match stores matched bare path" "$EXISTING_MATCH_STATE_DIR/daily-recovery.json" "project-b/shared-session.jsonl"

echo ""
echo "=== Duplicate Claude JSONL matches redacted existing bare markdown ==="

REDACTED_MATCH_HOME="$TEST_DIR/redacted-match-home"
REDACTED_MATCH_STATE_DIR="$TEST_DIR/redacted-match-state"
REDACTED_MATCH_OBSIDIAN="$TEST_DIR/redacted-match-obsidian"
REDACTED_MATCH_PROJECTS_DIR="$TEST_DIR/redacted-match-claude-projects"
REDACTED_MATCH_CODEX_DIR="$TEST_DIR/redacted-match-codex-sessions"
REDACTED_MATCH_RECOVERY_LOG="$TEST_DIR/redacted-match-recovery.log"
REDACTED_MATCH_RECALL_LIST="$TEST_DIR/redacted-match-recall-list.json"
mkdir -p "$REDACTED_MATCH_HOME/.claude" "$REDACTED_MATCH_STATE_DIR" "$REDACTED_MATCH_OBSIDIAN" \
    "$REDACTED_MATCH_PROJECTS_DIR" "$REDACTED_MATCH_CODEX_DIR"

cat > "$REDACTED_MATCH_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$REDACTED_MATCH_OBSIDIAN/existing.md" <<'EOF'
---
date: 2026-06-03
title: "existing"
source: "Claude Code"
session_id: "redacted-session"
record_kind: "interactive"
msg_count: 1
last_message_hash: "sha256:x"
transcript_hash: "sha256:y"
tags:
  - "claude"
---

# existing

## Summary

## Decisions

## Next Actions

## Transcript

### User 1

my api key is [REDACTED_API_KEY]
EOF

cat > "$REDACTED_MATCH_PROJECTS_DIR/redacted-session.jsonl" <<'EOF'
{"type":"user","sessionId":"redacted-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"my api key is sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK"}}
EOF

if MOCK_RECALL_LIST="$REDACTED_MATCH_RECALL_LIST" \
HOME="$REDACTED_MATCH_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$REDACTED_MATCH_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$REDACTED_MATCH_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$REDACTED_MATCH_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$REDACTED_MATCH_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$REDACTED_MATCH_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    REDACTED_MATCH_EXIT=0
else
    REDACTED_MATCH_EXIT=$?
fi

assert_eq "redacted existing match recovery succeeds" "0" "$REDACTED_MATCH_EXIT"
assert_eq "redacted existing match does not create duplicate markdown" "1" "$(saved_markdown_count "$REDACTED_MATCH_OBSIDIAN")"
assert_contains "redacted existing match remains bare" "$REDACTED_MATCH_OBSIDIAN/existing.md" "session_id: \"redacted-session\""
assert_not_contains "redacted existing match does not write raw secret" "$REDACTED_MATCH_OBSIDIAN/existing.md" "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK"
assert_contains "redacted existing match stores bare path" "$REDACTED_MATCH_STATE_DIR/daily-recovery.json" "redacted-session.jsonl"

echo ""
echo "=== Claude JSONL matches unredacted existing bare markdown ==="

UNREDACTED_MATCH_HOME="$TEST_DIR/unredacted-match-home"
UNREDACTED_MATCH_STATE_DIR="$TEST_DIR/unredacted-match-state"
UNREDACTED_MATCH_OBSIDIAN="$TEST_DIR/unredacted-match-obsidian"
UNREDACTED_MATCH_PROJECTS_DIR="$TEST_DIR/unredacted-match-claude-projects"
UNREDACTED_MATCH_CODEX_DIR="$TEST_DIR/unredacted-match-codex-sessions"
UNREDACTED_MATCH_RECOVERY_LOG="$TEST_DIR/unredacted-match-recovery.log"
UNREDACTED_MATCH_RECALL_LIST="$TEST_DIR/unredacted-match-recall-list.json"
mkdir -p "$UNREDACTED_MATCH_HOME/.claude" "$UNREDACTED_MATCH_STATE_DIR" "$UNREDACTED_MATCH_OBSIDIAN" \
    "$UNREDACTED_MATCH_PROJECTS_DIR" "$UNREDACTED_MATCH_CODEX_DIR"

cat > "$UNREDACTED_MATCH_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

python3 - "$UNREDACTED_MATCH_OBSIDIAN/existing.md" <<'PY'
import hashlib
import sys

secret = "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK"
transcript = f"### User 1\n\nmy api key is {secret}\n"
digest = lambda value: "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()
sys.stdout = open(sys.argv[1], "w", encoding="utf-8")
print("---")
print("date: 2026-06-03")
print('title: "existing"')
print('source: "Claude Code"')
print('session_id: "unredacted-session"')
print('record_kind: "interactive"')
print("msg_count: 1")
print(f'last_message_hash: "{digest(transcript)}"')
print(f'transcript_hash: "{digest(transcript)}"')
print("tags:")
print('  - "claude"')
print("---")
print()
print("# existing")
print()
print("## Summary")
print()
print("## Decisions")
print()
print("## Next Actions")
print()
print("## Transcript")
print()
print(transcript, end="")
PY

cat > "$UNREDACTED_MATCH_PROJECTS_DIR/unredacted-session.jsonl" <<'EOF'
{"type":"user","sessionId":"unredacted-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"my api key is sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK"}}
{"type":"assistant","sessionId":"unredacted-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"assistant","content":"unredacted migrated answer"}}
EOF

if MOCK_RECALL_LIST="$UNREDACTED_MATCH_RECALL_LIST" \
HOME="$UNREDACTED_MATCH_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$UNREDACTED_MATCH_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$UNREDACTED_MATCH_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$UNREDACTED_MATCH_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$UNREDACTED_MATCH_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$UNREDACTED_MATCH_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    UNREDACTED_MATCH_EXIT=0
else
    UNREDACTED_MATCH_EXIT=$?
fi

assert_eq "unredacted existing match recovery succeeds" "0" "$UNREDACTED_MATCH_EXIT"
assert_eq "unredacted existing match does not create duplicate markdown" "1" "$(saved_markdown_count "$UNREDACTED_MATCH_OBSIDIAN")"
assert_contains "unredacted existing match remains bare" "$UNREDACTED_MATCH_OBSIDIAN/existing.md" "session_id: \"unredacted-session\""
assert_contains "unredacted existing match appends answer" "$UNREDACTED_MATCH_OBSIDIAN/existing.md" "unredacted migrated answer"
assert_contains "unredacted existing match migrates secret" "$UNREDACTED_MATCH_OBSIDIAN/existing.md" "[REDACTED_API_KEY]"
assert_not_contains "unredacted existing match removes raw secret" "$UNREDACTED_MATCH_OBSIDIAN/existing.md" "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK"
assert_contains "unredacted existing match stores bare path" "$UNREDACTED_MATCH_STATE_DIR/daily-recovery.json" "unredacted-session.jsonl"

echo ""
echo "=== Duplicate Claude JSONL normal filenames write separate markdown ==="

DUP_NORMAL_HOME="$TEST_DIR/duplicate-normal-home"
DUP_NORMAL_STATE_DIR="$TEST_DIR/duplicate-normal-state"
DUP_NORMAL_OBSIDIAN="$TEST_DIR/duplicate-normal-obsidian"
DUP_NORMAL_PROJECTS_DIR="$TEST_DIR/duplicate-normal-claude-projects"
DUP_NORMAL_CODEX_DIR="$TEST_DIR/duplicate-normal-codex-sessions"
DUP_NORMAL_RECOVERY_LOG="$TEST_DIR/duplicate-normal-recovery.log"
DUP_NORMAL_RECALL_LIST="$TEST_DIR/duplicate-normal-recall-list.json"
mkdir -p "$DUP_NORMAL_HOME/.claude" "$DUP_NORMAL_STATE_DIR" "$DUP_NORMAL_OBSIDIAN" \
    "$DUP_NORMAL_PROJECTS_DIR/project-a" "$DUP_NORMAL_PROJECTS_DIR/project-b" "$DUP_NORMAL_CODEX_DIR"

cat > "$DUP_NORMAL_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$DUP_NORMAL_PROJECTS_DIR/project-a/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"normal parent a"}}
EOF
cat > "$DUP_NORMAL_PROJECTS_DIR/project-b/shared-session.jsonl" <<'EOF'
{"type":"user","sessionId":"shared-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"normal parent b"}}
EOF

if MOCK_RECALL_LIST="$DUP_NORMAL_RECALL_LIST" \
HOME="$DUP_NORMAL_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$DUP_NORMAL_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$DUP_NORMAL_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$DUP_NORMAL_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$DUP_NORMAL_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$DUP_NORMAL_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    DUP_NORMAL_EXIT=0
else
    DUP_NORMAL_EXIT=$?
fi

assert_eq "duplicate normal recovery succeeds" "0" "$DUP_NORMAL_EXIT"
assert_eq "duplicate normal recovery writes two saved markdown files" "2" "$(saved_markdown_count "$DUP_NORMAL_OBSIDIAN")"
DUP_NORMAL_A_MD=$(grep -rl "normal parent a" "$DUP_NORMAL_OBSIDIAN" 2>/dev/null | head -1)
DUP_NORMAL_B_MD=$(grep -rl "normal parent b" "$DUP_NORMAL_OBSIDIAN" 2>/dev/null | head -1)
assert_file_exists "duplicate normal first markdown is written" "$DUP_NORMAL_A_MD"
assert_file_exists "duplicate normal second markdown is written" "$DUP_NORMAL_B_MD"
assert_contains "duplicate normal first keeps bare persisted id" "$DUP_NORMAL_A_MD" "session_id: \"shared-session\""
assert_not_contains "duplicate normal second uses path persisted id" "$DUP_NORMAL_B_MD" "session_id: \"shared-session\""

echo ""
echo "=== Duplicate Claude JSONL preserves previous bare path ==="

STABLE_DUP_HOME="$TEST_DIR/stable-duplicate-home"
STABLE_DUP_STATE_DIR="$TEST_DIR/stable-duplicate-state"
STABLE_DUP_OBSIDIAN="$TEST_DIR/stable-duplicate-obsidian"
STABLE_DUP_PROJECTS_DIR="$TEST_DIR/stable-duplicate-claude-projects"
STABLE_DUP_CODEX_DIR="$TEST_DIR/stable-duplicate-codex-sessions"
STABLE_DUP_RECOVERY_LOG="$TEST_DIR/stable-duplicate-recovery.log"
STABLE_DUP_RECALL_LIST="$TEST_DIR/stable-duplicate-recall-list.json"
mkdir -p "$STABLE_DUP_HOME/.claude" "$STABLE_DUP_STATE_DIR" "$STABLE_DUP_OBSIDIAN" \
    "$STABLE_DUP_PROJECTS_DIR/project-b" "$STABLE_DUP_CODEX_DIR"

cat > "$STABLE_DUP_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$STABLE_DUP_PROJECTS_DIR/project-b/stable-session.jsonl" <<'EOF'
{"type":"user","sessionId":"stable-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"stable B only"}}
EOF

if MOCK_RECALL_LIST="$STABLE_DUP_RECALL_LIST" \
HOME="$STABLE_DUP_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$STABLE_DUP_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$STABLE_DUP_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$STABLE_DUP_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$STABLE_DUP_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$STABLE_DUP_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    STABLE_DUP_FIRST_EXIT=0
else
    STABLE_DUP_FIRST_EXIT=$?
fi

mkdir -p "$STABLE_DUP_PROJECTS_DIR/project-a"
cat > "$STABLE_DUP_PROJECTS_DIR/project-a/stable-session.jsonl" <<'EOF'
{"type":"user","sessionId":"stable-session","timestamp":"2026-06-03T00:00:02Z","message":{"role":"user","content":"stable A only"}}
EOF

if MOCK_RECALL_LIST="$STABLE_DUP_RECALL_LIST" \
HOME="$STABLE_DUP_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$STABLE_DUP_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$STABLE_DUP_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$STABLE_DUP_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$STABLE_DUP_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$STABLE_DUP_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    STABLE_DUP_SECOND_EXIT=0
else
    STABLE_DUP_SECOND_EXIT=$?
fi

assert_eq "stable duplicate first recovery succeeds" "0" "$STABLE_DUP_FIRST_EXIT"
assert_eq "stable duplicate second recovery succeeds" "0" "$STABLE_DUP_SECOND_EXIT"
assert_eq "stable duplicate writes bare plus new path markdown" "2" "$(saved_markdown_count "$STABLE_DUP_OBSIDIAN")"
assert_eq "stable duplicate does not clone previous bare transcript" "1" "$(saved_grep_count "stable B only" "$STABLE_DUP_OBSIDIAN")"
assert_eq "stable duplicate writes new transcript once" "1" "$(saved_grep_count "stable A only" "$STABLE_DUP_OBSIDIAN")"
STABLE_DUP_B_MD=$(grep -rl "stable B only" "$STABLE_DUP_OBSIDIAN" 2>/dev/null | head -1)
STABLE_DUP_A_MD=$(grep -rl "stable A only" "$STABLE_DUP_OBSIDIAN" 2>/dev/null | head -1)
assert_contains "stable duplicate previous bare stays bare" "$STABLE_DUP_B_MD" "session_id: \"stable-session\""
assert_not_contains "stable duplicate new path uses path id" "$STABLE_DUP_A_MD" "session_id: \"stable-session\""

echo ""
echo "=== Duplicate Claude JSONL keeps path identity after sibling disappears ==="

PATH_STABLE_HOME="$TEST_DIR/path-stable-home"
PATH_STABLE_STATE_DIR="$TEST_DIR/path-stable-state"
PATH_STABLE_OBSIDIAN="$TEST_DIR/path-stable-obsidian"
PATH_STABLE_PROJECTS_DIR="$TEST_DIR/path-stable-claude-projects"
PATH_STABLE_CODEX_DIR="$TEST_DIR/path-stable-codex-sessions"
PATH_STABLE_RECOVERY_LOG="$TEST_DIR/path-stable-recovery.log"
PATH_STABLE_RECALL_LIST="$TEST_DIR/path-stable-recall-list.json"
mkdir -p "$PATH_STABLE_HOME/.claude" "$PATH_STABLE_STATE_DIR" "$PATH_STABLE_OBSIDIAN" \
    "$PATH_STABLE_PROJECTS_DIR/project-a" "$PATH_STABLE_PROJECTS_DIR/project-b" "$PATH_STABLE_CODEX_DIR"

cat > "$PATH_STABLE_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

cat > "$PATH_STABLE_PROJECTS_DIR/project-a/child-a.jsonl" <<'EOF'
{"type":"user","sessionId":"path-stable-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"path stable A"}}
EOF
cat > "$PATH_STABLE_PROJECTS_DIR/project-b/child-b.jsonl" <<'EOF'
{"type":"user","sessionId":"path-stable-session","timestamp":"2026-06-03T00:00:01Z","message":{"role":"user","content":"path stable B"}}
EOF

if MOCK_RECALL_LIST="$PATH_STABLE_RECALL_LIST" \
HOME="$PATH_STABLE_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$PATH_STABLE_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$PATH_STABLE_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$PATH_STABLE_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$PATH_STABLE_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$PATH_STABLE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    PATH_STABLE_FIRST_EXIT=0
else
    PATH_STABLE_FIRST_EXIT=$?
fi

rm -f "$PATH_STABLE_PROJECTS_DIR/project-a/child-a.jsonl"
set_mtime_offset "$PATH_STABLE_PROJECTS_DIR/project-b/child-b.jsonl" 5

if MOCK_RECALL_LIST="$PATH_STABLE_RECALL_LIST" \
HOME="$PATH_STABLE_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$PATH_STABLE_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$PATH_STABLE_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$PATH_STABLE_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$PATH_STABLE_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$PATH_STABLE_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    PATH_STABLE_SECOND_EXIT=0
else
    PATH_STABLE_SECOND_EXIT=$?
fi

assert_eq "path-stable first recovery succeeds" "0" "$PATH_STABLE_FIRST_EXIT"
assert_eq "path-stable second recovery succeeds" "0" "$PATH_STABLE_SECOND_EXIT"
assert_eq "path-stable keeps original two saved markdown files" "2" "$(saved_markdown_count "$PATH_STABLE_OBSIDIAN")"
assert_eq "path-stable never creates a bare duplicate" "0" "$(grep -rl "session_id: \"path-stable-session\"" "$PATH_STABLE_OBSIDIAN" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "path-stable remaining transcript is not cloned" "1" "$(saved_grep_count "path stable B" "$PATH_STABLE_OBSIDIAN")"

echo ""
echo "=== Claude JSONL existing bare match scans beyond hook noise ==="

LONG_MATCH_HOME="$TEST_DIR/long-match-home"
LONG_MATCH_STATE_DIR="$TEST_DIR/long-match-state"
LONG_MATCH_OBSIDIAN="$TEST_DIR/long-match-obsidian"
LONG_MATCH_PROJECTS_DIR="$TEST_DIR/long-match-claude-projects"
LONG_MATCH_CODEX_DIR="$TEST_DIR/long-match-codex-sessions"
LONG_MATCH_RECOVERY_LOG="$TEST_DIR/long-match-recovery.log"
LONG_MATCH_RECALL_LIST="$TEST_DIR/long-match-recall-list.json"
mkdir -p "$LONG_MATCH_HOME/.claude" "$LONG_MATCH_STATE_DIR" "$LONG_MATCH_OBSIDIAN" \
    "$LONG_MATCH_PROJECTS_DIR" "$LONG_MATCH_CODEX_DIR"

cat > "$LONG_MATCH_RECALL_LIST" <<'EOF'
{"sessions":[]}
EOF

printf '%s' '{"messages":[{"role":"user","content":"long first"},{"role":"assistant","content":"long second"}]}' | \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
    python3 "$REPO_DIR/scripts/ai-log-writer.py" create \
    --date=2026-06-03 \
    --title=existing \
    --source="Claude Code" \
    --session-id=long-session \
    --record-kind=interactive \
    --tag=claude > "$LONG_MATCH_OBSIDIAN/existing.md"

cat > "$LONG_MATCH_PROJECTS_DIR/long-session.jsonl" <<'EOF'
{"type":"user","sessionId":"long-session","timestamp":"2026-06-03T00:00:00Z","message":{"role":"user","content":"long first"}}
EOF
python3 - "$LONG_MATCH_PROJECTS_DIR/long-session.jsonl" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "a", encoding="utf-8") as handle:
    for index in range(2000):
        print(
            json.dumps(
                {
                    "type": "hook_success",
                    "sessionId": "long-session",
                    "message": {"role": "system", "content": f"hook noise {index}"},
                },
                separators=(",", ":"),
            ),
            file=handle,
        )
    print(
        json.dumps(
            {
                "type": "assistant",
                "sessionId": "long-session",
                "timestamp": "2026-06-03T00:00:01Z",
                "message": {"role": "assistant", "content": "long second"},
            },
            separators=(",", ":"),
        ),
        file=handle,
    )
PY

if MOCK_RECALL_LIST="$LONG_MATCH_RECALL_LIST" \
HOME="$LONG_MATCH_HOME" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$LONG_MATCH_OBSIDIAN" \
AI_SECOND_BRAIN_STATE_DIR="$LONG_MATCH_STATE_DIR" \
AI_DAILY_RECOVERY_LOG="$LONG_MATCH_RECOVERY_LOG" \
AI_RECOVERY_LOOKBACK_DAYS=2 \
AI_RECOVERY_MAX_SESSIONS=10 \
CODEX_SESSIONS_DIR="$LONG_MATCH_CODEX_DIR" \
CLAUDE_PROJECTS_DIR="$LONG_MATCH_PROJECTS_DIR" \
SYNC_RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh" \
SYNC_CODEX_SCRIPT="$FAKE_CODEX_SYNC" \
    "$SCRIPT"; then
    LONG_MATCH_EXIT=0
else
    LONG_MATCH_EXIT=$?
fi

assert_eq "long match recovery succeeds" "0" "$LONG_MATCH_EXIT"
assert_eq "long match does not create duplicate markdown" "1" "$(saved_markdown_count "$LONG_MATCH_OBSIDIAN")"
assert_contains "long match bare note remains bare" "$LONG_MATCH_OBSIDIAN/existing.md" "session_id: \"long-session\""
assert_eq "long match second message remains single" "1" "$(saved_grep_count "long second" "$LONG_MATCH_OBSIDIAN")"

if find "$REPO_DIR/scripts" -maxdepth 2 -type f -path '*/__pycache__/*' | grep -q .; then
    fail "daily recovery avoids pycache"
else
    pass "daily recovery avoids pycache"
fi

echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
