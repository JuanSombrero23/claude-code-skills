---
title: Heuristics for classifying sessions as junk / finished / open
purpose: Used by the session-curator skill's `cleanup` mode and by the LLM-interpretation subagents that turn raw index entries into a status verdict.
generator: session-curator/references (Phase 3)
generated: 2026-05-31
---

# Classification heuristics

The cleanup mode classifies every session in the index into one of:

- **junk** — never had real content; safe to delete.
- **finished** — substantive work that wrapped up cleanly; safe to archive/leave.
- **open** — substantive work in progress or abandoned mid-flow; **do not propose deletion**.

The skill **never auto-deletes.** It only proposes; the user confirms each batch.

## Signals available per session (from the index)

- `userCount`, `assistantCount` — interaction depth
- `sizeKb` — total transcript size
- `endedWithExit` — true if a `<command-name>/exit</command-name>` system line is present
- `lastLineType` — last event type written (e.g. `assistant`, `user`, `system`)
- `firstUser`, `lastUser`, `lastAssistant` — text snippets
- `temporal` — activeMinutes, daysSpan, daysActive, intensity, rhythm
- `customTitle` — whether the user invested in naming it
- `duplicateGroups` membership

## Junk heuristics (high confidence)

A session is **likely junk** if ANY of:

- `userCount <= 1` AND `sizeKb < 5`
- `firstUser` matches a throwaway prompt pattern: `^(/exit|/clear|/plugin|/model|/help|ok|test|x|y|hi|hello|hey|done|thanks?)\s*$` (case-insensitive)
- `lastUser` is the same throwaway pattern AND `userCount <= 3`
- `sizeKb < 3` AND `lastLineType != "user"` (never even got Claude to respond)
- Membership in a `duplicateGroups` entry where another sibling has substantially more content (= this one is a stale dup of the canonical)

Be conservative — when in doubt, classify as `open`, not `junk`. The cost of a false positive (deleting work) is much higher than a false negative (keeping clutter).

## Finished heuristics (medium confidence)

A session is **likely finished** if ALL of:

- `endedWithExit == true`, OR `lastUser` matches a closing pattern: `^(thanks?|done|perfect|great|bye|that.?s all|got it).{0,30}$` (case-insensitive)
- `mtime` is **>3 days ago** (still-recent sessions are usually paused, not finished)
- Not in any `duplicateGroups`

Borderline: sessions ended with `/exit` but interrupted mid-task. The LLM subagent should read `lastAssistant` — if it ends with a question to the user, that's "open" even if `/exit` followed.

## Open heuristics (default)

Everything else. Specifically:

- `endedWithExit == false` AND `mtime < 7 days` → almost certainly still open/active
- `lastAssistant` ends with `?` or `[awaiting]` markers
- `lastUser` is a half-sentence or trails off
- Recent `temporal.intensity` was high but stopped abruptly

## What the cleanup subagent should output

For each session, a verdict block:

```json
{
  "id": "...",
  "verdict": "junk|finished|open",
  "confidence": "high|medium|low",
  "reason": "one short sentence — what triggered this classification",
  "proposedAction": "delete|leave|rename|none"
}
```

Confidence is for the user's UX, not for the skill's automation. The skill batches verdicts by `verdict` and presents them for the user's per-batch approval. Nothing executes without their confirmation.

## What to never propose

- Deleting a session that's still being actively written (`mtime < 10 min ago`)
- Deleting any session with `customTitle` set (the user invested in naming it → they care)
- Bulk delete of `open` sessions without per-session review
