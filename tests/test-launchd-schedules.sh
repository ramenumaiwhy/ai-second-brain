#!/bin/bash
# Regression tests for macOS launchd schedule generation.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/install-launchd-schedules.sh"
TEST_DIR=$(mktemp -d /tmp/test-launchd-schedules-XXXXXX)
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

assert_file_exists() {
    local label="$1" file="$2"
    if [ -f "$file" ]; then
        pass "$label"
    else
        fail "$label (missing: $file)"
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

assert_not_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -Fq "$pattern" "$file" 2>/dev/null; then
        fail "$label (unexpected pattern: $pattern)"
    else
        pass "$label"
    fi
}

assert_executable() {
    local label="$1" file="$2"
    if [ -x "$file" ]; then
        pass "$label"
    else
        fail "$label (not executable: $file)"
    fi
}

run_install() {
    local out="$1" err="$2"
    shift 2
    "$SCRIPT" "$@" > "$out" 2> "$err"
}

echo ""
echo "=== LaunchAgent generation ==="

SECOND_BRAIN="$TEST_DIR/notes & vault"
AGENTS_DIR="$TEST_DIR/LaunchAgents"
STATE_DIR="$TEST_DIR/state"
mkdir -p "$SECOND_BRAIN"

SECOND_BRAIN_DIR="$SECOND_BRAIN" \
AI_LAUNCH_AGENTS_DIR="$AGENTS_DIR" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_LAUNCHD_IDLE_INTERVAL_SECONDS=1200 \
AI_LAUNCHD_DAILY_HOUR=4 \
AI_LAUNCHD_DAILY_MINUTE=30 \
CODEX_SESSIONS_DIR="$TEST_DIR/codex & sessions" \
CLAUDE_PROJECTS_DIR="$TEST_DIR/claude-projects" \
AI_IDLE_MIN_AGE_SECONDS=1800 \
AI_IDLE_MAX_SESSIONS=7 \
AI_RECOVERY_LOOKBACK_DAYS=5 \
AI_RECOVERY_MAX_SESSIONS=9 \
    run_install "$TEST_DIR/install.out" "$TEST_DIR/install.err" --no-load

IDLE_PLIST="$AGENTS_DIR/com.ai-second-brain.idle-sync.plist"
DAILY_PLIST="$AGENTS_DIR/com.ai-second-brain.daily-recovery.plist"

assert_executable "installer is executable" "$SCRIPT"
assert_file_exists "idle plist is written" "$IDLE_PLIST"
assert_file_exists "daily plist is written" "$DAILY_PLIST"
assert_file_contains "install output prints idle path" "$TEST_DIR/install.out" "$IDLE_PLIST"
assert_file_contains "install output prints daily path" "$TEST_DIR/install.out" "$DAILY_PLIST"
assert_not_contains "no-load skips launchctl output" "$TEST_DIR/install.out" "loaded com.ai-second-brain"

assert_file_contains "idle label is stable" "$IDLE_PLIST" "<string>com.ai-second-brain.idle-sync</string>"
assert_file_contains "idle script path is absolute" "$IDLE_PLIST" "<string>$REPO_DIR/scripts/sync-idle-ai-sessions.sh</string>"
assert_file_contains "idle interval is configurable" "$IDLE_PLIST" "<integer>1200</integer>"
assert_file_contains "idle runs at load" "$IDLE_PLIST" "<key>RunAtLoad</key>"
assert_file_contains "idle includes state dir" "$IDLE_PLIST" "<string>$STATE_DIR</string>"
assert_file_contains "idle path includes local bin" "$IDLE_PLIST" "$HOME/.local/bin"
assert_file_contains "idle path includes cargo bin" "$IDLE_PLIST" "$HOME/.cargo/bin"
assert_file_contains "idle escapes second brain path" "$IDLE_PLIST" "<string>$TEST_DIR/notes &amp; vault</string>"
assert_file_contains "idle preserves custom codex sessions dir" "$IDLE_PLIST" "<string>$TEST_DIR/codex &amp; sessions</string>"
assert_file_contains "idle preserves min age" "$IDLE_PLIST" "<key>AI_IDLE_MIN_AGE_SECONDS</key>"
assert_file_contains "idle preserves max sessions" "$IDLE_PLIST" "<string>7</string>"
assert_file_contains "idle has stderr log" "$IDLE_PLIST" "launchd-idle-sync.err.log"

assert_file_contains "daily label is stable" "$DAILY_PLIST" "<string>com.ai-second-brain.daily-recovery</string>"
assert_file_contains "daily script path is absolute" "$DAILY_PLIST" "<string>$REPO_DIR/scripts/recover-ai-sessions-daily.sh</string>"
assert_file_contains "daily uses calendar interval" "$DAILY_PLIST" "<key>StartCalendarInterval</key>"
assert_file_contains "daily hour is configurable" "$DAILY_PLIST" "<integer>4</integer>"
assert_file_contains "daily minute is configurable" "$DAILY_PLIST" "<integer>30</integer>"
assert_file_contains "daily preserves custom claude projects dir" "$DAILY_PLIST" "<string>$TEST_DIR/claude-projects</string>"
assert_file_contains "daily path includes local bin" "$DAILY_PLIST" "$HOME/.local/bin"
assert_file_contains "daily path includes cargo bin" "$DAILY_PLIST" "$HOME/.cargo/bin"
assert_file_contains "daily preserves lookback days" "$DAILY_PLIST" "<key>AI_RECOVERY_LOOKBACK_DAYS</key>"
assert_file_contains "daily preserves recovery max sessions" "$DAILY_PLIST" "<string>9</string>"
assert_file_contains "daily has stdout log" "$DAILY_PLIST" "launchd-daily-recovery.out.log"

