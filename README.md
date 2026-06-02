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
- `shasum` (macOS 標準)
- `recall` (サードパーティ CLI。[zippoxer/recall](https://github.com/zippoxer/recall) を参照)

### recall のインストール

```bash
# Homebrew
brew install zippoxer/tap/recall

# または Cargo
cargo install --git https://github.com/zippoxer/recall
```

recall は必須。同期スクリプトは起動時にコマンドの存在を確認し、無ければ即終了する。`recall read` が失敗した場合の JSONL フォールバックは内蔵しているが、recall 自体のインストールは必要。

## 注意

- `SECOND_BRAIN_DIR` には**絶対パス**を指定し、**シンボリックリンクではない**ディレクトリを使うこと
- スクリプトは symlink の保存先を拒否する安全機構を持っている
- AI 会話ログの実体は `SECOND_BRAIN_DIR` 配下に保存し、このリポジトリには入れないこと
- transcript 保存前に `scripts/redact-secrets.py` で redaction（秘密情報の伏せ字化）を行う

## テスト

```bash
cd ~/ai-second-brain
bash tests/test-sync-recall.sh
bash tests/test-redaction.sh
```

## ライセンス

MIT
