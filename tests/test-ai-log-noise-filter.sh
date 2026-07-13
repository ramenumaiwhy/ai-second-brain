#!/bin/bash
# Regression tests for conservative AI log noise filtering.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRITER="$REPO_DIR/scripts/ai-log-writer.py"
RECALL_SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh"
CODEX_SCRIPT="$REPO_DIR/scripts/sync-codex-to-obsidian.sh"
SEARCH_SCRIPT="$REPO_DIR/scripts/search-second-brain.sh"
SEARCH_LISTER="$REPO_DIR/scripts/list-searchable-second-brain.py"
ARCHIVE_PLAN_SCRIPT="$REPO_DIR/scripts/plan-root-ai-log-archive.py"
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
    find "$1" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

raw_markdown_by_session_id() {
    local root="$1" sid="$2"
    find "$root/AI-Logs/raw" -name '*.md' -type f -print0 2>/dev/null | \
        xargs -0 grep -l "session_id: \"$sid\"" 2>/dev/null | head -1 || true
}

readable_markdown_for_raw() {
    local root="$1" raw_file="$2"
    python3 - "$root" "$raw_file" <<'PY'
import os
import sys
root, raw_file = sys.argv[1:3]
relative = os.path.relpath(os.path.realpath(raw_file), os.path.realpath(root)).replace(os.sep, "/")
print(os.path.join(root, *("AI-Logs/readable/" + relative[len("AI-Logs/raw/"):]).split("/")))
PY
}

assert_readable_matches_raw() {
    local label="$1" root="$2" raw_file="$3"
    local expected
    expected=$(python3 - "$root" "$raw_file" <<'PY'
import hashlib
import os
import sys

root, raw_file = sys.argv[1:3]
rel = os.path.relpath(os.path.realpath(raw_file), os.path.realpath(root)).replace(os.sep, "/")
stem = rel[:-3] if rel.endswith(".md") else rel
readable_rel = "AI-Logs/readable/" + stem[len("AI-Logs/raw/"):] + ".md"
digest = "sha256:" + hashlib.sha256(open(raw_file, "rb").read()).hexdigest()
print(os.path.join(root, *readable_rel.split("/")))
print(f'raw_ref: "[[{stem}]]"')
print(f'raw_hash: "{digest}"')
PY
)
    local readable_file raw_ref_line raw_hash_line
    readable_file=$(printf '%s\n' "$expected" | sed -n '1p')
    raw_ref_line=$(printf '%s\n' "$expected" | sed -n '2p')
    raw_hash_line=$(printf '%s\n' "$expected" | sed -n '3p')
    if [ -f "$readable_file" ]; then
        pass "$label readable exists"
    else
        fail "$label readable exists (missing: $readable_file)"
        return
    fi
    assert_file_contains "$label raw_ref matches raw path" "$readable_file" "$raw_ref_line"
    assert_file_contains "$label raw_hash matches raw bytes" "$readable_file" "$raw_hash_line"
}

