---
description: Resolve an escalation with an explicit human decision
argument-hint: "[<slug>] <decision>"
allowed-tools: Read, Write, Edit, Bash(rm:*)
disable-model-invocation: true
---

# /sdd-fleet:resolve-escalation

You are the **orchestrator**. An escalation means the bounded cycles were
exhausted (or a human halted the work); **only a human decision unblocks it** —
so this command is not model-invocable (`disable-model-invocation: true`); a
human types it, carrying their decision. Before this command existed, the only
way out was undocumented file surgery; this is the sanctioned path.

## Arguments

`$ARGUMENTS` — `[<slug>] <decision>`:

- If the first token names an existing `.sdd/<token>/` directory, it selects
  that feature/bug; otherwise the active item from `.sdd/ACTIVE` is used.
- Everything else is the **decision** (free text, **required**): what the human
  chose — e.g. "accept architect's position, drop the streaming requirement" or
  "blockers waived for the prototype phase; revisit at v2".

If the decision is empty, refuse — an escalation cannot be waved through
without a recorded choice:
`SDD_FLEET_RESOLVE_REFUSE: {"code":2,"reason":"missing-decision"}`.

## What you do

1. **Resolve the target.** Determine `<slug>` per the arguments. If neither a
   named slug nor a non-empty `.sdd/ACTIVE` resolves, refuse
   (`{"code":2,"reason":"no-target"}`).

2. **Require the escalation.** `.sdd/<slug>/ESCALATION.md` must exist. If not,
   refuse — there is nothing to resolve:
   `SDD_FLEET_RESOLVE_REFUSE: {"feature":"<slug>","code":2,"reason":"no-escalation"}`.

3. **Read the escalation context.** From `ESCALATION.md`, note the phase it was
   written in and the cycle count. From `.sdd/<slug>/PROGRESS.md`, read `PHASE`
   (normally `ESCALATED`) and `LANE` (bug vs forward feature).

4. **Determine the pre-escalation phase and its cycle counter.** Prefer the
   phase recorded inside ESCALATION.md; if it is absent, infer from which
   counter is exhausted in PROGRESS.md. The mapping:

   | Pre-escalation phase | Counter to reset |
   |---|---|
   | `REVIEW` (spec review) | `CYCLE` |
   | `BUILD` (deep-build iterations) | `BUILD_CYCLE` |
   | `CHANGE_REVIEW` | `CHANGE_CYCLE` |
   | `DIAGNOSE` (bug lane) | `CYCLE` |
   | `FIX` / `VERIFY` (bug lane) | `FIX_CYCLE` |

   If you cannot determine the phase from either source, refuse
   (`{"code":2,"reason":"phase-undeterminable"}`) and ask the human to name it —
   never guess a state transition.

5. **Archive into the audit trail (append-only).** Append a block to
   `.sdd/<slug>/REVIEW.md`:

   ```
   ## Escalation resolved — <iso8601 now>
   ### Archived ESCALATION.md
   <the full ESCALATION.md content, verbatim>
   ### Human decision
   <the decision, verbatim>
   resolution: counter <name> reset, phase restored to <phase>
   ```

   Append only — never modify existing REVIEW.md entries. (For a bug that has
   no REVIEW.md yet, create it with the standard append-only header first.)

6. **Reset state.** Edit `.sdd/<slug>/PROGRESS.md`:
   - Set the exhausted counter from step 4 back to `0` (the human decision
     re-opens the budget).
   - Set `PHASE:` back to the pre-escalation phase from step 4.
   - Refresh `UPDATED:`.

7. **Delete `.sdd/<slug>/ESCALATION.md`.** The gates key off this file's
   existence; it must go for work to resume. Its content is preserved verbatim
   in REVIEW.md (step 5), so nothing is lost.

8. **Emit the signal, then report.**
   ```
   SDD_FLEET_RESOLVED: {"feature":"<slug>","phase":"<restored phase>","counter_reset":"<CYCLE|BUILD_CYCLE|CHANGE_CYCLE|FIX_CYCLE>","decision":"<first ~100 chars>"}
   ```
   Tell the user which phase the item is back in and the natural next command
   (e.g. `/sdd-fleet:feature-dev`, `/sdd-fleet:feature-dev`, `/sdd-fleet:pr-review`,
   `/sdd-fleet:feature-dev`, or `/sdd-fleet:feature-dev`). If the decision implies spec
   or diagnosis edits (e.g. "drop the requirement"), remind the human those edits
   are theirs/PO's to make before re-running the phase.

## Hard rules

- **Never resolve without an explicit decision argument** — that text is the
  audit record of *why* the deadlock broke.
- **REVIEW.md is append-only.** Archive; never rewrite history.
- **Never touch spec.md, acceptance.md, diagnosis.md, or DECISIONS.md** — the
  decision may *call for* edits there, but those belong to their owners.
- **Headless contract.** Exactly one `SDD_FLEET_RESOLVE*` signal line before
  any prose. A slash command cannot set a process exit code — the signal lines
  on stdout are the sole machine contract (`code` 2 = refused).
