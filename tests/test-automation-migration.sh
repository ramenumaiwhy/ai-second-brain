#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYNC_SCRIPT="$REPO_DIR/scripts/sync-codex-to-obsidian.sh"
PLANNER="$REPO_DIR/scripts/plan-automation-view-migration.py"
APPLIER="$REPO_DIR/scripts/apply-automation-view-migration.py"
TEST_DIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(mktemp -d /tmp/test-automation-migration-XXXXXX)")
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (expected: %s, got: %s)\n' "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

mkdir -p "$TEST_DIR/home/.claude" "$TEST_DIR/sessions" "$TEST_DIR/notes"
SID="123e4567-e89b-12d3-a456-426614174201"
JSONL="$TEST_DIR/sessions/automation.jsonl"
cat > "$JSONL" <<JSONL
{"type":"session_meta","timestamp":"2026-06-03T10:10:00Z","payload":{"id":"$SID","timestamp":"2026-06-03T10:10:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Automation: Health Check\nAutomation ID: health-check\nAutomation memory: \$CODEX_HOME/automations/health-check/memory.md\nLast run: 2026-06-03T10:00:00Z\n\nCheck health."}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Healthy."}]}}
JSONL

HOME="$TEST_DIR/home" \
SECOND_BRAIN_DIR="$TEST_DIR/notes" \
CODEX_SESSIONS_DIR="$TEST_DIR/sessions" \
    "$SYNC_SCRIPT" "$JSONL"

AUTOMATION_VIEW=$(find "$TEST_DIR/notes/AI-Logs/automation" -name '*.md' -type f | head -1)
READABLE_VIEW="$TEST_DIR/notes/AI-Logs/readable/codex/2026-06/$SID.md"
mkdir -p "$(dirname "$READABLE_VIEW")"
cp "$AUTOMATION_VIEW" "$READABLE_VIEW"
rm "$AUTOMATION_VIEW"

MANIFEST="$TEST_DIR/manifest.jsonl"
SECOND_BRAIN_DIR="$TEST_DIR/notes" "$PLANNER" > "$MANIFEST" 2> "$TEST_DIR/planner.err"
SOURCE_ORIGINAL="$TEST_DIR/source-original.md"
cp "$READABLE_VIEW" "$SOURCE_ORIGINAL"

assert_eq "planner finds one verified automation view" "1" "$(wc -l < "$MANIFEST" | tr -d ' ')"
assert_eq "planner reports no collision" "False" "$(python3 - "$MANIFEST" <<'PY'
import json
import sys
print(json.loads(open(sys.argv[1], encoding="utf-8").readline())["collision"])
PY
)"
assert_eq "planner is read only" "1" "$([ -f "$READABLE_VIEW" ] && printf 1 || printf 0)"
assert_eq "planner reports candidate count" "1" "$(sed -n 's/.* candidates=\([0-9][0-9]*\)$/\1/p' "$TEST_DIR/planner.err")"
assert_eq "planner records a frozen file snapshot" "True" "$(python3 - "$MANIFEST" <<'PY'
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
required = {"raw_mtime_ns", "raw_size", "raw_sha256", "source_mtime_ns", "source_size", "source_sha256"}
print(required <= row.keys())
PY
)"
assert_eq "planner rejects unclosed frontmatter" "True" "$(python3 - "$PLANNER" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("migration_planner", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
frontmatter, _body = module.read_markdown_bytes(b'---\nsession_id: "broken"\nbody\n')
print(frontmatter == {})
PY
)"

RAW_FILE=$(python3 - "$MANIFEST" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding="utf-8").readline())["raw_path"])
PY
)
TARGET_FILE=$(python3 - "$MANIFEST" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding="utf-8").readline())["target_path"])
PY
)
RAW_BEFORE_HASH=$(shasum -a 256 "$RAW_FILE" | awk '{print $1}')
SOURCE_BEFORE_HASH=$(shasum -a 256 "$READABLE_VIEW" | awk '{print $1}')

printf '\ndrift\n' >> "$READABLE_VIEW"
set +e
SECOND_BRAIN_DIR="$TEST_DIR/notes" AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" \
    "$APPLIER" apply --manifest "$MANIFEST" --batch-id drift >/dev/null 2>&1
DRIFT_EXIT=$?
set -e
assert_eq "apply rejects source drift" "1" "$DRIFT_EXIT"
assert_eq "drift failure does not create target" "0" "$([ -e "$TARGET_FILE" ] && printf 1 || printf 0)"
cp "$SOURCE_ORIGINAL" "$READABLE_VIEW"
python3 - "$MANIFEST" "$READABLE_VIEW" <<'PY'
import json, os, sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
mtime = int(row["source_mtime_ns"])
os.utime(sys.argv[2], ns=(mtime, mtime))
PY

