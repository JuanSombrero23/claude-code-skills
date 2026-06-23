---
title: Claude Code session transcript (.jsonl) format
purpose: Reference for the session-curator skill's parsers. Read this when extending Extract-SessionIndex.ps1, Watch-Session.ps1, or any subagent that needs to interpret raw transcript lines.
generator: session-curator/references (Phase 3)
generated: 2026-05-31
sources: Official docs at code.claude.com/docs/en/sessions.md + empirical inspection of ~/.claude/projects/ in May 2026.
---

# Claude Code session transcript format

Each Claude Code session writes an **append-only JSON-lines** file at:

```
~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
```

Where `<encoded-cwd>` is the cwd path with `:` removed and `\`/spaces/`-` all collapsed to `-`. (Encoding is lossy — you cannot reliably reconstruct the original cwd from the folder name; read the `cwd` field of any line instead.)

The file is written one event per line, each line a single `JSON.stringify(...) + "\n"`. Encoding is **UTF-8, no BOM**. Reading from another process is safe as long as you open with `FileShare.ReadWrite` (Windows lock would otherwise reject readers).

Auto-cleanup: Claude itself deletes transcript files after `cleanupPeriodDays` days (default 30). Bump that in `settings.json` if you want a longer retention. The session-curator skill therefore never needs its own "purge old" mode.

## Line types we care about

### `user` — user prompt or tool result
```json
{"type":"user","message":{"role":"user","content":"<string OR array of blocks>"},"timestamp":"...","sessionId":"...","cwd":"...","uuid":"..."}
```
- `content` is a **string** for plain prompts.
- `content` is an **array of blocks** when it contains `tool_result` blocks (or a mix). Real user text lives in blocks of `type:"text"`. Synthetic wrapper messages (e.g. `<command-name>/exit</command-name>`) start with `<` and should be filtered out of any "what did the user say" extraction.

### `assistant` — assistant turn
```json
{"type":"assistant","message":{"role":"assistant","content":[ <blocks> ]},"timestamp":"..."}
```
Blocks are typed: `text` (visible reply), `thinking` (reasoning, usually hidden), `tool_use` (tool invocation with `name`, `id`, `input`). Concatenate `text` blocks for a "what did the assistant say last" extraction; skip `thinking` unless you really want it.

### `system` — local commands and meta events
```json
{"type":"system","subtype":"local_command","content":"<command-name>/exit</command-name>...","timestamp":"..."}
```
A clean `/exit` is detected by `subtype=="local_command"` + content containing `/exit`. There is **no other documented sentinel** for clean exit vs. crash.

### `custom-title` — rename marker (undocumented)
```json
{"type":"custom-title","customTitle":"<the-name>","sessionId":"..."}
{"type":"agent-name","agentName":"<the-name>","sessionId":"..."}
```
Written when a session is renamed via `/rename`, `Ctrl+R` in the picker, or `claude -n <name>` at startup. **The picker reads the LAST such line.** Confirmed empirically against session `51f02ff0-...` in May 2026. This is the format `Apply-SessionRenames.ps1` writes for batch renames. The format is undocumented; treat as fragile and always back up before mutating.

### `last-prompt` / `mode` / `permission-mode` — bookkeeping
Lightweight metadata lines, no content of interest for the indexer.

## Session rotation on `/clear` (iOS / remote-control)

**Empirical finding 2026-06-01 during smoke test v2.** Originally we assumed `/clear` writes a SessionEnd + SessionStart pair into the same `.jsonl` and the file continues. That's NOT what happens when `/clear` is issued from Claude on iOS or via remote-control:

- The old `.jsonl` receives `queue-operation` events recording the `/clear` and then **goes dormant** — no further writes.
- A **brand-new `.jsonl`** with a fresh session ID is created in the same project folder. All subsequent activity goes there.
- Confirmed twice in the same smoke-test run (sessions `b6448979` → `37f6fc14` → `0f799f16` → `0963c5fb` across three `/clear`s).

Implications:

- A session-curator survey will see N separate sessions for what the user perceives as one continuous conversation interrupted by `/clear`s. The naming-convention subagent should be aware (one user mental-model may map to multiple post-`/clear` siblings).
- The monitor mode MUST watch the project DIRECTORY (FileSystemWatcher on `*.jsonl`), not a single file — confirmed empirically: a single-file tail goes silent the moment `/clear` rotates to a new jsonl. `Watch-Session.ps1` already uses dir-level FSW for exactly this reason.
- Whether the CLI (non-iOS, non-remote-control) shows the same behaviour is not yet verified — needs separate confirmation on a desktop CLI session.
- The `queue-operation` lines written to the old file before rotation are noise and are filtered out by `Watch-Session.ps1`'s formatter (only `user`, `assistant`, `system`+`local_command`, and `custom-title` types are surfaced).

## Fork lineage (parentSessionId)

When a session is created via `claude --fork-session <id>`, the new session's `.jsonl` contains a `parentSessionId` field — but **it is an object**, not a plain string:

```json
"parentSessionId": { "sessionId": "<parent-uuid>", "messageUuid": "<message-uuid>" }
```

Confirmed empirically 2026-05-30 against 3 forked sessions in a personal toolbox project. `Extract-SessionIndex.ps1` flattens this to a plain string id for downstream use.

## Duplicate / fork-chain pattern

When `claude --continue` or the remote-control "continue" path runs in rapid succession, you get N sessions in the same project with the same `firstUser` ("continue") and `parentSessionId` pointing to a common ancestor. They are not bugs — they are fork chains. `Extract-SessionIndex.ps1` groups them in `duplicateGroups[]` so cleanup mode can flag canonical-vs-duplicate.

## What we DON'T parse

- `thinking` blocks (skipped unless `Watch-Session -ShowThinking`)
- Sub-agent jsonls (under `<sessionId>/subagents/agent-<id>.jsonl`) — these are read by Claude itself; the curator doesn't surface them, but the file walker filters them out by directory name.
- The `tasks/` directory (Bash output logs); same filter.
