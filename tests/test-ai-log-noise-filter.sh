#!/bin/bash
# Regression tests for conservative AI log noise filtering.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRITER="$REPO_DIR/scripts/ai-log-writer.py"
RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh"
CODEX_SCRIPT="$REPO_DIR/scripts/sync-codex-to-obsidian.sh"
TEST_DIR=$(mktemp -d /tmp/test-ai-log-noise-filter-XXXXXX)
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

assert_file_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (missing pattern: $pattern)"
    fi
}

assert_file_not_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq "$pattern" "$file" 2>/dev/null; then
        fail "$label (unexpected pattern: $pattern)"
    else
        pass "$label"
    fi
}

assert_file_count() {
    local label="$1" file="$2" pattern="$3" expected="$4"
    local actual
    actual=$(awk -v pat="$pattern" 'index($0, pat) {count++} END {print count + 0}' "$file" 2>/dev/null || printf '0\n')
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected: $expected, got: $actual)"
    fi
}

markdown_count() {
    find "$1" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

json_value() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

path, expression = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
for part in expression.split("."):
    value = value[int(part)] if part.isdigit() else value[part]
print(value)
PY
}

echo ""
echo "=== Writer filter ==="

MESSAGES_JSON="$TEST_DIR/messages.json"
cat > "$MESSAGES_JSON" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[heartbeat] no changes."},
    {"role": "assistant", "content": "Cron automation completed: no changes."},
    {"role": "assistant", "content": "Heartbeat automation completed."},
    {"role": "user", "content": "[cron] no changes."},
    {"role": "user", "content": "なんかheartbeatでcronが記録される件を相談したい"},
    {"role": "assistant", "content": "cronやheartbeatを通常ノートから外すのがよい"}
  ]
}
JSON

FILTERED_JSON="$TEST_DIR/filtered.json"
python3 "$WRITER" filter < "$MESSAGES_JSON" > "$FILTERED_JSON"

assert_eq "filter keeps ordinary discussion" "2" "$(json_value "$FILTERED_JSON" "count")"
assert_eq "filter counts omitted wrappers" "4" "$(json_value "$FILTERED_JSON" "omitted_count")"
assert_eq "kept user message is ordinary discussion" "なんかheartbeatでcronが記録される件を相談したい" "$(json_value "$FILTERED_JSON" "messages.0.content")"

EMPTY_MESSAGE_JSON="$TEST_DIR/empty-message.json"
cat > "$EMPTY_MESSAGE_JSON" <<'JSON'
{
  "messages": [
    {"role": "user", "content": ""},
    {"role": "assistant", "content": "   "}
  ]
}
JSON
EMPTY_MESSAGE_FILTERED_JSON="$TEST_DIR/empty-message-filtered.json"
python3 "$WRITER" filter --include-omitted < "$EMPTY_MESSAGE_JSON" > "$EMPTY_MESSAGE_FILTERED_JSON"
assert_eq "filter counts empty omitted messages" "2" "$(json_value "$EMPTY_MESSAGE_FILTERED_JSON" "omitted_count")"
assert_eq "filter keeps empty source positions" "2" "$(json_value "$EMPTY_MESSAGE_FILTERED_JSON" "source_count")"

WRAPPER_CONTENT_JSON="$TEST_DIR/wrapper-content.json"
cat > "$WRAPPER_CONTENT_JSON" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes\nでも同期されていないので調べて"},
    {"role": "user", "content": "[cron] no changes でも同期されていないので調べて"}
  ]
}
JSON
WRAPPER_CONTENT_FILTERED_JSON="$TEST_DIR/wrapper-content-filtered.json"
python3 "$WRITER" filter < "$WRAPPER_CONTENT_JSON" > "$WRAPPER_CONTENT_FILTERED_JSON"
assert_eq "filter keeps wrapper-prefixed multiline request" "2" "$(json_value "$WRAPPER_CONTENT_FILTERED_JSON" "count")"
assert_eq "wrapper-prefixed request omits nothing" "0" "$(json_value "$WRAPPER_CONTENT_FILTERED_JSON" "omitted_count")"

