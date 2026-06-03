# AI log reference practices

This note keeps the external references used for the readable AI log policy.
It stores links and implementation takeaways only. Do not copy private logs or
article bodies into this repository.

## Conclusion

The useful pattern is not "save every byte into the readable vault." The better
pattern is:

1. Keep Markdown as the durable source of truth.
2. Put summaries, decisions, and next actions above raw transcript.
3. Keep routine automation chatter out of the human-facing notes.
4. Preserve operational state in state files or sync logs.
5. Save failures, recoveries, decisions, task results, and daily summaries as
   durable notes.

This matches the current repository direction and adds one sharper rule:
heartbeat/cron no-op chatter is not a knowledge asset.

## References

### Claude Code conversation logging to Obsidian

- URL: https://zenn.dev/pepabo/articles/ffb79b5279f6ee
- Useful practice: automatically save Claude Code conversations as Markdown in
  an Obsidian-managed knowledge base.
- Implementation takeaway: automatic capture is useful, but the article also
  removes system/noise messages and local command noise from the readable note.

### Claude Code session continuity with hooks

- URL: https://zenn.dev/sora_biz/articles/claude-code-session-continuity
- Useful practice: use hooks to maintain session handoff context such as
  `HANDOFF.md` instead of treating the full transcript as the only memory.
- Implementation takeaway: continuity files are different from raw logs. A
  small handoff artifact can be more useful than a larger transcript.

### Claude Code memory recall from session logs

- URL: https://zenn.dev/flinters_blog/articles/d824ce0576dcf2
- Useful practice: summarize session records and recall relevant past memory
  from keywords.
- Implementation takeaway: raw JSONL and memory/recall are separate layers.
  The implementation should keep simple search useful instead of relying on a
  noisy raw dump.

### GitHub Copilot CLI session commands

- URL: https://zenn.dev/chips0711/scraps/fa3752e24fc73f
- Useful practice: provide separate commands for session reset/resume, Markdown
  sharing, research reports, and quick questions that do not affect history.
- Implementation takeaway: mature AI CLI workflows separate shareable reports
  from operational session management.

### Claude Code x Obsidian LLM Wiki

- URL: https://qiita.com/usayamadausako/items/c8b5cca97554f6f64782
- Useful practice: use Obsidian/Markdown as an LLM-readable wiki across
  sessions.
- Implementation takeaway: automatic note generation can make a vault
  self-expand with duplicated or wrong information. Manual triggers and cleanup
  rules matter.

### Fully automatic Claude Code to Obsidian logging

- URL: https://qiita.com/delphinus/items/9325c8dd750c85bac944
- Useful practice: save Claude Code conversations automatically and make them
  searchable across machines.
- Implementation takeaway: even automatic logging needs filters. The article
  mentions excluding read-only/noisy commands with a blocklist.

### Work knowledge in GitHub as a second brain

- URL: https://note.com/proper_iris7880/n/n69251e18d1c5
- Useful practice: keep work knowledge as Markdown in a private GitHub
  repository so local AI tools can read it directly.
- Implementation takeaway: simple Markdown and folder structure reduce noise
  compared with rich block APIs.

### Obsidian x Claude Code AI-readable vault design

- URL: https://note.com/hacklog_stealth/n/nc2bf3a7e0f6b
- Useful practice: design the vault so AI can find files by filename,
  frontmatter, and simple text search.
- Implementation takeaway: notes that look organized to humans can still be
  noisy for grep and semantic search. Frontmatter and naming rules are part of
  the product, not decoration.

### LLM Wiki

- URL: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
- Useful practice: separate raw sources, generated Markdown wiki, and schema
  or workflow documents.
- Implementation takeaway: the durable layer should be structured Markdown,
  not an unbounded pile of raw logs.

## Policy extracted for this repository

- `interactive` AI conversations stay as one Markdown file per session.
- Routine `heartbeat`, `cron`, `checkpoint`, and no-op automation chatter does
  not become a readable note.
- If automation produces a meaningful result, save it as one of:
  `task_result`, `user_decision`, `failure_recovery`, `ops_lesson`, or
  `daily_summary`.
- If a source transcript includes explicit automation wrapper messages, the
  sync path may omit those messages and record only the useful conversation.
- Operational counters and reports belong in state files or sync logs, not in
  the Markdown vault.
