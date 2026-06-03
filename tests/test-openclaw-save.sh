#!/bin/bash
# Regression tests for OpenClaw/Himeno event source-page saves.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/save-openclaw-event.py"
TEST_DIR=$(mktemp -d /tmp/test-openclaw-save-XXXXXX)
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR"
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

run_event() {
    local json="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    printf '%s' "$json" | python3 "$SCRIPT" >"$stdout_file" 2>"$stderr_file" && return 0
    return $?
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected: $expected, got: $actual)"
    fi
}

assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -Fq -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label (missing: $needle)"
    fi
}

assert_file_not_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -Fq -- "$needle" "$file"; then
        fail "$label (unexpected: $needle)"
    else
        pass "$label"
    fi
}

assert_count() {
    local label="$1" expected="$2"
    local count
    count=$(find "$SECOND_BRAIN_DIR/OpenClaw/sources" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "$label" "$expected" "$count"
}

event_path_from() {
    local file="$1"
    head -n 1 "$file"
}

export SECOND_BRAIN_DIR="$TEST_DIR/notes"
export REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py"
mkdir -p "$SECOND_BRAIN_DIR"

echo "=== task_result save ==="

task_json='{
  "record_kind": "task_result",
  "title": "Deploy completed",
  "task_id": "task-123",
  "completed_at": "2026-06-03T10:00:00+09:00",
  "summary": "Deployment finished with OPENAI_API_KEY=sk-proj-openclawPhaseToken0000000000",
  "content": "Authorization: Bearer openclawBearerToken000000000000\nNormal result stayed visible.",
  "next_actions": ["Watch metrics"]
}'

if run_event "$task_json" "$TEST_DIR/task.out" "$TEST_DIR/task.err"; then
    pass "task_result exits 0"
else
    fail "task_result exits 0"
fi
TASK_MD=$(event_path_from "$TEST_DIR/task.out")
if [ -f "$TASK_MD" ]; then
    pass "task_result markdown is created"
else
    fail "task_result markdown is created"
fi
assert_file_contains "task_result under OpenClaw sources" "$TEST_DIR/task.out" "$SECOND_BRAIN_DIR/OpenClaw/sources/"
assert_file_contains "task_result has date" "$TASK_MD" "date: 2026-06-03"
assert_file_contains "task_result has source" "$TASK_MD" 'source: "OpenClaw/Himeno"'
assert_file_contains "task_result has session id" "$TASK_MD" 'session_id: "openclaw:task_result:'
assert_file_contains "task_result has record kind" "$TASK_MD" 'record_kind: "task_result"'
assert_file_contains "task_result has msg count" "$TASK_MD" "msg_count: 1"
assert_file_contains "task_result has last hash" "$TASK_MD" 'last_message_hash: "sha256:'
assert_file_contains "task_result has transcript hash" "$TASK_MD" 'transcript_hash: "sha256:'
assert_file_contains "task_result has dedupe hash" "$TASK_MD" 'dedupe_key_hash: "sha256:'
assert_file_contains "task_result has Summary" "$TASK_MD" "## Summary"
assert_file_contains "task_result has Decisions" "$TASK_MD" "## Decisions"
assert_file_contains "task_result has Next Actions" "$TASK_MD" "## Next Actions"
assert_file_contains "task_result has Transcript" "$TASK_MD" "## Transcript"
assert_file_contains "task_result keeps normal content" "$TASK_MD" "Normal result stayed visible."
assert_file_contains "task_result masks API key" "$TASK_MD" "[REDACTED]"
assert_file_contains "task_result masks bearer" "$TASK_MD" "Bearer [REDACTED]"
assert_file_not_contains "task_result omits API key value" "$TASK_MD" "openclawPhaseToken"
assert_file_not_contains "task_result omits bearer value" "$TASK_MD" "openclawBearerToken"
assert_file_not_contains "task_result stdout omits secret" "$TEST_DIR/task.out" "openclawPhaseToken"
assert_count "one OpenClaw source after task_result" "1"

duplicate_task_json='{
  "record_kind": "task_result",
  "title": "Changed title should not create duplicate",
  "task_id": "task-123",
  "completed_at": "2026-06-03T10:00:00+09:00",
  "summary": "Deployment finished with a changed title.",
  "content": "Normal result stayed visible."
}'
run_event "$duplicate_task_json" "$TEST_DIR/task-dup.out" "$TEST_DIR/task-dup.err" || fail "duplicate task_result exits 0"
assert_eq "duplicate task_result returns existing path" "$TASK_MD" "$(event_path_from "$TEST_DIR/task-dup.out")"
assert_count "duplicate task_result does not add file" "1"

echo "=== allowed OpenClaw event kinds ==="

decision_json='{
  "record_kind": "user_decision",
  "date": "2026-06-03",
  "source_message_id": "msg-456",
  "summary": "Use Markdown as the source of truth.",
  "decisions": ["Obsidian is only a viewer"]
}'
run_event "$decision_json" "$TEST_DIR/decision.out" "$TEST_DIR/decision.err" || fail "user_decision exits 0"
DECISION_MD=$(event_path_from "$TEST_DIR/decision.out")
assert_file_contains "user_decision uses record kind" "$DECISION_MD" 'record_kind: "user_decision"'
assert_file_contains "user_decision keeps decision" "$DECISION_MD" "Obsidian is only a viewer"

