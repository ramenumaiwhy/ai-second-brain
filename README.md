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

### 3. Claude Code の Stop フックに軽量 checkpoint を登録

`~/.claude/settings.json` の `hooks.Stop` に以下を追加:

```json
{
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "command": "~/ai-second-brain/scripts/record-ai-session-checkpoint.sh --source claude --session-id \"$SESSION_ID\""
      }
    ]
  }
}
```

Stop hook は会話終了の確定ではなく、アシスタント返答の終了で呼ばれる。そのためここでは同期を実行せず、`~/.claude/ai-second-brain-state/` に「この session が更新された」という checkpoint だけを書く。

既存の Stop フックスクリプトがある場合は、直接同期ではなく以下を呼び出す:

```bash
~/ai-second-brain/scripts/record-ai-session-checkpoint.sh --source claude --session-id "$SESSION_ID" &>/dev/null
```

このコマンドは軽量なのでバックグラウンド化しない。`SESSION_ID` が空の場合は Claude hook の stdin JSON から `session_id` を読む。

### 4. idle sync を登録

idle sync は checkpoint を見て、最後の更新から一定時間たった session だけを同期する。デフォルトでは15分以上 idle の session を対象にする。

手動実行:

```bash
~/ai-second-brain/scripts/sync-idle-ai-sessions.sh
```

macOS の `launchd` で10分ごとに実行する例:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.ai-second-brain.idle-sync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOU/ai-second-brain/scripts/sync-idle-ai-sessions.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SECOND_BRAIN_DIR</key>
    <string>/absolute/path/to/your/notes</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
```

古い設定から移行する場合は、Stop hook から `sync-recall-to-obsidian.sh` や `sync-codex-to-obsidian.sh` を直接呼ぶ行を消し、`record-ai-session-checkpoint.sh` に置き換える。

明示的に今すぐ保存したい場合だけ、同期スクリプトを直接実行する:

```bash
~/ai-second-brain/scripts/sync-recall-to-obsidian.sh "$SESSION_ID"
~/ai-second-brain/scripts/sync-codex-to-obsidian.sh "$CODEX_JSONL_FILE"
```

### 5. daily recovery を登録

daily recovery は Stop hook や idle sync が取りこぼした session を、最近更新されたローカルログから回収する。デフォルトでは直近3日、最大50件だけを見る。

手動実行:

```bash
~/ai-second-brain/scripts/recover-ai-sessions-daily.sh
```

`launchd` では1日1回の実行にする。daily recovery は候補を絞って既存の同期スクリプトへ渡すだけなので、既に最新のMarkdownは `msg_count` 判定でスキップされる。上限で古い候補が取り残されないよう、state file に最近試した候補を保存して次回は未処理候補を優先する。

## スクリプト一覧

| スクリプト | 用途 |
|-----------|------|
| `scripts/record-ai-session-checkpoint.sh` | Stop hook 用の軽量 checkpoint 記録 |
| `scripts/sync-idle-ai-sessions.sh` | idle になった checkpoint → Markdown |
| `scripts/recover-ai-sessions-daily.sh` | 最近更新された session の日次回収 |
| `scripts/sync-recall-to-obsidian.sh` | Claude Code 会話 → Markdown |
| `scripts/sync-codex-to-obsidian.sh` | Codex セッション → Markdown |
| `scripts/convert_to_obsidian.py` | ChatGPT エクスポート → Markdown |
| `scripts/session-reminder.sh` | 長時間セッションの Obsidian 書き出しリマインダー |

## 環境変数

| 変数名 | 必須 | デフォルト | 用途 |
|--------|------|-----------|------|
| `SECOND_BRAIN_DIR` | Yes | — | Markdown 保存先ディレクトリ |
| `CODEX_SESSIONS_DIR` | No | `~/.codex/sessions` | Codex JSONL の場所 |
| `AI_SECOND_BRAIN_STATE_DIR` | No | `~/.claude/ai-second-brain-state` | checkpoint 状態ファイルの場所 |
| `AI_IDLE_MIN_AGE_SECONDS` | No | `900` | idle sync 対象になるまでの秒数 |
| `AI_RECOVERY_LOOKBACK_DAYS` | No | `3` | daily recovery が見る過去日数 |
| `AI_RECOVERY_MAX_SESSIONS` | No | `50` | daily recovery 1回あたりの最大候補数 |
| `CLAUDE_PROJECTS_DIR` | No | `~/.claude/projects` | Claude Code JSONL fallback の場所 |

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
bash tests/test-idle-sync.sh
bash tests/test-daily-recovery.sh
```

## ライセンス

MIT
