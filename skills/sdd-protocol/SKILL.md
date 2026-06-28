---
name: sdd-protocol
description: The canonical spec-driven development protocol for the sdd-fleet agent software house. Defines the SPEC → REVIEW → FINALIZE → BUILD → CHANGE_REVIEW → HANDOFF state machine, the .sdd/ workspace layout and file ownership, the deterministic phase gates, the bounded review-cycle and human-escalation policy, and the blocker/major/minor severity rubric. This is the single source of truth for how the fleet runs. Consult it whenever orchestrating a feature or bug, transitioning phases, running a review, finalizing a spec, handing off to devops, or deciding whether to escalate — and any time a sdd-fleet command or role agent needs the workflow rules.
---

# SDD Protocol

This skill governs the runtime behaviour of the **sdd-fleet** software house.
Commands and role agents defer to it for the workflow, gates, and escalation rules.
It is the authority: where any agent prompt or command body disagrees with this file,
this file wins.

Four deeper references live alongside this file:

- **For the product tier** (vision/backlog/stack, the PLAN machine, product memory,
  the DEVELOPING loop, the intent quality floor) read `references/product-tier.md`.
- **For the bug lane** (triage → reproduce → diagnose → fix → verify → ship-fix,
  the `diagnosis.md` artifact, the reproducing-test gate) read
  `references/bug-lane.md`.
- **For the workspace tier** (the estate layer *above* this per-repo machine — the
  two-level `.sdd/`, the reserved `_epic/` namespace, the plan → human-ratify →
  deterministic-dispatch spine, derived-not-stored epic status, and the modelless
  conductor) read `references/workspace-tier.md`.
- **For cross-repo contract governance** (the `service.json` descriptor, the derived
  service catalog + blast radius, semver + pinned-consumer lookup, and the five fail-closed
  gates — descriptor validation, the dependency edge gate, the consumer-driven contract gate,
  the blast-radius human gate at the HANDOFF transition, and the publish-ordering gate)
  read `references/service-catalog.md`.

## Operating principles

- **Spec is the contract.** No source is written until the active spec is
  `FINALIZED` (bug lane: until the diagnosis is `CONFIRMED` and a reproducing test
  exists).
- **Gates are deterministic; judgments are adversarial.** Binary phase transitions
  are enforced by hooks (exit code 2 = block + feedback). Convergence judgments run
  as workflow cross-examination + survival vote (see REVIEW). The category error to
  avoid is hook-enforcing a judgment.
- **Filesystem is shared memory.** Subagent context is isolated and does not sync
  between roles. Everything that must cross roles lives as a file in
  `.sdd/<feature>/`. There is no per-agent persistent memory layer.
- **Escalate, don't loop forever.** Each review gate is bounded at **3 cycles**.
  One workflow run (or one `/sdd-fleet:pr-review` change-review pass) = one cycle;
  cross-examination rounds inside a single workflow run do NOT bump the counter.
  The run that exhausts the budget — cycle 3 with blockers still surviving — writes
  `ESCALATION.md`, sets `PHASE: ESCALATED`, and halts that phase for a human. There
  is no separate "4th cycle".
- **The orchestrator routes, it does not build.** The main session assigns work,
  runs gates, and synthesizes. It never writes production source itself.
- **One item in flight.** `.sdd/ACTIVE` names the single active feature or bug.
  Acquisition and release go through `scripts/acquire-active.sh` (atomic noclobber
  lock on `.sdd/ACTIVE.lock` with owner metadata) — never check-then-write the
  file by hand. The lock serializes within one working tree; sdd-fleet assumes
  **one orchestrator session per worktree** (two clones of the same repo are not
  serialized against each other — see ".sdd/ in version control").

## Workspace layout and ownership

