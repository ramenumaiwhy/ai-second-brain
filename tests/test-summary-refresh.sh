#!/bin/bash
# Regression tests for safe AI log summary refreshes.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/update-ai-log-summary.py"
TEST_DIR=$(mktemp -d /tmp/test-summary-refresh-XXXXXX)
PASS=0
FAIL=0
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

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

assert_file_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq -- "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (missing pattern: $pattern)"
    fi
}

assert_file_contains_text() {
    local label="$1" file="$2" text="$3"
    if python3 - "$file" "$text" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8")
sys.exit(0 if sys.argv[2] in content else 1)
PY
    then
        pass "$label"
    else
        fail "$label (missing multiline text)"
    fi
}

assert_not_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq -- "$pattern" "$file" 2>/dev/null; then
        fail "$label (unexpected pattern: $pattern)"
    else
        pass "$label"
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected: $expected, got: $actual)"
    fi
}

transcript_part() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace")
marker = "## Transcript"
index = text.rindex(marker)
sys.stdout.write(text[index:])
PY
}

fix_transcript_hash() {
    python3 - "$1" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_bytes().decode("utf-8", errors="replace")
matches = list(re.finditer(r"(?m)^## Transcript[ \t]*\r?$", text))
if not matches:
    sys.exit(0)
match = matches[-1]
transcript = text[match.end():]
if transcript.startswith("\r\n"):
    transcript = transcript[2:]
elif transcript.startswith("\n"):
    transcript = transcript[1:]
if transcript.startswith("\r\n"):
    transcript = transcript[2:]
elif transcript.startswith("\n"):
    transcript = transcript[1:]
normalized = transcript.replace("\r\n", "\n").replace("\r", "\n").rstrip()
normalized = normalized + "\n" if normalized else ""
digest = "sha256:" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()
text = re.sub(r'transcript_hash: "sha256:[^"]*"', f'transcript_hash: "{digest}"', text, count=1)
path.write_text(text, encoding="utf-8")
PY
}

write_note() {
    local path="$1"
    python3 - "$path" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    """---
date: 2026-06-03
title: "Refresh Target"
source: "Codex"
session_id: "summary-session"
record_kind: "interactive"
msg_count: 2
last_message_hash: "sha256:last"
transcript_hash: "sha256:transcript"
tags:
  - "codex"
  - "ai-log"
---
# Refresh Target

## Summary

old summary

## Decisions

- old decision

## Next Actions

- old action

## Transcript

### User 1

Keep this transcript byte-for-byte.

### Assistant 1

This transcript mentions ## Summary as plain text.
""",
    encoding="utf-8",
)
PY
    fix_transcript_hash "$path"
}

echo ""
echo "=== Refresh existing sections ==="

NOTE="$TEST_DIR/2026-06-03_refresh.md"
write_note "$NOTE"
BEFORE_TRANSCRIPT=$(transcript_part "$NOTE")

cat > "$TEST_DIR/summary.json" <<'JSON'
{
  "summary": "new summary with sk-proj-abcdefghijklmnopqrstuvwxyz",
  "decisions": ["keep Markdown primary", "mask Bearer abcdefghijklmnopqrstuvwxyz"],
  "next_actions": ["run review", "ship safely"]
}
JSON

AI_SUMMARY_REFRESHED_AT="2026-06-03T00:00:00Z" \
    "$SCRIPT" "$NOTE" --input-json "$TEST_DIR/summary.json" > "$TEST_DIR/update.out"

AFTER_TRANSCRIPT=$(transcript_part "$NOTE")
assert_eq "transcript is preserved" "$BEFORE_TRANSCRIPT" "$AFTER_TRANSCRIPT"
assert_file_contains "path is printed" "$TEST_DIR/update.out" "$NOTE"
assert_file_contains "summary timestamp is written" "$NOTE" 'summary_refreshed_at: "2026-06-03T00:00:00Z"'
assert_file_contains "summary is updated" "$NOTE" "new summary with [REDACTED_API_KEY]"
assert_file_contains "decisions are updated as bullets" "$NOTE" "- keep Markdown primary"
assert_file_contains "next actions are updated as bullets" "$NOTE" "- ship safely"
assert_file_contains "bearer token is redacted" "$NOTE" "Bearer [REDACTED]"
assert_not_contains "api key value is omitted" "$NOTE" "sk-proj-abcdefghijklmnopqrstuvwxyz"
assert_not_contains "bearer value is omitted" "$NOTE" "Bearer abcdefghijklmnopqrstuvwxyz"
if find "$HOME/.claude" -name '*-obsidian-sync.lock' -type d | grep -q .; then
    fail "sync locks are released after update"
else
    pass "sync locks are released after update"
fi

echo ""
echo "=== False Transcript heading in summary ==="

