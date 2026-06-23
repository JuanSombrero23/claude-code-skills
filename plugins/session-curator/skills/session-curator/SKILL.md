---
name: session-curator
description: >
  Cross-project Claude Code session browser, cleaner, renamer, mover, and
  monitor. Triggers when you ask to survey, search, clean up, rename, resume,
  continue-from, move/relocate, live-monitor, monitor, or monitor sessions across your
  ~/.claude/projects/ folders. Also covers crash-recovery, fork-lineage, and
  junk/duplicate detection. Always prefer this skill over reading raw .jsonl
  files directly — it keeps transcripts out of the main conversation context.
---

# session-curator

A cross-project browser, cleaner, renamer, monitor, and crash-recovery helper
for Claude Code sessions. Operates across every `.jsonl` transcript under
`~/.claude/projects/*/`, not just the current project.

## Invocation rules — read this BEFORE running any script

This skill's scripts live under `~/.claude/skills/session-curator/scripts/`. Two rules govern how to invoke them. **Get either wrong and the call fails** (witnessed in smoke tests v1 and v2):

### Rule 1: ALWAYS use the **PowerShell tool**, NEVER the Bash tool

The scripts are `.ps1` files and rely on PowerShell-style environment variables. The **Bash tool** on Windows is Git Bash — it does NOT understand `$env:USERPROFILE` (it sees `$env` as an empty variable, leaving the literal string `:USERPROFILE\...` which fails with "argument not recognized as the name of a script file"). Use the **PowerShell tool** instead. Every invocation in this skill should go through PowerShell.

### Rule 2: Do NOT use `~` in the path argument