```
.sdd/
  ACTIVE                 # one line: the active feature/bug slug. Empty = nothing active.
  ACTIVE.lock            # owner/slug/held-since metadata while ACTIVE is held (acquire-active.sh).
  .gitignore             # scaffolded: keeps the per-worktree coordination files out of git.
  PRODUCT                # one line: the product slug, if a product tier exists.
  _product/              # the product tier (see references/product-tier.md).
  <feature>/
    spec.md              # architect. STATUS line + spec body. Source of truth.
    acceptance.md        # architect. Testable acceptance criteria.
    DECISIONS.md         # architect. Append-only ADR log.
    TEST_PLAN.md         # qa. Test design mapped to acceptance criteria.
    IMPL_NOTES.md        # coder. Implementation notes and deviations.
    REVIEW.md            # reviewers. Append-only review log (see format below).
    PROGRESS.md          # orchestrator. Phase + cycle state (schema below).
    SKILL_MANIFEST.md    # orchestrator (from classifier). OPTIONAL. Per-role domain skills to load at BUILD.
    ESCALATION.md        # exists only when a gate has exhausted its cycles.
  <bug>/                 # bug lane: diagnosis.md replaces spec.md (see references/bug-lane.md).
```

Write boundaries: `architect` writes `spec.md` + `acceptance.md`; `architect`
and `qa` are reviewers — during review they write **only inside `.sdd/<active>/`**
(ADRs, REVIEW.md, TEST_PLAN.md) and never source; `coder` writes source +
`IMPL_NOTES.md`, only while `PHASE` is `BUILD` (bug lane: only after `CONFIRMED`);
`devops` writes CI/CD, IaC, and release artifacts, only after CHANGE_REVIEW
approval; the `scribe` (workflow-internal) applies workflow envelopes — the single
canonical writer of workflow-driven state mutations.

`.sdd/ACTIVE` empty (or absent) means nothing is active; all write-gating hooks then
allow operations through. Every hook resolves the active item by reading this file —
never an environment variable. Commands acquire and release it via
`scripts/acquire-active.sh` (atomic create of `.sdd/ACTIVE.lock`, then the slug into
`ACTIVE`; release verifies the slug, removes the lock, and empties `ACTIVE`). The
script never reads a clock — callers pass `--now`; stale-lock judgment is the
human/orchestrator's, informed by the `status` mode's held-since.

## .sdd/ in version control

`.sdd/` is the audit trail — **commit it**. Specifically: commit every
per-feature/per-bug workspace (`.sdd/<slug>/` — spec, acceptance, ADRs, reviews,
notes, PROGRESS), the product tier (`.sdd/_product/`), and the `.sdd/PRODUCT`
marker. **Ignore the per-working-tree coordination files** — they are live locks
and transient sentinels, meaningful only to the worktree that wrote them and
merge-conflict magnets if committed:

```
ACTIVE
ACTIVE.lock
.workflow-in-flight
.stop-test-retries
.skip-stop-tests
```

`/sdd-fleet:new-product`, `/sdd-fleet:jira-story`, and `/sdd-fleet:jira-story`
scaffold `.sdd/.gitignore` with exactly those entries when it is absent.

**Single driver per worktree.** The `ACTIVE` lock serializes acquisition *within*
one working tree only. sdd-fleet assumes one orchestrator session per worktree;
two clones (or git worktrees) of the same repo each hold their own ignored
`ACTIVE`/`ACTIVE.lock` and are not serialized against each other — reconciling
parallel clones is human merge discipline, not the lock's job.

## PROGRESS.md schema

Exact field names; hooks and commands parse these lines. Scaffolded PROGRESS
files are stamped `SDD_SCHEMA: 1` — readers parse named fields and ignore
unknown lines, so the stamp is inert at runtime; it exists so a future schema
change is detectable on disk and can be CHANGELOG'd with a migration note (see
the Compatibility convention in `CHANGELOG.md`; finish or park in-flight items
before a major upgrade).

Forward feature:

