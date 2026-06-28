# Troubleshoot-fix bug lane — reference

sdd-fleet runs a **second state machine** for diagnosing and fixing bugs whose
*cause is unknown*, parallel to (never replacing) the forward feature machine. Where
the forward machine's contract artifact is `spec.md`, the bug lane's is
**`diagnosis.md`**. The full lane:

```
REPORT → REPRODUCE → DIAGNOSE → FIX → VERIFY → HANDOFF
```

A repo that never files a bug behaves byte-for-byte as a feature-only repo — the lane
is purely additive.

## The diagnosis.md artifact

The bug-lane analog of `spec.md`. Its first non-blank line is a STATUS line whose
value is one of `REPORTED | REPRODUCING | DIAGNOSED | CONFIRMED | FIXED`, advancing
monotonically across the phases. Required `##` sections (validated structurally):
`## Symptom + reproduction steps`, `## Root-cause hypothesis`, `## Blast radius`,
`## Fix strategy`. The canonical structure lives in the **`sdd-diagnosis-template`**
skill. `CONFIRMED` is the bug-lane analog of a `FINALIZED` spec — the point at which
source writes unlock.

**`validate-diagnosis-status` (PostToolUse Write|Edit|NotebookEdit).** The bug-lane
analog of `validate-spec-status`, keyed on `basename == diagnosis.md` under `.sdd/`.
Rejects (exit 2) a write whose STATUS is missing or not one of the five tokens, or
any of whose four required headings is absent. Feature dirs have no `diagnosis.md`
and bug dirs have no `spec.md`, so the two validators never cross-fire.

**Lane resolution.** `_lib.sh` provides `read_diagnosis_status <slug>` (mirrors
`read_spec_status`), `resolve_lane <slug>` (echoes `bug` when
`.sdd/<slug>/diagnosis.md` exists, else `feature` — presence of `diagnosis.md` is the
**structural** discriminator; the PROGRESS `LANE:` field is the parseable mirror),
and `tests_exist` (≥1 regular file under `tests/`).

**Bug-lane PROGRESS.md fields.** A bug's `PROGRESS.md` (written by
`/sdd-fleet:jira-story`) carries
`PHASE: REPORT | REPRODUCE | DIAGNOSE | FIX | VERIFY | HANDOFF | ESCALATED`, plus
`SEV: sev0|sev1|sev2`, `FIX_CYCLE: <int>`, and `LANE: bug`. A forward feature carries
no `LANE` field (absence reads as a feature). A bug `PROGRESS.md` carries **no**
`TIER`/`BUILD_MODE` (forward-machine fields); the bug-lane hooks never read them, and
a reader of an absent field returns empty rather than aborting, so their absence is
safe.

## Entry (REPORT): /sdd-fleet:jira-story

`/sdd-fleet:jira-story <symptom>` is the lane's **sole entry** (the bug-lane analog of
`/sdd-fleet:jira-story`). It refuses while `.sdd/ACTIVE` is non-empty — **a bug
and a forward feature share the single `.sdd/ACTIVE` lock** (one item in flight, the
simplest correct rule; there is no second `ACTIVE_BUG` lane, so a sev0 cannot preempt
a mid-flight feature — the human parks the feature first with `/sdd-fleet:park`).
On a clean lock it:

1. derives a kebab-case `bug-<…>` slug and acquires the in-flight lock
   (`scripts/acquire-active.sh acquire` — atomic; writes the slug to `.sdd/ACTIVE`);
2. scaffolds `.sdd/<slug>/` with **`diagnosis.md`** (`STATUS: REPORTED`, the symptom
   verbatim under `## Symptom + reproduction steps`) and a bug-lane `PROGRESS.md`
   (`SDD_SCHEMA: 1`, `LANE: bug`, `PHASE: REPORT`, `SEV: pending`, `CYCLE: 0`,
   `FIX_CYCLE: 0`) — and **no** `spec.md`/`acceptance.md`;
3. runs the **triage classifier** — the `classifier` agent in **bug mode** (see
   `agents/classifier.md` § Bug-mode) — for `{severity, cause_known}`;
4. **routes on `cause_known`:** `true` → the cause is obvious from the report; emit
   `SDD_FLEET_TRIAGE_KNOWN_CAUSE`, **delete the scaffold, release the lock**
   (`acquire-active.sh release`),
   and send the user to the forward `/sdd-fleet:jira-story` trivial path (the
   sharp boundary). `false` → stay in the lane: write `SEV`, keep `PHASE: REPORT`,
   emit `SDD_FLEET_TRIAGE`. Next command: `/sdd-fleet:feature-dev`.