failure_json='{
  "record_kind": "failure_recovery",
  "incident_id": "incident-789",
  "recovered_at": "2026-06-03T11:00:00+09:00",
  "summary": "iCloud write failed and was retried.",
  "content": "Recovery succeeded after rerun."
}'
run_event "$failure_json" "$TEST_DIR/failure.out" "$TEST_DIR/failure.err" || fail "failure_recovery exits 0"
FAILURE_MD=$(event_path_from "$TEST_DIR/failure.out")
assert_file_contains "failure_recovery uses record kind" "$FAILURE_MD" 'record_kind: "failure_recovery"'
assert_file_contains "failure_recovery keeps recovery note" "$FAILURE_MD" "Recovery succeeded after rerun."

lesson_json='{
  "record_kind": "ops_lesson",
  "date": "2026-06-03",
  "source_artifact_path": "/tmp/openclaw/report.md",
  "summary": "Retry writes when iCloud returns a transient error.",
  "content": "Use deterministic scripts for capture."
}'
run_event "$lesson_json" "$TEST_DIR/lesson.out" "$TEST_DIR/lesson.err" || fail "ops_lesson exits 0"
LESSON_MD=$(event_path_from "$TEST_DIR/lesson.out")
assert_file_contains "ops_lesson uses record kind" "$LESSON_MD" 'record_kind: "ops_lesson"'
assert_file_contains "ops_lesson keeps source artifact" "$LESSON_MD" "source_artifact_path: /tmp/openclaw/report.md"

daily_json='{
  "record_kind": "daily_summary",
  "date": "2026-06-03",
  "summary": "Himeno saved only durable work outcomes today.",
  "next_actions": ["Run daily recovery tomorrow"]
}'
run_event "$daily_json" "$TEST_DIR/daily.out" "$TEST_DIR/daily.err" || fail "daily_summary exits 0"
DAILY_MD=$(event_path_from "$TEST_DIR/daily.out")
assert_file_contains "daily_summary uses record kind" "$DAILY_MD" 'record_kind: "daily_summary"'
assert_file_contains "daily_summary keeps next action" "$DAILY_MD" "Run daily recovery tomorrow"
assert_count "all allowed kinds are saved" "5"

echo "=== UTF-8 stdin under C locale ==="

UNICODE_SECOND_BRAIN_DIR="$TEST_DIR/日本語-notes"
mkdir -p "$UNICODE_SECOND_BRAIN_DIR"
unicode_json='{
  "record_kind": "daily_summary",
  "date": "2026-06-04",
  "summary": "日本語の要約"
}'
if printf '%s' "$unicode_json" | LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 SECOND_BRAIN_DIR="$UNICODE_SECOND_BRAIN_DIR" REDACTION_HELPER="$REDACTION_HELPER" python3 "$SCRIPT" >"$TEST_DIR/unicode.out" 2>"$TEST_DIR/unicode.err"; then
    pass "UTF-8 stdin works under C locale"
else
    fail "UTF-8 stdin works under C locale"
fi
UNICODE_MD=$(event_path_from "$TEST_DIR/unicode.out")
assert_file_contains "UTF-8 stdin keeps Japanese" "$UNICODE_MD" "日本語の要約"
assert_file_not_contains "UTF-8 stdin avoids traceback" "$TEST_DIR/unicode.err" "Traceback"
assert_file_contains "UTF-8 stdout keeps non-ASCII path" "$TEST_DIR/unicode.out" "日本語-notes"

echo "=== rejected inputs ==="

heartbeat_json='{
  "record_kind": "heartbeat",
  "date": "2026-06-03",
  "summary": "Routine heartbeat noise."
}'
if run_event "$heartbeat_json" "$TEST_DIR/heartbeat.out" "$TEST_DIR/heartbeat.err"; then
    fail "heartbeat is rejected"
else
    pass "heartbeat is rejected"
fi
assert_file_contains "heartbeat explains allowed kinds" "$TEST_DIR/heartbeat.err" "unsupported record_kind"
assert_count "heartbeat does not add file" "5"

missing_task_json='{
  "record_kind": "task_result",
  "completed_at": "2026-06-03T12:00:00+09:00",
  "summary": "Missing task id."
}'
if run_event "$missing_task_json" "$TEST_DIR/missing-task.out" "$TEST_DIR/missing-task.err"; then
    fail "missing task_id is rejected"
else
    pass "missing task_id is rejected"
fi
assert_file_contains "missing task_id explains field" "$TEST_DIR/missing-task.err" "missing required field: task_id"
assert_count "missing task_id does not add file" "5"

empty_content_json='{
  "record_kind": "daily_summary",
  "date": "2026-06-03"
}'
if run_event "$empty_content_json" "$TEST_DIR/empty.out" "$TEST_DIR/empty.err"; then
    fail "empty content is rejected"
else
    pass "empty content is rejected"
fi
assert_file_contains "empty content explains failure" "$TEST_DIR/empty.err" "missing event content"

echo "=== safe output paths ==="

SYMLINK_ROOT="$TEST_DIR/notes-link"
ln -s "$SECOND_BRAIN_DIR" "$SYMLINK_ROOT"
REAL_SECOND_BRAIN_DIR="$SECOND_BRAIN_DIR"
export SECOND_BRAIN_DIR="$SYMLINK_ROOT"
if run_event "$daily_json" "$TEST_DIR/symlink-root.out" "$TEST_DIR/symlink-root.err"; then
    fail "symlink SECOND_BRAIN_DIR is rejected"
else
    pass "symlink SECOND_BRAIN_DIR is rejected"
fi
assert_file_contains "symlink root explains failure" "$TEST_DIR/symlink-root.err" "non-symlink"
export SECOND_BRAIN_DIR="$REAL_SECOND_BRAIN_DIR"

if find "$TEST_DIR" -name '__pycache__' -type d | grep -q .; then
    fail "OpenClaw save avoids pycache"
else
    pass "OpenClaw save avoids pycache"
fi

echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
