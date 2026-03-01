# AI Second Brain

AI との会話を自動で Markdown に保存し、Obsidian などのノートアプリで検索・振り返りできるようにするスクリプト集。

対応ツール:
- **Claude Code** — `recall` CLI 経由で会話を取得
- **Codex** (OpenAI) — JSONL セッションファイルを直接パース
- **ChatGPT** — エクスポート JSON を変換

## セットアップ

### 1. クローン

```bash
git clone https://github.com/ramenumaiwhy/ai-second-brain.git ~/ai-second-brain
```

### 2. 環境変数を設定

Markdown の保存先ディレクトリを `SECOND_BRAIN_DIR` に指定する。

```bash
# ~/.zshrc (or ~/.bashrc)
export SECOND_BRAIN_DIR="$HOME/path/to/your/notes"
```

### 3. Claude Code の Stop フックに登録

`~/.claude/settings.json` の `hooks.Stop` に以下を追加:

```json
{
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "command": "~/ai-second-brain/scripts/sync-recall-to-obsidian.sh \"$SESSION_ID\""
      }
    ]
  }
}
```

または既存の Stop フックスクリプトから呼び出す:

```bash
~/ai-second-brain/scripts/sync-recall-to-obsidian.sh "$SESSION_ID" &>/dev/null &
~/ai-second-brain/scripts/sync-codex-to-obsidian.sh &>/dev/null &
```

## スクリプト一覧

| スクリプト | 用途 |
|-----------|------|
| `scripts/sync-recall-to-obsidian.sh` | Claude Code 会話 → Markdown |
| `scripts/sync-codex-to-obsidian.sh` | Codex セッション → Markdown |
| `scripts/convert_to_obsidian.py` | ChatGPT エクスポート → Markdown |
| `scripts/session-reminder.sh` | 長時間セッションの Obsidian 書き出しリマインダー |

## 環境変数

| 変数名 | 必須 | デフォルト | 用途 |
|--------|------|-----------|------|
| `SECOND_BRAIN_DIR` | Yes | — | Markdown 保存先ディレクトリ |
| `CODEX_SESSIONS_DIR` | No | `~/.codex/sessions` | Codex JSONL の場所 |

## 依存コマンド

- `jq`
- `python3`
- `recall` (Claude Code CLI に付属)

## テスト

```bash
cd ~/ai-second-brain
bash tests/test-sync-recall.sh
```

## ライセンス

MIT