## The source-write gates

Two PreToolUse gates (Write|Edit|NotebookEdit) gate **source** writes for an active
bug; the `guard-bash-writes` Bash gate applies the same locked/unlocked condition to
shell write patterns. A forward feature has no `diagnosis.md`, so `resolve_lane`
returns `feature` and both bug branches short-circuit to `exit 0` — the forward
machine is unaffected.

- **`require-reproducing-test.sh` (the inviolable gate).** For an active bug, a write
  to **source** (outside `.sdd/` and outside `tests/`) is blocked (exit 2) unless
  **both** `read_diagnosis_status == CONFIRMED` **and** `tests_exist` (≥1 file under
  `tests/`). Writes under `.sdd/` or `tests/` are always allowed — the reproducing
  test must be writable before CONFIRMED. The gate is **severity-independent** (it
  never reads `SEV`): it holds even for sev0.
- **`block-source-before-finalized.sh` (second unlock).** Before the existing
  `read_spec_status`/FINALIZED branch, a bug-lane branch: a CONFIRMED bug's source
  write exits 0; a non-CONFIRMED bug's is blocked. **A bug's `tests/` write is always
  permitted** (the bug branch short-circuits on `path_in_tests`) — the reproducing
  test must land at REPRODUCE, *before* CONFIRMED, so blocking it would deadlock the
  lane against `require-reproducing-test`. The FINALIZED branch is unchanged — a
  forward feature never enters the bug branch.

Layered, a bug source write requires `CONFIRMED` **and** a reproducing test —
strictly stronger than the forward path's single FINALIZED condition, never weaker.
Both hooks carry committed harnesses (`require-reproducing-test.test.sh`,
`block-source-before-finalized.test.sh` — the latter locks in the byte-identical
forward behavior as a regression).

## REPRODUCE + DIAGNOSE (the confirmation workflow)

Two commands carry a bug from a reproduction to a confirmed (or refuted) root cause:

- **`/sdd-fleet:feature-dev` (REPORT→REPRODUCE).** Delegates to **qa** to author ≥1
  **failing reproduction test** under `tests/` that fails *because of the defect*,
  records the steps into `diagnosis.md`, and flips its STATUS
  `REPORTED→REPRODUCING`. qa writes only `tests/` + the `.sdd/` artifact (never
  source — `require-reproducing-test` blocks source until CONFIRMED).

- **`/sdd-fleet:feature-dev` (REPRODUCE→DIAGNOSE → confirmation workflow).** Gates on
  a recorded hypothesis (`## Root-cause hypothesis` / `## Blast radius` /
  `## Fix strategy` must be non-empty), flips STATUS `REPRODUCING→DIAGNOSED`, drops
  the `.workflow-in-flight` marker (run-id owned), and dispatches
  **`workflows/diagnose.js`** (args `{slug, cycle, now, run_id}`).