CRON_JOB_JSON="$TEST_DIR/cron-job.json"
cat > "$CRON_JOB_JSON" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "cron job failed: why?"},
    {"role": "user", "content": "[cron] job failed: why?"},
    {"role": "user", "content": "Cron automation failed: sync crashed with exit 1"}
  ]
}
JSON
CRON_JOB_FILTERED_JSON="$TEST_DIR/cron-job-filtered.json"
python3 "$WRITER" filter < "$CRON_JOB_JSON" > "$CRON_JOB_FILTERED_JSON"
assert_eq "filter keeps ordinary cron troubleshooting" "3" "$(json_value "$CRON_JOB_FILTERED_JSON" "count")"
assert_eq "ordinary cron troubleshooting omits nothing" "0" "$(json_value "$CRON_JOB_FILTERED_JSON" "omitted_count")"

XML_AUTOMATION_JSON="$TEST_DIR/xml-automation.json"
cat > "$XML_AUTOMATION_JSON" <<'JSON'
{
  "messages": [
    {"role": "assistant", "content": "<automation status=\"no changes\">checked</automation>"},
    {"role": "assistant", "content": "<automation status=\"failed\">sync crashed</automation>"},
    {"role": "assistant", "content": "<automation status=\"no changes\">でも同期されていないので調べて</automation>"},
    {"role": "assistant", "content": "<automation status=\"completed\" result=\"created 3 notes\"/>"},
    {"role": "assistant", "content": "<automation status=\"completed with warnings\"/>"},
    {"role": "assistant", "content": "<automation status=\"completed\" result=\"no changes\"/>"},
    {"role": "assistant", "content": "<automation status=\"completed\" source=\"launchd\"/>"}
  ]
}
JSON
XML_AUTOMATION_FILTERED_JSON="$TEST_DIR/xml-automation-filtered.json"
python3 "$WRITER" filter < "$XML_AUTOMATION_JSON" > "$XML_AUTOMATION_FILTERED_JSON"
assert_eq "filter keeps failed/substantive XML automation" "5" "$(json_value "$XML_AUTOMATION_FILTERED_JSON" "count")"
assert_eq "filter omits no-op XML automation" "2" "$(json_value "$XML_AUTOMATION_FILTERED_JSON" "omitted_count")"
assert_eq "failed XML automation content is preserved" "<automation status=\"failed\">sync crashed</automation>" "$(json_value "$XML_AUTOMATION_FILTERED_JSON" "messages.0.content")"
assert_eq "XML result attribute content is preserved" "<automation status=\"completed\" result=\"created 3 notes\"/>" "$(json_value "$XML_AUTOMATION_FILTERED_JSON" "messages.2.content")"
assert_eq "XML warning status is preserved" "<automation status=\"completed with warnings\"/>" "$(json_value "$XML_AUTOMATION_FILTERED_JSON" "messages.3.content")"

FILTER_DISABLED_JSON="$TEST_DIR/filter-disabled.json"
AI_LOG_NOISE_FILTER=0 python3 "$WRITER" filter < "$MESSAGES_JSON" > "$FILTER_DISABLED_JSON"

assert_eq "filter can be disabled" "6" "$(json_value "$FILTER_DISABLED_JSON" "count")"
assert_eq "disabled filter omits nothing" "0" "$(json_value "$FILTER_DISABLED_JSON" "omitted_count")"

WRITER_MD="$TEST_DIR/writer.md"
python3 "$WRITER" create \
    --date 2026-06-03 \
    --title "Noise filter" \
    --source "Codex" \
    --session-id "noise-filter-session" \
    --record-kind "interactive" \
    --tag "codex" < "$MESSAGES_JSON" > "$WRITER_MD"

assert_file_contains "writer records omitted count" "$WRITER_MD" "omitted_msg_count: 4"
assert_file_contains "writer counts kept messages" "$WRITER_MD" "msg_count: 2"
assert_file_contains "writer keeps ordinary cron discussion" "$WRITER_MD" "なんかheartbeatでcronが記録される件を相談したい"
assert_file_not_contains "writer omits heartbeat wrapper" "$WRITER_MD" "[heartbeat] no changes."
assert_file_not_contains "writer omits cron wrapper" "$WRITER_MD" "Cron automation completed"

