# AI conversation log design

## Purpose

AI Second Brain is a portable archive for conversations with AI tools.

The data should stay useful even if a specific service, model, app, or chat UI disappears. Obsidian is a viewer and editor, not the source of truth. The source of truth is plain Markdown saved under `SECOND_BRAIN_DIR`.

## Goals

- Keep AI conversations as durable personal data.
- Preserve the existing Second Brain Markdown style.
- Make logs readable by humans and future LLMs.
- Support Codex, Claude Code, OpenClaw/Himeno, and future AI tools through the same record shape.
- Avoid depending on Codex, Claude, OpenClaw, Obsidian, or any single vendor for recall.
- Keep enough raw transcript to reconstruct the original conversation.
- Keep summary sections above the transcript so daily use does not require reading everything.

## Non-goals

- Do not build a new note app.
- Do not move the vault out of Obsidian/iCloud in the first version.
- Do not publish private logs by default.
- Do not require JSONL as the primary archive format.
- Do not try to perfectly detect when a conversation is truly finished.
- Do not save secrets, API keys, tokens, or `.env` content into Second Brain.

## Storage Model

The repository stores scripts, policy, tests, and implementation notes.

The actual conversation records stay in the Markdown vault pointed to by `SECOND_BRAIN_DIR`:

```text
$SECOND_BRAIN_DIR/
  2026-06-02_codex_セカンドブレイン記録設計_019e....md
  2026-06-02_Claude_Code_転職PJ整理_019e....md
  OpenClaw/
    sources/
    syntheses/
```

This preserves the existing layout. A future migration can add `AI-Logs/`, but version 1 should not require moving old notes. Moving the vault structure first would create work without improving recall.

## Record Shape

Each AI conversation record is one Markdown file with YAML frontmatter.

YAML frontmatter is the metadata block between the first two `---` lines. It makes notes searchable and machine-readable without changing the body.

```md
---
date: 2026-06-02
title: "セカンドブレイン記録設計"
source: "Codex"
session_id: "019e..."
record_kind: "interactive"
msg_count: 12
last_message_hash: "sha256:..."
transcript_hash: "sha256:..."
tags:
  - "codex"
  - "ai-log"
---

# セカンドブレイン記録設計

## Summary

この会話では、Codex / Claude Code / OpenClaw/Himeno の会話ログを
Second Brain にMarkdownで残す運用を整理した。

## Decisions

- Markdownを主形式にする。
- 会話終了は完璧に判定せず、アイドル保存と日次回収で補う。
- 生ログは `Transcript` に残し、上部に要約を置く。

## Next Actions

- Codex / Claude Code の差分保存を整える。
- OpenClaw/Himeno のタスク完了記録を同じ思想で保存する。

## Transcript

### User 1

...

### Assistant 1

...
```

## Required Fields

- `date`: record date in `YYYY-MM-DD`.
- `title`: human-readable title derived from the first meaningful user message.
- `source`: one of `Codex`, `Claude Code`, `OpenClaw/Himeno`, `ChatGPT`, or another future source name.
- `session_id`: stable source session identifier. This links the Markdown record back to the original local log.
- `record_kind`: category such as `interactive`, `codex_review`, `task_result`, `daily_summary`, or `chatgpt`.
- `msg_count`: number of saved user/assistant messages, used for append-only sync.
- `last_message_hash`: hash of the last saved normalized message. This catches append-position drift that `msg_count` alone can miss.
- `transcript_hash`: hash of all saved normalized transcript messages. This catches broader saved-content drift after parser changes, forks, or source log rewrites.
- `tags`: at minimum, source tag plus `ai-log`.

## Body Sections

- `Summary`: short summary for quick reading.
- `Decisions`: decisions, conclusions, and durable preferences.
- `Next Actions`: unfinished actions and follow-ups.
- `Transcript`: original conversation text, appended over time.

`Summary`, `Decisions`, and `Next Actions` can be generated after initial transcript save. Transcript persistence is the first priority; polished summaries are second.

## Sources

### Codex

Codex source logs live under `~/.codex/sessions`.

The existing `scripts/sync-codex-to-obsidian.sh` parses Codex JSONL session files and writes Markdown. It should keep doing that, but the output should follow the shared record shape.

### Claude Code

Claude Code is read through `recall` first, with JSONL fallback when recall is incomplete.

The existing `scripts/sync-recall-to-obsidian.sh` already handles this path. Today it appends by matching `session_id` and counting `## Q...` / `## A...` transcript headings. Future implementation should align it with the shared `msg_count`, `last_message_hash`, and `transcript_hash` contract.

### OpenClaw/Himeno

OpenClaw/Himeno is different from Codex and Claude Code because it is a resident assistant, not just a chat session.

Its durable records should remain under:

```text
$SECOND_BRAIN_DIR/OpenClaw/
```

Himeno should save:

- Task completions.
- User decisions.
- Failures and recovery notes.
- Operational lessons.
- Daily summaries when useful.

Himeno should not save every routine heartbeat line. Heartbeat noise would bury the useful memory.

### Future AI Tools

Future tools should implement the same normalized Markdown record. The tool-specific parser can differ, but the final Markdown should not.

## Timing Model

Conversation end is not a reliable event. A model response ending does not mean the user is done.

Use four timing paths:

- Explicit save: when the user says "記録して", "Second Brainに残して", or similar.
- Idle save: when a session has no new messages for 15 to 30 minutes.
- Append save: when a saved session receives more messages, append only the new messages.
- Daily recovery: once per day, scan for unsaved or partially saved sessions and recover them.

This avoids pretending that a Stop hook means the conversation is finished.

## Sync Strategy

The sync process should be append-only by default.

1. Find the source session.
2. Extract user and assistant messages.
3. Locate an existing Markdown file by `session_id`.
4. Compare source message count with saved `msg_count`.
5. Compare the saved `last_message_hash` with the corresponding source message.
6. Compare `transcript_hash` for the saved prefix when practical.
7. Append only new messages.
8. Update `msg_count`, `last_message_hash`, and `transcript_hash`.
9. Refresh summary sections when safe.

The existing scripts already implement most of this for Codex and Claude Code. Version 1 should improve scheduling and consistency before adding new storage formats.

## Safety Rules

Before writing to Second Brain, mask obvious secrets:

- API keys.
- Bearer tokens.
- Bot tokens.
- OAuth tokens.
- `.env` blocks.
- Private key blocks.
- Known credential file contents.

If masking is uncertain, prefer saving a redacted placeholder over writing the raw value.

## Repository Role

This repository should contain:

- Sync scripts.
- Tests.
- Scheduling docs.
- Data-shape docs.
- Review checklists.
- Implementation plans.

This repository should not contain private conversation logs. The logs belong in the Obsidian vault.

## Initial Operating Policy

- Keep Markdown as the primary format.
- Keep Obsidian as the current save location.
- Avoid Stop-hook full sync.
- Use idle save plus daily recovery.
- Treat OpenClaw/Himeno as an operations memory source, not a transcript firehose.
- Build small reliability checks before expanding scope.
