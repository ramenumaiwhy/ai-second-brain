#!/bin/bash
# sync-recall-to-obsidian.sh の回帰テスト
# 目的: set -e の罠（grep 0件→即死）を二度と再発させない
#
# 実行: bash tests/test-sync-recall.sh (リポジトリルートから)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/sync-recall-to-obsidian.sh"
TEST_DIR=$(mktemp -d /tmp/test-sync-recall-XXXXXX)
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR" /tmp/recall-obsidian-sync.lock 2>/dev/null
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✅ $label"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $label (expected: $expected, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local label="$1" pattern="$2"
    local count
    count=$(find "$TEST_DIR/obsidian" -name "$pattern" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
        echo "  ✅ $label"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $label (no file matching: $pattern)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        echo "  ✅ $label"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $label (pattern not found: $pattern)"
        FAIL=$((FAIL + 1))
    fi
}

# ========== テスト用のモック recall コマンドを作成 ==========
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/recall" << 'MOCK_EOF'
#!/bin/bash
# mock recall: $MOCK_RECALL_DATA を返す
if [ "$1" = "read" ]; then
    cat "$MOCK_RECALL_DATA"
elif [ "$1" = "list" ]; then
    cat "$MOCK_RECALL_LIST"
fi
MOCK_EOF
chmod +x "$MOCK_BIN/recall"

# テスト用のスクリプトコピーを作成（SYNC_LOG/LOCK_DIRをオーバーライド、OBSIDIAN_DIRは環境変数で制御）
TEST_SCRIPT="$TEST_DIR/sync-under-test.sh"
sed "s|^SYNC_LOG=.*|SYNC_LOG=\"$TEST_DIR/sync.log\"|; s|^LOCK_DIR=.*|LOCK_DIR=\"$TEST_DIR/lock\"|" "$SCRIPT" > "$TEST_SCRIPT"
chmod +x "$TEST_SCRIPT"
mkdir -p "$TEST_DIR/obsidian"
export SECOND_BRAIN_DIR="$TEST_DIR/obsidian"

# ========== Test 1: 新規セッション（grep 0件でも即死しない） ==========
echo ""
echo "=== Test 1: 新規セッション（grep 0件→即死しないこと） ==="

cat > "$TEST_DIR/session1.json" << 'EOF'
{
  "session_id": "test-new-session-0001",
  "source": "claude",
  "cwd": "/tmp",
  "timestamp": "2026-02-10T12:00:00Z",
  "messages": [
    {"role": "user", "content": "テスト質問です", "timestamp": "2026-02-10T11:59:00Z"},
    {"role": "assistant", "content": "テスト回答です", "timestamp": "2026-02-10T12:00:00Z"}
  ]
}
EOF

export MOCK_RECALL_DATA="$TEST_DIR/session1.json"
export PATH="$MOCK_BIN:$PATH"

# ロックを事前解除
rm -rf "$TEST_DIR/lock" 2>/dev/null

bash "$TEST_SCRIPT" "test-new-session-0001" 2>&1 && EXIT_CODE=0 || EXIT_CODE=$?

assert_eq "exit code is 0" "0" "$EXIT_CODE"
assert_file_exists "ファイルが生成された" "2026-02-10_*_test-new.md"

GENERATED=$(find "$TEST_DIR/obsidian" -name "2026-02-10_*.md" | head -1)
if [ -n "$GENERATED" ]; then
    assert_file_contains "session_id が含まれる" "$GENERATED" "session_id: \"test-new-session-0001\""
    assert_file_contains "Q1 が含まれる" "$GENERATED" "^## Q1"
    assert_file_contains "A1 が含まれる" "$GENERATED" "^## A1"
fi

# ========== Test 2: 既存セッションへの差分追記 ==========
echo ""
echo "=== Test 2: 既存セッションへの差分追記 ==="

# 追加メッセージがあるデータ
cat > "$TEST_DIR/session1_updated.json" << 'EOF'
{
  "session_id": "test-new-session-0001",
  "source": "claude",
  "cwd": "/tmp",
  "timestamp": "2026-02-10T12:00:00Z",
  "messages": [
    {"role": "user", "content": "テスト質問です", "timestamp": "2026-02-10T11:59:00Z"},
    {"role": "assistant", "content": "テスト回答です", "timestamp": "2026-02-10T12:00:00Z"},
    {"role": "user", "content": "追加質問です", "timestamp": "2026-02-10T12:01:00Z"},
    {"role": "assistant", "content": "追加回答です", "timestamp": "2026-02-10T12:02:00Z"}
  ]
}
EOF