automation_markdown_by_session_id() {
    local root="$1" sid="$2"
    find "$root/AI-Logs/automation" -name '*.md' -type f -print0 2>/dev/null | \
        xargs -0 grep -l "raw_session_id: \"$sid\"" 2>/dev/null | head -1 || true
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
echo "=== Root archive dry-run ==="

ARCHIVE_NOTES="$TEST_DIR/archive-notes"
mkdir -p "$ARCHIVE_NOTES/AI-Logs/raw/codex/2026-06"
cat > "$ARCHIVE_NOTES/2026-06-03_codex_example.md" <<'MD'
---
date: 2026-06-03
title: "Codex\tExample"
source: "Codex"
session_id: "archive-codex"
tags:
  - "ai-log"
---

# Codex Example

## Transcript

### User 1

archive me
MD
printf 'not a generated log\n' > "$ARCHIVE_NOTES/README.md"
cat > "$ARCHIVE_NOTES/2026-06-03_human_note.md" <<'MD'
---
date: 2026-06-03
title: "Human note"
---

# Human note
MD
cat > "$ARCHIVE_NOTES/2026-06-03_no_transcript.md" <<'MD'
---
date: 2026-06-03
title: "No transcript"
source: "Codex"
session_id: "not-ai-log-enough"
---

# No transcript
MD
printf 'raw should be ignored\n' > "$ARCHIVE_NOTES/AI-Logs/raw/codex/2026-06/raw.md"
ARCHIVE_JSONL="$TEST_DIR/archive-plan.jsonl"
SECOND_BRAIN_DIR="$ARCHIVE_NOTES" "$ARCHIVE_PLAN_SCRIPT" --progress-every 1 > "$ARCHIVE_JSONL" 2>"$TEST_DIR/archive-plan.err"
assert_eq "archive dry-run finds one root candidate" "1" "$(wc -l < "$ARCHIVE_JSONL" | tr -d ' ')"
assert_file_contains "archive dry-run targets raw-archive codex" "$ARCHIVE_JSONL" "\"target\": \"$ARCHIVE_NOTES/AI-Logs/raw-archive/codex/2026-06/2026-06-03_codex_example.md\""
assert_file_contains "archive dry-run keeps session id" "$ARCHIVE_JSONL" "\"session_id\": \"archive-codex\""
assert_file_not_contains "archive dry-run ignores human date note" "$ARCHIVE_JSONL" "human_note"
assert_file_not_contains "archive dry-run ignores note without transcript" "$ARCHIVE_JSONL" "no_transcript"
assert_file_not_contains "archive dry-run ignores nested raw" "$ARCHIVE_JSONL" "raw should be ignored"
assert_file_contains "archive dry-run reports progress" "$TEST_DIR/archive-plan.err" "progress scanned="
assert_file_contains "archive dry-run reports count" "$TEST_DIR/archive-plan.err" "planned_archive_candidates=1"
assert_file_contains "archive dry-run reports scanned total" "$TEST_DIR/archive-plan.err" "archive_scan_summary scanned=4"
assert_file_contains "archive dry-run reports no-date skips" "$TEST_DIR/archive-plan.err" "skipped.no_date_prefix=1"
assert_file_contains "archive dry-run reports dataless skips" "$TEST_DIR/archive-plan.err" "skipped.icloud_dataless=0"
assert_file_contains "archive dry-run reports no-session skips" "$TEST_DIR/archive-plan.err" "skipped.no_session_id=1"
assert_file_contains "archive dry-run reports no-transcript skips" "$TEST_DIR/archive-plan.err" "skipped.no_transcript_marker=1"
assert_file_contains "archive dry-run reports candidates total" "$TEST_DIR/archive-plan.err" "candidates=1"
ARCHIVE_TSV="$TEST_DIR/archive-plan.tsv"
SECOND_BRAIN_DIR="$ARCHIVE_NOTES" "$ARCHIVE_PLAN_SCRIPT" --format tsv > "$ARCHIVE_TSV" 2>/dev/null
assert_eq "archive TSV has one data row" "2" "$(wc -l < "$ARCHIVE_TSV" | tr -d ' ')"
assert_eq "archive TSV keeps tabbed title in one field" "8" "$(python3 - "$ARCHIVE_TSV" <<'PY'
import csv
import sys

rows = list(csv.reader(open(sys.argv[1], encoding="utf-8"), delimiter="\t"))
print(len(rows[1]))
PY
)"
assert_eq "archive planner detects dataless stat flag" "1 0 0" "$(python3 - "$ARCHIVE_PLAN_SCRIPT" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("archive_plan", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

original_stat = module.os.stat

class StatResult:
    def __init__(self, flags):
        self.st_flags = flags

def fake_stat(flags=0, raises=False):
    def _stat(_path, follow_symlinks=False):
        if raises:
            raise OSError("stat failed")
        return StatResult(flags)
    return _stat

try:
    module.os.stat = fake_stat(module.SF_DATALESS)
    dataless = "1" if module.is_icloud_dataless(Path("example.md")) else "0"
    module.os.stat = fake_stat(0)
    local = "1" if module.is_icloud_dataless(Path("example.md")) else "0"
    module.os.stat = fake_stat(raises=True)
    error = "1" if module.is_icloud_dataless(Path("example.md")) else "0"
