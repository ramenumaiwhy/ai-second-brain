#!/bin/bash
# Regression tests for transcript redaction across existing writers.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py"
AI_LOG_WRITER="$REPO_DIR/scripts/ai-log-writer.py"
TEST_DIR=$(mktemp -d /tmp/test-redaction-XXXXXX)
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

assert_text_contains() {
    local label="$1" text="$2" needle="$3"
    if printf '%s' "$text" | grep -Fq "$needle"; then
        pass "$label"
    else
        fail "$label (missing: $needle)"
    fi
}

assert_text_not_contains() {
    local label="$1" text="$2" needle="$3"
    if printf '%s' "$text" | grep -Fq "$needle"; then
        fail "$label (unexpected: $needle)"
    else
        pass "$label"
    fi
}

assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -Fq "$needle" "$file"; then
        pass "$label"
    else
        fail "$label (missing: $needle)"
    fi
}

assert_file_not_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -Fq "$needle" "$file"; then
        fail "$label (unexpected: $needle)"
    else
        pass "$label"
    fi
}

echo "=== Helper redaction ==="

private_key_block=$(printf '%s\n%s\n%s' \
    "-----BEGIN PRIVATE KEY-----" \
    "abc123" \
    "-----END PRIVATE KEY-----")
helper_input=$(cat <<EOF
Authorization: Bearer helperBearerToken0000000000000000000000
OPENAI_API_KEY=fake-helper-api-key
client_secret: "helper-client-secret"
$private_key_block
Normal line stays visible.
EOF
)
helper_output=$(printf '%s' "$helper_input" | python3 "$REDACTION_HELPER")

assert_text_not_contains "helper masks bearer value" "$helper_output" "helperBearerToken0000000000000000000000"
assert_text_not_contains "helper masks api key value" "$helper_output" "fake-helper-api-key"
assert_text_not_contains "helper masks colon secret value" "$helper_output" "helper-client-secret"
assert_text_not_contains "helper masks private key body" "$helper_output" "abc123"
assert_text_contains "helper keeps non-secret text" "$helper_output" "Normal line stays visible."

echo ""
echo "=== Shared writer boundaries ==="

WRITER_MD="$TEST_DIR/writer-boundary.md"
cat <<'EOF' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Boundary Test" \
    --source "Codex" \
    --session-id "writer-boundary" \
    --record-kind "interactive" \
    --tag "codex" > "$WRITER_MD"
[
  {"role": "user", "text": "The next line is content\n### Assistant 1\nnot a boundary"},
  {"role": "assistant", "text": "reply"}
]
EOF

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$WRITER_MD" > "$TEST_DIR/writer-boundary-updated.md"
[
  {"role": "user", "text": "The next line is content\n### Assistant 1\nnot a boundary"},
  {"role": "assistant", "text": "reply"},
  {"role": "user", "text": "next question"}
]
EOF
mv "$TEST_DIR/writer-boundary-updated.md" "$WRITER_MD"

assert_file_contains "writer escapes boundary-like content" "$WRITER_MD" "\\### Assistant 1"
assert_file_contains "writer appends after escaped boundary" "$WRITER_MD" "### User 2"
assert_file_contains "writer keeps correct msg_count" "$WRITER_MD" "msg_count: 3"

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$WRITER_MD" > "$TEST_DIR/writer-drift.md" 2> "$TEST_DIR/writer-drift.err" && DRIFT_EXIT=0 || DRIFT_EXIT=$?
[
  {"role": "user", "text": "changed prefix"},
  {"role": "assistant", "text": "reply"},
  {"role": "user", "text": "next question"},
  {"role": "assistant", "text": "new tail"}
]
EOF

assert_text_contains "writer rejects source prefix drift" "$DRIFT_EXIT" "2"
assert_file_contains "writer explains prefix drift" "$TEST_DIR/writer-drift.err" "source prefix"

