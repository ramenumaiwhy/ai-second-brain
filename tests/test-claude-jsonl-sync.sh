#!/bin/bash
# Regression tests for Claude JSONL sync after the recall -> ctx migration.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/sync-recall-to-obsidian.sh"
TEST_DIR=$(mktemp -d /tmp/test-claude-jsonl-sync-XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] || fail "$label (expected: $expected, got: $actual)"
    printf 'PASS: %s\n' "$label"
}

HOME="$TEST_DIR/home"
PROJECTS_DIR="$HOME/.claude/projects"
SECOND_BRAIN="$TEST_DIR/second-brain"
SESSION_ID="ctx-migration-session"
JSONL_PATH="$PROJECTS_DIR/project-a/$SESSION_ID.jsonl"
mkdir -p "$(dirname "$JSONL_PATH")" "$SECOND_BRAIN"

cat > "$JSONL_PATH" <<'EOF'
{"type":"user","sessionId":"ctx-migration-session","timestamp":"2026-07-13T01:00:00Z","message":{"role":"user","content":"first question"}}
{"type":"assistant","sessionId":"ctx-migration-session","timestamp":"2026-07-13T01:00:01Z","message":{"role":"assistant","content":"first answer"}}
EOF

run_sync() {
    rm -rf "$HOME/.claude/recall-obsidian-sync.lock" 2>/dev/null || true
    HOME="$HOME" \
    PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SECOND_BRAIN_DIR="$SECOND_BRAIN" \
    CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" \
    CLAUDE_SESSION_JSONL_PATH="$JSONL_PATH" \
    "$SCRIPT" "$SESSION_ID"
}

if command -v recall >/dev/null 2>&1; then
    fail "test PATH unexpectedly contains recall"
fi

run_sync
RAW_FILE=$(find "$SECOND_BRAIN/AI-Logs/raw/claude" -name '*.md' -type f | head -1)
[ -n "$RAW_FILE" ] || fail "first sync did not create a raw log"
assert_eq "first sync stores one user turn" "1" "$(grep -c '^### User ' "$RAW_FILE")"
assert_eq "first sync stores one assistant turn" "1" "$(grep -c '^### Assistant ' "$RAW_FILE")"

FIRST_HASH=$(shasum -a 256 "$RAW_FILE" | awk '{print $1}')
run_sync
SECOND_HASH=$(shasum -a 256 "$RAW_FILE" | awk '{print $1}')
assert_eq "unchanged JSONL is idempotent" "$FIRST_HASH" "$SECOND_HASH"

cat >> "$JSONL_PATH" <<'EOF'
{"type":"user","sessionId":"ctx-migration-session","timestamp":"2026-07-13T01:01:00Z","message":{"role":"user","content":"second question"}}
{"type":"assistant","sessionId":"ctx-migration-session","timestamp":"2026-07-13T01:01:01Z","message":{"role":"assistant","content":"second answer"}}
EOF

run_sync
assert_eq "one appended user turn is stored once" "2" "$(grep -c '^### User ' "$RAW_FILE")"
assert_eq "one appended assistant turn is stored once" "2" "$(grep -c '^### Assistant ' "$RAW_FILE")"

mkdir -p "$PROJECTS_DIR/project-b"
cp "$JSONL_PATH" "$PROJECTS_DIR/project-b/$SESSION_ID.jsonl"
if HOME="$HOME" \
    PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SECOND_BRAIN_DIR="$SECOND_BRAIN" \
    CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" \
    "$SCRIPT" "$SESSION_ID"; then
    fail "pathless sync accepted an ambiguous session id"
else
    printf 'PASS: pathless sync rejects an ambiguous session id\n'
fi
rm -f "$PROJECTS_DIR/project-b/$SESSION_ID.jsonl"

OUTSIDE_JSONL="$TEST_DIR/outside.jsonl"
cp "$JSONL_PATH" "$OUTSIDE_JSONL"
if HOME="$HOME" \
    PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SECOND_BRAIN_DIR="$SECOND_BRAIN" \
    CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" \
    CLAUDE_SESSION_JSONL_PATH="$OUTSIDE_JSONL" \
    "$SCRIPT" "$SESSION_ID"; then
    fail "sync accepted a JSONL path outside CLAUDE_PROJECTS_DIR"
else
    printf 'PASS: sync rejects a JSONL path outside CLAUDE_PROJECTS_DIR\n'
fi

COLLISION_ID="duplicate-session-id"
mkdir -p "$PROJECTS_DIR/duplicate-a" "$PROJECTS_DIR/duplicate-b"
cat > "$PROJECTS_DIR/duplicate-a/first.jsonl" <<'EOF'
{"type":"user","sessionId":"duplicate-session-id","timestamp":"2026-07-13T02:00:00Z","message":{"role":"user","content":"collision one"}}
EOF
cat > "$PROJECTS_DIR/duplicate-b/second.jsonl" <<'EOF'
{"type":"user","sessionId":"duplicate-session-id","timestamp":"2026-07-13T02:01:00Z","message":{"role":"user","content":"collision two"}}
EOF
rm -rf "$HOME/.claude/recall-obsidian-sync.lock" 2>/dev/null || true
HOME="$HOME" \
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
SECOND_BRAIN_DIR="$SECOND_BRAIN" \
CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" \
    "$SCRIPT"
assert_eq "full sync keeps duplicate session paths separate" "2" "$(grep -rlE 'collision (one|two)' "$SECOND_BRAIN/AI-Logs/raw/claude" | wc -l | tr -d ' ')"

printf 'All Claude JSONL migration tests passed.\n'