FALSE_NOTE="$TEST_DIR/false-transcript-heading.md"
write_note "$FALSE_NOTE"
python3 - "$FALSE_NOTE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("old summary", "old summary\n\n## Transcript\n\nnot actual transcript")
path.write_text(text, encoding="utf-8")
PY
BEFORE_FALSE_TRANSCRIPT=$(transcript_part "$FALSE_NOTE")

printf '{"summary":"fixed summary"}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T00:30:00Z" \
    "$SCRIPT" "$FALSE_NOTE" > "$TEST_DIR/false.out"

AFTER_FALSE_TRANSCRIPT=$(transcript_part "$FALSE_NOTE")
assert_eq "false Transcript heading keeps canonical transcript" "$BEFORE_FALSE_TRANSCRIPT" "$AFTER_FALSE_TRANSCRIPT"
assert_file_contains "false Transcript summary is updated" "$FALSE_NOTE" "fixed summary"
assert_file_contains "false Transcript heading is escaped" "$FALSE_NOTE" "\\## Transcript"
assert_file_contains "false Transcript text is preserved" "$FALSE_NOTE" "not actual transcript"

echo ""
echo "=== CRLF markdown ==="

CRLF_NOTE="$TEST_DIR/crlf.md"
write_note "$CRLF_NOTE"
python3 - "$CRLF_NOTE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_bytes(text.replace("\n", "\r\n").encode("utf-8"))
PY
BEFORE_CRLF_TRANSCRIPT=$(transcript_part "$CRLF_NOTE")

printf '{"summary":"crlf summary"}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T00:45:00Z" \
    "$SCRIPT" "$CRLF_NOTE" > "$TEST_DIR/crlf.out"

AFTER_CRLF_TRANSCRIPT=$(transcript_part "$CRLF_NOTE")
assert_eq "CRLF transcript is preserved" "$BEFORE_CRLF_TRANSCRIPT" "$AFTER_CRLF_TRANSCRIPT"
assert_file_contains "CRLF markdown is refreshed" "$CRLF_NOTE" "crlf summary"

echo ""
echo "=== Missing sections are inserted ==="

MISSING_NOTE="$TEST_DIR/missing-sections.md"
cat > "$MISSING_NOTE" <<'MD'
---
date: 2026-06-03
title: "Missing Sections"
source: "Claude Code"
session_id: "missing-sections"
record_kind: "interactive"
msg_count: 1
last_message_hash: "sha256:last"
transcript_hash: "sha256:transcript"
tags:
  - "claude-code"
  - "ai-log"
---
# Missing Sections

## Transcript

### User 1

raw transcript
MD
fix_transcript_hash "$MISSING_NOTE"

printf '{"summary":"filled summary"}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T01:00:00Z" \
    "$SCRIPT" "$MISSING_NOTE" > "$TEST_DIR/missing.out"

assert_file_contains "missing summary inserted" "$MISSING_NOTE" "filled summary"
assert_file_contains "missing decisions heading inserted" "$MISSING_NOTE" "## Decisions"
assert_file_contains "missing next actions heading inserted" "$MISSING_NOTE" "## Next Actions"
assert_file_contains "missing transcript remains" "$MISSING_NOTE" "raw transcript"

echo ""
echo "=== Partial update and dry run ==="

PARTIAL_NOTE="$TEST_DIR/partial.md"
write_note "$PARTIAL_NOTE"
BEFORE_PARTIAL=$(cat "$PARTIAL_NOTE")
printf '{"summary":"dry run summary"}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T02:00:00Z" \
    "$SCRIPT" "$PARTIAL_NOTE" --dry-run > "$TEST_DIR/dry-run.out"

AFTER_PARTIAL=$(cat "$PARTIAL_NOTE")
assert_eq "dry run does not modify file" "$BEFORE_PARTIAL" "$AFTER_PARTIAL"
assert_file_contains "dry run prints updated summary" "$TEST_DIR/dry-run.out" "dry run summary"
assert_file_contains "dry run preserves existing decisions" "$TEST_DIR/dry-run.out" "- old decision"

printf '{"summary":"partial summary"}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T03:00:00Z" \
    "$SCRIPT" "$PARTIAL_NOTE" > "$TEST_DIR/partial.out"

assert_file_contains "partial summary is updated" "$PARTIAL_NOTE" "partial summary"
assert_file_contains "partial update preserves decisions" "$PARTIAL_NOTE" "- old decision"
assert_file_contains "partial update preserves next actions" "$PARTIAL_NOTE" "- old action"

echo ""
echo "=== Concurrency guard ==="

LOCK_NOTE="$TEST_DIR/sync-lock.md"
write_note "$LOCK_NOTE"
mkdir -p "$HOME/.claude/codex-obsidian-sync.lock"
printf '%s\n' "12345:unknown" > "$HOME/.claude/codex-obsidian-sync.lock/pid"

