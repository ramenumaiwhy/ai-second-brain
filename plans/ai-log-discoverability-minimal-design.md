# AI会話ログの検索品質を直す最小設計

## 結論

保存は壊れていない。壊れているのは分類と検索面だ。

次の3面へ分ける。

| 種別 | 正本 | 普段見る派生 | 既定検索 |
|---|---|---|---|
| 通常会話 | `AI-Logs/raw/<source>/YYYY-MM/<session_id>.md` | `AI-Logs/readable/<source>/YYYY-MM/<session_id>.md` | 対象 |
| Codex Automation | 同じ `raw` | `AI-Logs/automation/codex/YYYY-MM/<session_id>.md` | 除外 |
| 旧rootログ | 現位置のまま | 今回は作らない | 除外 |

`raw` は正本、`readable` と `automation` は作り直せる派生とする。秘密情報の
redaction、append-only、hash照合は変えない。

Automationを削除したり、LLMに「重要か」を判定させたりしない。通常会話の検索面から
機械的に分けるだけだ。

## 確認済みの現状

- `AI-Logs/raw`: 386件。
- `AI-Logs/readable`: 386件。
- うち18件が `Automation: OpenClaw Gateway Health Check`。
- 18件はすべて `record_kind: interactive` と誤分類されている。
- root直下Markdownは6,730件。
- うち6,683件は `20??-??-??_*.md` で、iCloudのdataless placeholder。
- rootだけでなく `AI-Logs/readable` 内にもdataless fileがあり、`rg` は
  `Operation timed out` を返した。
- Codex JSONLは即時保存されるが、Second Brainへの通常反映は翌05:00になっている。
- launchdのidle syncとdaily recoveryは正常終了している。
- ObsidianのExcluded filesは未設定。
- `~/.codex/config.toml` の `notify` はComputer Useが使用中。上書き禁止。
- `~/.codex/hooks.json` には既存の `Stop` hook群がある。

## 1. Automationの決定的分類

分類はメッセージ単位のnoise filterより前、redaction後に1回だけ行う。

Codexの最初の空でないUserメッセージをLFへ正規化し、外側の空行だけ除く。その先頭が
次のenvelope（定型ヘッダー）へ完全一致した場合だけ `automation` とする。

```regex
\AAutomation: (?P<title>[^\n]+)\n
Automation ID: (?P<id>[a-z0-9]+(?:-[a-z0-9]+)*)\n
Automation memory: \$CODEX_HOME/automations/(?P=id)/memory\.md\n
Last run: [^\n]+\n
(?:\n|$)
```

追加条件:

- sourceはCodex。
- `automation_id` は1〜128文字。
- `Automation ID` とmemory path内のIDが完全一致。
- envelope後に空でない実行指示がある。
- titleだけの一致、本文中の引用、行順違い、項目欠落は `interactive`。
- 曖昧なら必ず `interactive`。確信度やLLM fallbackは作らない。

分類ルール名は `codex-automation-envelope-v1` とする。

保存する追加メタデータはこれだけだ。

```yaml
record_kind: "automation"
automation_id: "openclaw-gateway-health-check"
classification_rule: "codex-automation-envelope-v1"
```

時刻付きの `classified_at` や推定確率は、再生成のたびに差分を増やすだけなので持たない。

## 2. 保存方針

### 通常会話

現行どおり `raw` と `readable` を生成する。

### Automation

- redaction済み全文を現行の `raw` に保存する。
- 人間が障害履歴を必要時に読める派生を `AI-Logs/automation` に生成する。
- `AI-Logs/readable` には生成しない。
- `AI-Logs/automation` は既定検索とObsidianの通常検索から除外する。
- automationの成功・失敗・重要度を意味判定しない。

Automationの異常だけを通常readableへ昇格する機能は後回しだ。現時点ではCodex自身の
inbox通知とautomation派生で足りる。

## 3. 検索方針

### 既定検索はdenylistではなくallowlist

`search-second-brain.sh` はSecond Brain root全体を `rg` に渡さない。次だけを候補にする。