NOISE_ONLY_APPEND_MD="$TEST_DIR/noise-only-append.md"
cat > "$TEST_DIR/noise-only-create.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "real answer"}
  ]
}
JSON
python3 "$WRITER" create \
    --date 2026-06-03 \
    --title "Noise only append" \
    --source "Codex" \
    --session-id "noise-only-append" \
    --record-kind "interactive" < "$TEST_DIR/noise-only-create.json" > "$NOISE_ONLY_APPEND_MD"
NOISE_ONLY_HASH_BEFORE=$(grep '^transcript_hash: ' "$NOISE_ONLY_APPEND_MD")
cat > "$TEST_DIR/noise-only-append.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "real answer"},
    {"role": "assistant", "content": "[heartbeat] no changes."}
  ]
}
JSON
python3 "$WRITER" append --existing-file "$NOISE_ONLY_APPEND_MD" < "$TEST_DIR/noise-only-append.json" > "$TEST_DIR/noise-only-next.md"
mv "$TEST_DIR/noise-only-next.md" "$NOISE_ONLY_APPEND_MD"
assert_file_contains "noise-only append records omitted audit" "$NOISE_ONLY_APPEND_MD" "omitted_msg_count: 1"
assert_file_contains "noise-only append keeps saved message count" "$NOISE_ONLY_APPEND_MD" "msg_count: 2"
assert_eq "noise-only append keeps transcript hash" "$NOISE_ONLY_HASH_BEFORE" "$(grep '^transcript_hash: ' "$NOISE_ONLY_APPEND_MD")"

DISABLED_APPEND_MD="$TEST_DIR/disabled-append.md"
cat > "$TEST_DIR/disabled-append-create.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real disabled task"}
  ]
}
JSON
python3 "$WRITER" create \
    --date 2026-06-03 \
    --title "Disabled append" \
    --source "Codex" \
    --session-id "disabled-append" \
    --record-kind "interactive" < "$TEST_DIR/disabled-append-create.json" > "$DISABLED_APPEND_MD"

cat > "$TEST_DIR/disabled-append-source.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real disabled task"},
    {"role": "assistant", "content": "disabled filter answer"}
  ]
}
JSON
AI_LOG_NOISE_FILTER=0 python3 "$WRITER" append --existing-file "$DISABLED_APPEND_MD" < "$TEST_DIR/disabled-append-source.json" > "$TEST_DIR/disabled-append-next.md"
mv "$TEST_DIR/disabled-append-next.md" "$DISABLED_APPEND_MD"
assert_file_contains "disabled filter append keeps compatibility" "$DISABLED_APPEND_MD" "disabled filter answer"
assert_file_contains "disabled filter append preserves omitted audit" "$DISABLED_APPEND_MD" "omitted_msg_count: 1"
assert_file_not_contains "disabled filter append does not backfill old wrapper" "$DISABLED_APPEND_MD" "[cron] no changes"

echo ""
echo "=== Writer shared legacy noisy chain append ==="

SHARED_CHAIN_MD="$TEST_DIR/shared-chain.md"
cat > "$TEST_DIR/shared-chain-existing.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"}
  ]
}
JSON
AI_LOG_NOISE_FILTER=0 python3 "$WRITER" create \
    --date 2026-06-03 \
    --title "Shared chain" \
    --source "Claude Code" \
    --session-id "shared-chain" \
    --record-kind "interactive" < "$TEST_DIR/shared-chain-existing.json" > "$SHARED_CHAIN_MD"

cat > "$TEST_DIR/shared-chain-append1.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "[heartbeat] no changes"},
    {"role": "assistant", "content": "real answer"}
  ]
}
JSON
python3 "$WRITER" append --existing-file "$SHARED_CHAIN_MD" < "$TEST_DIR/shared-chain-append1.json" > "$TEST_DIR/shared-chain-next.md"
mv "$TEST_DIR/shared-chain-next.md" "$SHARED_CHAIN_MD"

cat > "$TEST_DIR/shared-chain-append2.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "[heartbeat] no changes"},
    {"role": "assistant", "content": "real answer"},
    {"role": "user", "content": "follow up"}
  ]
}
JSON
python3 "$WRITER" append --existing-file "$SHARED_CHAIN_MD" < "$TEST_DIR/shared-chain-append2.json" > "$TEST_DIR/shared-chain-next.md"
mv "$TEST_DIR/shared-chain-next.md" "$SHARED_CHAIN_MD"