```
SDD_SCHEMA: 1
FEATURE: <slug>
PHASE: SPEC | REVIEW | FINALIZE | BUILD | CHANGE_REVIEW | HANDOFF | ESCALATED | PARKED
CYCLE: <int>          # spec-review cycles consumed (one increment per /sdd-fleet:feature-dev run)
CHANGE_CYCLE: <int>   # change-review cycles consumed (one increment per /sdd-fleet:pr-review pass)
BUILD_CYCLE: <int>    # deep-build cycles consumed (one increment per deep-build workflow run)
TIER: trivial | standard | large    # set by the classifier at /sdd-fleet:jira-story. `pending` until it runs.
BUILD_MODE: standard | deep-build   # selects /sdd-fleet:feature-dev's orchestration. Classifier sets deep-build for tier=large. `pending` until it runs.
REVIEW_ROLES: <csv>         # optional — /sdd-fleet:feature-dev roster (>=2 of architect,qa,coder). Default architect,qa,coder. A --roles flag overrides per-run.
REVIEW_CYCLE_BUDGET: <int>  # optional — /sdd-fleet:feature-dev escalation budget (1..3, clamped to the ceiling). Default 3. A --cycle-budget flag overrides per-run.
BUILD_CYCLE_BUDGET: <int>   # optional — deep-build escalation budget (1..3, clamped). Default 3. A --cycle-budget flag overrides per-run.
UPDATED: <iso8601>
```

The three optional config fields are **read-with-default** by their commands (absent ⇒
the workflow's built-in default); a command flag (`--roles` / `--cycle-budget`) overrides
the PROGRESS value for a single run, and budgets are clamped to the 3-cycle ceiling
(configurable downward only — escalation is never disabled). The bug lane's diagnose
budget is `DIAGNOSE_CYCLE_BUDGET` and the product plan-review roster is `PLAN_REVIEW_ROLES`
(same read-with-default + flag-override contract, each in its own PROGRESS file).

A bug's PROGRESS.md instead carries `LANE: bug` (absence of `LANE` reads as a
forward feature), `PHASE: REPORT | REPRODUCE | DIAGNOSE | FIX | VERIFY | HANDOFF |
ESCALATED | PARKED`, `SEV: sev0|sev1|sev2`, `CYCLE` (diagnose-confirmation cycles),
and `FIX_CYCLE` (verify→fix bounces) — plus the same `SDD_SCHEMA: 1` stamp. The
product tier's `_product/PROGRESS.md` is stamped too.

`/sdd-fleet:park` sets `PHASE: PARKED` on either lane and appends a
`PARKED: <iso8601> — was PHASE <prev> — <reason>` line; resuming is a deliberate
human edit.

## spec.md STATUS line

`spec.md` carries, at the start of a line within its first 30 lines:

```
STATUS: DRAFT | IN_REVIEW | FINALIZED | BLOCKED
```

`validate-spec-status` (PostToolUse on spec.md) rejects a write whose STATUS is
missing or invalid, or whose required sections (per the `sdd-spec-template` skill)
are absent. The bug lane's `diagnosis.md` STATUS contract is in
`references/bug-lane.md`.

## REVIEW.md entry format

Append-only. Reviewers add one block per cycle; never edit prior blocks. Resolution
of a concern is a *new* approving entry in a later cycle, not an edit.

```
## Cycle <N> — <role> — <iso8601>
- [blocker] <concern>
- [major]   <concern>
- [minor]   <concern>
status: concerns-raised | approved
```

In workflow REVIEW the reviewer subagents return structured concerns payloads; the
workflow merges them into the canonical entries above and the `scribe` appends them.
On non-workflow review paths (CHANGE_REVIEW, direct role invocation) the
`check-review-written` SubagentStop hook rejects a reviewer that stops without
appending its block for the current cycle.

## Severity rubric

| Severity | Definition | Gate effect |
|---|---|---|
| `blocker` | Correctness, security, data loss, or a contradiction of the spec/acceptance. | Blocks FINALIZE and HANDOFF. |
| `major` | Scalability, maintainability, or missing acceptance coverage. | Must be resolved or explicitly accepted (as an ADR) before the gate opens. |
| `minor` | Style, wording, nits. | Advisory; never blocks a gate. |