finally:
    module.os.stat = original_stat

print(" ".join([dataless, local, error]))
PY
)"

echo ""
echo "=== Search helper ==="

SEARCH_NOTES="$TEST_DIR/search-notes"
mkdir -p "$SEARCH_NOTES/AI-Logs/raw/codex/2026-06" \
    "$SEARCH_NOTES/AI-Logs/raw-archive/codex/2026-06" \
    "$SEARCH_NOTES/AI-Logs/readable/codex/2026-06" \
    "$SEARCH_NOTES/AI-Logs/automation/codex/2026-06" \
    "$SEARCH_NOTES/OpenClaw/sources" \
    "$SEARCH_NOTES/OpenClaw/raw/conversations" \
    "$SEARCH_NOTES/plans"
printf 'search-helper-needle raw\n' > "$SEARCH_NOTES/AI-Logs/raw/codex/2026-06/raw.md"
printf 'search-helper-needle archive\n' > "$SEARCH_NOTES/AI-Logs/raw-archive/codex/2026-06/archive.md"
printf 'search-helper-needle readable\n' > "$SEARCH_NOTES/AI-Logs/readable/codex/2026-06/readable.md"
printf 'search-helper-needle automation\n' > "$SEARCH_NOTES/AI-Logs/automation/codex/2026-06/automation.md"
printf 'search-helper-needle legacy\n' > "$SEARCH_NOTES/2026-06-03_legacy.md"
printf 'search-helper-needle root-human\n' > "$SEARCH_NOTES/README.md"
printf 'search-helper-needle openclaw\n' > "$SEARCH_NOTES/OpenClaw/sources/result.md"
printf 'search-helper-needle openclaw-raw\n' > "$SEARCH_NOTES/OpenClaw/raw/conversations/raw.md"
printf 'search-helper-needle binary-like\n' > "$SEARCH_NOTES/OpenClaw/sources/result.bin"
printf 'search-helper-needle plan\n' > "$SEARCH_NOTES/plans/plan.md"
SEARCH_OUTPUT=$(SECOND_BRAIN_DIR="$SEARCH_NOTES" "$SEARCH_SCRIPT" "search-helper-needle")
assert_eq "search helper returns allowlisted matches" "4" "$(printf '%s\n' "$SEARCH_OUTPUT" | grep -c 'search-helper-needle')"
assert_text_contains() {
    local label="$1" text="$2" pattern="$3"
    if printf '%s' "$text" | grep -Fq "$pattern"; then
        pass "$label"
    else
        fail "$label (missing pattern: $pattern)"
    fi
}
assert_text_not_contains() {
    local label="$1" text="$2" pattern="$3"
    if printf '%s' "$text" | grep -Fq "$pattern"; then
        fail "$label (unexpected pattern: $pattern)"
    else
        pass "$label"
    fi
}
assert_text_contains "search helper includes readable" "$SEARCH_OUTPUT" "readable"
assert_text_contains "search helper includes root human note" "$SEARCH_OUTPUT" "root-human"
assert_text_contains "search helper includes OpenClaw" "$SEARCH_OUTPUT" "openclaw"
assert_text_not_contains "search helper excludes OpenClaw raw" "$SEARCH_OUTPUT" "openclaw-raw"
assert_text_contains "search helper includes plans" "$SEARCH_OUTPUT" "plan"
assert_text_not_contains "search helper excludes raw" "$SEARCH_OUTPUT" " raw"
assert_text_not_contains "search helper excludes archive" "$SEARCH_OUTPUT" "archive"
assert_text_not_contains "search helper excludes automation" "$SEARCH_OUTPUT" "automation"
assert_text_not_contains "search helper excludes dated root legacy" "$SEARCH_OUTPUT" "legacy"
assert_text_not_contains "search helper excludes non-Markdown files" "$SEARCH_OUTPUT" "binary-like"
set +e
SECOND_BRAIN_DIR="$SEARCH_NOTES" "$SEARCH_SCRIPT" "definitely-not-present" >/dev/null 2>&1
SEARCH_NO_MATCH_EXIT=$?
SECOND_BRAIN_DIR="$SEARCH_NOTES" "$SEARCH_SCRIPT" --definitely-invalid >/dev/null 2>&1
SEARCH_INVALID_EXIT=$?
SECOND_BRAIN_DIR="$SEARCH_NOTES" SECOND_BRAIN_PYTHON=/definitely/missing/python "$SEARCH_SCRIPT" "search-helper-needle" >/dev/null 2>&1
SEARCH_MISSING_PYTHON_EXIT=$?
set -e
assert_eq "search helper preserves rg no-match exit" "1" "$SEARCH_NO_MATCH_EXIT"
assert_eq "search helper preserves rg argument error exit" "2" "$SEARCH_INVALID_EXIT"
assert_eq "search helper rejects a missing Python override" "2" "$SEARCH_MISSING_PYTHON_EXIT"
assert_eq "search lister detects dataless stat flag" "1 0 1" "$(python3 - "$SEARCH_LISTER" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("search_list", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
original_stat = module.os.stat