assert_file_contains "shared noisy chain appends after omitted count exists" "$SHARED_CHAIN_MD" "follow up"
assert_file_contains "shared noisy chain updates message count" "$SHARED_CHAIN_MD" "msg_count: 4"
assert_file_contains "shared noisy chain keeps omitted count" "$SHARED_CHAIN_MD" "omitted_msg_count: 2"

SHARED_SECRET_MD="$TEST_DIR/shared-secret.md"
SHARED_SECRET_LINE="api_key=sk-ant-api03-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghi"
python3 - "$SHARED_SECRET_MD" "$SHARED_SECRET_LINE" <<'PY'
import hashlib
import sys

path, secret = sys.argv[1:3]
transcript = f"### User 1\n\n{secret}\n"
digest = "sha256:" + hashlib.sha256(transcript.encode("utf-8")).hexdigest()
with open(path, "w", encoding="utf-8") as handle:
    handle.write(
        f"""---
date: 2026-06-03
title: "Shared secret"
source: "Claude Code"
session_id: "shared-secret"
record_kind: "interactive"
msg_count: 1
last_message_hash: "{digest}"
transcript_hash: "{digest}"
tags:
  - "ai-log"
---

# Shared secret

## Summary

## Transcript

{transcript}"""
    )
PY

cat > "$TEST_DIR/shared-secret-source.json" <<JSON
{
  "messages": [
    {"role": "user", "content": "$SHARED_SECRET_LINE"},
    {"role": "assistant", "content": "[cron] no changes"},
    {"role": "assistant", "content": "shared secret answer"}
  ]
}
JSON
python3 "$WRITER" append --existing-file "$SHARED_SECRET_MD" < "$TEST_DIR/shared-secret-source.json" > "$TEST_DIR/shared-secret-next.md"
mv "$TEST_DIR/shared-secret-next.md" "$SHARED_SECRET_MD"
assert_file_not_contains "shared noisy append removes legacy raw secret" "$SHARED_SECRET_MD" "$SHARED_SECRET_LINE"
assert_file_contains "shared noisy append migrates legacy secret" "$SHARED_SECRET_MD" "api_key=[REDACTED]"
assert_file_contains "shared noisy append keeps useful answer after redaction migration" "$SHARED_SECRET_MD" "shared secret answer"
assert_file_contains "shared noisy append updates redacted message count" "$SHARED_SECRET_MD" "msg_count: 2"
assert_file_contains "shared noisy append records omitted secret-chain count" "$SHARED_SECRET_MD" "omitted_msg_count: 1"

echo ""
echo "=== Claude sync all-filtered session ==="

MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN" "$TEST_DIR/claude-notes" "$TEST_DIR/home/.claude"
cat > "$MOCK_BIN/recall" <<'EOF'
#!/bin/bash
if [ "$1" = "read" ]; then
    cat "$MOCK_RECALL_DATA"
elif [ "$1" = "list" ]; then
    printf '{"sessions":[]}\n'
fi
EOF
chmod +x "$MOCK_BIN/recall"