The `review-rubric` skill is the canonical source. The table is deliberately
mirrored verbatim in each reviewer agent's prompt body — load-bearing for
non-workflow direct invocations and for agent-team mode (where per-agent frontmatter
`skills` are ignored), and belt-and-suspenders if the workflow's
`AgentDefinition.skills` preload regresses. If the copies ever disagree, the
`review-rubric` skill wins (`scripts/rubric-drift.test.sh` enforces agreement).

## State machine

```
SPEC ──► REVIEW ──► FINALIZE ──► BUILD ──► CHANGE_REVIEW ──► HANDOFF
          ▲  │                              ▲       │
          └──┘ (≤3 cycles, then ESCALATE)   └───────┘ (≤3 cycles, then ESCALATE)
```

**SPEC.** `/sdd-fleet:jira-story <slug>` scaffolds `.sdd/<slug>/`, runs the
classifier subagent to set `TIER` + `BUILD_MODE` in PROGRESS.md, and delegates to
architect to draft `spec.md` (STATUS=DRAFT) + `acceptance.md` — a minimal
skeleton from the classifier's `skeleton_spec_hint` for `TIER=trivial`, the full
spec otherwise. With a product tier present, the feature inherits the binding stack
and its backlog intent (see `references/product-tier.md`).

**Trivial fast-path.** Features classified `trivial` skip the REVIEW phase
entirely: `/sdd-fleet:feature-dev` recognizes `TIER=trivial` and flips the spec
without requiring a completed review cycle. See `agents/classifier.md` for criteria
and disqualifiers; the classifier errs toward `standard` because false-trivial is
the dangerous miss (it skips a review the change needed).

**REVIEW.** `/sdd-fleet:feature-dev` dispatches the `workflows/review.js` dynamic
workflow with `{feature, cycle, now, run_id}`, writing the run id into
`.sdd/<feature>/.workflow-in-flight` first (the marker makes the two
reviewer-gating hooks stand down while the run is live). The workflow runs four
phases:

1. **Fan-out** — architect, qa, coder review in parallel; each returns a structured
   concerns payload `{role, status, concerns:[{id,severity,text}]}`. Their
   `AgentDefinition.tools` omits `Write`/`Edit`; `AgentDefinition.skills` preloads
   `review-rubric`.
2. **Cross-examination** — each reviewer must refute or affirm peers' concerns. A
   refutation must be ≥40 characters, cite spec.md or acceptance.md as structured
   counter-evidence, and come from a different-role reviewer (self-refutation is
   filtered).
3. **Survival vote** — pure script logic. A concern survives unless refuted by a
   different-role reviewer with substantive reasoning. The cycle is *clean* iff
   zero surviving `[blocker]` items.
4. **Apply via scribe** — the scribe applies the structured envelope to PROGRESS.md
   (`state_delta`) and REVIEW.md (`review_entries`), writes ESCALATION.md when
   `escalation_payload` is non-null, and releases `.workflow-in-flight`.

Verdict semantics:
- `clean` — zero surviving blockers. Next: `/sdd-fleet:feature-dev`.
- `revise` — surviving blockers, budget remaining. Next: `/sdd-fleet:feature-dev`
  after PO revises spec.md.
- `escalate` — surviving blockers on the cycle that exhausts the 3-cycle budget.
  The scribe writes ESCALATION.md, sets PHASE=ESCALATED, halts.
- `incomplete` / `invalid-args` — a transient agent fault or bad dispatch args.
  Nothing is written, PHASE/CYCLE are unchanged, the marker is cleaned up — re-run.

