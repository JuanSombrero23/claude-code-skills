---
title: Session naming convention — customer-topic-action
purpose: Spec for the session-curator skill's `rename` mode. The LLM subagent that proposes names should read this file before deciding.
generator: session-curator/references (Phase 3)
generated: 2026-05-31
---

# Session naming convention

Default Claude Code session titles ("Chat session", "/plugin", "done", "Initial greeting") are useless for retrieval. The skill's `rename` mode replaces them with a structured slug:

```
<customer>-<topic>-<action>
```

All lowercase, hyphen-separated, ASCII only, no spaces, ≤60 chars total. Examples (with fictional client names — swap in your own):

- `acme-reporting-debugging-prompts`
- `globex-executive-report-formatting`
- `initech-pricing-model`
- `umbrella-invoice-import-pipeline-fix`
- `personal-global-claude-config-cleanup`
- `personal-session-curator-skill-build`

## Critical UX rule: cwd is a HINT, not the truth

Users often launch sessions from the **wrong folder** — personal work inside a customer directory, or vice versa. The naming subagent **must** read the actual session content (`firstUser`, `lastUser`, `lastAssistant` from the index) to infer the real customer, falling back to cwd only when content is genuinely ambiguous.

**Bad (cwd-only inference):**
> cwd is `Acme/Repos/acme-analyses` → customer = `acme`
> But session content is: "help me clean up my global claude config"
> → wrong slug.

**Good (content-first inference):**
> Session content makes it clear this is global Claude config work in an Acme folder by accident.
> → slug = `personal-global-claude-config-cleanup`

## Customer slugs

Built-in mapping rules (apply only when content is ambiguous). The rows below are
**fictional examples** — replace them with your own clients.

| cwd pattern (case-insensitive) | customer slug |
|---|---|
| Contains `Acme` | `acme` |
| Contains `Globex` | `globex` |
| Contains `Initech` | `initech` |
| Contains `Umbrella` | `umbrella` |
| `~/.claude` or `~` (your home) | `personal` |
| Anything else | `misc` |

**Add your own clients here.** Each row maps a substring that appears in the cwd
path (case-insensitive) to the slug prefix you want sessions for that client to
get. Order matters when patterns could overlap — put the more specific pattern
first and qualify the broader one (e.g. "Contains `X` and not the above").

If content clearly contradicts the cwd, **always trust content**. Note the discrepancy in the rename proposal so the user sees why you ignored the folder hint.

## Topic — what the session is about

2-4 words. Use nouns and gerunds. Concrete > generic.

- ✅ `agent-debugging`, `pricing-model`, `invoice-pipeline`, `report-formatting`, `tmdl-cleanup`
- ❌ `data-stuff`, `helping`, `working`, `general`

## Action — the verb of the session

1-2 words. What was being done (or attempted). Optional if the topic already implies it.

- ✅ `fix`, `setup`, `migration`, `prompts`, `review`, `cleanup`, `audit`, `build`
- ❌ `done`, `work`, `task`

## Proposal output format

The naming subagent emits one JSON object per session needing a name:

```json
{
  "id": "<sessionId>",
  "file": "<full path>",
  "newTitle": "customer-topic-action",
  "reasoning": "one sentence — what tipped the customer + topic + action choice",
  "cwdMismatch": false,
  "confidence": "high|medium|low"
}
```

`cwdMismatch: true` flags sessions where the inferred customer differs from what the cwd would suggest — surfaces these to the user for sanity check.

## Sessions to leave alone

- `customTitle` already set (unless the user explicitly says `--force-rename`)
- Throwaway / junk sessions (`junk` verdict from cleanup heuristics) — propose delete, not rename
- Active sessions (`mtime < 10 min`)
