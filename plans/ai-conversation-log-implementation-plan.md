# AI conversation log implementation plan

## Current State

The repository already contains the core pieces:

- `scripts/sync-codex-to-obsidian.sh`: Codex session JSONL to Markdown.
- `scripts/sync-recall-to-obsidian.sh`: Claude Code recall/JSONL to Markdown.
- `scripts/convert_to_obsidian.py`: ChatGPT export conversion.
- `scripts/session-reminder.sh`: long-session reminder hook.
- `tests/test-sync-recall.sh`: focused test for Claude Code sync behavior.

Local machine state shows `SECOND_BRAIN_DIR` points to the Obsidian Second Brain vault.

The main product gap is not format. The gap is operation:

- When to sync.
- How to avoid heavy full sync at every assistant response.
- How to recover missed sessions.
- How to keep OpenClaw/Himeno records useful instead of noisy.
- How to prevent secret leakage.

## Principles

- Preserve the existing Markdown-first Second Brain style.
- Prefer small changes over a new platform.
- Do not move historical notes in version 1.
- Avoid full sync from every Stop hook.
- Make every sync idempotent. Idempotent means running it twice should not duplicate records.
- Make daily recovery the safety net.
- Keep scripts portable and inspectable.

## Phase 0: Baseline and Guardrails

Goal: document and verify the current behavior before changing automation, and prevent new unredacted writers.

Tasks:

- Confirm current output fields for Codex and Claude Code records.
- Add or update tests for `session_id`, `msg_count`, append behavior, and frontmatter fields.
- Add fixture files for Codex and Claude Code source logs.
- Add a basic redaction test for obvious secrets.
- Add a minimal redaction helper and route existing Codex and Claude Code writers through it before changing their save behavior.
- Add the redaction helper before adding any new save path.
- Add a policy gate: no new writer may persist transcript text unless it passes through redaction.
- Document the current installed hook state in a local-only note or setup doc.

Acceptance criteria:

- Running tests proves append-only behavior.
- Test fixtures do not contain private data.
- The repository explains that private logs are stored in Obsidian, not in git.
- Redaction tests pass before any idle-save or daily-recovery writer is added.
- Existing Codex and Claude Code sync paths pass transcript text through the minimal redaction helper before Phase 1 writer changes land.
- Any implementation PR that adds a new writer without redaction is rejected.

## Phase 1: Shared Markdown Contract

Goal: make all sync paths write the same record shape.

Tasks:

- Align Codex output with required frontmatter fields:
  - `date`
  - `title`
  - `source`
  - `session_id`
  - `record_kind`
  - `msg_count`
  - `last_message_hash`
  - `transcript_hash`
  - `tags`
- Align Claude Code output with the same fields.
- Add `Summary`, `Decisions`, `Next Actions`, and `Transcript` sections.
- Keep transcript generation as the minimum viable save path.
- Allow summary sections to be blank or generated later.

Acceptance criteria:

- Codex and Claude Code records have compatible frontmatter.
- Existing notes can still be read by Obsidian.
- Existing records are not migrated automatically.
- Claude Code's current Q/A-heading append logic is either documented as temporary or replaced by `msg_count` plus `last_message_hash` and `transcript_hash`.

## Phase 2: Redaction Hardening

Goal: harden the already-mandatory redaction layer and prove it is used consistently.

Tasks:

- Expand the Phase 0 redaction helper used by both Codex and Claude Code sync paths.
- Mask obvious patterns:
  - `Bearer ...`
  - common API key prefixes.
  - bot token patterns.
  - `.env` assignment blocks.
  - private key blocks.
- Add tests for each pattern.
- Log that redaction happened without logging the secret itself.
- Add fixtures for multiline secrets and fenced code blocks.

Acceptance criteria:

- Tests prove secrets are masked in transcript output.
- Sync logs never print the secret value.
- Redaction failures fail closed when a pattern is clearly dangerous.

## Phase 3: Idle Save

Goal: save sessions after inactivity without treating each assistant response as conversation end.

Recommended design:

```text
Stop hook:
  record source + session_id + updated_at into a lightweight state file

idle sync job:
  every 10 minutes:
    read state file
    if updated_at is older than 15 to 30 minutes:
      sync that session
```

Tasks:

- Add a small state writer for Stop hook use.
- Add an idle sync script that processes stale sessions.
- Store state outside the Obsidian vault, for example under `~/.claude/ai-second-brain-state/`.
- Keep the state file format simple Markdown or JSON.
- Document how to install the idle job.
- Update `README.md` so Stop hook setup records only a lightweight checkpoint, not a full sync.
- Document how to migrate from the old direct Stop-hook sync style.