if printf '{"summary":"blocked summary"}' | "$SCRIPT" "$LOCK_NOTE" > "$TEST_DIR/lock.out" 2> "$TEST_DIR/lock.err"; then
    fail "busy sync lock is rejected"
else
    pass "busy sync lock is rejected"
fi
assert_file_contains "busy sync lock explains failure" "$TEST_DIR/lock.err" "sync lock is busy"
assert_not_contains "busy sync lock leaves markdown unchanged" "$LOCK_NOTE" "blocked summary"
rm -rf "$HOME/.claude/codex-obsidian-sync.lock"

STALE_LOCK_NOTE="$TEST_DIR/stale-sync-lock.md"
write_note "$STALE_LOCK_NOTE"
mkdir -p "$HOME/.claude/codex-obsidian-sync.lock"
printf '%s\n' "999999:unknown" > "$HOME/.claude/codex-obsidian-sync.lock/pid"
python3 - "$HOME/.claude/codex-obsidian-sync.lock" <<'PY'
import os
import sys
import time

stale_at = time.time() - 400
os.utime(sys.argv[1], (stale_at, stale_at))
PY

if printf '{"summary":"stale lock update"}' | "$SCRIPT" "$STALE_LOCK_NOTE" > "$TEST_DIR/stale-lock.out" 2> "$TEST_DIR/stale-lock.err"; then
    pass "stale sync lock is reaped"
else
    fail "stale sync lock is reaped"
fi
assert_file_contains "stale sync lock update is written" "$STALE_LOCK_NOTE" "stale lock update"
if find "$HOME/.claude" -name '*-obsidian-sync.lock' -type d | grep -q .; then
    fail "stale sync lock is released after update"
else
    pass "stale sync lock is released after update"
fi

