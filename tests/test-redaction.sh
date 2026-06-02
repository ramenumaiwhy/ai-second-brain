#!/bin/bash
# Regression tests for transcript redaction across existing writers.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REDACTION_HELPER="$REPO_DIR/scripts/redact-secrets.py"
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
    assert_file_contains "codex has source frontmatter" "$CODEX_MD" "source: Codex"
    assert_file_contains "codex has session_id frontmatter" "$CODEX_MD" "session_id: 123e4567-e89b-12d3-a456-426614174000"
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
printf 'PASS: %s / FAIL: %s\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
