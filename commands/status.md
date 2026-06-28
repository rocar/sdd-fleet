---
description: Report the active item's phase, cycles, and concerns
model: haiku
allowed-tools: Read, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/status-snapshot.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-feature.sh":*)
---

# /sdd-fleet:status

You are the **orchestrator**. Read-only command. You report state; you do
not mutate anything.

## Pre-loaded state (gathered at prompt-build time)

The deterministic snapshot below was injected before you started — narrate
from it; only Read the underlying `.sdd/` files when you need detail it does
not carry (e.g. verbatim `[blocker]` text from REVIEW.md, ESCALATION.md
contents). If the snapshot line is empty or an error (e.g. `jq` missing),
fall back to reading the files directly per the steps below.

Snapshot (`sdd-fleet/status-snapshot@2`):
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/status-snapshot.sh" 2>&1 || true`

## What you do

1. **Read `.sdd/ACTIVE`.** If empty or absent:
   - If `.sdd/_product/backlog.md` exists, there is a product tier with no feature
     in flight — skip the feature-detail steps (2–5) and go straight to the
     **Product backlog** section (step 5b), which surfaces the backlog and names the
     next unblocked feature to scaffold.
   - Otherwise report "no active feature" and stop. Suggest
     `/sdd-fleet:jira-story <slug>`.

1b. **Bug lane.** Read `.sdd/<active>/PROGRESS.md`. If it carries `LANE: bug`, the
   active item is a troubleshoot-fix **bug**, not a forward feature — report the **bug view** and
   **skip steps 2–4** (a bug has no `spec.md` or spec-review cycle):
   - Bug slug; `PHASE` (`REPORT|REPRODUCE|DIAGNOSE|FIX|VERIFY|HANDOFF|ESCALATED`); `SEV`.
   - `diagnosis.md` STATUS (`REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED`).
   - `CYCLE` (diagnose-confirmation cycles) and `FIX_CYCLE` (verify→fix bounces); `UPDATED`.
   - The count of test files under `tests/` (read-only — status never runs the suite; the
     `diagnosis.md` STATUS conveys the red→green lifecycle).
   - The most recent `.sdd/<slug>/REVIEW.md` diagnose block(s), if any (verbatim verdict lines).
   - Then do the ESCALATION check (step 5) and recommend the next bug-lane command by `PHASE`:
     `REPORT`→`/sdd-fleet:feature-dev`; `REPRODUCE`→record a hypothesis, then `/sdd-fleet:feature-dev`;
     `DIAGNOSE`→`/sdd-fleet:feature-dev` again (if refuted) or `/sdd-fleet:feature-dev` (if confirmed —
     PHASE will read `FIX`); `FIX`→`/sdd-fleet:feature-dev` then `/sdd-fleet:feature-dev`;
     `VERIFY`→`/sdd-fleet:feature-dev`; `HANDOFF`→`/sdd-fleet:pr-review`;
     `ESCALATED`→human only: `/sdd-fleet:resolve-escalation <decision>` (or `/sdd-fleet:park <reason>` to abandon).
   Then **stop** — do not run the forward-feature steps below.

2. **Read `.sdd/<active>/PROGRESS.md`.** Print:
   - Feature slug.
   - PHASE.
   - CYCLE (spec-review cycles consumed).
   - CHANGE_CYCLE (change-review cycles consumed).
   - UPDATED timestamp.

3. **Read `.sdd/<active>/spec.md` first line.** Print the STATUS value.

4. **Summarize the most recent REVIEW.md cycle.** Find every block tagged
   with the current `CYCLE` (if PHASE is in spec-review territory) or
   `CHANGE_CYCLE` (if PHASE is in change-review territory). For each
   reviewer block, print:
   - Reviewer name.
   - `status:` line value.
   - Count of `[blocker]`, `[major]`, `[minor]` items.
   - Verbatim text of every `[blocker]` item (so the user sees what's
     actually open).

5. **Check for `.sdd/<active>/ESCALATION.md`.** If it exists, print a
   prominent banner: the feature is escalated. Then print the file's
   contents — phase, cycle count, unresolved blockers, conflicting
   positions. Skip the "next command" recommendation; only a human unblocks
   an escalation — by running **`/sdd-fleet:resolve-escalation <decision>`**
   (archives the escalation into REVIEW.md, resets the exhausted cycle
   counter, restores the phase), or **`/sdd-fleet:park <reason>`** to shelve
   the item entirely.