if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$IDLE_PLIST" "$DAILY_PLIST" >/dev/null; then
        pass "generated plists are valid"
    else
        fail "generated plists are valid"
    fi
fi

echo ""
echo "=== Custom label prefix ==="

CUSTOM_AGENTS="$TEST_DIR/custom-agents"
SECOND_BRAIN_DIR="$SECOND_BRAIN" \
AI_LAUNCH_AGENTS_DIR="$CUSTOM_AGENTS" \
AI_SECOND_BRAIN_STATE_DIR="$STATE_DIR" \
AI_LAUNCHD_LABEL_PREFIX="com.example.ai-second-brain" \
    run_install "$TEST_DIR/custom.out" "$TEST_DIR/custom.err" --no-load

assert_file_exists "custom idle plist is written" "$CUSTOM_AGENTS/com.example.ai-second-brain.idle-sync.plist"
assert_file_contains "custom label is used" "$CUSTOM_AGENTS/com.example.ai-second-brain.idle-sync.plist" "com.example.ai-second-brain.idle-sync"

echo ""
echo "=== Validation failures ==="

unset SECOND_BRAIN_DIR
if AI_LAUNCH_AGENTS_DIR="$TEST_DIR/missing-agents" \
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/missing-state" \
    run_install "$TEST_DIR/missing.out" "$TEST_DIR/missing.err" --no-load; then
    fail "missing SECOND_BRAIN_DIR is rejected"
else
    pass "missing SECOND_BRAIN_DIR is rejected"
fi
assert_file_contains "missing SECOND_BRAIN_DIR explains failure" "$TEST_DIR/missing.err" "SECOND_BRAIN_DIR is required"

if SECOND_BRAIN_DIR="relative-notes" \
AI_LAUNCH_AGENTS_DIR="$TEST_DIR/relative-agents" \
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/relative-state" \
    run_install "$TEST_DIR/relative.out" "$TEST_DIR/relative.err" --no-load; then
    fail "relative SECOND_BRAIN_DIR is rejected"
else
    pass "relative SECOND_BRAIN_DIR is rejected"
fi
assert_file_contains "relative SECOND_BRAIN_DIR explains failure" "$TEST_DIR/relative.err" "absolute path"

SYMLINK_NOTES="$TEST_DIR/symlink-notes"
ln -s "$SECOND_BRAIN" "$SYMLINK_NOTES"
if SECOND_BRAIN_DIR="$SYMLINK_NOTES" \
AI_LAUNCH_AGENTS_DIR="$TEST_DIR/symlink-agents" \
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/symlink-state" \
    run_install "$TEST_DIR/symlink.out" "$TEST_DIR/symlink.err" --no-load; then
    fail "symlink SECOND_BRAIN_DIR is rejected"
else
    pass "symlink SECOND_BRAIN_DIR is rejected"
fi
assert_file_contains "symlink SECOND_BRAIN_DIR explains failure" "$TEST_DIR/symlink.err" "non-symlink"

if SECOND_BRAIN_DIR="$SECOND_BRAIN" \
AI_LAUNCH_AGENTS_DIR="$TEST_DIR/bad-interval-agents" \
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/bad-interval-state" \
AI_LAUNCHD_IDLE_INTERVAL_SECONDS=0 \
    run_install "$TEST_DIR/bad-interval.out" "$TEST_DIR/bad-interval.err" --no-load; then
    fail "zero idle interval is rejected"
else
    pass "zero idle interval is rejected"
fi
assert_file_contains "zero idle interval explains failure" "$TEST_DIR/bad-interval.err" "greater than 0"

if SECOND_BRAIN_DIR="$SECOND_BRAIN" \
AI_LAUNCH_AGENTS_DIR="$TEST_DIR/bad-hour-agents" \
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/bad-hour-state" \
AI_LAUNCHD_DAILY_HOUR=24 \
    run_install "$TEST_DIR/bad-hour.out" "$TEST_DIR/bad-hour.err" --no-load; then
    fail "bad daily hour is rejected"
else
    pass "bad daily hour is rejected"
fi
assert_file_contains "bad daily hour explains failure" "$TEST_DIR/bad-hour.err" "between 0 and 23"

if SECOND_BRAIN_DIR="$SECOND_BRAIN" \
AI_LAUNCH_AGENTS_DIR="$TEST_DIR/bad-label-agents" \
AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/bad-label-state" \
AI_LAUNCHD_LABEL_PREFIX="bad label" \
    run_install "$TEST_DIR/bad-label.out" "$TEST_DIR/bad-label.err" --no-load; then
    fail "bad label prefix is rejected"
else
    pass "bad label prefix is rejected"
fi
assert_file_contains "bad label prefix explains failure" "$TEST_DIR/bad-label.err" "unsupported characters"

if find "$REPO_DIR/scripts" "$REPO_DIR/tests" -name __pycache__ -type d | grep -q .; then
    fail "launchd installer avoids pycache"
else
    pass "launchd installer avoids pycache"
fi

echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