class StatResult:
    def __init__(self, flags):
        self.st_flags = flags

def fake_stat(flags=0, raises=False):
    def _stat(_path, follow_symlinks=False):
        if raises:
            raise OSError("stat failed")
        return StatResult(flags)
    return _stat

try:
    module.os.stat = fake_stat(module.SF_DATALESS)
    dataless = "1" if module.is_dataless(Path("example.md")) else "0"
    module.os.stat = fake_stat(0)
    local = "1" if module.is_dataless(Path("example.md")) else "0"
    module.os.stat = fake_stat(raises=True)
    error = "1" if module.is_dataless(Path("example.md")) else "0"
finally:
    module.os.stat = original_stat

print(" ".join([dataless, local, error]))
PY
)"

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

assert_eq "ordinary claude discussion creates raw and readable markdown" "2" "$(markdown_count "$TEST_DIR/claude-notes")"
CLAUDE_MD=$(raw_markdown_by_session_id "$TEST_DIR/claude-notes" "claude-ordinary")
assert_file_contains "ordinary claude discussion is preserved" "$CLAUDE_MD" "cronとheartbeatの保存方針を相談したい"
assert_readable_matches_raw "ordinary claude discussion" "$TEST_DIR/claude-notes" "$CLAUDE_MD"

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

assert_eq "all-filtered codex session creates raw and readable markdown" "2" "$(markdown_count "$TEST_DIR/codex-notes")"
CODEX_FILTERED_RAW=$(raw_markdown_by_session_id "$TEST_DIR/codex-notes" "123e4567-e89b-12d3-a456-426614174111")
assert_file_contains "all-filtered raw preserves user message" "$CODEX_FILTERED_RAW" "[cron] no changes"
assert_file_contains "all-filtered raw preserves assistant message" "$CODEX_FILTERED_RAW" "Heartbeat automation completed: no changes"
assert_file_contains "all-filtered raw counts every message" "$CODEX_FILTERED_RAW" "msg_count: 2"
assert_readable_matches_raw "all-filtered codex session" "$TEST_DIR/codex-notes" "$CODEX_FILTERED_RAW"