**`diagnose.js` — an inverted `review.js`.** Reviewer roles `[architect, coder]` (the
PO drops out). Each tries to **refute** the recorded hypothesis, citing the
**reproduction** (the failing test / `diagnosis.md` reproduction steps) — not
`spec.md`/`acceptance.md`. The substantive-refutation floor is reused verbatim (≥40
chars + a citation retargeted to the reproduction; self-refutation filtered by role).
The **inversion**: where a review concern *survives unless refuted*, here the
**hypothesis is CONFIRMED iff no refutation survives** cross-examination. Verdicts:
`confirmed` · `refuted` (revise + re-run while the cycle budget lasts) · `escalate`
(a refutation survives on the cycle that exhausts the 3-cycle budget, or the cause
genuinely can't be found → scribe writes `ESCALATION.md`, `PHASE: ESCALATED`) ·
`incomplete`/`invalid-args` (transient fault or bad dispatch — nothing written,
re-run). Cross-examination rounds within one run do not bump `CYCLE` (one
`/sdd-fleet:feature-dev` = one cycle). The **scribe is reused unchanged** — the
envelope shape matches `review.js`'s, and a surviving refutation is recorded as a
`blocker`.

**Gate-split: the CONFIRMED flip is `/sdd-fleet:feature-dev`'s job, not
`/sdd-fleet:feature-dev`.** `diagnose.js` is async-launched (fire-and-forget, like
`review.js`); the scribe records the verdict (`REVIEW.md` + `PROGRESS.md` CYCLE) on
completion. On `confirmed` the workflow advances `PHASE` → `FIX` (the scribe writes
PROGRESS PHASE); the **`/sdd-fleet:feature-dev`** gate then flips the `diagnosis.md` STATUS
→ `CONFIRMED` *content* — the write the scribe must not do — exactly as
`/sdd-fleet:feature-dev` (not `/sdd-fleet:feature-dev`) flips a spec to `FINALIZED` after
the async review. Keeping the deterministic STATUS write in a synchronous gate keeps
it out of the fire-and-forget workflow.

## FIX → VERIFY → HANDOFF (the fix tail)

Three gate commands carry a confirmed bug to a shipped fix, completing the lane:

- **`/sdd-fleet:feature-dev` (the FIX gate — the bug-lane `/sdd-fleet:feature-dev`).** On a
  `confirmed` bug (`PHASE: FIX`, set by `diagnose.js`) it flips `diagnosis.md` STATUS
  → `CONFIRMED` (the content write that unlocks source — `block-source`'s second
  unlock + `require-reproducing-test` now both pass, since the REPRODUCE test
  exists), then delegates to **coder** to implement the recorded fix strategy and
  turn the reproducing test GREEN without breaking the suite. Emits
  `SDD_FLEET_FIX_DONE`.
  - **sev0 hotfix fast-path.** `SEV: sev0` may run `/sdd-fleet:feature-dev` directly from
    `PHASE: DIAGNOSE` / STATUS `DIAGNOSED`, skipping the `diagnose.js`
    confirmation — but it records a **post-hoc obligation**
    (`SDD_FLEET_POSTHOC_DIAGNOSIS_DUE` + a `diagnosis.md` note) and **never**
    skips the reproducing-test gate. `sev1`/`sev2` get no fast-path.

- **`/sdd-fleet:feature-dev` (the VERIFY gate — the bug-lane CHANGE_REVIEW).** Reuses
  the **counterfactual verbatim**, with the mandatory snapshot procedure:
  1. **Snapshot first, always.** Before any revert, the orchestrator runs
     `git stash create` and records the printed SHA in
     `.sdd/<slug>/IMPL_NOTES.md` (`counterfactual-snapshot: <sha> (<iso8601>)`). If
     the command fails or prints nothing, the gate **refuses** — no counterfactual
     runs without a recorded snapshot.
  2. qa operates **against that recorded ref**: revert the coder's change with
     `git stash` (recoverable), confirm each reproducing test now **FAILS**, then
     restore (`git stash pop`, or `git stash apply <sha>` from the recorded snapshot
     if anything goes wrong). A **bare `git checkout` of the fixed files is
     forbidden** — it destroys the uncommitted fix with no recovery path. A test
     that passes regardless of the fix is decorative — a `[blocker]`.
  3. **Restore is verified before any verdict is evaluated**: the orchestrator
     confirms `git status` / `git diff <recorded-sha>` show the tree back at the
     snapshot state; a mismatched tree is a hard stop, recovered via the recorded
     SHA.
  Meanwhile architect reviews **blast radius** against `diagnosis.md`. Clean → flip
  `diagnosis.md` STATUS → `FIXED`, `PHASE: HANDOFF`. Bounce → `PHASE: FIX`,
  `FIX_CYCLE++` (bounded at 3, then ESCALATE). Emits `SDD_FLEET_VERIFY`.

- **`/sdd-fleet:pr-review` (HANDOFF).** devops ships the verified fix (sev0 = hotfix
  urgency); on `SDD_FLEET_DEVOPS_OK` it emits `SDD_FLEET_SHIP_FIX` and **releases the
  in-flight lock** (`acquire-active.sh release` — the lock-clear that unblocks the
  next item) — **no**
  product-backlog flip or DEVELOPING-loop advance (a bug is not a backlog feature).
  A missing/`_REFUSED` devops signal leaves the lock set and the fix unshipped (the
  safe default).

`/sdd-fleet:status` is bug-lane-aware (`LANE: bug` → prints phase / `SEV` /
`diagnosis.md` STATUS / `CYCLE` / `FIX_CYCLE`). An escalated bug is unblocked with
`/sdd-fleet:resolve-escalation <decision>` or abandoned with
`/sdd-fleet:park <reason>`.