- root直下の、日付prefixを持たないMarkdown。
- `AI-Logs/readable/`。
- `OpenClaw/`。
- `_generated/`。
- `plans/`。

次は常に対象外とする。

- root直下の `20??-??-??_*.md`。
- `AI-Logs/raw/`。
- `AI-Logs/raw-archive/`。
- `AI-Logs/automation/`。

候補fileは本文を開く前に `stat` だけでmacOSの `SF_DATALESS` flagを確認する。
dataless file、symlink、通常fileでないものは `rg` に渡さない。Linux等で `st_flags` が
なければ0として扱う。

候補が0件ならexit 1ではなく「該当するローカル実体なし」と分かる終了にする。
検索中にiCloud placeholderをhydrate（ダウンロード）してはならない。

### `.rgignore` は二重防御

Second Brain rootに次を置く。

```gitignore
/20??-??-??_*.md
/AI-Logs/raw/
/AI-Logs/raw-archive/
/AI-Logs/automation/
```

ripgrep公式Guideでは `.ignore` / `.rgignore` とnegative globが標準機能だ。ただし
`.rgignore` だけに依存せず、helperのallowlistを本体とする。

### Obsidian

vault root基準で次をExcluded filesへ追加する。

```text
Second-Brain/AI-Logs/raw
Second-Brain/AI-Logs/raw-archive
Second-Brain/AI-Logs/automation
```

Obsidian公式Helpによれば、Excluded filesに一致するfileはSearch結果へ出ない。

root直下のdated legacyを正規表現で除外する設定は、現在のObsidian UIで入力・動作確認して
から採用する。Context7で確認できた公式資料はSearch除外の効果までは保証するが、Excluded
files欄の正規表現構文までは十分に確認できなかった。未検証の構文を設計事実にしない。

当面、エージェント検索は必ずhelperを使う。Obsidianで旧ログが邪魔な場合は、移動を始める
前に別途UI上の除外方法を確認する。

## 4. Codex会話を15〜25分後に反映する

翌05:00だけでは遅い。既存のcheckpointとidle syncへCodexを接続する。

Codex公式Hooksでは、`Stop` hookはターン終了時に実行され、stdin JSONに
`session_id` と `transcript_path` が入る。これを使う。

1. `~/.codex/hooks.json` の既存 `Stop` 配列へcheckpoint handlerを追加する。
2. handlerは同期を実行せず、`record-ai-session-checkpoint.sh` だけを呼ぶ。
3. `record-ai-session-checkpoint.sh` はstdin JSONから `session_id` と
   `transcript_path` を読む。
4. sourceは固定で `codex`、pathは既存のpath検証を通す。
5. 最終ターンから15分idle後、10分間隔の既存idle syncが保存する。
6. 05:00のdaily recoveryは取りこぼし対策として残す。

想定反映時間は最終ターンから15〜25分だ。

`notify` は使わない。この端末ではComputer Useが既に占有しており、上書きすると別機能を
壊す。GPT-5.6-solの初案は `notify` adapterだったが、現行設定と公式Stop hook仕様を照合し、
Stop checkpointへ修正した。

公式資料は `transcript_path` のformatを安定interfaceとして保証していない。ここでは本文形式
をhook内で解釈せず、現行sync scriptへpathを渡すだけに留める。

## 5. 既存Automation派生の移行

削除しない。dry-runとapplyを分ける。

### Dry-run

- 対象はタイトルではなくclassifier一致で選ぶ。
- 対応するraw/readable、session ID、`raw_ref`、`raw_hash`を照合する。
- 移動元、移動先、before SHA-256、衝突、分類結果をJSONL manifestへ出す。
- iCloud dataless fileはskipし、理由を集計する。
- Second Brain全体は走査しない。`AI-Logs/raw/codex` と `readable/codex` だけを見る。
- 変更は0件。

現在の既知件数は18件だが、apply条件へ `18` をhardcodeしない。Automationは今も増えるためだ。
applyは、ユーザーが承認した凍結manifestの全行が現在も同じhashであることを条件にする。

### Apply

