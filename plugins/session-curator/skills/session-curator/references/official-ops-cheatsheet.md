---
title: Official Claude Code session operations — what works, what doesn't
purpose: Quick lookup for the session-curator skill when it needs to decide between an official command and a DIY operation.
generator: session-curator/references (Phase 3)
generated: 2026-05-31
sources: code.claude.com/docs/en/sessions.md, code.claude.com/docs/en/cli.md, code.claude.com/docs/en/hooks.md (queried via claude-code-guide subagent May 2026).
---

# Official Claude Code session ops

Status legend: ✅ supported / 🟡 partial / ❌ not supported.

## Rename a session — ✅
- In-session: `/rename <name>`
- In picker: `Ctrl+R`
- At startup: `claude -n <name>`
- On disk: appends two undocumented lines (`type:custom-title` and `type:agent-name`) to the session's `.jsonl`. See [jsonl-format.md](jsonl-format.md#custom-title-—-rename-marker-undocumented).
- For batch rename of CLOSED sessions, this skill bypasses the slash command and writes the same two lines directly. Always back up first. See [`scripts/Apply-SessionRenames.ps1`](../scripts/Apply-SessionRenames.ps1).

## Delete a session — 🟡
- `claude rm <id>` — **background sessions only.** Removes them from the active-list; the `.jsonl` stays on disk.
- `claude project purge [path]` — nuclear: wipes ALL local state for a project (transcripts, tasks, debug logs).
- No official per-interactive-session delete. The practical operation is `Remove-Item` the `.jsonl`.

## Archive a session — ❌
Not exposed in the Claude Code CLI at all. The right-click Archive in Claude Desktop is a Desktop-side metadata flag, doesn't touch the CLI's session files. This skill **does not implement archive**; auto-cleanup at 30 days (see retention below) already handles "stuff disappearing on its own."

## List sessions across all projects — 🟡
- Interactive only: `claude --resume` then `Ctrl+A` (all projects) or `Ctrl+W` (all worktrees).
- Non-interactive: `claude agents --json` lists **background sessions only**.
- For interactive sessions across projects, parsing `~/.claude/projects/*/*.jsonl` directly is the only path. This is what [`scripts/Extract-SessionIndex.ps1`](../scripts/Extract-SessionIndex.ps1) does.

## Resume a session — ✅
- Picker: `claude --resume` (current project) or `Ctrl+A` (all)
- Direct: `claude --resume <sessionId>` or `claude -r <sessionId>` — jumps straight in, works from ANY cwd
- Most recent in this dir: `claude --continue` / `-c`

## Fork a session — ✅
- `claude --fork-session <id>` creates a new session branched from `<id>` at the latest message.
- New session's `.jsonl` writes a `parentSessionId` field (object form — see [jsonl-format.md](jsonl-format.md#fork-lineage-parentsessionid)).
- Useful for "continue-from" mode when the prior session ended cleanly.

## Continue from a crashed session — ❌ (no official mechanism)
- No documented sentinel distinguishes a clean `/exit` from a crash.
- `--fork-session` works **only on cleanly-stored sessions**; if the prior session crashed mid-tool-call, the .jsonl may end on a partial event and fork may fail.
- DIY: extract the prior session's last state into a one-paragraph primer, paste into a fresh `claude` invocation.

## Retention / auto-cleanup — ✅
- Default: transcripts auto-deleted after **30 days**.
- Config: `cleanupPeriodDays` in `~/.claude/settings.json`. Set higher (e.g. 90) for longer history.
- Disable: `CLAUDE_CODE_SKIP_PROMPT_HISTORY=1` env var or `--no-session-persistence` flag (then sessions aren't written at all).

## Hooks relevant to session lifecycle
- **SessionStart** fires on `startup`, `resume`, `clear`, `compact`. Can inject context.
- **SessionEnd** fires on `clear`, `resume`, `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other`. **Does NOT fire on crashes.** No hook distinguishes clean exit from abandonment.
- No `MessageReceived` / cross-session hook. Cross-session observation must use file-tailing (see [monitoring.md](monitoring.md)).
