# claude-code-skills

> A growing collection of **Claude Code** skills, packaged as an installable marketplace.

Install once and Claude Code picks the skill up automatically across all your projects — it triggers on its own when it's relevant.

## Install

```
/plugin marketplace add JuanSombrero23/claude-code-skills
/plugin install session-curator@claude-code-skills
```

## What's inside

| Skill | What it does | Best for |
|---|---|---|
| **session-curator** | Browse, search, clean up, rename, resume, move, and live-monitor your Claude Code sessions across every project | Anyone juggling many sessions who wants to find, revive, or tidy them without digging through raw transcripts |

_More skills will land here over time._

## session-curator

A cross-project session manager. It never loads raw `.jsonl` transcripts into your context — it builds a compact index and works from that. Modes:

- **survey** — cross-project overview of your recent sessions
- **search** — find a past session from a vague description
- **cleanup** — classify finished / junk / open and propose safe deletions
- **rename** — give untitled sessions meaningful names
- **resume** / **continue-from** — jump back into, or fork from, a session
- **move** — relocate a session so you can resume it from a different folder
- **monitor** / **launch** — live-tail a running session, or reopen sessions as terminal tabs

**Example prompts:**
- "what was I working on across all my projects last week?"
- "clean up my sessions — what's junk?"
- "rename my untitled sessions"
- "find that session about the invoice import"

## Walkthroughs

### 1. Recover after a system crash

Your machine rebooted and took a screenful of terminals with it. You don't remember every project you had open. In a fresh Claude Code session:

> "My system crashed — what sessions was I working on right before? Reopen the ones that were still in progress in terminal windows."

What the skill does:

1. **survey** — regenerates a recent index and classifies how each session ended. Sessions that ended on a clean `/exit` are marked *closed*; the ones the crash cut off (no exit marker) show as *open*. It lists those in-progress sessions grouped by project so you can confirm the set before anything reopens.
2. **launch** — opens the sessions you pick as tabs in your current **Windows Terminal** window, each one `cd`'d to the right folder and running `claude --resume <id>`, with the tab re-titled to the session's name. (On macOS/Linux it prints a paste-able `cd "<cwd>"; claude --resume <id>` line per session instead of opening tabs.)

> 💡 Crash recovery works *because* Claude Code never writes a clean-exit marker for an abandoned session — so "what got interrupted" is exactly the set the skill offers to reopen.

### 2. Live-monitor a second session while you build

You're developing a skill or a hook with Claude in session **A**, and you want to test it for real in a separate session **B** — while **A** watches B's every move and audits the behavior as you go.

1. **Make B findable.** Open session B in another terminal and send any first prompt — Claude only writes a session's transcript to disk *after* the first user message, so until then the curator can't see it. Naming it makes lookup instant:
   > `/title hook-test`
2. **Grab B's handle.** Run `/status` in B to read its session id (or just use the title you set in step 1).
3. **Point A at B.** Back in session A:
   > "Monitor my `hook-test` session and audit what the new PreToolUse hook does as I exercise it."

   A resolves B by title (or id), then arms a live tail on B's transcript. Every prompt you send and every tool call Claude makes in B pings session A automatically — no copy-paste, no third terminal. A curates and audits in real time: *"the hook fired and blocked that `Bash` call correctly"*, *"that edit slipped past the guard — bug."*

> 💡 Two things make this click: a **first prompt in B** (so its transcript exists on disk) and B's **title or `/status` id** (so A finds it in one lookup instead of guessing across every project).

## Prerequisites

- **[PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`)** — the skill's scripts are PowerShell, which runs on Windows, macOS, and Linux (one-line install on any OS).
- **Windows Terminal** — only for the optional `launch` and `monitor` modes. The other seven modes work on any OS. Native macOS/Linux launchers are welcome — see [CONTRIBUTING](CONTRIBUTING.md).

## Contributing

New skills and cross-platform improvements are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 JuanSombrero23
