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

## Prerequisites

- **[PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`)** — the skill's scripts are PowerShell, which runs on Windows, macOS, and Linux (one-line install on any OS).
- **Windows Terminal** — only for the optional `launch` and `monitor` modes. The other seven modes work on any OS. Native macOS/Linux launchers are welcome — see [CONTRIBUTING](CONTRIBUTING.md).

## Contributing

New skills and cross-platform improvements are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 JuanSombrero23