cat > "$TEST_DIR/claude-all-filtered.json" <<'JSON'
{
  "session_id": "claude-all-filtered",
  "source": "claude",
  "timestamp": "2026-06-03T09:00:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "assistant", "content": "Heartbeat automation completed: no changes"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-all-filtered.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$TEST_DIR/claude-notes" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-all-filtered"

assert_eq "all-filtered claude session creates no markdown" "0" "$(markdown_count "$TEST_DIR/claude-notes")"

cat > "$TEST_DIR/claude-ordinary.json" <<'JSON'
{
  "session_id": "claude-ordinary",
  "source": "claude",
  "timestamp": "2026-06-03T09:10:00Z",
  "messages": [
    {"role": "user", "content": "cronとheartbeatの保存方針を相談したい"},
    {"role": "assistant", "content": "普通の会話なので保存する"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-ordinary.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$TEST_DIR/claude-notes" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-ordinary"

assert_eq "ordinary claude discussion creates markdown" "1" "$(markdown_count "$TEST_DIR/claude-notes")"
CLAUDE_MD=$(find "$TEST_DIR/claude-notes" -maxdepth 1 -name '*.md' -type f | head -1)
assert_file_contains "ordinary claude discussion is preserved" "$CLAUDE_MD" "cronとheartbeatの保存方針を相談したい"

echo ""
echo "=== Codex sync all-filtered session ==="

mkdir -p "$TEST_DIR/codex-notes" "$TEST_DIR/codex-sessions"
CODEX_JSONL="$TEST_DIR/codex-sessions/all-filtered.jsonl"
cat > "$CODEX_JSONL" <<'JSONL'
{"type":"session_meta","timestamp":"2026-06-03T10:00:00Z","payload":{"id":"123e4567-e89b-12d3-a456-426614174111","timestamp":"2026-06-03T10:00:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[cron] no changes"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Heartbeat automation completed: no changes"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_JSONL"

assert_eq "all-filtered codex session creates no markdown" "0" "$(markdown_count "$TEST_DIR/codex-notes")"

echo ""
echo "=== Codex sync legacy noisy append ==="

LEGACY_CODEX_SID="123e4567-e89b-12d3-a456-426614174222"
LEGACY_CODEX_MD="$TEST_DIR/codex-notes/legacy-noisy-codex.md"
cat > "$TEST_DIR/codex-legacy-existing.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"}
  ]
}
JSON
AI_LOG_NOISE_FILTER=0 python3 "$WRITER" create \
    --date 2026-06-03 \
    --title "Legacy noisy Codex" \
    --source "Codex" \
    --session-id "$LEGACY_CODEX_SID" \
    --record-kind "interactive" \
    --tag "codex" < "$TEST_DIR/codex-legacy-existing.json" > "$LEGACY_CODEX_MD"

LEGACY_CODEX_JSONL="$TEST_DIR/codex-sessions/legacy-noisy.jsonl"
cat > "$LEGACY_CODEX_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:20:00Z","payload":{"id":"$LEGACY_CODEX_SID","timestamp":"2026-06-03T10:20:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[cron] no changes"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"real task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"real answer"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$LEGACY_CODEX_JSONL"

assert_file_contains "legacy codex append keeps existing noisy entry" "$LEGACY_CODEX_MD" "[cron] no changes"
assert_file_contains "legacy codex append adds useful answer" "$LEGACY_CODEX_MD" "real answer"
assert_file_contains "legacy codex append updates message count" "$LEGACY_CODEX_MD" "msg_count: 3"
assert_file_contains "legacy codex append records omitted count" "$LEGACY_CODEX_MD" "omitted_msg_count: 1"

cat > "$LEGACY_CODEX_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:22:00Z","payload":{"id":"$LEGACY_CODEX_SID","timestamp":"2026-06-03T10:22:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[cron] no changes"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"real task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"real answer"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"codex follow up after noise"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$LEGACY_CODEX_JSONL"

assert_file_contains "legacy codex noisy chain adds follow up" "$LEGACY_CODEX_MD" "codex follow up after noise"
assert_file_count "legacy codex noisy chain does not duplicate answer" "$LEGACY_CODEX_MD" "real answer" "1"

echo ""
echo "=== Codex sync legacy Q/A noisy append ==="

LEGACY_QA_CODEX_SID="123e4567-e89b-12d3-a456-426614174333"
LEGACY_QA_CODEX_MD="$TEST_DIR/codex-notes/legacy-qa-noisy-codex.md"
cat > "$LEGACY_QA_CODEX_MD" <<MD
---
date: 2026-06-03
session_id: "$LEGACY_QA_CODEX_SID"
msg_count: 2
---
# Legacy Q/A Codex

## Q1
[cron] no changes

## Q2
real task

MD

LEGACY_QA_CODEX_JSONL="$TEST_DIR/codex-sessions/legacy-qa-noisy.jsonl"
cat > "$LEGACY_QA_CODEX_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:25:00Z","payload":{"id":"$LEGACY_QA_CODEX_SID","timestamp":"2026-06-03T10:25:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[cron] no changes"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"real task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"real answer 1"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"real answer 2"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$LEGACY_QA_CODEX_JSONL"

assert_file_contains "legacy Q/A codex append adds first useful answer" "$LEGACY_QA_CODEX_MD" "real answer 1"
assert_file_contains "legacy Q/A codex append adds second useful answer" "$LEGACY_QA_CODEX_MD" "real answer 2"
assert_file_contains "legacy Q/A codex append updates raw message count" "$LEGACY_QA_CODEX_MD" "msg_count: 4"

LEGACY_QA_SHIFT_CODEX_SID="123e4567-e89b-12d3-a456-426614174334"
LEGACY_QA_SHIFT_CODEX_MD="$TEST_DIR/codex-notes/legacy-qa-shift-codex.md"
cat > "$LEGACY_QA_SHIFT_CODEX_MD" <<MD
---
date: 2026-06-03
session_id: "$LEGACY_QA_SHIFT_CODEX_SID"
msg_count: 1
---
# Legacy Q/A Codex Shift

## Q1
real shifted task

MD

LEGACY_QA_SHIFT_CODEX_JSONL="$TEST_DIR/codex-sessions/legacy-qa-shift.jsonl"
cat > "$LEGACY_QA_SHIFT_CODEX_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:27:00Z","payload":{"id":"$LEGACY_QA_SHIFT_CODEX_SID","timestamp":"2026-06-03T10:27:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[cron] no changes"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"real shifted task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"shifted answer"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$LEGACY_QA_SHIFT_CODEX_JSONL"

assert_file_contains "legacy Q/A codex shifted append adds answer" "$LEGACY_QA_SHIFT_CODEX_MD" "shifted answer"
assert_file_count "legacy Q/A codex shifted append does not duplicate saved task" "$LEGACY_QA_SHIFT_CODEX_MD" "real shifted task" "1"
assert_file_contains "legacy Q/A codex shifted append updates raw message count" "$LEGACY_QA_SHIFT_CODEX_MD" "msg_count: 3"

echo ""
echo "=== Claude sync legacy noisy append ==="

CLAUDE_LEGACY_DIR="$TEST_DIR/claude-legacy-notes"
mkdir -p "$CLAUDE_LEGACY_DIR"
LEGACY_CLAUDE_MD="$CLAUDE_LEGACY_DIR/legacy-noisy-claude.md"
cat > "$TEST_DIR/claude-legacy-existing.json" <<'JSON'
{
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"}
  ]
}
JSON
AI_LOG_NOISE_FILTER=0 python3 "$WRITER" create \
    --date 2026-06-03 \
    --title "Legacy noisy Claude" \
    --source "Claude Code" \
    --session-id "claude-legacy-noise" \
    --record-kind "interactive" \
    --tag "claude" < "$TEST_DIR/claude-legacy-existing.json" > "$LEGACY_CLAUDE_MD"

cat > "$TEST_DIR/claude-legacy-append.json" <<'JSON'
{
  "session_id": "claude-legacy-noise",
  "source": "claude",
  "timestamp": "2026-06-03T10:30:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "real answer"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-append.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-noise"

assert_file_contains "legacy claude append keeps existing noisy entry" "$LEGACY_CLAUDE_MD" "[cron] no changes"
assert_file_contains "legacy claude append adds useful answer" "$LEGACY_CLAUDE_MD" "real answer"
assert_file_contains "legacy claude append updates message count" "$LEGACY_CLAUDE_MD" "msg_count: 3"
assert_file_contains "legacy claude append records omitted count" "$LEGACY_CLAUDE_MD" "omitted_msg_count: 1"

cat > "$TEST_DIR/claude-legacy-followup.json" <<'JSON'
{
  "session_id": "claude-legacy-noise",
  "source": "claude",
  "timestamp": "2026-06-03T10:32:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "real answer"},
    {"role": "user", "content": "claude follow up after noise"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-followup.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-noise"

assert_file_contains "legacy claude noisy chain adds follow up" "$LEGACY_CLAUDE_MD" "claude follow up after noise"
assert_file_count "legacy claude noisy chain does not duplicate answer" "$LEGACY_CLAUDE_MD" "real answer" "1"

echo ""
echo "=== Claude sync legacy Q/A noisy append ==="

LEGACY_QA_CLAUDE_MD="$CLAUDE_LEGACY_DIR/legacy-qa-noisy-claude.md"
cat > "$LEGACY_QA_CLAUDE_MD" <<'MD'
---
date: 2026-06-03
session_id: "claude-legacy-qa-noise"
msg_count: 2
---
# Legacy Q/A Claude

## Q1
[cron] no changes

## Q2
real task

MD

cat > "$TEST_DIR/claude-legacy-qa-append.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-noise",
  "source": "claude",
  "timestamp": "2026-06-03T10:35:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real task"},
    {"role": "assistant", "content": "real answer 1"},
    {"role": "assistant", "content": "real answer 2"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-append.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-noise"

assert_file_contains "legacy Q/A claude append adds first useful answer" "$LEGACY_QA_CLAUDE_MD" "real answer 1"
assert_file_contains "legacy Q/A claude append adds second useful answer" "$LEGACY_QA_CLAUDE_MD" "real answer 2"

LEGACY_QA_SHIFT_CLAUDE_MD="$CLAUDE_LEGACY_DIR/legacy-qa-shift-claude.md"
cat > "$LEGACY_QA_SHIFT_CLAUDE_MD" <<'MD'
---
date: 2026-06-03
session_id: "claude-legacy-qa-shift"
msg_count: 1
---
# Legacy Q/A Claude Shift

## Q1
real shifted task

MD

cat > "$TEST_DIR/claude-legacy-qa-shift.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-shift",
  "source": "claude",
  "timestamp": "2026-06-03T10:37:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real shifted task"},
    {"role": "assistant", "content": "shifted answer"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-shift.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-shift"

assert_file_contains "legacy Q/A claude shifted append adds answer" "$LEGACY_QA_SHIFT_CLAUDE_MD" "shifted answer"
assert_file_count "legacy Q/A claude shifted append does not duplicate saved task" "$LEGACY_QA_SHIFT_CLAUDE_MD" "real shifted task" "1"
assert_file_contains "legacy Q/A claude shifted append updates raw message count" "$LEGACY_QA_SHIFT_CLAUDE_MD" "msg_count: 3"

echo ""
echo "=== Claude sync legacy Q/A interleaved noise chain ==="

LEGACY_QA_INTERLEAVED_MD="$CLAUDE_LEGACY_DIR/legacy-qa-interleaved-claude.md"
cat > "$LEGACY_QA_INTERLEAVED_MD" <<'MD'
---
date: 2026-06-03
session_id: "claude-legacy-qa-interleaved"
msg_count: 2
---
# Legacy Q/A Claude Interleaved

## Q1
old question

## A1
old answer

MD

cat > "$TEST_DIR/claude-legacy-qa-interleaved-append1.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-interleaved",
  "source": "claude",
  "timestamp": "2026-06-03T10:40:00Z",
  "messages": [
    {"role": "user", "content": "old question"},
    {"role": "assistant", "content": "old answer"},
    {"role": "user", "content": "[cron] no changes"},
    {"role": "assistant", "content": "interleaved answer"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-interleaved-append1.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-interleaved"

cat > "$TEST_DIR/claude-legacy-qa-interleaved-append2.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-interleaved",
  "source": "claude",
  "timestamp": "2026-06-03T10:45:00Z",
  "messages": [
    {"role": "user", "content": "old question"},
    {"role": "assistant", "content": "old answer"},
    {"role": "user", "content": "[cron] no changes"},
    {"role": "assistant", "content": "interleaved answer"},
    {"role": "user", "content": "interleaved follow up"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-interleaved-append2.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-interleaved"

assert_file_contains "legacy Q/A interleaved append adds follow up" "$LEGACY_QA_INTERLEAVED_MD" "interleaved follow up"
assert_file_count "legacy Q/A interleaved append does not duplicate answer" "$LEGACY_QA_INTERLEAVED_MD" "interleaved answer" "1"
assert_file_contains "legacy Q/A interleaved append updates raw message count" "$LEGACY_QA_INTERLEAVED_MD" "msg_count: 5"

echo ""
echo "=== Claude sync legacy Q/A no msg_count noise ==="

LEGACY_QA_NO_COUNT_MD="$CLAUDE_LEGACY_DIR/legacy-qa-no-count-claude.md"
cat > "$LEGACY_QA_NO_COUNT_MD" <<'MD'
---
date: 2026-06-03
session_id: "claude-legacy-qa-no-count"
---
# Legacy Q/A Claude No Count

## Q1
real no-count task

MD

cat > "$TEST_DIR/claude-legacy-qa-no-count.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-no-count",
  "source": "claude",
  "timestamp": "2026-06-03T10:50:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real no-count task"},
    {"role": "assistant", "content": "no-count answer"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-no-count.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-no-count"

assert_file_contains "legacy Q/A no-count append adds answer" "$LEGACY_QA_NO_COUNT_MD" "no-count answer"
assert_file_count "legacy Q/A no-count append does not duplicate saved task" "$LEGACY_QA_NO_COUNT_MD" "real no-count task" "1"

LEGACY_QA_NO_COUNT_SAVED_NOISE_MD="$CLAUDE_LEGACY_DIR/legacy-qa-no-count-saved-noise-claude.md"
cat > "$LEGACY_QA_NO_COUNT_SAVED_NOISE_MD" <<'MD'
---
date: 2026-06-03
session_id: "claude-legacy-qa-no-count-saved-noise"
---
# Legacy Q/A Claude No Count Saved Noise

## Q1
[cron] no changes

## Q2
real saved-noise task

MD

cat > "$TEST_DIR/claude-legacy-qa-no-count-saved-noise.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-no-count-saved-noise",
  "source": "claude",
  "timestamp": "2026-06-03T10:52:00Z",
  "messages": [
    {"role": "user", "content": "[cron] no changes"},
    {"role": "user", "content": "real saved-noise task"},
    {"role": "assistant", "content": "saved-noise answer 1"},
    {"role": "assistant", "content": "saved-noise answer 2"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-no-count-saved-noise.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-no-count-saved-noise"

assert_file_contains "legacy Q/A no-count saved-noise appends first answer" "$LEGACY_QA_NO_COUNT_SAVED_NOISE_MD" "saved-noise answer 1"
assert_file_contains "legacy Q/A no-count saved-noise appends second answer" "$LEGACY_QA_NO_COUNT_SAVED_NOISE_MD" "saved-noise answer 2"
assert_file_count "legacy Q/A no-count saved-noise does not duplicate saved task" "$LEGACY_QA_NO_COUNT_SAVED_NOISE_MD" "real saved-noise task" "1"

echo ""
echo "=== Claude sync legacy Q/A interleaved empty chain ==="

LEGACY_QA_EMPTY_MD="$CLAUDE_LEGACY_DIR/legacy-qa-empty-claude.md"
cat > "$LEGACY_QA_EMPTY_MD" <<'MD'
---
date: 2026-06-03
session_id: "claude-legacy-qa-empty"
msg_count: 1
---
# Legacy Q/A Claude Empty

## Q1
empty chain old

MD

cat > "$TEST_DIR/claude-legacy-qa-empty-append1.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-empty",
  "source": "claude",
  "timestamp": "2026-06-03T10:55:00Z",
  "messages": [
    {"role": "user", "content": "empty chain old"},
    {"role": "assistant", "content": ""},
    {"role": "assistant", "content": "empty chain answer"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-empty-append1.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-empty"

cat > "$TEST_DIR/claude-legacy-qa-empty-append2.json" <<'JSON'
{
  "session_id": "claude-legacy-qa-empty",
  "source": "claude",
  "timestamp": "2026-06-03T11:00:00Z",
  "messages": [
    {"role": "user", "content": "empty chain old"},
    {"role": "assistant", "content": ""},
    {"role": "assistant", "content": "empty chain answer"},
    {"role": "user", "content": "empty chain follow"}
  ]
}
JSON

MOCK_RECALL_DATA="$TEST_DIR/claude-legacy-qa-empty-append2.json" \
HOME="$TEST_DIR/home" \
PATH="$MOCK_BIN:$PATH" \
SECOND_BRAIN_DIR="$CLAUDE_LEGACY_DIR" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$RECALL_SCRIPT" "claude-legacy-qa-empty"

assert_file_contains "legacy Q/A empty append adds follow up" "$LEGACY_QA_EMPTY_MD" "empty chain follow"
assert_file_count "legacy Q/A empty append does not duplicate answer" "$LEGACY_QA_EMPTY_MD" "empty chain answer" "1"
assert_file_contains "legacy Q/A empty append updates raw message count" "$LEGACY_QA_EMPTY_MD" "msg_count: 4"

echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
