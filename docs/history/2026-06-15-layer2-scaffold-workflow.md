# Layer 2 — `/build-fleet:scaffold-workflow` (governed generate-then-pin)

**Status:** approved 2026-06-15. Part of the dynamic-workflow enrichment (research +
plan delivered 2026-06-15; slices 1–5 shipped Layer 1). This note records the approved
design; the workflow contract authority remains the `sdd-protocol` skill.

## Purpose

When build-fleet faces a **novel, large, unknown-shape task** that fits none of the four
fixed lanes (review / plan-review / deep-build / diagnose) — a repo-wide audit, a big
migration, a multi-angle stress-test — this lane lets Claude *author* a workflow for it
on the fly, then runs it through deterministic governance before it can become a frozen,
replayable, **project-local** workflow. Dynamic generation is an **authoring accelerator
only**; the executing artifact is always static. Determinism/auditability is non-negotiable.

## Pin target (decided)

A **runtime tool**: the ratified workflow is pinned into the **target project's
`.claude/workflows/<name>.js`** (the official Claude Code save location), invokable as
`/<name>`. It is NOT committed into build-fleet's own `workflows/` (that would be a plugin
release, and the runtime can't write the installed plugin). build-fleet supplies the
governance; the project owns the artifact.

## Run boundary (decided)

scaffold-workflow **never executes the candidate** before it is pinned. Author → govern →
pin. Execution happens only afterward, when the user runs `/<name>` on the now-static,
replayable artifact — never inside build-fleet's audited `.sdd/` lanes, never on
un-reviewed code. (Layer 3 — live dynamic execution in the audited path — stays rejected.)

## Command surface

One command, two modes (mirrors `plan-finalize`'s token-gated safety stop):

- `/build-fleet:scaffold-workflow <name> "<task>"` → **draft**: generate + lint + review +
  report. Never pins.
- `/build-fleet:scaffold-workflow ratify <name>` → **pin**: hard re-lint gate + freeze into
  `.claude/workflows/<name>.js`. The explicit `ratify` token is the headless safety stop.

### Draft flow
1. Orchestrator authors the candidate JS → `.sdd/_generated/<name>.js` (quarantine; under
   `.sdd/` so the write is gate-permitted), following determinism conventions (`export const
   meta`, `args.now`, no `Date`/`Math.random`/`new Date()`/fs/network, capped fan-out,
   structured schemas).
2. Run `scripts/workflow-determinism-lint.sh` (slice 1); report violations.
3. Adversarial review — Task fan-out **architect + qa interrogate** the candidate (uncapped
   fan-out, missing `args.now`, cost blowups, audit gaps, does-it-do-the-task).
   *Interrogate-don't-auto-kill*, like plan-review. Findings → `.sdd/_generated/<name>.review.md`.
4. Emit a report + `BUILD_FLEET_SCAFFOLD_DRAFT` signal and **stop**.

### Ratify flow
1. Candidate must exist.
2. `scripts/pin-workflow.sh <name>` re-runs the determinism lint as a **hard, fail-closed
   gate** (lint fail → refuse), then copies the candidate → `.claude/workflows/<name>.js`.
3. Emit `BUILD_FLEET_WORKFLOW_PINNED`. The user then runs `/<name>` themselves.

## Guarantees

- **Lint is the hard gate**, enforced inside `pin-workflow.sh` (a script — sloppy command
  prose can't pin non-deterministic code). Fail-closed, traversal-rejecting, like the other
  gates. The **review is advisory** (human weighs; the `ratify` token authorizes).
- **Never executes the candidate.** Only the user runs the pinned, frozen, replayable artifact.
- **Precondition:** refuse to pin while an active feature/bug is source-locked (the
  `block-source-before-finalized` / `guard-bash-writes` hooks would block a non-`.sdd/`
  write anyway). Clean message: finish or park the active item first. Mirrors plan-review's
  "refuse while mid-review" guard.
- **Quarantine is gitignored scratch** (`.sdd/_generated/` added to the `.sdd/.gitignore`
  scaffold); the durable artifact is the project-committed `.claude/workflows/<name>.js`.

## Files

- NEW `commands/scaffold-workflow.md` — the orchestration prose.
- NEW `scripts/pin-workflow.sh` + `scripts/pin-workflow.test.sh` — the deterministic, TDD'd
  pin keystone (lint-gate + validated copy + fail-closed).
- Reuses `scripts/workflow-determinism-lint.sh`.
- Docs: README command-reference row + a note; `CLAUDE.md` layout command count 21 → 22.
  No plugin version bump now (a release bundles slices 1–5 + this later).

## Explicitly out of scope (the Layer-3 line)

No running a workflow inside an audited feature/bug lane; no auto-pin; no generated
dispatching command (pinned workflows are plain `/<name>`); no live/un-reviewed execution
touching `.sdd/` state.

## Rejected alternatives

- Two separate commands (draft + a human-only `ratify-workflow`) — rejected for the
  single-command token-gate pattern already used by `plan-finalize`.
- Review-as-a-meta-workflow — rejected (avoids recursion; a synchronous Task fan-out is
  simpler, and the lint is the deterministic gate regardless).