CODEX_ORDINARY_JSONL="$TEST_DIR/codex-sessions/ordinary.jsonl"
CODEX_ORDINARY_SID="123e4567-e89b-12d3-a456-426614174112"
cat > "$CODEX_ORDINARY_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:05:00Z","payload":{"id":"$CODEX_ORDINARY_SID","timestamp":"2026-06-03T10:05:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"codex ordinary task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex ordinary answer"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_ORDINARY_JSONL"

CODEX_ORDINARY_MD=$(raw_markdown_by_session_id "$TEST_DIR/codex-notes" "$CODEX_ORDINARY_SID")
assert_file_contains "ordinary codex discussion is preserved" "$CODEX_ORDINARY_MD" "codex ordinary task"
assert_readable_matches_raw "ordinary codex discussion" "$TEST_DIR/codex-notes" "$CODEX_ORDINARY_MD"

echo ""
echo "=== Codex automation classification ==="

CODEX_AUTOMATION_JSONL="$TEST_DIR/codex-sessions/automation.jsonl"
CODEX_AUTOMATION_SID="123e4567-e89b-12d3-a456-426614174113"
cat > "$CODEX_AUTOMATION_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:10:00Z","payload":{"id":"$CODEX_AUTOMATION_SID","timestamp":"2026-06-03T10:10:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Automation: OpenClaw Gateway Health Check\nAutomation ID: openclaw-gateway-health-check\nAutomation memory: \$CODEX_HOME/automations/openclaw-gateway-health-check/memory.md\nLast run: 2026-06-03T10:00:00Z\n\nCheck gateway health."}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Gateway healthy."}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_AUTOMATION_JSONL"

CODEX_AUTOMATION_RAW=$(raw_markdown_by_session_id "$TEST_DIR/codex-notes" "$CODEX_AUTOMATION_SID")
CODEX_AUTOMATION_VIEW=$(automation_markdown_by_session_id "$TEST_DIR/codex-notes" "$CODEX_AUTOMATION_SID")
assert_file_contains "automation raw has record kind" "$CODEX_AUTOMATION_RAW" 'record_kind: "automation"'
assert_file_contains "automation raw has automation id" "$CODEX_AUTOMATION_RAW" 'automation_id: "openclaw-gateway-health-check"'
assert_file_contains "automation raw has classification rule" "$CODEX_AUTOMATION_RAW" 'classification_rule: "codex-automation-envelope-v1"'
assert_file_contains "automation derived view exists" "$CODEX_AUTOMATION_VIEW" 'record_kind: "automation"'
assert_eq "automation is absent from readable" "0" "$(find "$TEST_DIR/codex-notes/AI-Logs/readable" -name '*.md' -type f -print0 2>/dev/null | xargs -0 grep -l "$CODEX_AUTOMATION_SID" 2>/dev/null | wc -l | tr -d ' ')"

CODEX_AUTOMATION_QUOTE_JSONL="$TEST_DIR/codex-sessions/automation-quote.jsonl"
CODEX_AUTOMATION_QUOTE_SID="123e4567-e89b-12d3-a456-426614174114"
cat > "$CODEX_AUTOMATION_QUOTE_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:15:00Z","payload":{"id":"$CODEX_AUTOMATION_QUOTE_SID","timestamp":"2026-06-03T10:15:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Automation: OpenClaw Gateway Health Check というログについて相談したい"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"普通の相談として扱う。"}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" \
AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_AUTOMATION_QUOTE_JSONL"

CODEX_AUTOMATION_QUOTE_RAW=$(raw_markdown_by_session_id "$TEST_DIR/codex-notes" "$CODEX_AUTOMATION_QUOTE_SID")
assert_file_contains "automation title quote remains interactive" "$CODEX_AUTOMATION_QUOTE_RAW" 'record_kind: "interactive"'
assert_readable_matches_raw "automation title quote" "$TEST_DIR/codex-notes" "$CODEX_AUTOMATION_QUOTE_RAW"

echo ""
echo "=== Existing Codex raw reclassification ==="

CODEX_RECLASSIFY_JSONL="$TEST_DIR/codex-sessions/reclassify.jsonl"
CODEX_RECLASSIFY_SID="123e4567-e89b-12d3-a456-426614174115"
cat > "$CODEX_RECLASSIFY_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:20:00Z","payload":{"id":"$CODEX_RECLASSIFY_SID","timestamp":"2026-06-03T10:20:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ordinary task before classification"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ordinary answer"}]}}
JSONL

HOME="$TEST_DIR/home" SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_RECLASSIFY_JSONL"

CODEX_RECLASSIFY_RAW=$(raw_markdown_by_session_id "$TEST_DIR/codex-notes" "$CODEX_RECLASSIFY_SID")
CODEX_RECLASSIFY_READABLE=$(readable_markdown_for_raw "$TEST_DIR/codex-notes" "$CODEX_RECLASSIFY_RAW")
assert_file_contains "reclassification fixture starts interactive" "$CODEX_RECLASSIFY_READABLE" 'record_kind: "interactive"'
printf '\nuser-edited-derived-content\n' >> "$CODEX_RECLASSIFY_READABLE"

cat > "$CODEX_RECLASSIFY_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:20:00Z","payload":{"id":"$CODEX_RECLASSIFY_SID","timestamp":"2026-06-03T10:20:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Automation: Reclassification Test\nAutomation ID: reclassification-test\nAutomation memory: \$CODEX_HOME/automations/reclassification-test/memory.md\nLast run: 2026-06-03T10:19:00Z\n\nRun the check."}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Automation answer"}]}}
JSONL

HOME="$TEST_DIR/home" SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_RECLASSIFY_JSONL"

CODEX_RECLASSIFY_AUTOMATION=$(automation_markdown_by_session_id "$TEST_DIR/codex-notes" "$CODEX_RECLASSIFY_SID")
assert_file_contains "existing raw is reclassified as automation" "$CODEX_RECLASSIFY_RAW" 'record_kind: "automation"'
assert_file_contains "reclassified automation view is generated" "$CODEX_RECLASSIFY_AUTOMATION" 'automation_id: "reclassification-test"'
assert_eq "stale readable is removed after verified reclassification" "0" "$(find "$TEST_DIR/codex-notes/AI-Logs/readable" -name '*.md' -type f -print0 2>/dev/null | xargs -0 grep -l "$CODEX_RECLASSIFY_SID" 2>/dev/null | wc -l | tr -d ' ')"
CODEX_RECLASSIFY_BACKUP_DIR="$TEST_DIR/home/.claude/ai-second-brain-state/reclassified-derived/$CODEX_RECLASSIFY_SID"
assert_eq "edited stale readable is backed up before retirement" "1" "$(find "$CODEX_RECLASSIFY_BACKUP_DIR" -name 'interactive-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_file_contains "stale readable backup preserves user edits" "$(find "$CODEX_RECLASSIFY_BACKUP_DIR" -name 'interactive-*.md' -type f | head -1)" "user-edited-derived-content"

cat > "$CODEX_RECLASSIFY_JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:20:00Z","payload":{"id":"$CODEX_RECLASSIFY_SID","timestamp":"2026-06-03T10:20:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ordinary task after classification"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ordinary answer again"}]}}
JSONL

HOME="$TEST_DIR/home" SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_RECLASSIFY_JSONL"

CODEX_RECLASSIFY_READABLE=$(readable_markdown_for_raw "$TEST_DIR/codex-notes" "$CODEX_RECLASSIFY_RAW")
assert_file_contains "existing raw can return to interactive" "$CODEX_RECLASSIFY_RAW" 'record_kind: "interactive"'
assert_file_contains "interactive view is regenerated" "$CODEX_RECLASSIFY_READABLE" 'record_kind: "interactive"'
assert_eq "stale automation is removed after verified reverse classification" "0" "$(find "$TEST_DIR/codex-notes/AI-Logs/automation" -name '*.md' -type f -print0 2>/dev/null | xargs -0 grep -l "$CODEX_RECLASSIFY_SID" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "stale automation is backed up before retirement" "1" "$(find "$CODEX_RECLASSIFY_BACKUP_DIR" -name 'automation-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"

rm "$CODEX_RECLASSIFY_READABLE"
HOME="$TEST_DIR/home" SECOND_BRAIN_DIR="$TEST_DIR/codex-notes" CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions" \
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py" AI_LOG_WRITER="$WRITER" \
    "$CODEX_SCRIPT" "$CODEX_RECLASSIFY_JSONL"
assert_file_contains "missing current derived view is repaired on retry" "$CODEX_RECLASSIFY_READABLE" 'record_kind: "interactive"'

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
