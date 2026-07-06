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
    if printf '%s' "$text" | grep -Fq -- "$needle"; then
        pass "$label"
    else
        fail "$label (missing: $needle)"
    fi
}

assert_text_not_contains() {
    local label="$1" text="$2" needle="$3"
    if printf '%s' "$text" | grep -Fq -- "$needle"; then
        fail "$label (unexpected: $needle)"
    else
        pass "$label"
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

raw_markdown_by_session_id() {
    local root="$1" sid="$2"
    find "$root/AI-Logs/raw" -name '*.md' -type f -print0 2>/dev/null | \
        xargs -0 grep -l "session_id: \"$sid\"" 2>/dev/null | head -1 || true
}

echo "=== Helper redaction ==="

private_key_block=$(printf '%s\n%s\n%s' \
    "-----BEGIN PRIVATE KEY-----" \
    "abc123" \
    "-----END PRIVATE KEY-----")
stripe_key="rk_li""ve_helperStripeToken000000000000"
helper_input=$(cat <<'EOF'
Authorization: Bearer helperBearerToken0000000000000000000000
Authorization: Bearer --helperDashedBearerToken000000000000
OPENAI_API_KEY=fake-helper-api-key
client_secret: "helper-client-secret"
ANTHROPIC_API_KEY=sk-ant-api03-helperAnthropicToken0000000000000000
GOOGLE_API_KEY=AIzaHelperGoogleToken000000000000000000000
HF_TOKEN=hf_helperHuggingFaceToken000000000
MULTILINE_SECRET="helper multiline first
helper multiline second
helper multiline third"
ESCAPED_MULTILINE_SECRET="escaped quote \" stays secret
secret tail after escaped quote
escaped multiline close"
COMMENTED_MULTILINE_SECRET="helper comment first
helper comment second" # keep comment
JSON_MULTILINE_SECRET: "helper json first
helper json second",
SHELL_MULTILINE_SECRET="helper shell first
helper shell second";
JSON_COMMENT_MULTILINE_SECRET: "helper json comment first
helper json comment second", # keep comment
JSON_BRACE_MULTILINE_SECRET: "helper json brace first
helper json brace second" }
INLINE_JSON_OBJECT={"api_key": "helper inline first
helper inline second", "safe": "ok"}
SINGLE_LINE_INLINE_OBJECT={"api_key": "helper inline single", "safe": "visible-safe"}
CHAINED_SECRET="helper chained first", PASSWORD="helper chained password"
CHAINED_JSON_OBJECT={"api_key": "helper chained inline", "password": "helper chained json password", "safe": "visible-chained-safe"}
UNQUOTED_JSON_TAIL={"api_key": "helper unquoted first", "password": helper-unquoted-json-password, "safe": "visible-unquoted-safe"}
CHAINED_MULTILINE_JSON_OBJECT={"api_key": "helper chained inline first", "password": "helper chained multiline first
helper chained multiline second", "safe": "ok"}
COMMA_TAIL_SECRET="helper comma tail first
helper comma tail second", SAFE=ok
QUOTE_IN_MULTILINE_SECRET="helper quote first
second line with "quote", still secret
after secret"
QUOTE_PAIR_IN_MULTILINE_SECRET="helper pair quote first
text "quoted", foo=bar
still pair secret
"
QUOTE_COLON_IN_MULTILINE_SECRET="helper colon quote first
text "quoted", foo: bar
still colon secret
"
QUOTE_UPPER_IN_MULTILINE_SECRET="helper upper quote first
text "quoted", SAFE=ok
still upper secret
"
QUOTE_QUOTED_KEY_IN_MULTILINE_SECRET="helper quoted-key quote first
text "quoted", "foo": "bar"
still quoted-key secret
"
QUOTE_SECRET="helper prefix "middle", suffix"
```env
NPM_TOKEN=fake-helper-npm-token
```
Normal line stays visible.
EOF
)
helper_input="${helper_input}"$'\n'"STRIPE_SECRET_KEY=${stripe_key}"$'\n'"$private_key_block"$'\nUNCLOSED_SECRET="helper unterminated secret\nNormal line after unterminated secret remains.\nQUOTE_NORMAL_SECRET="helper quote normal\nNormal "quoted" text after unterminated secret remains.'
HELPER_AUDIT_LOG="$TEST_DIR/helper-audit.log"
helper_output=$(printf '%s' "$helper_input" | REDACTION_AUDIT_LOG="$HELPER_AUDIT_LOG" python3 "$REDACTION_HELPER")

assert_text_not_contains "helper masks bearer value" "$helper_output" "helperBearerToken0000000000000000000000"
assert_text_not_contains "helper masks dashed bearer value" "$helper_output" "helperDashedBearerToken000000000000"
assert_text_not_contains "helper masks api key value" "$helper_output" "fake-helper-api-key"
assert_text_not_contains "helper masks colon secret value" "$helper_output" "helper-client-secret"
assert_text_not_contains "helper masks anthropic key" "$helper_output" "helperAnthropicToken0000000000000000"
assert_text_not_contains "helper masks google key" "$helper_output" "HelperGoogleToken000000000000000000000"
assert_text_not_contains "helper masks stripe key" "$helper_output" "helperStripeToken000000000000"
assert_text_not_contains "helper masks huggingface token" "$helper_output" "helperHuggingFaceToken000000000"
assert_text_not_contains "helper masks multiline secret continuation" "$helper_output" "helper multiline second"
assert_text_not_contains "helper ignores escaped multiline quote" "$helper_output" "secret tail after escaped quote"
assert_text_not_contains "helper masks commented multiline secret continuation" "$helper_output" "helper comment second"
assert_text_not_contains "helper masks comma multiline secret continuation" "$helper_output" "helper json second"
assert_text_not_contains "helper masks semicolon multiline secret continuation" "$helper_output" "helper shell second"
assert_text_not_contains "helper masks comma-comment multiline secret continuation" "$helper_output" "helper json comment second"
assert_text_not_contains "helper masks brace multiline secret continuation" "$helper_output" "helper json brace second"
assert_text_not_contains "helper masks inline json multiline continuation" "$helper_output" "helper inline second"
assert_text_contains "helper preserves inline json multiline safe tail" "$helper_output" "\"safe\": \"ok\""
assert_text_not_contains "helper masks single-line inline json secret" "$helper_output" "helper inline single"
assert_text_contains "helper preserves single-line inline json tail" "$helper_output" "visible-safe"
assert_text_not_contains "helper masks chained assignment secret" "$helper_output" "helper chained password"
assert_text_not_contains "helper masks chained inline json secret" "$helper_output" "helper chained json password"
assert_text_contains "helper preserves chained inline json safe tail" "$helper_output" "visible-chained-safe"
assert_text_not_contains "helper masks unquoted json tail secret" "$helper_output" "helper-unquoted-json-password"
assert_text_contains "helper preserves unquoted json tail safe field" "$helper_output" "visible-unquoted-safe"
assert_text_not_contains "helper masks chained multiline inline json secret" "$helper_output" "helper chained multiline second"
assert_text_not_contains "helper masks comma-tail multiline continuation" "$helper_output" "helper comma tail second"
assert_text_not_contains "helper ignores quote-comma inside multiline secret" "$helper_output" "still secret"
assert_text_not_contains "helper keeps quote-comma multiline secret closed later" "$helper_output" "after secret"
assert_text_not_contains "helper ignores lowercase pair after quote inside multiline secret" "$helper_output" "foo=bar"
assert_text_not_contains "helper keeps lowercase pair multiline secret closed later" "$helper_output" "still pair secret"
assert_text_not_contains "helper ignores colon pair after quote inside multiline secret" "$helper_output" "foo: bar"
assert_text_not_contains "helper keeps colon pair multiline secret closed later" "$helper_output" "still colon secret"
assert_text_not_contains "helper ignores uppercase pair after quote inside multiline secret" "$helper_output" "SAFE=ok"
assert_text_not_contains "helper keeps uppercase pair multiline secret closed later" "$helper_output" "still upper secret"
assert_text_not_contains "helper ignores quoted key after quote inside multiline secret" "$helper_output" "\"foo\": \"bar\""
assert_text_not_contains "helper keeps quoted-key multiline secret closed later" "$helper_output" "still quoted-key secret"
assert_text_not_contains "helper masks quote-comma same-line secret tail" "$helper_output" "middle"
assert_text_not_contains "helper masks quote-comma same-line secret suffix" "$helper_output" "suffix"
weak_tail_output=$(printf '%s\n' \
    'COMMA_TAIL_SECRET="helper weak close first' \
    'helper weak close second", SAFE=ok' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks weak comma-tail multiline continuation" "$weak_tail_output" "helper weak close second"
assert_text_contains "helper preserves weak comma-tail trailing assignment" "$weak_tail_output" "SAFE=ok"
comment_quote_output=$(printf '%s\n' \
    'COMMENT_QUOTE_SECRET="helper comment quote first' \
    'helper comment quote second" # comment "quoted"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks comment-quote multiline continuation" "$comment_quote_output" "helper comment quote second"
assert_text_contains "helper preserves quoted closing comment" "$comment_quote_output" '# comment "quoted"'
delimiter_comment_output=$(printf '%s\n' \
    'DELIMITER_COMMENT_SECRET="helper delimiter comment first' \
    'helper delimiter comment comma", # keep comma comment' \
    'DELIMITER_BRACE_COMMENT_SECRET="helper delimiter comment brace first' \
    'helper delimiter comment brace" } # keep brace comment' \
    'after delimiter comment' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks comma delimiter comment continuation" "$delimiter_comment_output" "helper delimiter comment comma"
assert_text_not_contains "helper masks brace delimiter comment continuation" "$delimiter_comment_output" "helper delimiter comment brace"
assert_text_contains "helper preserves safe line after delimiter comment" "$delimiter_comment_output" "after delimiter comment"
embedded_pair_output=$(printf '%s\n' \
    'QUOTE_PAIR_SECRET="helper prefix "middle", foo=bar still secret"' \
    'QUOTE_COLON_SECRET: "helper prefix "middle", foo: bar still secret"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks embedded assignment-looking quote tail" "$embedded_pair_output" "foo=bar still secret"
assert_text_not_contains "helper masks embedded colon-looking quote tail" "$embedded_pair_output" "foo: bar still secret"
embedded_json_tail_output=$(printf '%s\n' \
    'QUOTE_JSON_TAIL_SECRET="helper prefix ", "foo": "helper leaked json tail"' \
    'QUOTE_JSON_TAIL_MULTILINE_SECRET="helper json tail first' \
    'helper json tail second ", "foo": "helper leaked multiline json tail' \
    'helper leaked multiline json final"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks embedded json-looking quote tail" "$embedded_json_tail_output" "helper leaked json tail"
assert_text_not_contains "helper masks embedded multiline json-looking quote tail" "$embedded_json_tail_output" "helper leaked multiline json tail"
assert_text_not_contains "helper masks embedded multiline json-looking final" "$embedded_json_tail_output" "helper leaked multiline json final"
multiline_embedded_pair_output=$(printf '%s\n' \
    'QUOTE_PAIR_IN_MULTILINE_SECRET="helper pair quote first' \
    'text "quoted", foo=bar' \
    'SAFE=still part of secret' \
    'final secret"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper keeps assignment-looking multiline tail secret" "$multiline_embedded_pair_output" "SAFE=still part of secret"
assert_text_not_contains "helper keeps final multiline tail secret" "$multiline_embedded_pair_output" "final secret"
embedded_unclosed_quote_output=$(printf '%s\n' \
    'QUOTE_EMBEDDED_UNCLOSED_SECRET="helper embedded unclosed first "middle' \
    'safe line after embedded suffix' \
    'Safe embedded quote line after suffix"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks embedded unclosed same-line suffix" "$embedded_unclosed_quote_output" "middle"
assert_text_contains "helper preserves line after embedded same-line suffix" "$embedded_unclosed_quote_output" "safe line after embedded suffix"
assert_text_contains "helper preserves quote line after embedded same-line suffix" "$embedded_unclosed_quote_output" 'Safe embedded quote line after suffix"'
quoted_key_assignment_output=$(printf '%s\n' \
    'QUOTE_QUOTED_KEY_IN_MULTILINE_SECRET="helper quoted key first' \
    'text "quoted", "foo": "bar"' \
    'API_KEY=still part of secret' \
    'final quoted key secret"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper keeps quoted-key assignment line secret" "$quoted_key_assignment_output" "API_KEY=still part of secret"
assert_text_not_contains "helper keeps quoted-key final line secret" "$quoted_key_assignment_output" "final quoted key secret"
quoted_comment_output=$(printf '%s\n' \
    'QUOTE_COMMENT_IN_MULTILINE_SECRET="helper comment quote first' \
    'text "quoted" # still part of secret' \
    'helper comment quote final secret"' \
    'QUOTE_COMMENT_SECRET="helper prefix "middle" # helper same-line comment secret"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper keeps quoted comment multiline tail secret" "$quoted_comment_output" "still part of secret"
assert_text_not_contains "helper keeps quoted comment final secret" "$quoted_comment_output" "helper comment quote final secret"
assert_text_not_contains "helper keeps embedded quoted comment same-line secret" "$quoted_comment_output" "helper same-line comment secret"
weak_false_close_output=$(printf '%s\n' \
    'UNCLOSED_SECRET="helper weak false secret' \
    'Normal "quoted", foo=bar' \
    'Next line' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks weak false-close secret" "$weak_false_close_output" "helper weak false secret"
assert_text_contains "helper preserves weak false-close normal line" "$weak_false_close_output" 'Normal "quoted", foo=bar'
assert_text_contains "helper preserves weak false-close following line" "$weak_false_close_output" "Next line"
nested_tail_secret_output=$(printf '%s\n' \
    'OBJ={"api_key": "helper nested first' \
    'helper nested second", "password": "helper nested password first' \
    'helper nested password second", "safe": "ok"}' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks nested tail multiline password" "$nested_tail_secret_output" "helper nested password second"
assert_text_not_contains "helper masks nested tail multiline first password line" "$nested_tail_secret_output" "helper nested password first"
assert_text_contains "helper preserves nested multiline safe tail" "$nested_tail_secret_output" '"safe": "ok"'
nested_container_value_output=$(printf '%s\n' \
    'OBJ={"password": ["helper array secret first", "helper array secret second"], "safe": "helper array safe"}' \
    'OBJ={"api_key": {"primary": "helper object secret first", "secondary": "helper object secret second"}, "safe": "helper object safe"}' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks json array sensitive value first" "$nested_container_value_output" "helper array secret first"
assert_text_not_contains "helper masks json array sensitive value second" "$nested_container_value_output" "helper array secret second"
assert_text_contains "helper preserves json array safe tail" "$nested_container_value_output" "helper array safe"
assert_text_not_contains "helper masks json object sensitive value first" "$nested_container_value_output" "helper object secret first"
assert_text_not_contains "helper masks json object sensitive value second" "$nested_container_value_output" "helper object secret second"
assert_text_contains "helper preserves json object safe tail" "$nested_container_value_output" "helper object safe"
multiline_container_value_output=$(printf '%s\n' \
    'OBJ={"password": {' \
    '  "inner": "helper multiline object secret"' \
    '}, "safe": "helper multiline object safe"}' \
    'OBJ={"api_key": [' \
    '  "helper multiline array secret"' \
    '], "safe": "helper multiline array safe"}' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks multiline json object secret" "$multiline_container_value_output" "helper multiline object secret"
assert_text_contains "helper preserves multiline json object safe tail" "$multiline_container_value_output" "helper multiline object safe"
assert_text_not_contains "helper masks multiline json array secret" "$multiline_container_value_output" "helper multiline array secret"
assert_text_contains "helper preserves multiline json array safe tail" "$multiline_container_value_output" "helper multiline array safe"
nested_unterminated_tail_output=$(printf '%s\n' \
    'OBJ={"api_key": "helper nested unterminated first' \
    'helper nested unterminated second", "password": "helper nested tail unterminated' \
    'After nested unterminated remains' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks nested unterminated tail secret" "$nested_unterminated_tail_output" "helper nested tail unterminated"
assert_text_contains "helper preserves text after nested unterminated tail" "$nested_unterminated_tail_output" "After nested unterminated remains"
top_level_json_tail_output=$(printf '%s\n' \
    'API_KEY: "helper top-level json first' \
    'helper top-level json second", "safe": "helper top-level safe tail"' \
    'API_KEY="helper top-level assignment first' \
    'helper top-level assignment second", "safe": "helper top-level assignment safe tail"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks top-level colon json-looking continuation" "$top_level_json_tail_output" "helper top-level json second"
assert_text_not_contains "helper masks top-level colon json-looking tail" "$top_level_json_tail_output" "helper top-level safe tail"
assert_text_not_contains "helper masks top-level assignment json-looking continuation" "$top_level_json_tail_output" "helper top-level assignment second"
assert_text_not_contains "helper masks top-level assignment json-looking tail" "$top_level_json_tail_output" "helper top-level assignment safe tail"
comparison_output=$(printf '%s\n' \
    'if password == "expected":' \
    'if token === expected:' \
    'const ok = api_key === expected;' \
    'const fn = (api_key) => api_key;' | python3 "$REDACTION_HELPER")
assert_text_contains "helper preserves password equality comparison" "$comparison_output" 'if password == "expected":'
assert_text_contains "helper preserves token strict equality comparison" "$comparison_output" 'if token === expected:'
assert_text_contains "helper preserves api_key strict equality comparison" "$comparison_output" 'const ok = api_key === expected;'
assert_text_contains "helper preserves arrow function with sensitive parameter" "$comparison_output" 'const fn = (api_key) => api_key;'
type_annotation_output=$(printf '%s\n' \
    'def connect(api_key: str) -> None:' \
    'interface Config { api_key: string; safe: string }' \
    'type T = { password: string }' | python3 "$REDACTION_HELPER")
assert_text_contains "helper preserves python api_key type annotation" "$type_annotation_output" 'def connect(api_key: str) -> None:'
assert_text_contains "helper preserves interface api_key type annotation" "$type_annotation_output" 'interface Config { api_key: string; safe: string }'
assert_text_contains "helper preserves password type annotation" "$type_annotation_output" 'type T = { password: string }'
prose_secret_output=$(printf '%s\n' \
    'Do not log api_key="helper prose secret"' \
    'Do not log api_key="helper prose tail secret" and keep this' \
    "Don't log api_key=\"helper apostrophe secret\"" \
    'text \" api_key="helper escaped outside quote secret"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks prose inline secret" "$prose_secret_output" "helper prose secret"
assert_text_not_contains "helper masks prose inline tail secret" "$prose_secret_output" "helper prose tail secret"
assert_text_contains "helper preserves prose text after quoted secret" "$prose_secret_output" "and keep this"
assert_text_not_contains "helper masks apostrophe prose inline secret" "$prose_secret_output" "helper apostrophe secret"
assert_text_not_contains "helper masks secret after escaped outside quote" "$prose_secret_output" "helper escaped outside quote secret"
inline_unquoted_output=$(printf '%s\n' \
    'NODE_ENV=production API_KEY=helper-inline-env-secret npm start' \
    'env PASSWORD=hunter2 npm start' \
    'cmd ENV=ok API_KEY=helper-inline-end-secret' \
    "API_KEY=\"helper-inline-prefix\" PASSWORD=\$(echo helper-inline-substitution-secret) npm start" \
    "API_KEY=\"helper-inline-backtick-prefix\" PASSWORD=\`echo helper-inline-backtick-secret\` npm start" \
    "API_KEY=\"helper-inline-multiline-prefix\" PASSWORD=\$(printf helper-inline-multiline-first" \
    "helper-inline-multiline-second) npm start" \
    "API_KEY=\"helper-inline-multiline-backtick-prefix\" PASSWORD=\`printf helper-inline-backtick-first" \
    "helper-inline-backtick-second\` npm start" \
    'env API_KEY=prefix" helper-inline-quoted-suffix" node script' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks inline unquoted env api key" "$inline_unquoted_output" "helper-inline-env-secret"
assert_text_not_contains "helper masks inline unquoted env password" "$inline_unquoted_output" "hunter2"
assert_text_not_contains "helper masks inline unquoted env api key at end" "$inline_unquoted_output" "helper-inline-end-secret"
assert_text_not_contains "helper masks inline env command substitution" "$inline_unquoted_output" "helper-inline-substitution-secret"
assert_text_not_contains "helper masks inline env backtick substitution" "$inline_unquoted_output" "helper-inline-backtick-secret"
assert_text_not_contains "helper masks inline multiline command substitution" "$inline_unquoted_output" "helper-inline-multiline-second"
assert_text_not_contains "helper masks inline multiline backtick substitution" "$inline_unquoted_output" "helper-inline-backtick-second"
assert_text_not_contains "helper masks inline quoted shell suffix" "$inline_unquoted_output" "helper-inline-quoted-suffix"
assert_text_contains "helper preserves inline unquoted env prefix" "$inline_unquoted_output" "NODE_ENV=production API_KEY=[REDACTED] npm start"
assert_text_contains "helper preserves inline unquoted env command" "$inline_unquoted_output" "env PASSWORD=[REDACTED] npm start"
assert_text_contains "helper preserves inline env substitution tail" "$inline_unquoted_output" "PASSWORD=[REDACTED] npm start"
assert_text_contains "helper preserves inline multiline substitution tail" "$inline_unquoted_output" 'API_KEY="[REDACTED]" PASSWORD=[REDACTED] npm start'
assert_text_contains "helper preserves inline multiline backtick tail" "$inline_unquoted_output" 'API_KEY="[REDACTED]" PASSWORD=[REDACTED] npm start'
assert_text_contains "helper preserves inline quoted shell tail" "$inline_unquoted_output" "env API_KEY=[REDACTED] node script"
query_secret_output=$(printf '%s\n' \
    'curl "https://example.test/path?api_key=helper-query-api-key&safe=ok"' \
    'curl https://example.test/path?token=helper-query-token#frag' \
    'open https://example.test/path?client-secret=helper-query-client-secret&safe=ok' \
    'curl "https://example.test/callback?secret_key=helper-query-secret-key&safe=ok"' \
    'curl "https://example.test/callback?secret-key=helper-query-secret-dash&safe=ok"' \
    "curl \"https://example.test/callback?token=helper-query-dollar\$secret-suffix&safe=ok\"" \
    "curl \"https://example.test/callback?token=\$helper-query-leading-dollar&safe=ok\"" \
    'curl "https://example.test/callback?token=helper-query-[bracket-secret]&safe=ok"' \
    'curl "https://example.test/callback?token=helper-query-{brace-secret}&safe=ok"' \
    'see (https://example.test/path?token=helper-query-token-paren)' \
    'see https://example.test/path?api_key=helper-query-key-period.' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks quoted url query api key" "$query_secret_output" "helper-query-api-key"
assert_text_not_contains "helper masks unquoted url query token" "$query_secret_output" "helper-query-token"
assert_text_not_contains "helper masks url query client secret" "$query_secret_output" "helper-query-client-secret"
assert_text_not_contains "helper masks url query secret key" "$query_secret_output" "helper-query-secret-key"
assert_text_not_contains "helper masks url query dashed secret key" "$query_secret_output" "helper-query-secret-dash"
assert_text_not_contains "helper masks url query dollar suffix" "$query_secret_output" "secret-suffix"
assert_text_not_contains "helper masks url query leading dollar" "$query_secret_output" "helper-query-leading-dollar"
assert_text_not_contains "helper masks url query bracket value" "$query_secret_output" "bracket-secret"
assert_text_not_contains "helper masks url query brace value" "$query_secret_output" "brace-secret"
assert_text_not_contains "helper masks url query before paren" "$query_secret_output" "helper-query-token-paren"
assert_text_not_contains "helper masks url query before period" "$query_secret_output" "helper-query-key-period"
assert_text_contains "helper preserves url query safe parameter" "$query_secret_output" "safe=ok"
assert_text_contains "helper preserves url query closing paren" "$query_secret_output" "token=[REDACTED])"
assert_text_contains "helper preserves url query trailing period" "$query_secret_output" "api_key=[REDACTED]."
query_idempotent_once=$(printf '%s\n' \
    'see https://example.test/path?api_key=[REDACTED]' \
    'see https://example.test/path?token=[REDACTED]&safe=ok' | python3 "$REDACTION_HELPER")
query_idempotent_twice=$(printf '%s\n' "$query_idempotent_once" | python3 "$REDACTION_HELPER")
assert_text_contains "helper preserves redacted url query once" "$query_idempotent_once" "api_key=[REDACTED]"
assert_text_contains "helper preserves redacted url query twice" "$query_idempotent_twice" "token=[REDACTED]&safe=ok"
assert_text_not_contains "helper avoids redacted url query bracket drift" "$query_idempotent_twice" "[REDACTED]]"
function_arg_output=$(printf '%s\n' \
    'client = OpenAI(api_key="helper function secret")' \
    'client = OpenAI(api_key="helper function tail secret", timeout=30)' \
    'client = OpenAI(api_key="helper function quoted tail secret", base_url="https://api.example", model="gpt-test")' \
    'client = OpenAI(api_key="helper function semicolon secret"); print("ok")' \
    'client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"), timeout=30)' \
    'client = OpenAI(api_key=api_key)' \
    'function f(token = "helper default arg secret") {}' \
    'headers={"api_key": "helper header semicolon secret"}; echo ok' \
    'requests.post(url, headers={"api_key": "helper header secret", "Content-Type": "application/json"})' \
    'const obj = { token: "helper js object secret", safe: "helper js object safe" }' \
    'API_KEY="helper multiline named first' \
    'helper multiline named second", BASE_URL="helper named tail safe"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks function api_key argument" "$function_arg_output" "helper function secret"
assert_text_not_contains "helper masks function tail api_key argument" "$function_arg_output" "helper function tail secret"
assert_text_not_contains "helper masks function quoted tail api_key argument" "$function_arg_output" "helper function quoted tail secret"
assert_text_not_contains "helper masks function semicolon api_key argument" "$function_arg_output" "helper function semicolon secret"
assert_text_not_contains "helper masks function default token argument" "$function_arg_output" "helper default arg secret"
assert_text_not_contains "helper masks header semicolon api_key" "$function_arg_output" "helper header semicolon secret"
assert_text_not_contains "helper masks js object token value" "$function_arg_output" "helper js object secret"
assert_text_not_contains "helper masks multiline named tail secret" "$function_arg_output" "helper multiline named second"
assert_text_contains "helper preserves function tail after quoted secret" "$function_arg_output" "timeout=30"
assert_text_contains "helper preserves quoted function tail after quoted secret" "$function_arg_output" 'base_url="https://api.example", model="gpt-test"'
assert_text_contains "helper preserves semicolon tail after function secret" "$function_arg_output" 'print("ok")'
assert_text_contains "helper preserves getenv api_key expression" "$function_arg_output" 'api_key=os.getenv("OPENAI_API_KEY"), timeout=30'
assert_text_contains "helper preserves variable api_key expression" "$function_arg_output" "api_key=api_key"
assert_text_contains "helper preserves default argument tail" "$function_arg_output" ') {}'
assert_text_contains "helper preserves semicolon tail after header secret" "$function_arg_output" "; echo ok"
assert_text_not_contains "helper masks nested header api_key" "$function_arg_output" "helper header secret"
assert_text_contains "helper preserves quoted header safe tail" "$function_arg_output" '"Content-Type": "application/json"'
assert_text_contains "helper preserves js object safe tail" "$function_arg_output" 'safe: "helper js object safe"'
assert_text_contains "helper preserves multiline named tail" "$function_arg_output" 'BASE_URL="helper named tail safe"'
same_line_tail_output=$(printf '%s\n' \
    'API_KEY="helper same-line secret" node script.js' \
    'API_KEY="helper same-line command secret"; echo ok' \
    'API_KEY="helper same-line comment secret" # keep comment' \
    'safe line after same-line secret' \
    'Safe text ends with quote"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks same-line assignment secret" "$same_line_tail_output" "helper same-line secret"
assert_text_not_contains "helper masks same-line command secret" "$same_line_tail_output" "helper same-line command secret"
assert_text_not_contains "helper masks same-line comment secret" "$same_line_tail_output" "helper same-line comment secret"
assert_text_contains "helper preserves same-line assignment tail" "$same_line_tail_output" "node script.js"
assert_text_contains "helper preserves same-line command delimiter tail" "$same_line_tail_output" "; echo ok"
assert_text_contains "helper preserves same-line separated comment" "$same_line_tail_output" "# keep comment"
assert_text_contains "helper preserves safe line after same-line assignment" "$same_line_tail_output" "safe line after same-line secret"
assert_text_contains "helper preserves dangling quote after same-line assignment" "$same_line_tail_output" 'Safe text ends with quote"'
shell_concat_output=$(printf '%s\n' \
    'API_KEY="helper concat prefix"helper-concat-suffix' \
    'API_KEY="helper underscore prefix"_helper_underscore_suffix' \
    "API_KEY=\"helper var prefix\"\$HELPER_SECRET_SUFFIX" \
    "API_KEY=\"helper quote prefix\"'helper quote suffix'" \
    'API_KEY="helper hash prefix"#helper-hash-suffix' \
    'API_KEY="helper escaped prefix"\ helper-escaped-suffix' \
    'API_KEY="helper adjacent data loss prefix"helper-adjacent-data-loss-suffix' \
    'safe line after adjacent suffix' \
    'Safe adjacent quote line after suffix"' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks adjacent literal suffix" "$shell_concat_output" "helper-concat-suffix"
assert_text_not_contains "helper masks adjacent underscore suffix" "$shell_concat_output" "helper_underscore_suffix"
assert_text_not_contains "helper masks adjacent variable suffix" "$shell_concat_output" "HELPER_SECRET_SUFFIX"
assert_text_not_contains "helper masks adjacent quoted suffix" "$shell_concat_output" "helper quote suffix"
assert_text_not_contains "helper masks adjacent hash suffix" "$shell_concat_output" "helper-hash-suffix"
assert_text_not_contains "helper masks escaped-space suffix" "$shell_concat_output" "helper-escaped-suffix"
assert_text_not_contains "helper masks adjacent data loss suffix" "$shell_concat_output" "helper-adjacent-data-loss-suffix"
assert_text_contains "helper preserves line after adjacent suffix" "$shell_concat_output" "safe line after adjacent suffix"
assert_text_contains "helper preserves quote line after adjacent suffix" "$shell_concat_output" 'Safe adjacent quote line after suffix"'
embedded_quote_flag_output=$(printf '%s\n' \
    'API_KEY="helper embedded flag first "helper embedded flag inner" helper embedded flag suffix" --token helper-embedded-flag-token' \
    'API_KEY="helper embedded one quote first "helper embedded one quote suffix" --password helper-embedded-one-quote-password' \
    'API_KEY="helper embedded spaced first " mid " helper embedded spaced suffix" --token helper-embedded-spaced-token' \
    'API_KEY="helper embedded multiline first' \
    'helper embedded multiline " mid " helper embedded multiline suffix" --token helper-embedded-multiline-token' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks embedded quote before flag inner" "$embedded_quote_flag_output" "helper embedded flag inner"
assert_text_not_contains "helper masks embedded quote before flag suffix" "$embedded_quote_flag_output" "helper embedded flag suffix"
assert_text_not_contains "helper masks embedded quote flag token" "$embedded_quote_flag_output" "helper-embedded-flag-token"
assert_text_not_contains "helper masks embedded one-quote suffix" "$embedded_quote_flag_output" "helper embedded one quote suffix"
assert_text_not_contains "helper masks embedded one-quote flag password" "$embedded_quote_flag_output" "helper-embedded-one-quote-password"
assert_text_not_contains "helper masks embedded spaced suffix" "$embedded_quote_flag_output" "helper embedded spaced suffix"
assert_text_not_contains "helper masks embedded spaced flag token" "$embedded_quote_flag_output" "helper-embedded-spaced-token"
assert_text_not_contains "helper masks embedded multiline suffix" "$embedded_quote_flag_output" "helper embedded multiline suffix"
assert_text_not_contains "helper masks embedded multiline flag token" "$embedded_quote_flag_output" "helper-embedded-multiline-token"
tail_sensitive_output=$(printf '%s\n' \
    'API_KEY="helper tail secret" deploy --password hunter2 --token abc123' \
    "API_KEY='helper single tail secret' deploy --client-secret hunter2 --api-key abc123" \
    'PASSWORD="helper comment tail secret" # password=hunter2 token=abc123' \
    "client_secret: 'helper colon tail secret' # token abc123" | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks flag password tail" "$tail_sensitive_output" "hunter2"
assert_text_not_contains "helper masks flag token tail" "$tail_sensitive_output" "abc123"
assert_text_contains "helper preserves flag password name" "$tail_sensitive_output" "--password"
assert_text_contains "helper preserves flag token name" "$tail_sensitive_output" "--token"
assert_text_contains "helper preserves client secret flag name" "$tail_sensitive_output" "--client-secret"
assert_text_contains "helper preserves api key flag name" "$tail_sensitive_output" "--api-key"
assert_text_not_contains "helper masks sensitive comment tail" "$tail_sensitive_output" "# password"
assert_text_not_contains "helper masks sensitive colon comment tail" "$tail_sensitive_output" "# token"
quoted_tail_flag_output=$(printf '%s\n' \
    "API_KEY=\"helper quoted tail primary\" bash -c 'cmd --token helper-quoted-tail-token'" \
    "API_KEY='helper double quoted tail primary' bash -c \"cmd --password helper-double-quoted-tail-password\"" \
    'API_KEY="helper literal quoted tail primary" "--api-key helper-literal-quoted-tail-api-key"' \
    "API_KEY=\"helper quoted tail keep primary\" 'safe --token helper-quoted-tail-keep-token' --url keep-quoted-tail-url" | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks quoted tail token flag" "$quoted_tail_flag_output" "helper-quoted-tail-token"
assert_text_not_contains "helper masks double quoted tail password flag" "$quoted_tail_flag_output" "helper-double-quoted-tail-password"
assert_text_not_contains "helper masks literal quoted tail api flag" "$quoted_tail_flag_output" "helper-literal-quoted-tail-api-key"
assert_text_not_contains "helper masks quoted tail keep token flag" "$quoted_tail_flag_output" "helper-quoted-tail-keep-token"
assert_text_contains "helper preserves quoted tail non-sensitive flag tail" "$quoted_tail_flag_output" "keep-quoted-tail-url"
standalone_flag_output=$(printf '%s\n' \
    'cmd --api-key="helper standalone api flag" --token helper-standalone-token' \
    "curl --password='helper standalone password flag' --client-secret helper-standalone-client-secret" \
    'cmd --password "helper escaped \"quote\" flag" rest' \
    'cmd --password helper-comma,password --token=helper-equals,token' \
    'cmd --token= helper-equals-space-secret --url keep-equals-space-url' \
    'cmd --password= "helper-equals-space-password" --url keep-equals-space-password-url' \
    'cmd --token= --url keep-empty-equals-url' \
    'cmd --token= --password helper-empty-equals-next-password --url keep-empty-equals-next-url' \
    'cmd --password helper-escaped\ space' \
    'cmd --password -helper-dash-flag-secret --token=-helper-equals-dash-flag-secret' \
    'cmd --token = helper-space-equals-secret --url keep-space-equals-url' \
    'cmd --token = --0123456789abcdef --url keep-spaced-equals-double-dash-url' \
    'cmd --token = --actual-secret-value --url keep-spaced-equals-sensitive-dash-url' \
    'cmd --token = Bearer helperSpaceEqualsBearerToken000000000000000000 --url keep-space-equals-bearer-url' \
    "cmd --password=\$(echo helper-dollar-flag-secret) --url keep-dollar-substitution-url" \
    "cmd --token \`echo helper-backtick-flag-secret\` --url keep-backtick-substitution-url" \
    "cmd --password <(echo helper-process-flag-secret) --url keep-process-substitution-url" \
    "cmd --password \$(printf helper-multiline-dollar-flag-first" \
    "helper-multiline-dollar-flag-second) --url keep-multiline-dollar-flag-url" \
    "cmd --token \`printf helper-multiline-backtick-flag-first" \
    "helper-multiline-backtick-flag-second\` --url keep-multiline-backtick-flag-url" \
    'cmd --password=--hunter2 --url keep-direct-equals-double-dash-url' \
    'cmd --token=--abc123 --url keep-direct-equals-token-double-dash-url' \
    'cmd --password --actual-secret-value --url keep-sensitive-double-dash-url' \
    'cmd --password --0123456789abcdef --url keep-long-double-dash-url' \
    'cmd --password "helper quoted flag prefix"helper-flag-suffix --token="helper equals quoted flag"helper-equals-flag-suffix' \
    "cmd --token='helper single quoted flag'helper-single-flag-suffix" \
    'cmd --token helper-control-secret&& echo keep-control-tail' \
    'cmd --password helper-pipe-secret| cat' \
    'cmd --token Bearer helperFlagBearerToken0000000000000000000000' \
    'cmd --token Bearer helper-short-bearer-token --url keep-bearer-url' \
    'cmd --token Bearer --helperDashedBearerToken000000000000 --url keep-dashed-bearer-url' \
    'cmd --token Bearer --password hunter2 --url keep-bearer-sensitive-flag-url' \
    'cmd --token Bearer --client-secret helper-bearer-client-secret --url keep-bearer-client-secret-url' \
    'cmd --token Bearer --verbose --url keep-bearer-flag-url' \
    'cmd --access-token helper-access-token --refresh-token helper-refresh-token --webhook-secret helper-webhook-secret' \
    'cmd --private-key helper-private-key --access-key helper-access-key --openai-api-key helper-openai-api-key --secret-key helper-secret-key' \
    'please run --token' \
    'normal text after flag without value' \
    'cmd --token --verbose --url http://example' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks standalone api key flag value" "$standalone_flag_output" "helper standalone api flag"
assert_text_not_contains "helper masks standalone token flag value" "$standalone_flag_output" "helper-standalone-token"
assert_text_not_contains "helper masks standalone password flag value" "$standalone_flag_output" "helper standalone password flag"
assert_text_not_contains "helper masks standalone client secret flag value" "$standalone_flag_output" "helper-standalone-client-secret"
assert_text_not_contains "helper masks escaped quote flag suffix" "$standalone_flag_output" 'quote" flag'
assert_text_not_contains "helper masks comma flag prefix" "$standalone_flag_output" "helper-comma"
assert_text_not_contains "helper masks comma flag suffix" "$standalone_flag_output" ",password"
assert_text_not_contains "helper masks equals comma flag prefix" "$standalone_flag_output" "helper-equals"
assert_text_not_contains "helper masks equals comma flag suffix" "$standalone_flag_output" ",token"
assert_text_not_contains "helper masks equals-space flag value" "$standalone_flag_output" "helper-equals-space-secret"
assert_text_contains "helper preserves equals-space flag tail" "$standalone_flag_output" "keep-equals-space-url"
assert_text_not_contains "helper masks equals-space quoted flag value" "$standalone_flag_output" "helper-equals-space-password"
assert_text_contains "helper preserves equals-space quoted flag tail" "$standalone_flag_output" "keep-equals-space-password-url"
assert_text_contains "helper preserves empty equals next flag" "$standalone_flag_output" "--token= --url keep-empty-equals-url"
assert_text_not_contains "helper masks empty equals following sensitive flag value" "$standalone_flag_output" "helper-empty-equals-next-password"
assert_text_contains "helper preserves empty equals following sensitive flag tail" "$standalone_flag_output" "keep-empty-equals-next-url"
assert_text_not_contains "helper masks escaped-space flag prefix" "$standalone_flag_output" "helper-escaped"
assert_text_not_contains "helper masks escaped-space flag suffix" "$standalone_flag_output" "\\ space"
assert_text_not_contains "helper masks dash-prefixed space flag value" "$standalone_flag_output" "helper-dash-flag-secret"
assert_text_not_contains "helper masks dash-prefixed equals flag value" "$standalone_flag_output" "helper-equals-dash-flag-secret"
assert_text_not_contains "helper masks spaced equals flag value" "$standalone_flag_output" "helper-space-equals-secret"
assert_text_contains "helper preserves spaced equals flag tail" "$standalone_flag_output" "keep-space-equals-url"
assert_text_not_contains "helper masks spaced equals double-dash long value" "$standalone_flag_output" "--0123456789abcdef"
assert_text_contains "helper preserves spaced equals double-dash long tail" "$standalone_flag_output" "keep-spaced-equals-double-dash-url"
assert_text_not_contains "helper masks spaced equals double-dash sensitive value" "$standalone_flag_output" "--actual-secret-value"
assert_text_contains "helper preserves spaced equals double-dash sensitive tail" "$standalone_flag_output" "keep-spaced-equals-sensitive-dash-url"
assert_text_not_contains "helper masks spaced equals bearer flag value" "$standalone_flag_output" "helperSpaceEqualsBearerToken000000000000000000"
assert_text_contains "helper preserves spaced equals bearer tail" "$standalone_flag_output" "keep-space-equals-bearer-url"
assert_text_not_contains "helper masks dollar flag substitution" "$standalone_flag_output" "helper-dollar-flag-secret"
assert_text_not_contains "helper masks backtick flag substitution" "$standalone_flag_output" "helper-backtick-flag-secret"
assert_text_not_contains "helper masks process flag substitution" "$standalone_flag_output" "helper-process-flag-secret"
assert_text_not_contains "helper masks multiline dollar flag substitution" "$standalone_flag_output" "helper-multiline-dollar-flag-second"
assert_text_not_contains "helper masks multiline backtick flag substitution" "$standalone_flag_output" "helper-multiline-backtick-flag-second"
assert_text_contains "helper preserves dollar flag substitution tail" "$standalone_flag_output" "keep-dollar-substitution-url"
assert_text_contains "helper preserves backtick flag substitution tail" "$standalone_flag_output" "keep-backtick-substitution-url"
assert_text_contains "helper preserves process flag substitution tail" "$standalone_flag_output" "keep-process-substitution-url"
assert_text_contains "helper preserves multiline dollar flag tail" "$standalone_flag_output" "keep-multiline-dollar-flag-url"
assert_text_contains "helper preserves multiline backtick flag tail" "$standalone_flag_output" "keep-multiline-backtick-flag-url"
assert_text_not_contains "helper masks direct equals double-dash password value" "$standalone_flag_output" "--hunter2"
assert_text_not_contains "helper masks direct equals double-dash token value" "$standalone_flag_output" "--abc123"
assert_text_contains "helper preserves direct equals double-dash password tail" "$standalone_flag_output" "keep-direct-equals-double-dash-url"
assert_text_contains "helper preserves direct equals double-dash token tail" "$standalone_flag_output" "keep-direct-equals-token-double-dash-url"
assert_text_contains "helper preserves sensitive double-dash tail" "$standalone_flag_output" "keep-sensitive-double-dash-url"
assert_text_contains "helper preserves long double-dash tail" "$standalone_flag_output" "keep-long-double-dash-url"
assert_text_not_contains "helper masks quoted flag adjacent suffix" "$standalone_flag_output" "helper-flag-suffix"
assert_text_not_contains "helper masks equals quoted flag adjacent suffix" "$standalone_flag_output" "helper-equals-flag-suffix"
assert_text_not_contains "helper masks single quoted flag adjacent suffix" "$standalone_flag_output" "helper-single-flag-suffix"
assert_text_not_contains "helper masks control-operator flag value" "$standalone_flag_output" "helper-control-secret"
assert_text_contains "helper preserves control-operator flag tail" "$standalone_flag_output" "&& echo keep-control-tail"
assert_text_not_contains "helper masks pipe-adjacent flag value" "$standalone_flag_output" "helper-pipe-secret"
assert_text_contains "helper preserves pipe-adjacent flag tail" "$standalone_flag_output" "| cat"
assert_text_not_contains "helper masks bearer token after flag" "$standalone_flag_output" "helperFlagBearerToken0000000000000000000000"
assert_text_not_contains "helper masks short bearer token after flag" "$standalone_flag_output" "helper-short-bearer-token"
assert_text_contains "helper preserves short bearer flag tail" "$standalone_flag_output" "keep-bearer-url"
assert_text_not_contains "helper masks dashed bearer token after flag" "$standalone_flag_output" "helperDashedBearerToken000000000000"
assert_text_contains "helper preserves dashed bearer flag tail" "$standalone_flag_output" "keep-dashed-bearer-url"
assert_text_not_contains "helper masks sensitive flag value after bearer" "$standalone_flag_output" "hunter2"
assert_text_contains "helper preserves sensitive flag tail after bearer" "$standalone_flag_output" "keep-bearer-sensitive-flag-url"
assert_text_not_contains "helper masks client secret after bearer" "$standalone_flag_output" "helper-bearer-client-secret"
assert_text_contains "helper preserves client secret tail after bearer" "$standalone_flag_output" "keep-bearer-client-secret-url"
assert_text_contains "helper preserves flag after bearer marker" "$standalone_flag_output" "--verbose --url keep-bearer-flag-url"
assert_text_not_contains "helper masks access token flag value" "$standalone_flag_output" "helper-access-token"
assert_text_not_contains "helper masks refresh token flag value" "$standalone_flag_output" "helper-refresh-token"
assert_text_not_contains "helper masks webhook secret flag value" "$standalone_flag_output" "helper-webhook-secret"
assert_text_not_contains "helper masks private key flag value" "$standalone_flag_output" "helper-private-key"
assert_text_not_contains "helper masks access key flag value" "$standalone_flag_output" "helper-access-key"
assert_text_not_contains "helper masks prefixed api key flag value" "$standalone_flag_output" "helper-openai-api-key"
assert_text_not_contains "helper masks secret key flag value" "$standalone_flag_output" "helper-secret-key"
assert_text_contains "helper preserves line after valueless flag" "$standalone_flag_output" "normal text after flag without value"
assert_text_contains "helper preserves next flag after valueless flag" "$standalone_flag_output" "--verbose --url"
unterminated_flag_output=$(printf '%s\n' \
    'cmd --password "helper unterminated flag secret rest' \
    'normal after unterminated flag' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks unterminated quoted flag suffix" "$unterminated_flag_output" "helper unterminated flag secret rest"
assert_text_contains "helper preserves line after unterminated quoted flag" "$unterminated_flag_output" "normal after unterminated flag"
multiline_flag_output=$(printf '%s\n' \
    'cmd --password "helper multiline flag first' \
    'helper multiline flag second" --url keep-url' \
    'normal after multiline flag' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks multiline quoted flag continuation" "$multiline_flag_output" "helper multiline flag second"
assert_text_contains "helper preserves multiline quoted flag tail" "$multiline_flag_output" "--url keep-url"
assert_text_contains "helper preserves line after multiline quoted flag" "$multiline_flag_output" "normal after multiline flag"
embedded_multiline_flag_output=$(printf '%s\n' \
    'cmd --password "helper embedded multiline flag first' \
    'helper embedded multiline flag " mid " helper embedded multiline flag suffix" --token helper-embedded-multiline-flag-token' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks embedded multiline flag middle" "$embedded_multiline_flag_output" " mid "
assert_text_not_contains "helper masks embedded multiline flag suffix" "$embedded_multiline_flag_output" "helper embedded multiline flag suffix"
assert_text_not_contains "helper masks embedded multiline flag tail token" "$embedded_multiline_flag_output" "helper-embedded-multiline-flag-token"
chained_multiline_flag_output=$(printf '%s\n' \
    'cmd --password "helper chained flag first' \
    'helper chained flag second" --token "helper chained token first' \
    'helper chained token second"' \
    'normal after chained multiline flag' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks chained multiline flag continuation" "$chained_multiline_flag_output" "helper chained flag second"
assert_text_not_contains "helper masks chained multiline flag tail first" "$chained_multiline_flag_output" "helper chained token first"
assert_text_not_contains "helper masks chained multiline flag tail second" "$chained_multiline_flag_output" "helper chained token second"
assert_text_contains "helper preserves line after chained multiline flag" "$chained_multiline_flag_output" "normal after chained multiline flag"
continued_flag_output=$(printf '%s\n' \
    "cmd --token \\" \
    'helper-continued-flag-token --url keep-continued-flag-url' \
    'normal after continued flag' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks line-continued flag value" "$continued_flag_output" "helper-continued-flag-token"
assert_text_contains "helper preserves line-continued flag tail" "$continued_flag_output" "keep-continued-flag-url"
assert_text_contains "helper preserves line after continued flag" "$continued_flag_output" "normal after continued flag"
continued_bearer_output=$(printf '%s\n' \
    "cmd --token \\" \
    'Bearer helperContinuedBearerToken000000000000000000 --url keep-continued-bearer-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks continued bearer flag value" "$continued_bearer_output" "helperContinuedBearerToken000000000000000000"
assert_text_contains "helper preserves continued bearer tail" "$continued_bearer_output" "keep-continued-bearer-url"
continued_spaced_equals_output=$(printf '%s\n' \
    "cmd --token \\" \
    '= helper-continued-spaced-equals --url keep-continued-spaced-equals-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks continued spaced equals flag value" "$continued_spaced_equals_output" "helper-continued-spaced-equals"
assert_text_contains "helper preserves continued spaced equals tail" "$continued_spaced_equals_output" "keep-continued-spaced-equals-url"
continued_dash_value_output=$(printf '%s\n' \
    "cmd --token \\" \
    '--actual-secret-value --url keep-continued-dash-value-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks continued dash-prefixed sensitive value" "$continued_dash_value_output" "--actual-secret-value"
assert_text_contains "helper preserves continued dash-prefixed value tail" "$continued_dash_value_output" "keep-continued-dash-value-url"
continued_sensitive_flag_output=$(printf '%s\n' \
    "cmd --token \\" \
    '--password hunter2 --url keep-continued-sensitive-flag-url' \
    "cmd --token \\" \
    '--password "helper continued quoted password" --url keep-continued-quoted-sensitive-flag-url' \
    "cmd --token \\" \
    '--password=helper-continued-equals-password --url keep-continued-equals-sensitive-flag-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks continued sensitive flag password" "$continued_sensitive_flag_output" "hunter2"
assert_text_not_contains "helper masks continued quoted sensitive flag password" "$continued_sensitive_flag_output" "helper continued quoted password"
assert_text_not_contains "helper masks continued equals sensitive flag password" "$continued_sensitive_flag_output" "helper-continued-equals-password"
assert_text_contains "helper preserves continued sensitive flag url" "$continued_sensitive_flag_output" "keep-continued-sensitive-flag-url"
assert_text_contains "helper preserves continued quoted sensitive flag url" "$continued_sensitive_flag_output" "keep-continued-quoted-sensitive-flag-url"
assert_text_contains "helper preserves continued equals sensitive flag url" "$continued_sensitive_flag_output" "keep-continued-equals-sensitive-flag-url"
continued_multi_flag_output=$(printf '%s\n' \
    "cmd --token \\" \
    "helper-continued-first\\" \
    'helper-continued-second --url keep-continued-multi-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks multi-continued flag first" "$continued_multi_flag_output" "helper-continued-first"
assert_text_not_contains "helper masks multi-continued flag second" "$continued_multi_flag_output" "helper-continued-second"
assert_text_contains "helper preserves multi-continued flag tail" "$continued_multi_flag_output" "keep-continued-multi-url"
continued_tail_flag_output=$(printf '%s\n' \
    "cmd --token \\" \
    "helper-continued-token --password \\" \
    'helper-continued-password --url keep-continued-tail-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks continued tail flag token" "$continued_tail_flag_output" "helper-continued-token"
assert_text_not_contains "helper masks continued tail flag password" "$continued_tail_flag_output" "helper-continued-password"
assert_text_contains "helper preserves continued tail flag url" "$continued_tail_flag_output" "keep-continued-tail-url"
continued_valueless_flag_output=$(printf '%s\n' \
    "cmd --token \\" \
    '--verbose --url keep-continued-valueless-url' | python3 "$REDACTION_HELPER")
assert_text_contains "helper preserves continued valueless flag tail" "$continued_valueless_flag_output" "--verbose --url keep-continued-valueless-url"
assert_text_not_contains "helper avoids redacting continued valueless flag" "$continued_valueless_flag_output" "[REDACTED]"
adjacent_multiline_flag_output=$(printf '%s\n' \
    'cmd --password "helper adjacent flag first' \
    "helper adjacent flag second\"'helper adjacent flag suffix first" \
    "helper adjacent flag suffix second' --url keep-adjacent-flag-url" | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks adjacent multiline flag suffix first" "$adjacent_multiline_flag_output" "helper adjacent flag suffix first"
assert_text_not_contains "helper masks adjacent multiline flag suffix second" "$adjacent_multiline_flag_output" "helper adjacent flag suffix second"
assert_text_contains "helper preserves tail after adjacent multiline flag suffix" "$adjacent_multiline_flag_output" "keep-adjacent-flag-url"
unterminated_adjacent_flag_output=$(printf '%s\n' \
    'cmd --password "helper unterminated adjacent flag first' \
    "helper unterminated adjacent flag second\"'helper unterminated adjacent flag suffix" \
    'normal after unterminated adjacent flag' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks unterminated adjacent flag suffix" "$unterminated_adjacent_flag_output" "helper unterminated adjacent flag suffix"
assert_text_contains "helper preserves line after unterminated adjacent flag" "$unterminated_adjacent_flag_output" "normal after unterminated adjacent flag"
inline_tail_multiline_flag_output=$(printf '%s\n' \
    'cmd --password "helper inline tail flag first' \
    'helper inline tail flag second" api_key="helper inline tail flag secret" --url keep-inline-tail-flag-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks inline secret after multiline flag" "$inline_tail_multiline_flag_output" "helper inline tail flag secret"
assert_text_contains "helper preserves tail after inline secret after multiline flag" "$inline_tail_multiline_flag_output" "keep-inline-tail-flag-url"
pending_flag_tail_order_output=$(printf '%s\n' \
    'API_KEY="helper tail order primary" password="helper tail order leaked" --token "helper tail order token first' \
    'helper tail order token second" --url keep-tail-order-url' \
    'OBJ={"api_key": "helper json tail order primary", "password": "helper json tail order leak"} --token "helper json tail order token first' \
    'helper json tail order token second" --url keep-json-tail-order-url' \
    'cmd --password "helper flag tail order first' \
    'helper flag tail order second" api_key="helper flag tail order leak" --token "helper flag tail order token first' \
    'helper flag tail order token second" --url keep-flag-tail-order-url' \
    'cmd --password "helper flag before inline first' \
    'helper flag before inline second" --token helper-flag-before-inline-token api_key="helper flag before inline first' \
    'helper flag before inline second" --url keep-flag-before-inline-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks inline secret before pending flag" "$pending_flag_tail_order_output" "helper tail order leaked"
assert_text_not_contains "helper masks json inline secret before pending flag" "$pending_flag_tail_order_output" "helper json tail order leak"
assert_text_not_contains "helper masks flag tail inline secret before pending flag" "$pending_flag_tail_order_output" "helper flag tail order leak"
assert_text_not_contains "helper masks pending flag token after inline tail" "$pending_flag_tail_order_output" "helper tail order token second"
assert_text_not_contains "helper masks pending flag token after json tail" "$pending_flag_tail_order_output" "helper json tail order token second"
assert_text_not_contains "helper masks pending flag token after flag tail" "$pending_flag_tail_order_output" "helper flag tail order token second"
assert_text_not_contains "helper masks flag before pending inline tail" "$pending_flag_tail_order_output" "helper-flag-before-inline-token"
assert_text_not_contains "helper masks pending inline after flag tail" "$pending_flag_tail_order_output" "helper flag before inline second"
assert_text_contains "helper preserves tail after pending flag inline tail" "$pending_flag_tail_order_output" "keep-tail-order-url"
assert_text_contains "helper preserves tail after pending flag json tail" "$pending_flag_tail_order_output" "keep-json-tail-order-url"
assert_text_contains "helper preserves tail after pending flag flag tail" "$pending_flag_tail_order_output" "keep-flag-tail-order-url"
assert_text_contains "helper preserves tail after flag before pending inline" "$pending_flag_tail_order_output" "keep-flag-before-inline-url"
assignment_tail_multiline_output=$(printf '%s\n' \
    'CHAINED_SECRET="helper chained tail first", PASSWORD="helper chained tail password first' \
    'helper chained tail password second"' \
    'API_KEY="helper closing tail first' \
    'helper closing tail second" --password helper-closing-tail-password --url keep-closing-tail-url' \
    "API_KEY=\"helper continued tail\" deploy --password \\" \
    'helper-continued-tail-password --url keep-continued-assignment-tail-url' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks chained multiline sensitive tail first" "$assignment_tail_multiline_output" "helper chained tail password first"
assert_text_not_contains "helper masks chained multiline sensitive tail second" "$assignment_tail_multiline_output" "helper chained tail password second"
assert_text_not_contains "helper masks closing flag tail value" "$assignment_tail_multiline_output" "helper-closing-tail-password"
assert_text_contains "helper preserves closing flag tail url" "$assignment_tail_multiline_output" "keep-closing-tail-url"
assert_text_not_contains "helper masks assignment continued flag tail value" "$assignment_tail_multiline_output" "helper-continued-tail-password"
assert_text_contains "helper preserves assignment continued flag tail url" "$assignment_tail_multiline_output" "keep-continued-assignment-tail-url"
escaped_outside_flag_output=$(printf '%s\n' \
    'echo \" then cmd --password helper-escaped-outside-flag-secret' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks flag after escaped outside quote" "$escaped_outside_flag_output" "helper-escaped-outside-flag-secret"
quoted_flag_output=$(printf '%s\n' \
    'log = "cmd --token helper quoted flag" api_key="helper quoted flag inline secret"' \
    'API_KEY="helper assignment contains --token text"' \
    'normal "quoted" after assignment flag text' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks inline secret after quoted flag" "$quoted_flag_output" "helper quoted flag inline secret"
assert_text_contains "helper preserves quoted flag text" "$quoted_flag_output" 'log = "cmd --token helper quoted flag"'
assert_text_contains "helper preserves quoted line after assignment flag text" "$quoted_flag_output" 'normal "quoted" after assignment flag text'
code_string_output=$(printf '%s\n' \
    'console.log("api_key: " + key)' \
    'console.log("set api_key: " + key)' \
    'print("token: " + token)' \
    'console.log("hello")' \
    'after' | python3 "$REDACTION_HELPER")
assert_text_contains "helper leaves code string with sensitive label" "$code_string_output" 'console.log("api_key: " + key)'
assert_text_contains "helper leaves spaced code string with sensitive label" "$code_string_output" 'console.log("set api_key: " + key)'
assert_text_contains "helper leaves token label in code string" "$code_string_output" 'print("token: " + token)'
assert_text_contains "helper keeps code line after sensitive label string" "$code_string_output" 'console.log("hello")'
closing_tail_output=$(printf '%s\n' \
    'PAREN_SECRET="helper before") helper after paren secret"' \
    'BRACE_SECRET="helper before"} helper after brace secret"' \
    'BRACKET_SECRET="helper before"] helper after bracket secret"' \
    'ORDINARY_TAIL_SECRET="helper ordinary tail first' \
    'helper ordinary tail second" and then safe' \
    'after ordinary tail secret' | python3 "$REDACTION_HELPER")
assert_text_not_contains "helper masks paren same-line secret tail" "$closing_tail_output" "helper after paren secret"
assert_text_not_contains "helper masks brace same-line secret tail" "$closing_tail_output" "helper after brace secret"
assert_text_not_contains "helper masks bracket same-line secret tail" "$closing_tail_output" "helper after bracket secret"
assert_text_not_contains "helper masks multiline ordinary tail continuation" "$closing_tail_output" "helper ordinary tail second"
assert_text_contains "helper preserves line after ordinary tail secret" "$closing_tail_output" "after ordinary tail secret"
assert_text_not_contains "helper masks unterminated secret line" "$helper_output" "helper unterminated secret"
assert_text_contains "helper preserves text after unterminated secret" "$helper_output" "Normal line after unterminated secret remains."
assert_text_not_contains "helper masks unterminated quote secret line" "$helper_output" "helper quote normal"
assert_text_contains "helper preserves quoted normal text after unterminated secret" "$helper_output" "Normal \"quoted\" text after unterminated secret remains."
idempotent_output=$(printf '%s\n' \
    'API_KEY="[REDACTED]"' \
    'Safe text ends with quote"' \
    'Normal "quoted"' \
    'This line should stay' \
    'ends with quote"' \
    'Next line' | python3 "$REDACTION_HELPER")
assert_text_contains "helper preserves immediate dangling quote line after redacted value" "$idempotent_output" "Safe text ends with quote\""
assert_text_contains "helper preserves quoted line after redacted value" "$idempotent_output" "Normal \"quoted\""
assert_text_contains "helper preserves normal line after redacted value" "$idempotent_output" "This line should stay"
assert_text_contains "helper preserves dangling quote line after redacted value" "$idempotent_output" "ends with quote\""
assert_text_not_contains "helper masks fenced env secret" "$helper_output" "fake-helper-npm-token"
assert_text_not_contains "helper masks private key body" "$helper_output" "abc123"
assert_text_contains "helper keeps non-secret text" "$helper_output" "Normal line stays visible."
assert_file_contains "helper writes redaction audit" "$HELPER_AUDIT_LOG" "redacted"
assert_file_not_contains "helper audit omits secret value" "$HELPER_AUDIT_LOG" "fake-helper-api-key"

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
text = text.replace('## Transcript\n\n', '## Notes\n\n## Transcript\n\nnot the transcript section\n\n## Transcript\n\n', 1)
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

LEGACY_REDACTOR="$TEST_DIR/legacy-redact.py"
cat > "$LEGACY_REDACTOR" <<'PY'
def redact_text(text):
    return text
PY

LEGACY_REDACTION_MD="$TEST_DIR/writer-legacy-redaction.md"
cat <<'EOF' | REDACTION_HELPER="$LEGACY_REDACTOR" python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "raw key AIzaHelperGoogleToken000000000000000000000" \
    --source "Codex" \
    --session-id "writer-legacy-redaction" \
    --record-kind "interactive" \
    --tag "codex" > "$LEGACY_REDACTION_MD"
[
  {"role": "user", "text": "raw key AIzaHelperGoogleToken000000000000000000000"}
]
EOF

cat <<'EOF' | REDACTION_HELPER="$REDACTION_HELPER" python3 "$AI_LOG_WRITER" append --existing-file "$LEGACY_REDACTION_MD" > "$TEST_DIR/writer-legacy-redaction-updated.md"
[
  {"role": "user", "text": "raw key AIzaHelperGoogleToken000000000000000000000"},
  {"role": "assistant", "text": "later"}
]
EOF
mv "$TEST_DIR/writer-legacy-redaction-updated.md" "$LEGACY_REDACTION_MD"

assert_file_not_contains "writer migrates old unredacted prefix" "$LEGACY_REDACTION_MD" "AIzaHelperGoogleToken000000000000000000000"
assert_file_contains "writer appends after redaction migration" "$LEGACY_REDACTION_MD" "### Assistant 1"
assert_file_contains "writer updates migrated msg_count" "$LEGACY_REDACTION_MD" "msg_count: 2"

LEGACY_TAIL_REDACTOR="$TEST_DIR/legacy-tail-redact.py"
cat > "$LEGACY_TAIL_REDACTOR" <<'PY'
def redact_text(text):
    return text.replace(
        'API_KEY="legacy tail secret" # keep comment',
        'API_KEY="[REDACTED]"',
    )
PY

LEGACY_TAIL_REDACTION_MD="$TEST_DIR/writer-legacy-tail-redaction.md"
cat <<'EOF' | REDACTION_HELPER="$LEGACY_TAIL_REDACTOR" python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Legacy Tail Redaction" \
    --source "Codex" \
    --session-id "writer-legacy-tail-redaction" \
    --record-kind "interactive" \
    --tag "codex" > "$LEGACY_TAIL_REDACTION_MD"
[
  {"role": "user", "text": "API_KEY=\"legacy tail secret\" # keep comment"}
]
EOF

cat <<'EOF' | REDACTION_HELPER="$REDACTION_HELPER" python3 "$AI_LOG_WRITER" append --existing-file "$LEGACY_TAIL_REDACTION_MD" > "$TEST_DIR/writer-legacy-tail-redaction-updated.md"
[
  {"role": "user", "text": "API_KEY=\"legacy tail secret\" # keep comment"},
  {"role": "assistant", "text": "API_KEY=\"current tail secret\" # current comment"}
]
EOF
mv "$TEST_DIR/writer-legacy-tail-redaction-updated.md" "$LEGACY_TAIL_REDACTION_MD"

assert_file_not_contains "writer legacy tail append omits secret" "$LEGACY_TAIL_REDACTION_MD" "legacy tail secret"
assert_file_not_contains "writer legacy tail append omits current secret" "$LEGACY_TAIL_REDACTION_MD" "current tail secret"
assert_file_contains "writer appends after legacy tail redaction" "$LEGACY_TAIL_REDACTION_MD" "### Assistant 1"
assert_file_contains "writer updates legacy tail msg_count" "$LEGACY_TAIL_REDACTION_MD" "msg_count: 2"
assert_file_contains "writer preserves current redaction tail after legacy append" "$LEGACY_TAIL_REDACTION_MD" "# current comment"

cat <<'EOF' | REDACTION_HELPER="$REDACTION_HELPER" python3 "$AI_LOG_WRITER" append --existing-file "$LEGACY_TAIL_REDACTION_MD" > "$TEST_DIR/writer-legacy-tail-redaction-second-updated.md"
[
  {"role": "user", "text": "API_KEY=\"legacy tail secret\" # keep comment"},
  {"role": "assistant", "text": "API_KEY=\"current tail secret\" # current comment"},
  {"role": "user", "text": "later"}
]
EOF
mv "$TEST_DIR/writer-legacy-tail-redaction-second-updated.md" "$LEGACY_TAIL_REDACTION_MD"

assert_file_contains "writer appends again after mixed legacy and current redaction" "$LEGACY_TAIL_REDACTION_MD" "### User 2"
assert_file_contains "writer updates mixed legacy current msg_count" "$LEGACY_TAIL_REDACTION_MD" "msg_count: 3"
assert_file_contains "writer keeps current redaction tail after second append" "$LEGACY_TAIL_REDACTION_MD" "# current comment"

PARTIAL_REDACTOR="$TEST_DIR/partial-redact.py"
cat > "$PARTIAL_REDACTOR" <<'PY'
def redact_text(text):
    return text.replace(
        'PARTIAL_SECRET="legacy first\nlegacy second"',
        'PARTIAL_SECRET="[REDACTED]"\nlegacy second"',
    )
PY

PARTIAL_REDACTION_MD="$TEST_DIR/writer-partial-redaction.md"
cat <<'EOF' | REDACTION_HELPER="$PARTIAL_REDACTOR" python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Partial Redaction" \
    --source "Codex" \
    --session-id "writer-partial-redaction" \
    --record-kind "interactive" \
    --tag "codex" > "$PARTIAL_REDACTION_MD"
[
  {"role": "user", "text": "PARTIAL_SECRET=\"legacy first\nlegacy second\""}
]
EOF

cat <<'EOF' | REDACTION_HELPER="$REDACTION_HELPER" python3 "$AI_LOG_WRITER" append --existing-file "$PARTIAL_REDACTION_MD" > "$TEST_DIR/writer-partial-redaction-updated.md" 2> "$TEST_DIR/writer-partial-redaction.err" && PARTIAL_REDACTION_EXIT=0 || PARTIAL_REDACTION_EXIT=$?
[
  {"role": "user", "text": "PARTIAL_SECRET=\"legacy first\nlegacy second\""},
  {"role": "assistant", "text": "later"}
]
EOF

assert_text_contains "writer rejects old partial redaction drift" "$PARTIAL_REDACTION_EXIT" "2"
assert_file_contains "writer explains old partial redaction drift" "$TEST_DIR/writer-partial-redaction.err" "source prefix"

REDACTED_DRIFT_MD="$TEST_DIR/writer-redacted-drift.md"
cat <<'EOF' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Redacted Drift" \
    --source "Codex" \
    --session-id "writer-redacted-drift" \
    --record-kind "interactive" \
    --tag "codex" > "$REDACTED_DRIFT_MD"
[
  {"role": "user", "text": "API_KEY=fake-redacted-drift-key\nnormal old text"}
]
EOF

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$REDACTED_DRIFT_MD" > "$TEST_DIR/writer-redacted-drift-updated.md" 2> "$TEST_DIR/writer-redacted-drift.err" && REDACTED_DRIFT_EXIT=0 || REDACTED_DRIFT_EXIT=$?
[
  {"role": "user", "text": "API_KEY=fake-redacted-drift-key\nnormal changed text"},
  {"role": "assistant", "text": "later"}
]
EOF

assert_text_contains "writer rejects redacted prefix drift" "$REDACTED_DRIFT_EXIT" "2"
assert_file_contains "writer explains redacted prefix drift" "$TEST_DIR/writer-redacted-drift.err" "source prefix"

REDACTED_TRUNCATED_MD="$TEST_DIR/writer-redacted-truncated.md"
cat <<'EOF' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Redacted Truncated" \
    --source "Codex" \
    --session-id "writer-redacted-truncated" \
    --record-kind "interactive" \
    --tag "codex" > "$REDACTED_TRUNCATED_MD"
[
  {"role": "user", "text": "API_KEY=fake-redacted-truncated-key\nnormal old text"}
]
EOF

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$REDACTED_TRUNCATED_MD" > "$TEST_DIR/writer-redacted-truncated-updated.md" 2> "$TEST_DIR/writer-redacted-truncated.err" && REDACTED_TRUNCATED_EXIT=0 || REDACTED_TRUNCATED_EXIT=$?
[
  {"role": "user", "text": "API_KEY=fake-redacted-truncated-key"},
  {"role": "assistant", "text": "later"}
]
EOF

assert_text_contains "writer rejects truncated redacted prefix" "$REDACTED_TRUNCATED_EXIT" "2"
assert_file_contains "writer explains truncated redacted prefix" "$TEST_DIR/writer-redacted-truncated.err" "source prefix"

QUOTED_REDACTED_TRUNCATED_MD="$TEST_DIR/writer-quoted-redacted-truncated.md"
cat <<'EOF' | python3 "$AI_LOG_WRITER" create \
    --date "2026-06-02" \
    --title "Quoted Redacted Truncated" \
    --source "Codex" \
    --session-id "writer-quoted-redacted-truncated" \
    --record-kind "interactive" \
    --tag "codex" > "$QUOTED_REDACTED_TRUNCATED_MD"
[
  {"role": "user", "text": "API_KEY=\"fake-quoted-redacted-truncated-key\"\nnormal old text"}
]
EOF

cat <<'EOF' | python3 "$AI_LOG_WRITER" append --existing-file "$QUOTED_REDACTED_TRUNCATED_MD" > "$TEST_DIR/writer-quoted-redacted-truncated-updated.md" 2> "$TEST_DIR/writer-quoted-redacted-truncated.err" && QUOTED_REDACTED_TRUNCATED_EXIT=0 || QUOTED_REDACTED_TRUNCATED_EXIT=$?
[
  {"role": "user", "text": "API_KEY=\"fake-quoted-redacted-truncated-key\""},
  {"role": "assistant", "text": "later"}
]
EOF

assert_text_contains "writer rejects quoted truncated redacted prefix" "$QUOTED_REDACTED_TRUNCATED_EXIT" "2"
assert_file_contains "writer explains quoted truncated redacted prefix" "$TEST_DIR/writer-quoted-redacted-truncated.err" "source prefix"

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

CLAUDE_MD=$(raw_markdown_by_session_id "$SECOND_BRAIN_DIR" "redaction-claude-session")
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
    assert_file_contains "claude logs redaction audit" "$HOME/.claude/recall-sync.log" "redacted"
    assert_file_not_contains "claude sync log omits api key" "$HOME/.claude/recall-sync.log" "fake-claude-api-key"
fi

echo ""
echo "=== Codex sync redaction ==="

export HOME="$TEST_DIR/codex-home"
export SECOND_BRAIN_DIR="$TEST_DIR/codex-obsidian"
export CODEX_SESSIONS_DIR="$TEST_DIR/codex-sessions"
mkdir -p "$HOME/.claude" "$SECOND_BRAIN_DIR" "$CODEX_SESSIONS_DIR"

cp "$REPO_DIR/tests/fixtures/codex-redaction-rollout.jsonl" "$CODEX_SESSIONS_DIR/rollout-redaction.jsonl"
bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh"

CODEX_MD=$(raw_markdown_by_session_id "$SECOND_BRAIN_DIR" "123e4567-e89b-12d3-a456-426614174000")
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
    assert_file_contains "codex logs redaction audit" "$HOME/.claude/codex-sync.log" "redacted"
    assert_file_not_contains "codex sync log omits api key" "$HOME/.claude/codex-sync.log" "fake-codex-api-key"
fi

echo ""
echo "=== Codex sync single JSONL ==="

export HOME="$TEST_DIR/codex-single-home"
export SECOND_BRAIN_DIR="$TEST_DIR/codex-single-obsidian"
export CODEX_SESSIONS_DIR="$TEST_DIR/codex-single-sessions"
mkdir -p "$HOME/.claude" "$SECOND_BRAIN_DIR" "$CODEX_SESSIONS_DIR"

cp "$REPO_DIR/tests/fixtures/codex-redaction-rollout.jsonl" "$CODEX_SESSIONS_DIR/manual-session.jsonl"

IGNORED_SID="123e4567-e89b-12d3-a456-426614174111"
cat > "$CODEX_SESSIONS_DIR/rollout-ignored.jsonl" <<EOF
{"type":"session_meta","timestamp":"2026-06-02T00:00:00Z","payload":{"id":"$IGNORED_SID","timestamp":"2026-06-02T00:00:00Z"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ignored full sync file"}]}}
EOF

bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh" "$CODEX_SESSIONS_DIR/manual-session.jsonl"

SINGLE_CODEX_MD=$(raw_markdown_by_session_id "$SECOND_BRAIN_DIR" "123e4567-e89b-12d3-a456-426614174000")
if [ -z "$SINGLE_CODEX_MD" ]; then
    fail "codex single markdown was created"
else
    pass "codex single markdown was created"
    assert_file_contains "codex single file uses target session" "$SINGLE_CODEX_MD" "session_id: \"123e4567-e89b-12d3-a456-426614174000\""
    assert_file_not_contains "codex single masks api key" "$SINGLE_CODEX_MD" "fake-codex-api-key"
fi

IGNORED_MD=$(find "$SECOND_BRAIN_DIR" -name '*.md' -type f -print0 | xargs -0 grep -l "session_id: \"$IGNORED_SID\"" 2>/dev/null | head -1 || true)
if [ -z "$IGNORED_MD" ]; then
    pass "codex single file does not run full sync"
else
    fail "codex single file does not run full sync"
fi

MISSING_DIR_HOME="$TEST_DIR/codex-single-missing-home"
MISSING_DIR_OBSIDIAN="$TEST_DIR/codex-single-missing-obsidian"
MISSING_DIR="$TEST_DIR/codex-single-missing-sessions"
MISSING_TARGET_JSONL="$CODEX_SESSIONS_DIR/manual-session.jsonl"
mkdir -p "$MISSING_DIR_HOME/.claude" "$MISSING_DIR_OBSIDIAN"
if HOME="$MISSING_DIR_HOME" SECOND_BRAIN_DIR="$MISSING_DIR_OBSIDIAN" CODEX_SESSIONS_DIR="$MISSING_DIR" \
    bash "$REPO_DIR/scripts/sync-codex-to-obsidian.sh" "$MISSING_TARGET_JSONL" >/dev/null 2>&1; then
    fail "codex single sync fails when sessions dir is missing"
else
    pass "codex single sync fails when sessions dir is missing"
fi
if [ "$(find "$MISSING_DIR_OBSIDIAN" -name '*.md' -type f | wc -l | tr -d ' ')" = "0" ]; then
    pass "codex missing sessions dir writes no markdown"
else
    fail "codex missing sessions dir writes no markdown"
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

DASH_MD=$(raw_markdown_by_session_id "$SECOND_BRAIN_DIR" "$DASH_SID")
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