export MOCK_RECALL_DATA="$TEST_DIR/session1_updated.json"
rm -rf "$TEST_DIR/lock" 2>/dev/null

bash "$TEST_SCRIPT" "test-new-session-0001" 2>&1 && EXIT_CODE2=0 || EXIT_CODE2=$?

assert_eq "exit code is 0" "0" "$EXIT_CODE2"

if [ -n "$GENERATED" ]; then
    assert_file_contains "Q2 が追記された" "$GENERATED" "^## Q2"
    assert_file_contains "A2 が追記された" "$GENERATED" "^## A2"
    assert_file_contains "追加質問が含まれる" "$GENERATED" "追加質問です"
fi

# ========== Test 3: 差分なしの場合はスキップ ==========
echo ""
echo "=== Test 3: 差分なし→スキップ ==="

rm -rf "$TEST_DIR/lock" 2>/dev/null
BEFORE_SIZE=$(wc -c < "$GENERATED" 2>/dev/null || echo 0)

bash "$TEST_SCRIPT" "test-new-session-0001" 2>&1 && EXIT_CODE3=0 || EXIT_CODE3=$?

AFTER_SIZE=$(wc -c < "$GENERATED" 2>/dev/null || echo 0)

assert_eq "exit code is 0" "0" "$EXIT_CODE3"
assert_eq "ファイルサイズ変化なし" "$BEFORE_SIZE" "$AFTER_SIZE"

# ========== Test 4: 全セッション同期（jqパイプ） ==========
echo ""
echo "=== Test 4: 全セッション同期 ==="

cat > "$TEST_DIR/list.json" << 'EOF'
{
  "sessions": [
    {"session_id": "test-bulk-001"},
    {"session_id": "test-bulk-002"}
  ]
}
EOF

cat > "$TEST_DIR/bulk1.json" << 'EOF'
{
  "session_id": "test-bulk-001",
  "source": "claude",
  "cwd": "/tmp",
  "timestamp": "2026-02-09T10:00:00Z",
  "messages": [
    {"role": "user", "content": "バルクテスト1", "timestamp": "2026-02-09T10:00:00Z"},
    {"role": "assistant", "content": "バルク回答1", "timestamp": "2026-02-09T10:00:01Z"}
  ]
}
EOF

cat > "$TEST_DIR/bulk2.json" << 'EOF'
{
  "session_id": "test-bulk-002",
  "source": "codex",
  "cwd": "/tmp",
  "timestamp": "2026-02-09T11:00:00Z",
  "messages": [
    {"role": "user", "content": "バルクテスト2", "timestamp": "2026-02-09T11:00:00Z"},
    {"role": "assistant", "content": "バルク回答2", "timestamp": "2026-02-09T11:00:01Z"}
  ]
}
EOF

# mockを書き換え: readの引数でファイルを切り替え
cat > "$MOCK_BIN/recall" << MOCK_EOF
#!/bin/bash
if [ "\$1" = "read" ]; then
    case "\$2" in
        test-bulk-001) cat "$TEST_DIR/bulk1.json" ;;
        test-bulk-002) cat "$TEST_DIR/bulk2.json" ;;
        *) cat "$MOCK_RECALL_DATA" ;;
    esac
elif [ "\$1" = "list" ]; then
    cat "$TEST_DIR/list.json"
fi
MOCK_EOF
chmod +x "$MOCK_BIN/recall"

rm -rf "$TEST_DIR/lock" 2>/dev/null

bash "$TEST_SCRIPT" 2>&1 && EXIT_CODE4=0 || EXIT_CODE4=$?

assert_eq "exit code is 0" "0" "$EXIT_CODE4"
assert_file_exists "bulk-001 ファイル生成" "*test-bul*.md"

# ========== Test 5: マルチラインメッセージ（リグレッション防止） ==========
echo ""
echo "=== Test 5: マルチラインメッセージが保持されること ==="

# マルチラインメッセージを含むセッション
cat > "$TEST_DIR/multiline.json" << 'EOF'
{
  "session_id": "test-multiline-001",
  "source": "claude",
  "cwd": "/tmp",
  "timestamp": "2026-02-11T10:00:00Z",
  "messages": [
    {"role": "user", "content": "1行目のテスト\n2行目のテスト\n3行目のテスト", "timestamp": "2026-02-11T10:00:00Z"},
    {"role": "assistant", "content": "回答1行目\n回答2行目\n\nコードブロック:\n```python\nprint('hello')\n```\n回答最終行", "timestamp": "2026-02-11T10:00:01Z"}
  ]
}
EOF