5b. **Product backlog, if a product tier exists.** If
   `.sdd/_product/backlog.md` exists, summarize it:
   - For each `## Phase N: <name> — STATUS:` line, print the phase name + its STATUS.
   - Under each phase, print every feature row with its state: `PENDING`, or `DONE`
     (with its `handoff:` date) — and if a row's slug matches `.sdd/ACTIVE`, annotate
     it `← active (in flight, PHASE=<phase>)`. Active is **derived from `.sdd/ACTIVE`**,
     not a backlog marker.
   - A roll-up line: `<done>/<total> features done across <N> phases`.
   - **If no feature is active, resolve what's next via the shared resolver**
     — the same read-only helper `/sdd-fleet:pr-review` uses, so status and the loop never
     disagree:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-feature.sh"
     ```
     It emits one JSON line; report from its `status`:
     - `next` → name the slug + phase and suggest `/sdd-fleet:jira-story <slug>`.
     - `complete` → "product backlog complete (`done/total`)" — nothing to start.
     - `deadlocked` → "`<pending>` features remain but none are unblocked — check
       `depends-on` / cycles in `backlog.md`."
     - `empty` → "backlog has no parseable feature rows — check its format" (not
       "complete"; `total=0`).
     Do **not** re-derive the next feature in prose; use the resolver output verbatim.
   Read-only, like the rest of status (the resolver only reads `backlog.md`).

6. **Recommend the next command** based on PHASE:
   - `SPEC` → architect is drafting; run `/sdd-fleet:feature-dev` when
     PO signals ready.
   - `REVIEW` with open blockers → PO is revising; re-run
     `/sdd-fleet:feature-dev` once revisions land.
   - `REVIEW` with all approvals → `/sdd-fleet:feature-dev` (the gate), then
     `/sdd-fleet:feature-dev` (the BUILD orchestration).
   - `BUILD` → if the BUILD orchestration has not started (no qa test suite /
     IMPL_NOTES activity yet), run `/sdd-fleet:feature-dev`; once coder + qa
     signal done, run `/sdd-fleet:pr-review`.
   - `CHANGE_REVIEW` with open blockers → coder is fixing; re-run
     `/sdd-fleet:pr-review` once fixes land.
   - `HANDOFF` → devops shipping; no command needed.
   - `ESCALATED` → human-in-the-loop required: `/sdd-fleet:resolve-escalation
     <decision>` is the sanctioned unblock; `/sdd-fleet:park <reason>` shelves
     the item.
   - `PARKED` → the item was parked (see the `PARKED:` line in PROGRESS.md for
     when/why); resuming is a deliberate human edit — see `/sdd-fleet:park`.

## Machine-readable snapshot (orchestrators / polling)

For a non-interactive caller (an external orchestrator polling project state), the
human report above is the wrong shape and too costly — it spawns a model. Use the
deterministic, LLM-free resolver instead:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status-snapshot.sh"
```

It reads the same `.sdd/` state this command narrates and emits **exactly one JSON
object** (`schema: sdd-fleet/status-snapshot@2`) on stdout — the product tier
(vision/stack one-liners, backlog counts + per-feature rows, next unblocked feature)
and the active item (feature or bug lane: phase, status, cycles, escalation).
Read-only; run from the repo root. `product` is `null` with no product tier;
`active` is `null` with nothing in flight. Backlog resolution + counts reuse
`scripts/next-feature.sh` (one source of truth). **sdd-fleet ships no publishing
path** — where (or whether) the snapshot goes is the orchestrator's concern
(orchestrator-agnostic).

## Hard rules

- This command **never** writes any file. Read-only. (It may invoke the read-only
  `scripts/next-feature.sh` resolver, which only reads `backlog.md` and writes nothing.)
- This command **never** runs tests or invokes subagents.
- If any of the expected `.sdd/<active>/` files are missing or malformed,
  report which and stop — recovery is the user's call (probably
  hand-edit PROGRESS.md, or `/sdd-fleet:jira-story` with a fresh slug
  if the workspace is irrecoverable).