mkdir -p "$(dirname "$TARGET_FILE")"
printf 'collision\n' > "$TARGET_FILE"
set +e
SECOND_BRAIN_DIR="$TEST_DIR/notes" AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" \
    "$APPLIER" apply --manifest "$MANIFEST" --batch-id collision >/dev/null 2>&1
COLLISION_EXIT=$?
set -e
assert_eq "apply rejects target collision" "1" "$COLLISION_EXIT"
rm "$TARGET_FILE"

ln -s "$TEST_DIR/notes" "$TEST_DIR/notes-link"
set +e
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" \
    "$APPLIER" apply --root "$TEST_DIR/notes-link" --manifest "$MANIFEST" --batch-id symlink-root >/dev/null 2>&1
SYMLINK_ROOT_EXIT=$?
set -e
assert_eq "apply rejects a symlink root" "1" "$SYMLINK_ROOT_EXIT"

LOCKED_APPLY_EXIT=$(python3 - "$APPLIER" "$TEST_DIR/notes" "$TEST_DIR/state" "$MANIFEST" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

script, root, state, manifest = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("automation_apply", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
with module.migration_lock(Path(state), Path(root)):
    result = subprocess.run(
        [script, "apply", "--root", root, "--state-dir", state, "--manifest", manifest, "--batch-id", "locked"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
print(result.returncode)
PY
)
assert_eq "apply rejects a concurrent migration" "1" "$LOCKED_APPLY_EXIT"

APPLY_OUTPUT=$(SECOND_BRAIN_DIR="$TEST_DIR/notes" AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" \
    "$APPLIER" apply --manifest "$MANIFEST" --batch-id apply-one)
BATCH_ONE=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["batch_dir"])' <<< "$APPLY_OUTPUT")
assert_eq "apply moves verified view out of readable" "0" "$([ -e "$READABLE_VIEW" ] && printf 1 || printf 0)"
assert_eq "apply creates automation target" "1" "$([ -f "$TARGET_FILE" ] && printf 1 || printf 0)"
assert_eq "apply updates raw classification" "1" "$(grep -c 'record_kind: "automation"' "$RAW_FILE")"
assert_eq "apply updates target classification" "1" "$(grep -c 'record_kind: "automation"' "$TARGET_FILE")"

TARGET_APPLIED_COPY="$TEST_DIR/target-applied.md"
cp "$TARGET_FILE" "$TARGET_APPLIED_COPY"
printf '\nuser edit after apply\n' >> "$TARGET_FILE"
set +e
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" "$APPLIER" rollback --batch-dir "$BATCH_ONE" >/dev/null 2>&1
EDITED_ROLLBACK_EXIT=$?
set -e
assert_eq "rollback refuses an edited target" "1" "$EDITED_ROLLBACK_EXIT"
assert_eq "failed rollback keeps edited target" "1" "$(grep -c 'user edit after apply' "$TARGET_FILE")"
cp "$TARGET_APPLIED_COPY" "$TARGET_FILE"

ROLLBACK_RACE_RESULT=$(python3 - "$APPLIER" "$BATCH_ONE" <<'PY'
import importlib.util
from pathlib import Path
import sys

script, batch_dir = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("automation_apply_race", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
batch_file = Path(batch_dir) / "batch.json"
original = module.rollback_preflight

def injected(batch_path, batch):
    validated = original(batch_path, batch)
    Path(validated[0]["source"]).write_text("created after rollback preflight\n", encoding="utf-8")
    return validated

module.rollback_preflight = injected
try:
    module.restore_batch(batch_file)
except RuntimeError:
    print(Path(module.json.loads(batch_file.read_text(encoding="utf-8"))["rows"][0]["source_path"]).read_text(encoding="utf-8").strip())
else:
    print("rollback unexpectedly succeeded")
PY
)
assert_eq "rollback does not overwrite a source created after preflight" "created after rollback preflight" "$ROLLBACK_RACE_RESULT"
rm "$READABLE_VIEW"

AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" "$APPLIER" rollback --batch-dir "$BATCH_ONE" >/dev/null
assert_eq "rollback restores readable source" "1" "$([ -f "$READABLE_VIEW" ] && printf 1 || printf 0)"
assert_eq "rollback removes unchanged automation target" "0" "$([ -e "$TARGET_FILE" ] && printf 1 || printf 0)"
assert_eq "rollback restores raw bytes exactly" "$RAW_BEFORE_HASH" "$(shasum -a 256 "$RAW_FILE" | awk '{print $1}')"
assert_eq "rollback restores readable bytes exactly" "$SOURCE_BEFORE_HASH" "$(shasum -a 256 "$READABLE_VIEW" | awk '{print $1}')"

SECOND_BRAIN_DIR="$TEST_DIR/notes" AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state" \
    "$APPLIER" apply --manifest "$MANIFEST" --batch-id apply-two >/dev/null
assert_eq "reapply succeeds after rollback" "1" "$([ -f "$TARGET_FILE" ] && [ ! -e "$READABLE_VIEW" ] && printf 1 || printf 0)"

printf '\nPASS: %s / FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