# mockを書き換え
cat > "$MOCK_BIN/recall" << MOCK_EOF
#!/bin/bash
if [ "\$1" = "read" ]; then
    case "\$2" in
        test-multiline-001) cat "$TEST_DIR/multiline.json" ;;
        *) cat "$MOCK_RECALL_DATA" ;;
    esac
elif [ "\$1" = "list" ]; then
    cat "$TEST_DIR/list.json"
fi
MOCK_EOF
chmod +x "$MOCK_BIN/recall"

rm -rf "$TEST_DIR/lock" 2>/dev/null

bash "$TEST_SCRIPT" "test-multiline-001" 2>&1 && EXIT_CODE5=0 || EXIT_CODE5=$?

assert_eq "exit code is 0" "0" "$EXIT_CODE5"

ML_FILE=$(find "$TEST_DIR/obsidian" -name "2026-02-11_*.md" | head -1)
if [ -n "$ML_FILE" ]; then
    assert_file_contains "2行目が含まれる" "$ML_FILE" "2行目のテスト"
    assert_file_contains "3行目が含まれる" "$ML_FILE" "3行目のテスト"
    assert_file_contains "回答2行目が含まれる" "$ML_FILE" "回答2行目"
    assert_file_contains "コードブロックが含まれる" "$ML_FILE" "print\\('hello'\\)"
    assert_file_contains "回答最終行が含まれる" "$ML_FILE" "回答最終行"
else
    echo "  ❌ マルチラインファイルが生成されなかった"
    FAIL=$((FAIL + 1))
fi

# ========== Test 6: マルチライン差分追記 ==========
echo ""
echo "=== Test 6: マルチラインメッセージの差分追記 ==="

cat > "$TEST_DIR/multiline_updated.json" << 'EOF'
{
  "session_id": "test-multiline-001",
  "source": "claude",
  "cwd": "/tmp",
  "timestamp": "2026-02-11T10:00:00Z",
  "messages": [
    {"role": "user", "content": "1行目のテスト\n2行目のテスト\n3行目のテスト", "timestamp": "2026-02-11T10:00:00Z"},
    {"role": "assistant", "content": "回答1行目\n回答2行目\n\nコードブロック:\n```python\nprint('hello')\n```\n回答最終行", "timestamp": "2026-02-11T10:00:01Z"},
    {"role": "user", "content": "追加質問の1行目\n追加質問の2行目", "timestamp": "2026-02-11T10:01:00Z"},
    {"role": "assistant", "content": "追加回答の1行目\n追加回答の2行目\n追加回答の3行目", "timestamp": "2026-02-11T10:01:01Z"}
  ]
}
EOF

cat > "$MOCK_BIN/recall" << MOCK_EOF
#!/bin/bash
if [ "\$1" = "read" ]; then
    case "\$2" in
        test-multiline-001) cat "$TEST_DIR/multiline_updated.json" ;;
        *) cat "$MOCK_RECALL_DATA" ;;
    esac
elif [ "\$1" = "list" ]; then
    cat "$TEST_DIR/list.json"
fi
MOCK_EOF
chmod +x "$MOCK_BIN/recall"

rm -rf "$TEST_DIR/lock" 2>/dev/null

bash "$TEST_SCRIPT" "test-multiline-001" 2>&1 && EXIT_CODE6=0 || EXIT_CODE6=$?

assert_eq "exit code is 0" "0" "$EXIT_CODE6"

if [ -n "$ML_FILE" ]; then
    assert_file_contains "追記Q2が含まれる" "$ML_FILE" "^## Q2"
    assert_file_contains "追記の2行目が含まれる" "$ML_FILE" "追加質問の2行目"
    assert_file_contains "追記A2の2行目が含まれる" "$ML_FILE" "追加回答の2行目"
    assert_file_contains "追記A2の3行目が含まれる" "$ML_FILE" "追加回答の3行目"
else
    echo "  ❌ マルチラインファイルが見つからない"
    FAIL=$((FAIL + 1))
fi

# ========== 結果サマリー ==========
echo ""
echo "================================"
echo "  PASS: $PASS / FAIL: $FAIL"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    echo "⚠️  テスト失敗あり！"
    exit 1
else
    echo "✅ All tests passed!"
    exit 0
fi