PowerShell does NOT expand `~` inside string arguments to `pwsh -File` (only inside cmdlets like `Set-Location`). Use `$env:USERPROFILE` with Windows separators, double-quoted:

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\session-curator\scripts\Extract-SessionIndex.ps1" -Days 21
```

If `$env:USERPROFILE` for any reason fails (you accidentally invoked via Bash, or some other reason), the fallback is to resolve the absolute path from the home directory yourself — e.g. ``"$HOME/.claude/skills/session-curator/scripts/<script>.ps1"`` — rather than hardcoding a username. Use it only as a last resort.

Documentation and narrative file references elsewhere in this skill (e.g. "see `~/.claude/skills/session-curator/.session-index.json`") still use `~` for human readability — only the actual `pwsh -File ...` invocations need the `$env:USERPROFILE` form. The script bodies themselves resolve `$HOME` correctly; the issue is purely about the **path argument** passed to `pwsh -File` from outside.

## Core principle: never load raw `.jsonl` into the main context

Session transcripts are big and unbounded. If this skill loaded them into the
main conversation, it would burn your context window for no benefit. Instead:

1. The helper script [`scripts/Extract-SessionIndex.ps1`](scripts/Extract-SessionIndex.ps1)
   parses every recent `.jsonl` into a **compact JSON index** at
   `~/.claude/skills/session-curator/.session-index.json`. One file, overwritten
   per run — see its `_meta` block for the schema.
2. The skill (this file) and any subagents it launches read the **compact JSON**,
   never the raw `.jsonl`.
3. Sub-tasks that need deeper interpretation (topic inference, junk
   classification, naming proposals) are delegated to **subagents** that
   receive only the slice of the index they need and return only their verdicts.

Treat this as the prime directive. If you're about to `Read` a session `.jsonl`
file from the main loop, stop and use the index instead. If a session needs
deep inspection, spawn a subagent.

## When this skill triggers

Use it whenever the user mentions:

- "what was I working on last week", "show me recent sessions", "what did I do across all my projects"
- "find that session about X", "where did we discuss Y", "I started a session about Z somewhere"
- "clean up my sessions", "what's junk", "what can I delete", "I have too many sessions"
- "rename my sessions", "give my untitled sessions proper names"
- "resume that thing about X", "pick up session abc123"
- "continue from session X in a new one", "fork from where session Y stopped", "that session crashed, start fresh from there"
- "move that session to the right project", "this session got opened in the wrong folder", "relocate session X so I can resume it from <other cwd>", "fork in place won't work, just move it"
- "watch the session in my other terminal", "follow what the other agent is doing in the other window", "tail session X"
- "open my sessions in tabs", "reopen everything from today", "launch these sessions in my terminal", "open them as tabs"

Also use it any time the user asks Claude to look at past sessions, even if they
don't name the operation. Default to surveying when intent is unclear.

## Nine modes

| Mode | What it does |
|------|--------------|
| [survey](#survey-mode) | Cross-project overview of the last N days with AI summaries |
| [search](#search-mode) | Find a specific past session by leads the user gives |
| [cleanup](#cleanup-mode) | Classify finished / junk / open; propose deletions the user approves per batch |
| [rename](#rename-mode) | Propose customer-topic-action names for untitled sessions; optionally apply in batch |
| [resume](#resume-mode) | Print the exact `claude --resume` command + a "where you were" briefing |
| [continue-from](#continue-from-mode) | Fork (when possible) or generate a primer for a fresh session |
| [move](#move-mode) | Relocate a session's files to a different project folder so `claude --resume` picks it up from a new cwd |
| [monitor](#monitor-mode) | Emit a paste-able command that tails another session's `.jsonl` live |
| [launch](#launch-mode) | Open chosen sessions as tabs in your current Windows Terminal window |

## Common workflow (every mode)

1. **Ensure the index is fresh.** Read `_meta.generated` from `.session-index.json` FIRST — do not skip this check. Regenerate ONLY if missing or older than 5 minutes; otherwise reuse. Smoke test v2 caught a redundant regen on a 3-min-old index because this check was skipped. Quick check:
   ```powershell
   $idx = "$env:USERPROFILE\.claude\skills\session-curator\.session-index.json"
   if (-not (Test-Path $idx) -or ((Get-Date) - (Get-Content $idx -Raw | ConvertFrom-Json)._meta.generated).TotalMinutes -gt 5) {
       pwsh -File "$env:USERPROFILE\.claude\skills\session-curator\scripts\Extract-SessionIndex.ps1" -Days 21
   }
   ```
   Use a wider window (`-Days 90`) only if the user explicitly asks for older sessions
   AND they have bumped `cleanupPeriodDays` in `settings.json` past 30. Otherwise
   anything older than 30 days has been auto-cleaned by Claude itself —
   see [`references/official-ops-cheatsheet.md`](references/official-ops-cheatsheet.md).

2. **Read the index from disk.** Never `cat` or `Read` the raw `.jsonl` files.

   Each entry in `sessions[]` carries exactly these fields — use them verbatim, do NOT guess synonyms (smoke test v2 caught a subagent improvising `lastMtime`, which doesn't exist):

   | Field | Type | Notes |
   |---|---|---|
   | `id` | string | Full session UUID |
   | `file` | string | Absolute path to the `.jsonl` |
   | `cwd` | string | Working directory recorded *inside* the transcript. **GOTCHA: may differ from the folder the `.jsonl` lives in if cwd drifted mid-session — and `claude --resume` scopes by the folder, not this field. Verify before building any `cd "<cwd>"; claude --resume` command (resume/continue-from/move/launch all rely on it). See the cwd-drift landmine in [launch mode](#launch-mode).** |
   | `gitBranch` | string | Branch at start, may be empty |
   | `customTitle` | string\|null | `/rename` title; null = untitled |
   | `mtime` | ISO datetime | Last write — **`mtime`, not `lastMtime`** |
   | `sizeKb` | number | File size in KB |
   | `userCount` / `assistantCount` | number | Message counts |
   | `firstUser` / `lastUser` / `lastAssistant` | string | Truncated to ≤600 chars |
   | `lastLineType` | string | `user` / `assistant` / `system` / `custom-title` / ... |
   | `endedWithExit` | bool | True if last line is `/exit` local_command |
   | `parentSessionId` | string\|null | Flattened from fork object; null if not forked |
   | `temporal` | object\|null | `{firstActivity, lastActivity, activeMinutes, daysSpan, intensity, rhythm}` — may be null on very short sessions |

   Top-level index also has `_meta` (provenance), `duplicateGroups[]`, and `forks[]`. Always read the `_meta.generated` timestamp before using the index — regenerate if >5 minutes old (per step 1).

3. **Filter and dispatch.** Slice the index to the relevant subset (recent N,
   matching a search lead, missing custom title, etc.). For tasks that need
   judgment (topic inference, junk classification, naming), launch a subagent
   and pass it only the slice — not the whole index.

4. **Report to the user: overview table, then resume commands as standalone code
   blocks.** Use a markdown table for the scannable columns only —
   `When | Project | Topic | Status`. **Never put the resume command in a table
   cell** — table cells wrap long paths and break copy-paste (confirmed live
   2026-06-10: a table-cell resume command dropped its leading character on copy,
   so the resume failed with "No sessions match"). Instead, render resume
   commands per the [Output conventions](#output-conventions): each one its own
   standalone fenced code block, on its own line, no line breaks inside, directly
   under a short description line naming the session. The command **must `cd` to
   the session's `cwd` first** so the resumed session lands in the right folder
   (paths, git context, and project CLAUDE.md all resolve from cwd). Canonical
   form, the `cwd` double-quoted (it often contains spaces, e.g. a
   `OneDrive - Acme Corp` path):

   **<short description naming the session>**
   ```
   cd "<cwd>"; claude --resume <fullId>
   ```

   If a session's `cwd` is empty in the index, fall back to a bare
   `claude --resume <fullId>` (still its own code block) and note the cwd was unknown.

5. **For mutating ops (rename, delete):** never act without explicit confirmation
   from the user per batch. Show the proposal, ask "apply these N? (yes/no/edit)",
   then proceed.

## Survey mode

**Trigger phrases:** "what did I do last week", "show me recent sessions",
"cross-project overview", "what was I working on across everything".

**Steps:**
1. Regenerate index with the requested window (default 21 days, override via the user's words).
2. Group sessions into ~20-session batches by project. For each batch, launch a
   subagent with this prompt:
   > Here are N session summaries from `<project>` covering the last <window>
   > days. For each, return one JSON line: `{id, topic, status, where_stopped}`.
   > - `topic`: 5-10 words describing what the session was actually about,
   >   using session content (not cwd) as the authority — see
   >   [`references/naming-convention.md`](references/naming-convention.md)
   >   for the customer-content-cwd reasoning.
   > - `status`: "completed" / "in-progress" / "abandoned" / "junk" per
   >   [`references/junk-heuristics.md`](references/junk-heuristics.md).
   > - `where_stopped`: 5-10 words describing what was happening at the last
   >   timestamp — used by the user to remember what to pick up.
   > Return ONLY the JSON lines, no commentary.
3. **Collect the subagent verdicts** into a single NDJSON file (one JSON line per session) at a temp path, e.g. `$env:TEMP\session-curator-verdicts.ndjson`. Do not improvise inline PowerShell formatters — that path led to `"Missing ')'"` errors in smoke test v1.
4. **Render the canonical markdown via the helper script** — do NOT improvise inline PowerShell to build the table:
   ```powershell
   pwsh -File "$env:USERPROFILE\.claude\skills\session-curator\scripts\Format-SurveyMarkdown.ps1" `
        -VerdictsFile "$env:TEMP\session-curator-verdicts.ndjson" `
        -Window 21 `
        -OutputFile "$env:USERPROFILE\.claude\skills\session-curator\.last-survey.md"
   ```
   The helper produces the canonical scannable table (When | Project | Topic | Status — no resume column) followed by a "Resume commands" section where each session's command is a standalone fenced code block under its own description line, plus a per-project breakdown, status histogram, and an "open threads worth picking up" section (each with its resume command as a standalone code block). It writes the file AND prints a confirmation line. Read the file back if you need to surface a section into chat.