Acceptance criteria:

- Stop hook does not run full sync.
- Idle sync can save one stale session.
- Running idle sync again does not duplicate messages.
- README setup matches the lightweight-checkpoint design.

## Phase 4: Daily Recovery

Goal: recover anything idle sync missed.

Tasks:

- Add a daily recovery command.
- For Codex, scan `~/.codex/sessions` for recently modified sessions.
- For Claude Code, scan recall session list plus JSONL fallback within a bounded window.
- Sync only sessions whose `session_id` is missing or whose `msg_count` is stale.
- Produce a short recovery report.
- Track `last_recovery_at`, target lookback days, and maximum sessions per run in a state file.

Acceptance criteria:

- A daily run can recover missed sessions.
- Recovery report includes counts only, not transcript content.
- The command can be used manually before automating it.
- A daily run does not require scanning all historical sessions every time.

## Phase 5: OpenClaw/Himeno Integration

Goal: capture useful Himeno memory without saving heartbeat noise.

Tasks:

- Keep Himeno records under `$SECOND_BRAIN_DIR/OpenClaw/`.
- Define allowed record kinds:
  - `task_result`
  - `user_decision`
  - `failure_recovery`
  - `ops_lesson`
  - `daily_summary`
- Define event boundaries and dedupe keys before writing:
  - `task_result`: `task_id` plus completion timestamp.
  - `user_decision`: `decision_id` or content hash plus source message id.
  - `failure_recovery`: incident id or content hash plus recovery timestamp.
  - `ops_lesson`: content hash plus source artifact path.
  - `daily_summary`: date plus source.
- Do not save every heartbeat line.
- Prefer task completion summaries, user decisions, and failure recoveries.
- Add a Himeno save command that writes source pages into `OpenClaw/sources/`.
- Add or repair wiki compile checks only after iCloud write instability is handled.

Acceptance criteria:

- Himeno records are useful when read later.
- Routine heartbeat chatter does not flood the vault.
- A failed OpenClaw/iCloud write is retriable and visible.
- Re-running Himeno save does not duplicate a task result or decision record.

## Phase 6: Scheduling

Goal: make the operation reliable but not intrusive.

Recommended schedule:

- Explicit user request: sync immediately.
- Stop hook: write lightweight checkpoint only.
- Idle sync: every 10 minutes, save sessions idle for 15 to 30 minutes.
- Daily recovery: once per day.
- Himeno task-result save: at task completion or meaningful decision point.

Implementation options:

- macOS `launchd`: good for local scheduled scripts.
- OpenClaw cron: good when the LLM should inspect or summarize.
- Codex automation: good for isolated periodic checks.

Version 1 should prefer deterministic scripts for capture and reserve LLM work for summaries and audits.

## Phase 7: Summary Refresh

Goal: make saved logs easier to read without risking transcript loss.

Tasks:

- Add an optional summary refresher.
- It reads a saved Markdown transcript and fills or updates:
  - `Summary`
  - `Decisions`
  - `Next Actions`
- Preserve the transcript verbatim except for redaction.
- Mark generated summaries with a timestamp.

Acceptance criteria:

- Transcript remains intact.
- Summary refresh can be skipped without losing the raw conversation.
- The user can ask any future LLM to read the Markdown directly.

## Testing Plan

Run order for implementation changes:

```bash
bash tests/test-sync-recall.sh
```

If TypeScript or Node code is added later, follow the local policy:

```bash
tsc --noEmit
# then configured linter
# then vitest
```

This repository currently appears shell/Python-oriented, so do not add TypeScript tooling unless a real implementation need appears.

## Open Questions

- Should idle threshold be 15 minutes or 30 minutes?
- Should records stay in Second Brain root forever, or should new records eventually move under `AI-Logs/`?
- Should summary refresh be automatic or explicit-only?
- How should OpenClaw/Himeno expose task completion events to the sync script?
- Should ChatGPT import use the same shared record shape now or wait until Codex/Claude are stable?

## Recommended First Slice

Start with the smallest valuable implementation:

1. Add shared frontmatter contract tests.
2. Add redaction helper tests.
3. Add Stop-hook checkpoint writer.
4. Add idle sync script for Codex and Claude Code.
5. Add daily recovery command.

This gives durable Markdown capture without changing the vault structure or flooding Second Brain.