**FINALIZE.** `/sdd-fleet:feature-dev` runs the finalize gate — the gate ONLY (it is
idempotent; the BUILD orchestration is `/sdd-fleet:feature-dev`'s). Permitted only when
the most recent review cycle is fully approved with no open blockers (`[major]`
items each fixed or ADR-recorded). On success: STATUS=FINALIZED, PHASE=BUILD. The
source-write block lifts at this point and not before.

**BUILD.** Sequential, tests-first. `/sdd-fleet:feature-dev` (run after the finalize
gate passes) dispatches qa first, then coder:

1. **qa drafts TEST_PLAN.md + writes failing tests** per the `test-plan` skill —
   each test must initially FAIL (no source exists yet) — then signals
   `SDD_FLEET_QA_TESTS_READY: <count> failing tests in tests/`.
2. **coder implements to spec.** Coder refuses to begin until qa's failing tests
   exist and all fail, then iterates until every qa test passes, recording `gap:` /
   `deviation:` / `todo:` markers in `IMPL_NOTES.md`.

Both roles first load any skills routed to them in `SKILL_MANIFEST.md` (advisory,
never gating — see the `skill-routing` skill).

**BUILD variants.** `PROGRESS.md`'s `BUILD_MODE` field selects the execution mode
(set by the classifier; manual override via PROGRESS.md edit or invoking
`/sdd-fleet:feature-dev` directly):

- **`standard`** — the sequential qa-then-coder pattern above, orchestrated by
  `/sdd-fleet:feature-dev` via the Task tool.
- **`deep-build`** — for multi-file / multi-package features. `/sdd-fleet:feature-dev`
  runs qa first (same as standard), then routes implementation to
  `workflows/deep-build.js`: an architect subagent designs a file partition, N
  coders (default 3, max 8) fan out in parallel against the pre-existing failing
  tests, and an adversarial review sub-phase (architect for design, qa for coverage
  + counterfactual) catches gaps before BUILD is declared complete; the scribe
  aggregates results into `IMPL_NOTES.md`. Verdicts mirror REVIEW's (`clean` /
  `needs-iteration` / `escalate` / `incomplete`) against the 3-cycle `BUILD_CYCLE`
  budget; on `incomplete`, partial worktree writes are possible if coders had
  fanned out — inspect before re-running.

**CHANGE_REVIEW.** `/sdd-fleet:pr-review` sets PHASE=CHANGE_REVIEW, increments
`CHANGE_CYCLE`, and runs architect (design adherence + ADR compliance) +
qa (meets `acceptance.md` + coverage gaps) against the diff. qa also
runs the **counterfactual** — each test must FAIL if coder's source change were
reverted (a test that passes regardless is decorative). The counterfactual is
**snapshot-first**: record a `git stash create` SHA in IMPL_NOTES.md before any
revert, operate against that ref, verify the restore against it before evaluating
any verdict, and never use a bare `git checkout` of the changed files (full
procedure in `agents/qa.md`).

Exit (to HANDOFF): all three approve with no open blockers. Fail → back to BUILD,
bounded by the 3-cycle `CHANGE_CYCLE` budget, then ESCALATE.

**HANDOFF.** devops takes the finalized, reviewed change → CI/CD, IaC, release
notes. It advances only on an explicit `SDD_FLEET_DEVOPS_OK` signal (a silent or
refused return leaves the feature unshipped). Entering HANDOFF is itself gated: a
change whose **blast radius** is risky (≥ N transitive consumers, or
`money_movement`/`pii` on a reached consumer or on the changed service itself — see
`references/service-catalog.md`) cannot transition until a human approves it via
`/sdd-fleet:handoff-approve`, an approval **pinned to that blast radius** (it goes
stale and re-blocks if the radius widens). On a full completion, handoff flips
the product backlog row (if any), releases the in-flight lock
(`acquire-active.sh release`), and surfaces the next unblocked feature — see
`references/product-tier.md` § DEVELOPING loop.

## Hard gates (enforced by hooks)

Registered in `hooks/hooks.json`; scripts (each with a committed test harness) in
`hooks/scripts/`.

