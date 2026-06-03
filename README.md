# AI Second Brain

AI との会話を自動で Markdown に保存し、Obsidian などのノートアプリで検索・振り返りできるようにするスクリプト集。

対応ツール:
- **Claude Code** — `recall` CLI 経由で会話を取得
- **Codex** (OpenAI) — JSONL セッションファイルを直接パース
- **ChatGPT** — エクスポート JSON を変換
- **OpenClaw/Himeno** — 重要イベントだけを source page として保存

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

### 4. スケジュールを登録

idle sync は checkpoint を見て、最後の更新から一定時間たった session だけを同期する。デフォルトでは15分以上 idle の session を対象にする。

手動実行:

```bash
~/ai-second-brain/scripts/sync-idle-ai-sessions.sh
```

macOS の `launchd` には以下で登録する。`launchd` は macOS のユーザー定期実行機構だ。

```bash
~/ai-second-brain/scripts/install-launchd-schedules.sh
```

このコマンドは `~/Library/LaunchAgents/` に2つの plist を書く。

- `com.ai-second-brain.idle-sync`: 10分ごとに idle sync を実行
- `com.ai-second-brain.daily-recovery`: 毎日05:00に daily recovery を実行

実行時に設定されている `CODEX_SESSIONS_DIR`, `CLAUDE_PROJECTS_DIR`, `AI_IDLE_MIN_AGE_SECONDS`, `AI_RECOVERY_LOOKBACK_DAYS` なども plist に埋め込む。`launchd` は `.zshrc` を読まないので、非デフォルト設定を使う場合は登録コマンドの前に環境変数を設定する。

plist だけを書いて読み込まない場合:

```bash
~/ai-second-brain/scripts/install-launchd-schedules.sh --no-load
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

`install-launchd-schedules.sh` は daily recovery を1日1回に登録する。daily recovery は候補を絞って既存の同期スクリプトへ渡すだけなので、既に最新のMarkdownは `msg_count` 判定でスキップされる。上限で古い候補が取り残されないよう、state file に最近試した候補を保存して次回は未処理候補を優先する。

### 6. OpenClaw/Himeno の重要イベントを保存

Himeno は常時ログを保存しない。保存対象は以下の5種類だけに絞る。

- `task_result`
- `user_decision`
- `failure_recovery`
- `ops_lesson`
- `daily_summary`

手動実行例:

```bash
cat <<'JSON' | ~/ai-second-brain/scripts/save-openclaw-event.py
{
  "record_kind": "task_result",
  "title": "Daily recovery added",
  "task_id": "task-123",
  "completed_at": "2026-06-03T10:00:00+09:00",
  "summary": "AI Second Brain に daily recovery を追加した。",
  "next_actions": ["OpenClaw/Himeno integration を進める"]
}
JSON
```

保存先は `$SECOND_BRAIN_DIR/OpenClaw/sources/`。同じイベントを再実行しても、dedupe key（重複判定キー）で同じ記録として扱われるためファイルは増えない。

### 7. Summary を後から更新

Transcript は保存したまま、上部の `Summary`, `Decisions`, `Next Actions` だけを後から更新できる。

```bash
cat <<'JSON' | ~/ai-second-brain/scripts/update-ai-log-summary.py "$SECOND_BRAIN_DIR/2026-06-03_example.md"
{
  "summary": "この会話では AI ログ保存の運用を整理した。",
  "decisions": ["Transcript は保持する"],
  "next_actions": ["必要なときだけ summary を更新する"]
}
JSON
```

このスクリプトは transcript を書き換えず、要約側だけを redaction に通して `summary_refreshed_at` を frontmatter に残す。

### 8. heartbeat/cron ノイズの扱い

このリポジトリは Second Brain を readable archive として扱う。readable archive は、人間と LLM が読むための保存場所だ。heartbeat や cron の「何もなかった」通知は知識ではないので、通常は Markdown ノートにしない。

Codex / Claude Code の同期では、明示的な automation wrapper（自動実行の状態通知）だけを保守的に省く。普通の会話で `heartbeat` や `cron` という単語が出てきた場合は保存する。

省かれたメッセージがある場合は frontmatter に `omitted_msg_count` を残す。本文には routine chatter を入れない。

フィルタを一時的に無効にする場合:

```bash
AI_LOG_NOISE_FILTER=0 ~/ai-second-brain/scripts/sync-recall-to-obsidian.sh "$SESSION_ID"
AI_LOG_NOISE_FILTER=0 ~/ai-second-brain/scripts/sync-codex-to-obsidian.sh "$CODEX_JSONL_FILE"
```

## スクリプト一覧

| スクリプト | 用途 |
|-----------|------|
| `scripts/record-ai-session-checkpoint.sh` | Stop hook 用の軽量 checkpoint 記録 |
| `scripts/install-launchd-schedules.sh` | idle sync と daily recovery の LaunchAgent 登録 |
| `scripts/sync-idle-ai-sessions.sh` | idle になった checkpoint → Markdown |
| `scripts/recover-ai-sessions-daily.sh` | 最近更新された session の日次回収 |
| `scripts/save-openclaw-event.py` | OpenClaw/Himeno の重要イベント → source page |
| `scripts/update-ai-log-summary.py` | 保存済みAIログの Summary/Decisions/Next Actions 更新 |
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
| `AI_IDLE_MAX_SESSIONS` | No | `20` | idle sync 1回あたりの最大候補数 |
| `AI_LAUNCHD_IDLE_INTERVAL_SECONDS` | No | `600` | idle sync LaunchAgent の実行間隔 |
| `AI_LAUNCHD_DAILY_HOUR` | No | `5` | daily recovery LaunchAgent の実行時刻（時） |
| `AI_LAUNCHD_DAILY_MINUTE` | No | `0` | daily recovery LaunchAgent の実行時刻（分） |
| `AI_LAUNCHD_PATH` | No | `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` | LaunchAgent 用 PATH |
| `AI_LAUNCH_AGENTS_DIR` | No | `~/Library/LaunchAgents` | plist 書き込み先 |
| `AI_RECOVERY_LOOKBACK_DAYS` | No | `3` | daily recovery が見る過去日数 |
| `AI_RECOVERY_MAX_SESSIONS` | No | `50` | daily recovery 1回あたりの最大候補数 |
| `CLAUDE_PROJECTS_DIR` | No | `~/.claude/projects` | Claude Code JSONL fallback の場所 |
| `AI_LOG_NOISE_FILTER` | No | `1` | 明示的な heartbeat/cron automation wrapper を省く。`0`, `false`, `no`, `off` で無効 |
| `AI_LOG_NOISE_PATTERNS_FILE` | No | — | 追加の省略パターンを1行1正規表現で指定 |

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
bash tests/test-ai-log-noise-filter.sh
bash tests/test-idle-sync.sh
bash tests/test-daily-recovery.sh
bash tests/test-openclaw-save.sh
bash tests/test-launchd-schedules.sh
bash tests/test-summary-refresh.sh
```

## ライセンス

MIT