if PYTHONDONTWRITEBYTECODE=1 python3 - "$SCRIPT" "$TEST_DIR/changed-before-write.md" <<'PY'
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True
script = Path(sys.argv[1])
path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("summary_refresh_under_test", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

path.write_bytes(b"before\n")
expected = module.read_bytes(path)
path.write_bytes(b"after\n")
try:
    module.ensure_unchanged(path, expected)
except module.SummaryRefreshError as exc:
    if "changed while refreshing" in str(exc):
        sys.exit(0)
sys.exit(1)
PY
then
    pass "pre-write change guard detects modified markdown"
else
    fail "pre-write change guard detects modified markdown"
fi

if PYTHONDONTWRITEBYTECODE=1 python3 - "$SCRIPT" "$TEST_DIR/lstart.lock" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
script = Path(sys.argv[1])
path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("summary_refresh_lock_under_test", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

expected_lstart = "Wed Jun  3 04:00:00 2026"
module.process_lstart = lambda pid: expected_lstart
lock = module.SyncLock(path)
lock.acquire()
try:
    info = (path / "pid").read_text(encoding="utf-8").strip()
finally:
    lock.release()

expected = f"{os.getpid()}:{expected_lstart}"
sys.exit(0 if info == expected else 1)
PY
then
    pass "sync lock records process start time"
else
    fail "sync lock records process start time"
fi

echo ""
echo "=== Managed headings in summary content ==="

DUPLICATE_HEADING_NOTE="$TEST_DIR/duplicate-managed-headings.md"
write_note "$DUPLICATE_HEADING_NOTE"
python3 - "$DUPLICATE_HEADING_NOTE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("old summary", "A\n\n## Decisions\n\nB")
path.write_text(text, encoding="utf-8")
PY

printf '{"next_actions":["fresh action"]}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T03:30:00Z" \
    "$SCRIPT" "$DUPLICATE_HEADING_NOTE" > "$TEST_DIR/duplicate-managed-headings.out"
assert_file_contains "duplicate managed heading is escaped" "$DUPLICATE_HEADING_NOTE" "\\## Decisions"
assert_file_contains_text "duplicate managed heading preserves blank line" "$DUPLICATE_HEADING_NOTE" $'\\## Decisions\n\nB'
assert_file_contains "duplicate managed heading preserves actual decisions" "$DUPLICATE_HEADING_NOTE" "- old decision"
assert_file_contains "duplicate managed heading applies partial update" "$DUPLICATE_HEADING_NOTE" "fresh action"

HEADING_NOTE="$TEST_DIR/managed-headings.md"
write_note "$HEADING_NOTE"
cat > "$TEST_DIR/managed-headings.json" <<'JSON'
{
  "summary": "A\n\n## Decisions\n\nB\n\n## Transcript\n\nC",
  "decisions": "C\n\n## Next Actions\n\nD"
}
JSON

AI_SUMMARY_REFRESHED_AT="2026-06-03T04:00:00Z" \
    "$SCRIPT" "$HEADING_NOTE" --input-json "$TEST_DIR/managed-headings.json" > "$TEST_DIR/managed-headings.out"
assert_file_contains "summary managed heading is escaped" "$HEADING_NOTE" "\\## Decisions"
assert_file_contains "transcript managed heading is escaped" "$HEADING_NOTE" "\\## Transcript"
assert_file_contains "decisions managed heading is escaped" "$HEADING_NOTE" "\\## Next Actions"
assert_file_contains_text "summary escaped heading keeps blank line" "$HEADING_NOTE" $'\\## Decisions\n\nB'
assert_file_contains_text "transcript escaped heading keeps blank line" "$HEADING_NOTE" $'\\## Transcript\n\nC'
assert_file_contains_text "decisions escaped heading keeps blank line" "$HEADING_NOTE" $'\\## Next Actions\n\nD'

printf '{"next_actions":["fresh action"]}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T04:30:00Z" \
    "$SCRIPT" "$HEADING_NOTE" > "$TEST_DIR/managed-headings-second.out"
assert_file_contains "partial refresh preserves escaped summary heading" "$HEADING_NOTE" "\\## Decisions"
assert_file_contains "partial refresh preserves summary tail" "$HEADING_NOTE" "B"
assert_file_contains "partial refresh preserves escaped transcript heading" "$HEADING_NOTE" "\\## Transcript"
assert_file_contains "partial refresh preserves escaped decisions heading" "$HEADING_NOTE" "\\## Next Actions"
assert_file_contains "partial refresh preserves decisions tail" "$HEADING_NOTE" "D"
assert_file_contains "partial refresh updates next actions" "$HEADING_NOTE" "fresh action"

echo ""
echo "=== Non-managed sections are preserved ==="

EXTRA_NOTE="$TEST_DIR/extra-section.md"
write_note "$EXTRA_NOTE"
python3 - "$EXTRA_NOTE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("## Transcript", "## Notes\n\nmanual note\n\n## Transcript", 1)
path.write_text(text, encoding="utf-8")
PY
BEFORE_EXTRA_TRANSCRIPT=$(transcript_part "$EXTRA_NOTE")

printf '{"next_actions":["updated action"]}' | \
AI_SUMMARY_REFRESHED_AT="2026-06-03T05:00:00Z" \
    "$SCRIPT" "$EXTRA_NOTE" > "$TEST_DIR/extra.out"

AFTER_EXTRA_TRANSCRIPT=$(transcript_part "$EXTRA_NOTE")
assert_eq "extra section keeps transcript" "$BEFORE_EXTRA_TRANSCRIPT" "$AFTER_EXTRA_TRANSCRIPT"
assert_file_contains "extra section heading is preserved" "$EXTRA_NOTE" "## Notes"
assert_file_contains "extra section body is preserved" "$EXTRA_NOTE" "manual note"
assert_file_contains "extra section update is applied" "$EXTRA_NOTE" "updated action"

echo ""
echo "=== Rejected inputs ==="

if printf '{}' | "$SCRIPT" "$PARTIAL_NOTE" > "$TEST_DIR/empty.out" 2> "$TEST_DIR/empty.err"; then
    fail "empty JSON is rejected"
else
    pass "empty JSON is rejected"
fi
assert_file_contains "empty JSON explains failure" "$TEST_DIR/empty.err" "must include summary"

NO_TRANSCRIPT="$TEST_DIR/no-transcript.md"
cat > "$NO_TRANSCRIPT" <<'MD'
---
date: 2026-06-03
title: "No Transcript"
source: "Codex"
session_id: "no-transcript"
record_kind: "interactive"
msg_count: 0
last_message_hash: "sha256:"
transcript_hash: "sha256:"
tags:
  - "codex"
---
# No Transcript
MD

if printf '{"summary":"x"}' | "$SCRIPT" "$NO_TRANSCRIPT" > "$TEST_DIR/no-transcript.out" 2> "$TEST_DIR/no-transcript.err"; then
    fail "missing Transcript is rejected"
else
    pass "missing Transcript is rejected"
fi
assert_file_contains "missing Transcript explains failure" "$TEST_DIR/no-transcript.err" "missing Transcript"

SYMLINK_NOTE="$TEST_DIR/symlink.md"
ln -s "$PARTIAL_NOTE" "$SYMLINK_NOTE"
if printf '{"summary":"x"}' | "$SCRIPT" "$SYMLINK_NOTE" > "$TEST_DIR/symlink.out" 2> "$TEST_DIR/symlink.err"; then
    fail "symlink markdown is rejected"
else
    pass "symlink markdown is rejected"
fi
assert_file_contains "symlink explains failure" "$TEST_DIR/symlink.err" "non-symlink"

if find "$REPO_DIR/scripts" "$REPO_DIR/tests" -name __pycache__ -type d | grep -q .; then
    fail "summary refresh avoids pycache"
else
    pass "summary refresh avoids pycache"
fi

echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