1. No source write while the active spec STATUS ≠ FINALIZED — and, for an active
   bug, none before diagnosis CONFIRMED + a reproducing test exists. Blocks ALL
   non-`.sdd`, non-`tests/` writes. *(block-source-before-finalized +
   require-reproducing-test, PreToolUse Write|Edit|NotebookEdit.)*
2. The Bash escape hatch is guarded: while source is locked, Bash commands matching
   write-to-source patterns (`>`/`>>` redirection, `tee`, `sed -i`, `patch`,
   `cp`/`mv`/`install` destinations) outside `.sdd/` and `tests/` are blocked —
   conservative pattern matching; the Write/Edit gates remain the contract.
   *(guard-bash-writes, PreToolUse Bash.)*
3. During REVIEW and CHANGE_REVIEW, ALL writes are confined to `.sdd/<active>/` on
   non-workflow paths (workflow REVIEW enforces via `AgentDefinition.tools`
   allowlists that omit Write/Edit; the hook stands down while a live
   `.workflow-in-flight` marker exists). *(restrict-reviewer-writes, PreToolUse
   Write|Edit|NotebookEdit.)*
4. spec.md, the product backlog, and diagnosis.md always carry a valid STATUS line
   and required structure. *(validate-spec-status, validate-backlog-status,
   validate-diagnosis-status — PostToolUse.)*
5. A reviewer cannot stop without recording its review for the current cycle —
   non-workflow paths only; workflow REVIEW enforces via its envelope
   post-condition, and the hook stands down while a live marker exists.
   *(check-review-written, SubagentStop.)*
6. A session cannot stop on a failing test/lint stack while an item is active —
   bounded: after 3 consecutive red-suite stops it writes ESCALATION.md and lets
   the stop through. No recognized stack → silent no-op so bootstrap repos don't
   deadlock. *(stop-tests, Stop.)*
7. Orphaned `.workflow-in-flight` markers are reaped on Stop — released (empty)
   markers immediately, abandoned ones after a staleness threshold.
   *(reap-stale-workflow-markers, Stop.)*

**Fail-closed semantics.** The gates anchor at `CLAUDE_PROJECT_DIR` (a drifted cwd
cannot silently disable them), reject any `..` path segment before prefix-matching,
require `jq` while an item is active (missing jq blocks rather than no-ops), and
trap unexpected script errors to exit 2 (block) rather than exit 1 (silently
non-blocking). Deliberate allows are explicit `exit 0`.

**The workflow marker.** Dispatch commands write their run id into
`.sdd/<workspace>/.workflow-in-flight` before invoking a workflow. The scribe
releases it (overwrites it with empty content) at envelope-apply time, only when the
marker's content matches the envelope's `run_id` — a stale or retried run can never
release a newer dispatch's marker. The marker-keyed hooks treat an **empty marker as
absent**, so enforcement re-engages the moment the scribe releases it; the Stop-hook
reaper deletes released and orphaned markers.

## Escalation, park, resolve

When a review gate exhausts its cycle budget with blockers still open, the
responsible workflow/command writes `.sdd/<slug>/ESCALATION.md` containing: the
phase, the cycle count, the unresolved blockers (verbatim from REVIEW.md), and the
conflicting positions. It sets PHASE=ESCALATED and stops. Escalation is a
first-class outcome, not a failure — the human decides how to break the deadlock.

Two human-driven commands operate on stuck state:

- **`/sdd-fleet:resolve-escalation <decision>`** — archives ESCALATION.md into
  REVIEW.md (append-only), deletes ESCALATION.md, resets the exhausted cycle
  counter, restores the pre-escalation phase, and records the human decision. The
  sanctioned unblock path.
- **`/sdd-fleet:park <reason>`** — records the parked state in PROGRESS.md and
  releases the in-flight lock via `acquire-active.sh release` (e.g. so a sev0 bug
  can be triaged mid-feature). Nothing is deleted; resuming is a deliberate human
  act (re-acquire the lock, restore the pre-park PHASE).

Parking is a human act (the command is not model-invocable); the orchestrator's job
when blocked is to surface the conflict and stop.
