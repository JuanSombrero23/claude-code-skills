# Move mode — rationale, encoded-cwd convention, landmines

Companion reference for the [Move mode](../SKILL.md#move-mode) playbook in
`SKILL.md`. Read this before offering the operation to the user so the migration
plan you show them includes the right warnings.

## Why this exists

`claude --resume` and `claude --fork-session` are scoped by *the encoded cwd
folder name only*. A session created from cwd `A` cannot be resumed from cwd
`B` via the official CLI — but physically moving the `.jsonl` (plus sidecar
folder) into `B`'s project folder makes it appear in B's resume picker.

**Empirical confirmation (2026-06-08).** We moved the
`acme-credit-balance-customer` session from
`~/Acme/acme-operational-data-warehouse` to
`~/Acme/acme-analyses/analyses/0001-2026-05-20-customer-credit-balance`.
After `claude --resume` from the new cwd:

- `pwd` returned the destination cwd
- File reads defaulted to the destination project
- `/memory` showed the destination project's CLAUDE.md chain (analyses, not dwh)
- "Open auto-memory folder" (item 7 in `/memory`) showed only the cherry-picked
  entries

Embedded `cwd` fields inside the jsonl did NOT override the new folder
context — they were preserved on disk but Claude trusts the launch cwd at
resume time.

## Encoded-cwd convention

Claude derives the project folder name from the cwd by replacing every
non-alphanumeric character (`\`, `:`, ` `, etc.) with `-`. Worked example:

```
cwd:    C:\Users\you\OneDrive - Acme Corp\Repos\Acme\acme-analyses\analyses\0001-...
folder: C--Users-you-OneDrive---Acme-Corp-Repos-Acme-acme-analyses-analyses-0001-...
```

Note the run of three dashes from ` - ` (space-dash-space). Compute this
deterministically before quoting paths.

## What moves vs what doesn't (full notes)

| Item | Move? | Note |
|---|---|---|
| `<sessionId>.jsonl` | YES | The session file. |
| `<sessionId>/` sidecar folder (`subagents/`, `tool-results/`) | YES | Referenced by relative path from jsonl; broken if left behind. |
| `<project>/memory/*.md` (per-project auto-memory) | **Cherry-pick only** | Per-project. Bulk-moving pollutes the destination project's memory with source-project context. Classify each file relative to the destination project's focus, copy only what's relevant, and rebuild `MEMORY.md` to index only the copied entries. |
| Plans (`~/.claude/plans/*`) | NO | Global, not per-project. Untouched. |
| User CLAUDE.md hierarchy | NO | Resolved from cwd upward at resume time; the destination chain activates automatically. |
| Shell snapshots / other internal state | NO | Out of scope; resume handles them. |

## Known landmines (surface to the user when offering the move)

1. **Embedded `cwd` field in jsonl lines** is preserved (we don't rewrite it).
   Empirically, resume ignores this in favor of the actual cwd Claude is
   launched from — but it remains an unknown for edge cases (compaction
   recomputing from history, telemetry, etc.).
2. **Absolute file paths in tool-call history** still point at the source
   project. Harmless as history. Follow-up commands referencing those paths
   from memory will still target the source.
3. **Unknown unknowns** — internal indexes, telemetry, shell snapshots may
   reference the source project. Resume worked clean in the 2026-06-08 smoke
   test; flag any weirdness back as new data points to add to this list.

## Future learnings

Append confirmed observations here as the move operation gets exercised on
new session shapes (compacted sessions, sessions with workflows, sessions
with Plan/TaskCreate state, cross-drive moves, etc.). Each new entry should
include date + what worked + what broke.