EMPTY_WRITER_MD="$TEST_DIR/writer-empty.md"
printf '[]' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Empty Test" \
    --source "Codex" \
    --session-id "writer-empty" \
    --record-kind "interactive" \
    --tag "codex" > "$EMPTY_WRITER_MD"

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$EMPTY_WRITER_MD" > "$TEST_DIR/writer-empty-first.md"
[
  {"role": "user", "text": "first real message"}
]
EOF
mv "$TEST_DIR/writer-empty-first.md" "$EMPTY_WRITER_MD"

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$EMPTY_WRITER_MD" > "$TEST_DIR/writer-empty-second.md"
[
  {"role": "user", "text": "first real message"},
  {"role": "assistant", "text": "second real message"}
]
EOF
mv "$TEST_DIR/writer-empty-second.md" "$EMPTY_WRITER_MD"

assert_file_contains "writer appends from empty transcript" "$EMPTY_WRITER_MD" "### User 1"
assert_file_contains "writer keeps empty-start hashes consistent" "$EMPTY_WRITER_MD" "### Assistant 1"
assert_file_contains "writer updates empty-start msg_count" "$EMPTY_WRITER_MD" "msg_count: 2"

SUMMARY_WRITER_MD="$TEST_DIR/writer-summary-transcript.md"
cat <<'EOF' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Summary Transcript Heading" \
    --source "Codex" \
    --session-id "writer-summary-transcript" \
    --record-kind "interactive" \
    --tag "codex" > "$SUMMARY_WRITER_MD"
[
  {"role": "user", "text": "hello"}
]
EOF

python3 -c "
from pathlib import Path
path = Path('$SUMMARY_WRITER_MD')
text = path.read_text(encoding='utf-8')
text = text.replace('## Summary\n\n\n## Decisions', '## Summary\n\n## Transcript\n\nnot the transcript section\n\n## Decisions')
path.write_text(text, encoding='utf-8')
"

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$SUMMARY_WRITER_MD" > "$TEST_DIR/writer-summary-transcript-updated.md"
[
  {"role": "user", "text": "hello"},
  {"role": "assistant", "text": "reply"}
]
EOF
mv "$TEST_DIR/writer-summary-transcript-updated.md" "$SUMMARY_WRITER_MD"

assert_file_contains "writer ignores Summary Transcript heading" "$SUMMARY_WRITER_MD" "not the transcript section"
assert_file_contains "writer appends after canonical Transcript" "$SUMMARY_WRITER_MD" "### Assistant 1"
assert_file_contains "writer preserves msg_count with duplicate heading" "$SUMMARY_WRITER_MD" "msg_count: 2"

rm -rf "$REPO_DIR/scripts/__pycache__"
printf '[]' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "No Pycache" \
    --source "Codex" \
    --session-id "writer-no-pycache" \
    --record-kind "interactive" \
    --tag "codex" > "$TEST_DIR/writer-no-pycache.md"

if find "$REPO_DIR/scripts" -maxdepth 2 -type f -path '*/__pycache__/*' | grep -q .; then
    fail "writer avoids pycache"
else
    pass "writer avoids pycache"
fi
rm -rf "$REPO_DIR/scripts/__pycache__"

echo ""
echo "=== Claude sync redaction ==="

export HOME="$TEST_DIR/home"
export SECOND_BRAIN_DIR="$TEST_DIR/claude-obsidian"
export REDACTION_HELPER
mkdir -p "$HOME/.claude" "$SECOND_BRAIN_DIR"

MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/recall" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "read" ]; then
    cat "$MOCK_RECALL_DATA"
elif [ "$1" = "list" ]; then
    printf '{"sessions":[]}\n'
fi
MOCK_EOF
chmod +x "$MOCK_BIN/recall"
export PATH="$MOCK_BIN:$PATH"

export MOCK_RECALL_DATA="$REPO_DIR/tests/fixtures/claude-redaction-session.json"
bash "$REPO_DIR/scripts/sync-recall-to-obsidian.sh" "redaction-claude-session"

