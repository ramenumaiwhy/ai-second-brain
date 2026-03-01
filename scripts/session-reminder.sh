#!/bin/bash

# UserPromptSubmit hook: 20ターンごとにObsidian書き出しリマインダーを注入

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // empty' | tr -dc 'A-Za-z0-9_-' | cut -c1-64)

if [ -z "$session_id" ]; then
  exit 0
fi

TURN_FILE="/tmp/claude-turn-count-${session_id}"
INTERVAL=20

if [ -f "$TURN_FILE" ] && [ ! -L "$TURN_FILE" ]; then
  count=$(cat "$TURN_FILE")
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  count=$((count + 1))
else
  count=1
fi
printf '%s' "$count" > "$TURN_FILE"

if [ $((count % INTERVAL)) -eq 0 ]; then
  cat <<'MSG'
📝 セッション長期化リマインダー: 深い分析中であれば、現在の分析状態をObsidianに書き出すことを検討してください。書き出し先: ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/notes/Second-Brain/
MSG
fi
