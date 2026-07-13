#!/bin/bash
# Regression tests for immediate Hermes turn saves.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/save-hermes-turn.py"
TEST_DIR=$(mktemp -d /tmp/test-hermes-save-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export SECOND_BRAIN_DIR="$TEST_DIR/notes"
export AI_SECOND_BRAIN_STATE_DIR="$TEST_DIR/state"
mkdir -p "$SECOND_BRAIN_DIR"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

run_turn() {
    printf '%s' "$1" | python3 "$SCRIPT"
}

first='{
  "session_id": "hermes:test/session",
  "turn_id": "turn-1",
  "platform": "cli",
  "user_message": "Hermes syncを作って",
  "assistant_response": "保存した。\nOPENAI_API_KEY=sk-proj-openclawPhaseToken0000000000"
}'
FIRST_PATH=$(run_turn "$first")
[ -f "$FIRST_PATH" ] || fail "readable log was not created"
RAW_PATH="$SECOND_BRAIN_DIR/AI-Logs/raw/hermes/$(date +%Y-%m)/hermes:test-session.md"
[ -f "$RAW_PATH" ] || fail "raw log was not created"
grep -Fq 'source: "Hermes Agent"' "$RAW_PATH" || fail "source metadata is missing"
grep -Fq 'last_hermes_turn_id: "turn-1"' "$RAW_PATH" || fail "turn id is missing"
grep -Fq '[REDACTED]' "$RAW_PATH" || fail "secret was not redacted"
! grep -Fq 'openclawPhaseToken' "$RAW_PATH" || fail "secret leaked"

run_turn "$first" >/dev/null
[ "$(grep -c '^### User ' "$RAW_PATH")" = 1 ] || fail "duplicate turn was appended"

second='{
  "session_id": "hermes:test/session",
  "turn_id": "turn-2",
  "platform": "telegram",
  "user_message": "次も保存して",
  "assistant_response": "二つ目も保存した。"
}'
run_turn "$second" >/dev/null
[ "$(grep -c '^### User ' "$RAW_PATH")" = 2 ] || fail "second user turn was not appended"
[ "$(grep -c '^### Assistant ' "$RAW_PATH")" = 2 ] || fail "second assistant turn was not appended"
grep -Fq '二つ目も保存した。' "$FIRST_PATH" || fail "readable log was not refreshed"

REPO_DIR="$REPO_DIR" python3 - <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
plugin_path = Path(os.environ["REPO_DIR"]) / "integrations" / "hermes-second-brain" / "__init__.py"
spec = importlib.util.spec_from_file_location("hermes_second_brain_test", plugin_path)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load Hermes plugin")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module._on_post_llm_call(
    session_id="plugin-callback",
    turn_id="plugin-turn-1",
    platform="test",
    user_message="plugin hook test",
    assistant_response="plugin hook saved",
)
PY
PLUGIN_PATH="$SECOND_BRAIN_DIR/AI-Logs/readable/hermes/$(date +%Y-%m)/plugin-callback.md"
[ -f "$PLUGIN_PATH" ] || fail "post_llm_call plugin did not save"
grep -Fq 'plugin hook saved' "$PLUGIN_PATH" || fail "post_llm_call plugin lost assistant response"

echo "PASS: Hermes turns save immediately and idempotently"