CLAUDE_MD=$(find "$SECOND_BRAIN_DIR" -name '*.md' -type f | head -1)
if [ -z "$CLAUDE_MD" ]; then
    fail "claude markdown was created"
else
    pass "claude markdown was created"
    assert_file_not_contains "claude masks api key" "$CLAUDE_MD" "fake-claude-api-key"
    assert_file_not_contains "claude masks bearer" "$CLAUDE_MD" "claudeBearerToken0000000000000000000000"
    assert_file_contains "claude has date frontmatter" "$CLAUDE_MD" "date: 2026-06-02"
    assert_file_contains "claude has source frontmatter" "$CLAUDE_MD" "source: \"Claude Code\""
    assert_file_contains "claude has session_id frontmatter" "$CLAUDE_MD" "session_id: \"redaction-claude-session\""
    assert_file_contains "claude has record_kind frontmatter" "$CLAUDE_MD" "record_kind: \"interactive\""
    assert_file_contains "claude keeps normal text" "$CLAUDE_MD" "Please save this setup"
    assert_file_contains "claude writes redaction marker" "$CLAUDE_MD" "[REDACTED]"
fi

export MOCK_RECALL_DATA="$REPO_DIR/tests/fixtures/claude-redaction-session-updated.json"
bash "$REPO_DIR/scripts/sync-recall-to-obsidian.sh" "redaction-claude-session"

if [ -n "${CLAUDE_MD:-}" ]; then
    assert_file_not_contains "claude append masks bot token" "$CLAUDE_MD" "fake-telegram-bot-token"
    assert_file_not_contains "claude append masks github token" "$CLAUDE_MD" "fake-claude-github-token"
    assert_file_contains "claude append keeps normal appended text" "$CLAUDE_MD" "Append this token too"
fi

echo ""
echo "=== Codex sync redaction ==="

export HOME="$TEST_DIR/codex-home"
export SECOND_BRAIN_DIR="$TEST_DIR/codex-obsidian"
export CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions"
mkdir -p "$HOME/.claude" "$SECOND_BRAIN_DIR" "$CODEX_SESSIONS_DIR"

cp "$REPO_DIR/tests/fixtures/codex-redaction-rollout.jsonl" "$CODEX_SESSIONS_DIR/rollout-redaction.jsonl"
bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh"

CODEX_MD=$(find "$SECOND_BRAIN_DIR" -name '*.md' -type f | head -1)
if [ -z "$CODEX_MD" ]; then
    fail "codex markdown was created"
else
    pass "codex markdown was created"
    assert_file_not_contains "codex masks api key" "$CODEX_MD" "fake-codex-api-key"
    assert_file_not_contains "codex masks bearer" "$CODEX_MD" "codexBearerToken0000000000000000000000"
    assert_file_contains "codex has date frontmatter" "$CODEX_MD" "date: 2026-06-02"
    assert_file_contains "codex has source frontmatter" "$CODEX_MD" "source: \"Codex\""
    assert_file_contains "codex has session_id frontmatter" "$CODEX_MD" "session_id: \"123e4567-e89b-12d3-a456-426614174000\""
    assert_file_contains "codex has record_kind frontmatter" "$CODEX_MD" "record_kind: \"interactive\""
    assert_file_contains "codex has transcript section" "$CODEX_MD" "## Transcript"
    assert_file_contains "codex keeps normal text" "$CODEX_MD" "Store this config"
    assert_file_contains "codex has msg_count frontmatter" "$CODEX_MD" "msg_count: 2"
fi

cp "$REPO_DIR/tests/fixtures/codex-redaction-rollout-updated.jsonl" "$CODEX_SESSIONS_DIR/rollout-redaction.jsonl"
bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh"