5. Highlight any sessions in `duplicateGroups` with a "dup of {canonical}" marker when reporting in chat. The helper file already flags the duplicate-group count in its footer.
6. If the user asked for a window > 21 days, remind them about `cleanupPeriodDays` and
   point to [`references/official-ops-cheatsheet.md`](references/official-ops-cheatsheet.md#retention--auto-cleanup--).

**Output to chat:** the table + a 2-line summary ("47 sessions across 8 projects.
Most active: acme-reporting (4 sessions, 12h active). 3 untitled sessions —
say 'rename them' to clean up.").

**Optional artifact:** if the user asks "save it" or "give me a file", also write
the rendered markdown to `~/.claude/skills/session-curator/.last-survey.md` —
include a top YAML frontmatter with `generator`, `generated`, `window`,
`sessionCount`, and a `safeToDelete: Yes — regenerated on next survey.`

## Search mode

**Trigger phrases:** "find that session about X", "where did we discuss Y",
"I started something about Z, where is it".

**Steps:**
1. Regenerate (or reuse fresh) index.
2. Launch ONE subagent with the index + the user's search lead:
   > The user is looking for a past session. Their lead: `<lead>`. Here is the session
   > index. Score each session by relevance to the lead, considering: customTitle,
   > firstUser, lastUser, lastAssistant, cwd. Return the top 5 as JSON:
   > `[{id, why, confidence}]`. Be honest about low confidence.
3. Show the user the top 5 in a table with `When | Project | Why this match` — then
   print each match's resume command as a standalone fenced code block beneath
   the table, per [Output conventions](#output-conventions) (never in a table cell).
4. If confidence on all 5 is low, suggest expanding the window or refining the lead.

## Cleanup mode

**Trigger phrases:** "clean up my sessions", "what can I delete", "what's junk",
"audit my session list".

**Steps:**
1. Regenerate index.
2. Launch a subagent with the full index + the rules in
   [`references/junk-heuristics.md`](references/junk-heuristics.md):
   > Classify each session as junk / finished / open per the heuristics file.
   > Return one JSON line per session: `{id, verdict, confidence, reason, proposedAction}`.
3. Group results by verdict. Show the user:
   - JUNK (N sessions) — propose delete, list with one-line reason each
   - FINISHED (N sessions) — leave alone, just FYI count
   - OPEN (N sessions) — leave alone, FYI count
4. For the JUNK list, ask: "Delete these N? (yes / no / pick which)". On yes:
   `Remove-Item` each `.jsonl`. NEVER auto-delete without confirmation.
5. Always exclude from delete proposal:
   - Sessions with `customTitle` set (the user invested in naming → they care)
   - Sessions modified within the last 10 minutes (live-session protection)

## Rename mode

**Trigger phrases:** "rename my sessions", "give my untitled sessions proper names",
"clean up the session list with real names".

**Steps:**
1. Regenerate index.
2. Filter to sessions where `customTitle` is null AND `userCount > 1` AND
   not in the JUNK verdict from cleanup heuristics.
3. Launch a **single** subagent with that slice + [`references/naming-convention.md`](references/naming-convention.md):
   > Propose a customer-topic-action slug for each session. Read the naming
   > convention spec. Critical: customer is inferred from session CONTENT first;
   > cwd is a fallback hint. Flag `cwdMismatch: true` on any session where the
   > inferred customer differs from cwd. Return JSON per session as specified in
   > the spec.

   **Why a single subagent here, not parallel batches like survey mode uses?**
   Naming benefits from a global view that per-session classification does not:
   - **Slug uniqueness.** Two parallel subagents with no cross-batch awareness
     can propose identical slugs for different sessions (e.g. both batches
     producing `acme-reporting-debugging`). One agent seeing all candidates
     avoids collisions naturally.
   - **Stylistic consistency.** A single agent settles on one convention
     (e.g. always `acme-x-y`, never mixing `acme_x_y`). Parallel batches drift.
   - **Trade-off.** Single agent is sequential — ~1-2 min for ~40 sessions vs
     ~20-30s parallel. Acceptable at this scale. For 100+ candidates, switch
     to parallel-N + a post-merge dedup/normalize pass. The complexity isn't
     worth it below ~80.

   The pre-filtered slice (truncated `firstUser`/`lastUser`/`lastAssistant`
   already ≤600 chars per `Extract-SessionIndex.ps1`) keeps the subagent's
   context bounded — ~50KB for 40 sessions, never the raw `.jsonl` MBs. Prime
   directive holds for the subagent too.
4. **Render the proposal table via the helper script** — do NOT improvise inline `node -e` or PowerShell to build the table (smoke test v2 hit `${p.newTitle}` bash-substitution bugs and path-concat bugs going this route):
   ```powershell
   pwsh -File "$env:USERPROFILE\.claude\skills\session-curator\scripts\Format-ProposalsTable.ps1" `
        -CandidatesFile "$env:TEMP\session-curator-rename-candidates.json" `
        -ProposalsFile  "$env:TEMP\session-curator-rename-proposals.json"
   ```
   The helper emits the markdown table (`When | Project | Proposed name | Conf | Mismatch | Reason`) plus a per-customer breakdown and YAML frontmatter. Highlight `Mismatch=Y` rows so the user can sanity check the customer inference.
5. Ask: "Apply these N? (yes — direct write / show /rename commands instead /
   pick which / no)". 
   - On **direct write**: write proposals to a temp JSON, invoke
     `Apply-SessionRenames.ps1 -ProposalsFile <temp> -Apply`. The script accepts
     either a **bare array** `[{id, file, newTitle, ...}, ...]` or a **wrapped object** `{proposals: [...]}` — both work, no need to wrap. Handles backups,
     the 10-minute live-session guard, and the 30-day backup retention.
     Report success/skip counts.
   - On **show commands**: print one `/rename <newTitle>` line per session.
     The user pastes them after resuming each.
6. Reference [`references/official-ops-cheatsheet.md`](references/official-ops-cheatsheet.md#rename-a-session-)
   if the user asks how the on-disk rename actually works.

## Resume mode

**Trigger phrases:** "resume that thing about X", "pick up session abc123",
"jump back into <description>".

**Steps:**
1. If the user gave an `<id>` or `<id-prefix>`, look it up directly in the index.
2. If the user gave a description, run [Search mode](#search-mode) silently and pick
   the top result (or ask "did you mean A or B?" if confidence is split).
3. Print:
   - The exact resume command as a **standalone fenced code block** on its own
     line (per [Output conventions](#output-conventions)), `cd`-ing to the
     session's `cwd` first:
     ```
     cd "<cwd>"; claude --resume <fullId>
     ```
   - A 3-bullet "where you were" briefing pulled from the session's
     `firstUser`, `lastUser`, `lastAssistant` plus the temporal rhythm string.
   - One line of "what was probably next" if `lastAssistant` ended with a question
     to the user.

## Continue-from mode

**Trigger phrases:** "continue from session X in a new one", "fork from session Y",
"that session crashed, pick it up in a fresh window".

**Hybrid strategy:**
1. **Try official fork first.** If the prior session ended cleanly (no `endedWithExit`
   sentinel ≠ crashed; presence is fine), print:
   ```powershell
   claude --fork-session <id>
   ```
   and a one-line "this opens a branched session from the latest message of X".
2. **Fall back to primer-paste** if the user reports the fork fails OR if the prior
   session's `lastLineType` suggests a mid-tool-call crash. Generate a primer
   they can paste into a fresh `claude` invocation:
   > Continuation of session `<id>` (`<customTitle or topic>`).
   > **Goal so far:** <distilled from firstUser + assistant turns>
   > **What was being attempted at cutoff:** <from lastUser + lastAssistant>
   > **Any open questions Claude asked the user:** <if lastAssistant ended with ?>
   > **Files / commands in flight:** <if last few tool_uses were edits or bash>
3. For the primer path, route the distillation through a subagent so the raw
   transcript stays out of the user's main context. The subagent receives the
   relevant index entry plus a request to fetch the last ~10 messages from the
   raw `.jsonl` IF NEEDED — the subagent reads the raw file, the user's main context
   gets only the primer.

## Move mode

**Trigger phrases:** "move that session to the right project", "this session
got opened in the wrong folder", "relocate session X to <project>", "I want
to resume this in a different cwd", "fork in place won't work, just move the
session".

**One-line rationale:** `claude --resume` and `--fork-session` scope by
encoded cwd folder name only; physically copying the `.jsonl` + sidecar into
the destination project folder makes it resumable from a new cwd.
Background, the encoded-cwd convention, the full what-moves table, and the
3 known landmines: [`references/move-mode.md`](references/move-mode.md) —
read this BEFORE offering the operation so the plan you show the user includes the
right warnings.

**What moves vs what doesn't (quick reference, see move-mode.md for notes):**

| Item | Move? |
|---|---|
| `<sessionId>.jsonl` | YES |
| `<sessionId>/` sidecar folder | YES |
| `<project>/memory/*.md` (per-project auto-memory) | Cherry-pick only |
| Plans / CLAUDE.md hierarchy / shell snapshots | NO |

**Steps:**

1. **Identify the session** (by id, lead, or interactive pick from the index).
   If the user only gave a description, run [Search mode](#search-mode) silently.
2. **Identify the destination cwd.** Ask the user if not explicit. Compute the
   encoded folder name (replace every non-alphanumeric with `-` — see
   `references/move-mode.md` for the worked example). The destination project
   folder may not exist yet; pre-creating it is fine.
3. **Show the migration plan** to the user, including the landmines from
   `references/move-mode.md`. Confirm before touching anything.
4. **Copy (never move) the session unit.** Leave originals as fallback:
   ```powershell
   $src = Join-Path $HOME ".claude/projects/<source-encoded>"
   $dst = Join-Path $HOME ".claude/projects/<dest-encoded>"
   Copy-Item (Join-Path $src "<sid>.jsonl") -Destination $dst
   Copy-Item (Join-Path $src "<sid>")       -Destination $dst -Recurse  # sidecar folder
   ```
5. **Memory cherry-pick** (only if source `memory/` has files beyond
   `MEMORY.md`). Read `<src>/memory/MEMORY.md`. Launch ONE subagent with the
   moved session's index entry + the MEMORY.md descriptions; prompt:
   classify each file as `must-have | probably | skip` for the moved
   session's focus, return `[{file, tier, reason}]`. Present a tiered table
   to the user, confirm, copy approved files into `<dst>/memory/`, and write a
   fresh `MEMORY.md` indexing ONLY the copied files (do NOT copy the source
   `MEMORY.md` verbatim).
6. **Hand the user the sanity-check list** to run after `claude --resume` in the
   destination cwd:
   - `pwd` in a Bash call returns the destination cwd
   - File reads default to the destination project
   - `/memory` shows the destination project's CLAUDE.md chain
   - "Open auto-memory folder" (item 7 in `/memory`) shows only the
     cherry-picked entries
7. **Cleanup of source** is offered ONLY after the user confirms the resumed
   session is clean. Delete the source jsonl + sidecar folder. Do NOT delete
   the source `memory/` folder — it belongs to the source project.

**Do NOT auto-apply.** Per-batch confirmed, like rename and delete. Always
copy-then-verify-then-delete, never move directly.

## Monitor mode

**Trigger phrases:** "watch the session in my other terminal", "follow what
the other agent is doing over there", "tail session X", "let me see what's happening
in that other window".

**Steps:**

1. **Ask the user for the session name first** — unless they already gave an id,
   id-prefix, or distinctive description. Use `AskUserQuestion` with one
   free-text-friendly question:
   > What's the custom title of the session you want to monitor? (run `/title`
   > in the other window if you haven't given it one — the title makes lookup
   > instant.)

   Why ask first: monitor mode runs while the user has an active terminal open
   somewhere. A custom title lookup is O(1) against the index; description-
   based search burns a subagent round-trip and might still ambiguous-match.
   The `/title` nudge is a one-shot habit-builder.

2. **Remind the user that the session must have sent at least one user prompt**
   before its `.jsonl` exists on disk. Mention this BEFORE running the
   lookup if the index regen finds nothing matching the title, OR proactively
   on the very first monitor-mode invocation per conversation. Phrasing:
   > Heads up — Claude Code only writes the session's `.jsonl` after the
   > first user message lands. If you just opened the window and haven't
   > typed anything yet, send any first prompt in the other terminal
   > (`/title my-test-session` counts), then come back.

3. **Regenerate the index with `-Days 1`** (recent-only — monitor targets are
   by definition live sessions). Do not use the default 21-day window here;
   it wastes scan time on cold sessions. If the title doesn't match within
   1 day, only then widen to 3 days before falling back to description
   search.

4. **Resolve the target session.** Lookup priority:
   a. Exact `customTitle` match (case-insensitive)
   b. `customTitle` regex / substring match
   c. Id or id-prefix
   d. Fall back to description-based [Search mode](#search-mode) only if a–c
      all miss

   If still nothing: re-issue the "first prompt is needed" reminder from
   step 2 — this is the most common cause of an empty result.

5. **DEFAULT — arm the Monitor tool against the skill's bundled tail
   script.** This is what the user wants when they say "monitor session X":
   *push notifications into this chat as the other session ticks*, with
   no paste, no extra terminal, and no in-chat polling needed. The skill
   ships [`scripts/Tail-SessionForMonitor.ps1`](scripts/Tail-SessionForMonitor.ps1)
   specifically for this — it filters the raw `.jsonl` stream down to one
   stdout line per meaningful event (`[USER]` / `[ASST]` / `[TOOL]` / `[SYS]`),
   tool_result noise suppressed.

   Resolve the `.jsonl` absolute path from the index entry (`sessions[].file`),
   then call the Monitor tool. Build the script path from `$HOME` so it resolves
   on any OS (single-quote the whole pwsh `-Command` so `$HOME` is expanded by
   pwsh, not the outer shell):
   ```
   Monitor(
     description: "<customTitle> session events",
     persistent: true,
     timeout_ms: 3600000,
     command: 'pwsh -NoProfile -Command "& (Join-Path $HOME ''.claude/skills/session-curator/scripts/Tail-SessionForMonitor.ps1'') -File ''<absolute path to jsonl>''"'
   )
   ```
   Tell the user one line: "Monitor armed — your next prompt in `<title>` pings
   me automatically." Then keep working on whatever else is queued. Events
   arrive on their own schedule; respond as they land.

   **Context-hygiene reminder:** even with the filter, never echo the raw
   event stream verbatim into chat. Summarize: "you typed `<prompt>`,
   other-Claude called `Bash` and got blocked by the catalog-first hook"
   beats pasting 8 raw lines.

6. **Fallback — in-chat polling read.** Only when Monitor is unavailable
   (deferred-tools session that didn't load it, or the user explicitly asks
   "don't push, just look on demand"). Read the `.jsonl` directly, render
   the recent tail as a `| Time | Tag | Body |` table, and offer "say
   'what's new' for the next delta." Track last-read timestamp in
   conversation memory.

7. **Desktop-window fallback** — ONLY if the user explicitly asks for a second
   terminal ("open a live tail in another window"). Use `Start-Process
   -NoExit` to launch [`scripts/Watch-Session.ps1`](scripts/Watch-Session.ps1):
   ```powershell
   Start-Process -FilePath pwsh -ArgumentList @(
     '-NoExit', '-NoProfile',
     '-File', "$env:USERPROFILE\.claude\skills\session-curator\scripts\Watch-Session.ps1",
     '-SessionId', '<id>'
   ) -WindowStyle Normal
   ```

8. **Richer UI alternatives** ([`references/monitoring.md`](references/monitoring.md))
   — claude-code-trace, tail-claude, disler's hook dashboard — only when
   the user signals they want a persistent dashboard outside chat.

## Launch mode

**Trigger phrases:** "open my sessions in tabs", "reopen everything from today",
"launch these sessions in my terminal", "open them as tabs".

This mode assumes Claude runs inside **Windows Terminal**. The skill can
open chosen sessions directly as **tabs in the current WT window** — each tab
pointed (via wt's `-d`) at the session's cwd and running `claude --resume <id>`.
Claude Code re-titles each tab to the session's custom name on load. (Launch and
monitor modes are Windows-first; see the cross-platform note at the end of this
section.)

**Steps:**
1. Ensure the index is fresh (per common workflow).
2. Decide WHICH sessions to open. Do NOT bulk-open everything by default — apply
   the resume-readiness filter (see [Output conventions](#output-conventions)):
   skip clean-ended sessions, propose the open + deferred ones, confirm the set.
3. **Open one test tab first** on the first launch of a conversation, so the user
   confirms it lands in the current window (not a new one). Then open the rest.
4. Invoke the bundled launcher (it reads cwd + title from the index by id/prefix):
   ```powershell
   pwsh -File "$env:USERPROFILE\.claude\skills\session-curator\scripts\Open-Sessions.ps1" -Ids <id1>,<id2>,<id3>
   ```
   Add `-DryRun` to print the `wt` calls without launching.

**wt.exe quoting landmine (confirmed live 2026-06-10):** do NOT build the `wt`
call with PowerShell's `--%` token or one interpolated string — the quotes leak
into wt's `-d` value and produce an invalid doubled path
(`<home>\"<home>""`, error 0x8007010b: the tab opens but no shell
launches). `Open-Sessions.ps1` splats a string[] to `& wt.exe @args` instead, and
uses `-d <dir>` (never `cd ...;`) so wt's `;` command-splitting can't fire. Prefer
the script over hand-rolling a `wt` command.

**Detecting WT is unreliable from the tool shell.** `$env:WT_SESSION` read inside
the PowerShell/Bash tool's spawned shell came back EMPTY even though the user WAS in
Windows Terminal (the tool shell doesn't inherit the terminal env, and
ParentProcessId is PID-reuse-noisy). Do NOT conclude "no tabs" from that signal —
ask the user or check their latest screenshot. If they're genuinely in a plain conhost
window, fall back to one window per session via `Start-Process pwsh -ArgumentList
'-NoExit','-Command',"claude --resume <id>"`.

**cwd-drift landmine — the index `cwd` can point to the wrong folder for resume
(confirmed live 2026-06-23, mass crash-recovery of 12 tabs).** `claude --resume
<id>` finds a session ONLY when the current directory's encoded folder name
matches the `~/.claude/projects/<encoded>/` folder the `.jsonl` physically lives
in. But the index's `cwd` field is read from *inside* the transcript and reflects
the cwd at the moment sampled — if Claude or the user `cd`-ed mid-session, that drifts
away from the creation folder. `Open-Sessions.ps1` opens the tab with `-d <index
cwd>`, so a drifted session launches in the wrong dir and resume fails with **"No
conversation found with session ID: <id>"**, dropping to a bare pwsh prompt
(symptom: a tab titled `pwsh in <leaf>` instead of the session name). Only the
drifted session fails; siblings are fine. Pre-flight check before launching a
recovery set — encode each session's recorded cwd and compare to its real folder:
```powershell
$enc    = ($s.cwd -replace '[^A-Za-z0-9]','-')           # encode recorded cwd
$folder = Split-Path (Split-Path $s.file -Parent) -Leaf   # actual project folder
if ($enc -ne $folder) { '<id> will fail to resume from its index cwd' }
```
For a mismatch, the correct resume dir is the **decoded project folder**, not the
index `cwd`. Recover it from a sibling session sharing the same folder (its
recorded `cwd` is the real path), then open the tab there directly:
```powershell
$wtArgs = @('-w','0','new-tab','--title','<title>','-d','<real folder path>',
            'pwsh','-NoExit','-Command','claude --resume <fullId>')
& wt.exe @wtArgs
```
The clean fix (deferred 2026-06-23) is to have `Open-Sessions.ps1` / the index
derive a `resumeCwd` from the project folder rather than the in-transcript `cwd`.

## Output conventions

- **Always** use markdown tables for the scannable overview of a multi-session
  report — `When | Project | Topic | Status`. **Never put a resume command
  inside a table cell** — cells wrap long paths and break copy-paste.
- **Always** print resume commands as **standalone fenced code blocks** — one
  command per block, on its own line, with no line breaks inside the command,
  directly under a short description line naming the session — so the whole line
  copies cleanly in one click. Never inside a table cell, never inline mid-prose.
  The command `cd`s to the session's `cwd` (double-quoted) then resumes by full
  UUID:

  ```
  cd "<cwd>"; claude --resume <fullId>
  ```

  The `cd` is mandatory so the resumed session opens in the correct folder. Only
  when `cwd` is empty in the index, fall back to a bare `claude --resume <fullId>`
  (still its own standalone code block) and say cwd was unknown.
- **Never** include emojis.
- **Never** print more than 5 sessions in chat without grouping or paginating
  — for larger outputs ("survey of 80 sessions"), report top 10 in chat and
  write the full table to `.last-survey.md` with a "47 more in .last-survey.md"
  footer.
- **Always** include a one-line summary at the top so the user can see scope at a glance.
- **Group multi-session lists by customer**, inferred from the session-title
  prefix (first token of `customTitle`): `acme-*`, `globex-*`, `initech-*`,
  `personal-*` (the user's own config/tooling), etc. Users name sessions
  deliberately — lean on it; give each customer its own block/sub-table. Use the
  same title-prefix intelligence for other signals: `delete-`/`personal-delete-*` =
  marked-for-deletion, `*-test*` / `*-test-session*` = throwaway test. Distinguish
  a topical word from a marker (e.g. `acme-DeleteRows` is real work ABOUT deleting
  rows, not a delete marker).
- **Flag resume-readiness — never recommend reopening clean-ended sessions.** For
  every session in a resume/launch list, classify the ending from the index:
  - **closed (skip by default):** `endedWithExit == true`, OR `lastUser`/
    `lastAssistant` signals completion — "we're done", "done thx", "closing
    out/down", "solved/finished in another session", "all wrapped up", a sign-off
    with no pending question.
  - **open (worth resuming):** ended mid-task, or `lastAssistant` is asking the user a
    question, or `[Request interrupted...]`.
  - **deferred (HIGH-value resume, NOT a skip):** explicit "paused/deferred",
    "pick up later", "continue later", "state saved so we can pick up cold".
  Mark each row `closed`/`open`/`deferred` and default the launch set to
  open + deferred. "paused/deferred ≠ done" — a saved-state pause means the user
  intends to return.
- **Never** auto-execute destructive ops; always confirm per batch.

## File hygiene (what this skill writes)

| File | Created | Lifecycle | Provenance |
|------|---------|-----------|------------|
| `~/.claude/skills/session-curator/.session-index.json` | every survey/search/cleanup/rename run | overwritten each run; one file ever | top-level `_meta` block |
| `~/.claude/projects-backup/<UTC-date>/<sid>__<HHMMSS>.jsonl` | only on `Apply-SessionRenames.ps1 -Apply` | one file per renamed session; folders >30 days auto-pruned | sidecar `_README.md` in each day folder |
| `~/.claude/skills/session-curator/.last-survey.md` | only when the user asks to save | overwritten each run; one file ever | YAML frontmatter at top |

No other files. The skill never scatters per-invocation logs, temp files, or
sidecars. Every artifact self-describes (so any file this skill writes carries
its own provenance and is safe to inspect or delete).

**Hygiene rule — the skill dir is exclusively for the three files above.** Any other file that ends up in `~/.claude/skills/session-curator/` (e.g. `.slices/`, `.subagent-verdicts.ndjson`, intermediate scratch from a subagent's working set) is leftover and should be deleted at end-of-run. Subagent scratch files belong under `$env:TEMP\session-curator-*` (`%TEMP%` is wiped by Windows housekeeping; the skill dir is not). Smoke test v2 caught two stragglers from earlier iterations — both have since been removed.

## Things this skill explicitly does NOT do

- **Archive** — Claude auto-cleans transcripts after 30 days via
  `cleanupPeriodDays`. The skill does not duplicate that. If the user wants a
  "keep-forever catalog" of session summaries, that's a v2 follow-up.
- **Modify live sessions** — anything with `mtime < 10 min` is treated as live
  and protected from rename/delete.
- **Read raw `.jsonl` into the main loop** — see "Core principle" above.
- **Bulk delete without per-batch confirmation** — even when verdicts are
  high-confidence junk.

## Where to look next

- Implementation: [`scripts/Extract-SessionIndex.ps1`](scripts/Extract-SessionIndex.ps1),
  [`scripts/Apply-SessionRenames.ps1`](scripts/Apply-SessionRenames.ps1),
  [`scripts/Open-Sessions.ps1`](scripts/Open-Sessions.ps1) (launch mode),
  [`scripts/Watch-Session.ps1`](scripts/Watch-Session.ps1)
- File format: [`references/jsonl-format.md`](references/jsonl-format.md)
- Official ops: [`references/official-ops-cheatsheet.md`](references/official-ops-cheatsheet.md)
- Classification rules: [`references/junk-heuristics.md`](references/junk-heuristics.md)
- Naming spec: [`references/naming-convention.md`](references/naming-convention.md)
- Move mode rationale + encoded-cwd convention + landmines: [`references/move-mode.md`](references/move-mode.md)
- Monitor mode internals + alternatives: [`references/monitoring.md`](references/monitoring.md)