- ユーザーの明示承認後だけ実行する。
- 対象の元バイトを `AI_SECOND_BRAIN_STATE_DIR/migrations/<batch-id>/` へbackupする。
- rawの分類メタデータを更新する。
- automation派生を再生成し、`AI-Logs/automation/...` へ配置する。
- 元readableはmanifestに従って検索面から退避する。
- path、hash、mtimeのどれかがdry-run後に変わっていたら全体を停止する。
- 同じmanifestの再applyは0変更で終わる。

### Rollback

- post-apply hashがmanifestと一致するときだけ実行できる。
- backupから元pathと元バイトを復元する。
- 移行後に人間が編集していたら停止する。
- rollback後のSHA-256がbefore hashと完全一致することを確認する。

## 6. 実装順序

### Must now

1. Automation classifierとunit test。
2. `AI-Logs/automation`への出力分岐。
3. 検索helperのallowlist化とdataless除外。
4. `.rgignore` とObsidian folder exclusionsの案内。
5. Codex Stop hookからcheckpointへの接続。
6. Automation migrationのdry-run manifest。

ここまでなら既存ファイルを移動しない。

### 承認後

7. 凍結manifestのAutomation派生だけ移行。
8. 直後にrollbackをテストし、再applyする。

### Later

- root 6,683件をhydrateした後のarchive。
- automation異常だけの昇格・月次集約。
- Claude/Codex同期scriptの共通化。
- 旧rootログのreadable化。
- ChatGPT converterの移設。

## 7. 受入基準

- 既知Automation fixtureは `automation`。
- titleだけを引用した普通の相談は `interactive`。
- 普通のcron/heartbeat相談は従来どおり保存される。
- Automationはrawとautomation派生、通常会話はrawとreadableを生成する。
- 既定検索でraw、raw-archive、automation、dated rootが0件。
- hydratedなreadable、OpenClaw、plansは検索できる。
- 検索前後でplaceholderのflagとdownload状態が変わらない。
- secretがraw、派生、manifest、logへ漏れない。
- Stop hookは正しいsession IDとJSONL pathをcheckpointへ記録する。
- 最終ターンから15〜25分後に一度だけ同期される。
- daily recovery再実行で重複しない。
- migration dry-runは0変更。
- applyは凍結manifest分だけ、再applyは0変更。
- rollback後はbefore SHA-256と完全一致する。

## 8. テスト

- `tests/test-ai-log-noise-filter.sh`
  - Automation envelopeのtrue/false positive。
  - 通常会話とAutomationの出力先。
  - redaction維持。
- 新規 `tests/test-search-scope.sh`
  - allowlist、dated root除外、dataless除外、symlink拒否。
- 新規 `tests/test-codex-checkpoint-hook.sh`
  - Stop hook payloadからID/pathを記録。
  - path不正時に拒否。
- 新規 `tests/test-automation-migration.sh`
  - dry-run、hash drift停止、再apply、rollback。
- 既存のredaction、idle、daily recovery、launchd testsを回帰実行。

このrepositoryはTypeScriptを含まないため、AGENTS.mdの `tsc`、linter、Vitestは該当なし。
検証順は `py_compile`、`bash -n`、shell tests、`git diff --check` とする。

## 9. 非目標

- embedding、vector DB、全文検索index、database。
- LLM classifier、LLMによる削除判断。
- 新dependency、新daemon、新LaunchAgent。
- raw本文・redaction方式の全面変更。
- root 6,683件のhydrate、移動、削除。
- Automation内容の重要度判定。
- 既存同期scriptの全面rewrite。
- retention期限や自動削除。

## 参照した現行資料

- Context7: ripgrep公式Guideのignore/glob挙動。
- Context7: Obsidian公式HelpのExcluded filesとSearch挙動。
- OpenAI公式: Codex HooksのStop input fields。
- OpenAI公式: Codex `notify` とuser-level config制約。
- `docs/second-brain-fable5-review.html`。
- `plans/second-brain-readable-md-minimal-plan.md`。
- `plans/second-brain-cleanup-design.md`。
- 実際のSecond Brain、launchd、Codex config/hooks。
