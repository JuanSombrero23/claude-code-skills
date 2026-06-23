---
title: Cross-session observation — Watch-Session.ps1 and alternatives
purpose: Reference for the session-curator skill's `monitor` mode. Explains how the bundled Watch-Session.ps1 works, what its limits are, and which mature community tools the user can swap in if they want a richer UI.
generator: session-curator/references (Phase 3)
generated: 2026-05-31
sources: claude-code-guide subagent (official docs) + general-purpose web research May 2026.
---

# Cross-session monitoring

## The use case

You run Claude Code session A in one terminal (testing a feature) and session B in another terminal (developing the same feature). You want B (or your own eyes in a third terminal) to **follow A's activity in near-real-time** — see A's user prompts, assistant replies, tool calls, tool results as they happen.

## What's officially supported: nothing

- No `/observe`, `/follow`, `/attach` slash commands or CLI flags
- No MCP tool for live session streaming
- No cross-session hook (`PostToolUse` etc. fire only inside the firing session)
- No "linked sessions" or session pairs concept

This is a pure DIY pattern. Two community approaches have matured:

## Pattern A — JSONL tail (what this skill uses)

Tail the running session's `.jsonl` from another process. Works on any session, including ones you didn't start yourself.

The bundled [`scripts/Watch-Session.ps1`](../scripts/Watch-Session.ps1) implements this with:

- **`System.IO.FileSystemWatcher`** on the project directory (not just one file) — event-driven, sub-100ms latency.
- **Persistent `FileStream`** opened with `FileShare.ReadWrite` — never blocks the running Claude process even though it has the file open in append mode.
- **Auto-follow on `--resume`**: when the watched session is resumed, Claude writes to a NEW `.jsonl` in the same project dir. The watcher's `Created` event picks it up and starts tailing the new file too.
- **Line-buffered parser**: each event arrives as one complete `JSON.stringify(...) + "\n"`. The reader buffers partial lines until it sees `\n`, then `try { ConvertFrom-Json } catch { skip }` per line.
- **Pretty formatter**: text-tagged events (`[USER]`, `[ASST]`, `[TOOL <name>]`, `[RESULT]`) with truncated content. Thinking blocks suppressed by default (`-ShowThinking` to show).

### Why NOT `Get-Content -Wait`

It polls every ~1s. It cannot follow `--resume`-rotation. It can hit Windows file-sharing issues. FileSystemWatcher is strictly better for this use case.

### Known limits

- Subagent jsonls (under `<sessionId>/subagents/agent-<id>.jsonl`) are NOT followed by default. You can watch them explicitly by passing the path to `-File`.
- Large `tool_result` blocks with embedded `\n` inside string values are handled correctly (line-oriented reader, not byte).
- `/clear` and `/compact` don't truncate the file — they emit `system` events. The watcher just keeps streaming.

## Pattern B — hook-based push (richer, requires controlling both sessions)

If you control both A and B, you can configure A with `PostToolUse` / `Stop` hooks that push events over HTTP/WebSocket to a dashboard B subscribes to. Higher fidelity (carries intent + result, not just transcript text), bigger setup.

**Canonical reference**: `disler/claude-code-hooks-multi-agent-observability` on GitHub. Recommended only if the JSONL tail proves insufficient.

## Mature community alternatives (drop-in replacements for `Watch-Session.ps1`)

If `Watch-Session.ps1` is too plain and you want a TUI / web dashboard:

| Tool | Language | Strength |
|---|---|---|
| `delexw/claude-code-trace` | TS / desktop | TUI + web + desktop, explicit "live tail sessions" feature |
| `kylesnowschwartz/tail-claude` | Go | Bubble Tea TUI, closest to literal `tail -f` |
| `NirDiamant/claude-watch` | TBD | live dashboard |
| `daaain/claude-code-log` | various | mostly post-hoc, some live |

Install one of these and the skill's `monitor` mode can print its command instead — UX stays the same (skill prints the command, the user pastes it in another terminal). The skill should not assume any of them is installed; check on first run if the user asks for the richer UX.

## When to use which

| Situation | Use |
|---|---|
| Quick "what's it doing right now" peek, no setup | `Watch-Session.ps1` (default) |
| Long sessions, lots of activity, want filtering/search UI | Install `claude-code-trace` or `tail-claude` |
| Want to record events with tags/notes for later review | Install disler's hook dashboard |
| Want to also see THINKING blocks | `Watch-Session.ps1 -ShowThinking` |
| Want to see raw jsonl for debugging | `Watch-Session.ps1 -Raw` |