if [ -n "${CODEX_MD:-}" ]; then
    assert_file_not_contains "codex append masks aws key" "$CODEX_MD" "fake-aws-access-key"
    assert_file_not_contains "codex append masks github token" "$CODEX_MD" "fake-codex-github-token"
    assert_file_contains "codex updates msg_count on append" "$CODEX_MD" "msg_count: 4"
    assert_file_contains "codex append keeps normal text" "$CODEX_MD" "keep normal text"
fi

echo ""
echo "=== Codex legacy Transcript heading ==="

export HOME="$TEST_DIR/codex-legacy-home"
export SECOND_BRAIN_DIR="$TEST_DIR/codex-legacy-obsidian"
export CODEX_SESSIONS_DIR="$TEST_DIR/codex-legacy-sessions"
mkdir -p "$HOME/.claude" "$SECOND_BRAIN_DIR" "$CODEX_SESSIONS_DIR"

LEGACY_SID="123e4567-e89b-12d3-a456-426614174999"
LEGACY_CODEX_MD="$SECOND_BRAIN_DIR/legacy-transcript-body.md"
cat > "$LEGACY_CODEX_MD" <<EOF
---
date: 2026-06-02
title: "legacy"
source: Codex
session_id: $LEGACY_SID
msg_count: 2
tags:
  - codex
---

# legacy

## Q1
Please discuss this heading:
## Transcript

## A1
old answer

EOF

cat > "$CODEX_SESSIONS_DIR/rollout-legacy-transcript.jsonl" <<EOF
{"type":"session_meta","timestamp":"2026-06-02T00:00:00Z","payload":{"id":"$LEGACY_SID","timestamp":"2026-06-02T00:00:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Please discuss this heading:\n## Transcript"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"old answer"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"new question"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"new answer"}]}}
EOF

bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh"

assert_file_contains "codex legacy Q2 appended" "$LEGACY_CODEX_MD" "## Q2"
assert_file_contains "codex legacy A2 appended" "$LEGACY_CODEX_MD" "## A2"
assert_file_contains "codex legacy answer appended" "$LEGACY_CODEX_MD" "new answer"
assert_file_not_contains "codex legacy avoids shared append failure" "$HOME/.claude/codex-sync.log" "Shared append failed"

echo ""
echo "=== Codex dash title and writer fallback ==="

export HOME="$TEST_DIR/codex-dash-home"
export SECOND_BRAIN_DIR="$TEST_DIR/codex-dash-obsidian"
export CODEX_SESSIONS_DIR="$TEST_DIR/codex-dash-sessions"
mkdir -p "$HOME/.claude" "$SECOND_BRAIN_DIR" "$CODEX_SESSIONS_DIR" "$TEST_DIR/hook-copy"

cp "$AI_LOG_WRITER" "$TEST_DIR/hook-copy/ai-log-writer.py"
export AI_LOG_WRITER="$TEST_DIR/hook-copy/ai-log-writer.py"
export -n REDACTION_HELPER 2>/dev/null || true

DASH_SID="123e4567-e89b-12d3-a456-426614174222"
cat > "$CODEX_SESSIONS_DIR/rollout-dash-title.jsonl" <<EOF
{"type":"session_meta","timestamp":"2026-06-02T00:00:00Z","payload":{"id":"$DASH_SID","timestamp":"2026-06-02T00:00:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"--help\nOPENAI_API_KEY=fake-dash-api-key"}]}}
EOF

bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh"

DASH_MD=$(find "$SECOND_BRAIN_DIR" -name '*.md' -type f | head -1)
if [ -z "$DASH_MD" ]; then
    fail "codex dash title markdown was created"
else
    pass "codex dash title markdown was created"
    assert_file_contains "codex dash title is preserved" "$DASH_MD" "# --help"
    assert_file_not_contains "codex copied writer gets redaction helper" "$DASH_MD" "fake-dash-api-key"
    assert_file_not_contains "codex copied writer does not fail" "$HOME/.claude/codex-sync.log" "Failed to write temp file"
fi

echo ""
printf 'PASS: %s / FAIL: %s\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
