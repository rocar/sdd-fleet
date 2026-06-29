---
description: Own CHANGE_REVIEW and the ship for the active item — dispatch the change-review workflow (architect + qa, adjudicated survival vote, deterministic counterfactual, bounded regression-guarded loop) over the implemented change, then on a clean verdict ship via devops, release the lock, and flip the backlog (forward HANDOFF, or bug ship-fix / sev0 hotfix).
allowed-tools: Read, Edit, Bash, Task, Workflow
---

# /sdd-fleet:pr-review

You are the **orchestrator**. This command owns **CHANGE_REVIEW and the ship**.
Read `.sdd/ACTIVE` and `PROGRESS.md` (`LANE`, `PHASE`); preserve every gate and
`SDD_FLEET_*` signal exactly.

- **Forward (`PHASE` BUILD→CHANGE_REVIEW→HANDOFF):** dispatch the **change-review
  workflow** (`workflows/change-review.js` — the same engine as REVIEW, on the
  implemented change) with the deterministic counterfactual as a vote input; on a
  clean verdict, ship via devops, release the lock, flip the backlog.
- **Bug (`LANE: bug`, `PHASE` VERIFY→HANDOFF):** ship the verified fix (sev0 =
  hotfix).

## Forward change-review + handoff (folded from handoff)


<!-- Deliberately model-invocable (audit §3.22 evaluated): handoff is dispatched
     by the orchestrator inside the DEVELOPING loop, and its devops leg only
     advances on an explicit SDD_FLEET_DEVOPS_OK signal — the human gates live
     at /sdd-fleet:feature-dev and /sdd-fleet:plan-finalize, not here. -->

# /sdd-fleet:pr-review

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol`
skill. Consult it for the CHANGE_REVIEW phase, the CHANGE_CYCLE budget
(≤ 3 then ESCALATE), and DevOps' refusal conditions.

## What you do

1. **Resolve the active feature.** Read `.sdd/ACTIVE`. If empty, refuse.

2. **Check phase.** Read PROGRESS.md. PHASE must be `BUILD` or
   `CHANGE_REVIEW`. If it's anything else (especially `SPEC` or `REVIEW`),
   refuse and tell the user to run `/sdd-fleet:feature-dev` then
   `/sdd-fleet:feature-dev` first.

3. **Check ESCALATION.md.** If it exists, refuse.

4. **Pre-flight: tests must exist and pass.**
   - If no tests exist (no `tests/` dir, no test files, no `test`
     command), refuse: BUILD is not complete until qa has authored tests
     per `acceptance.md`.
   - Run the project's test command (npm test / pytest / make test, per
     `stop-tests.sh`'s detection). If tests fail, refuse with the failing
     output. The `stop-tests` hook would catch this at session-end anyway;
     catching it here gives a clearer error.

4b. **Capture REAL coverage (grounds qa, not its opinion — audit C3).** Run the
   deterministic helper and record its verdict so the change-review qa reviewer (which
   reads IMPL_NOTES.md) reacts to the captured number, not a guess:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/coverage.sh"
   ```
   Append the `SDD_FLEET_COVERAGE: {…}` line to `.sdd/<slug>/IMPL_NOTES.md` as
   `real-coverage: <pct>% (per scripts/coverage.sh)`. Branch on its verdict:
   - `report` / `ok` → proceed (the real % is now on record for qa).
   - `below` (an `SDD_FLEET_COVERAGE_MIN` threshold is set and unmet) → refuse
     `SDD_FLEET_REFUSE: {"command":"pr-review","code":2,"reason":"coverage-below-threshold","pct":<n>,"min":<n>}`;
     coverage is a real gate when a threshold is configured.
   - `skip` (no coverage tool / unparseable) → note it in IMPL_NOTES.md and proceed;
     qa falls back to matrix-based assessment (the capture is best-effort, not a hard
     dependency).

5. **Verify the workflow runtime.** CHANGE_REVIEW runs as a dynamic workflow
   (`workflows/change-review.js`) — **the same deterministic engine as REVIEW**
   (fan-out → cross-examine → neutral-adjudicator survival vote → bounded,
   regression-guarded loop), on the implemented change. The cross-examination,
   survival vote, cycle budget, count-must-fall guard, and ESCALATION.md write all
   live in the workflow, not in this command's prose. If the `Workflow` tool is
   unavailable, refuse
   `SDD_FLEET_REFUSE: {"command":"pr-review","code":3,"reason":"workflow-runtime-unavailable"}`
   and tell the user to enable workflows (Claude Code v2.1.154+).

6. **Resolve the change-cycle.** Read `CHANGE_CYCLE:` from PROGRESS.md; if absent,
   add `CHANGE_CYCLE: 0` first (an `.sdd/` write; the scribe replaces fields in
   place, so it must exist before dispatch). The budget is 3 cycles and the
   **workflow owns** escalation (it writes ESCALATION.md + `PHASE: ESCALATED` on the
   exhausting cycle, and escalates EARLY when the surviving-blocker count fails to
   strictly fall). Belt-and-suspenders only: if `CHANGE_CYCLE >= 3` AND the latest
   CHANGE_REVIEW cycle in REVIEW.md still has open `[blocker]` items, refuse
   `SDD_FLEET_REFUSE: {"command":"pr-review","code":2,"reason":"change-cycle-budget-exhausted","change_cycle":<n>}`.
   Otherwise the new cycle = `CHANGE_CYCLE + 1`. **Do not pre-bump `CHANGE_CYCLE` or
   set `PHASE: CHANGE_REVIEW`** — the workflow's scribe writes both via the envelope.

7. **Run the deterministic counterfactual (the script decides, you narrate).** It
   reverts ONLY the coder's source change (keeping the qa-authored tests), runs the
   suite, and emits the verdict — you do not judge the red/green delta:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/counterfactual.sh"
   ```
   Capture the verdict from its `SDD_FLEET_COUNTERFACTUAL: {…}` line (`pass` | `fail`
   | `skip`) and record it in `IMPL_NOTES.md`. You **pass it to the workflow**
   (step 8b) as a VOTE INPUT: a `fail` becomes a blocker in the survival vote there —
   you do not adjudicate it yourself.

8. **Compose the run id and drop the workflow-in-flight marker.** Compose
   `change-review-<slug>-c<new_cycle>-<iso8601 now>` (the same `now` you pass in 8b)
   and write it as the single line of `.sdd/<slug>/.workflow-in-flight` (the
   reviewer-gating hooks stand down while it is live; the scribe releases it on
   completion only if its content matches `run_id`). **Cleanup obligation:** if the
   Workflow tool fails to launch, or a post-launch poll shows the run died before any
   scribe ran, release the marker yourself — only if its content still matches your
   run id.

8a. **Emit the cost preview** (headless contract). Parse the `@cost-ceiling` header
   of `${CLAUDE_PLUGIN_ROOT}/workflows/change-review.js` and emit one line:
   `SDD_FLEET_COST_PREVIEW: {"workflow":"change-review","feature":"<slug>","cycle":<N>,"input_ceiling":<N>,"output_ceiling":<N>}`.

8b. **Invoke the Workflow tool.** Call `Workflow` with:
   - `scriptPath`: `${CLAUDE_PLUGIN_ROOT}/workflows/change-review.js`
   - `args`: `{ "feature": "<slug>", "cycle": <new_cycle>, "now": "<iso8601>", "run_id": "<id from step 8>", "roles": ["architect","qa"], "counterfactual": "<pass|fail|skip from step 7>" }` — **plus** `"prior_blockers": <n>` from PROGRESS.md `CHANGE_SURVIVING_BLOCKERS` when present (**omit on the first change cycle** so the regression guard is disabled for cycle 1), **plus** `"criteria": [<AC ids>]` parsed from `.sdd/<slug>/acceptance.md` (or the spec's inline `## Acceptance Criteria`) so the workflow requires a per-AC verdict from every reviewer (silence impossible); omit/empty when there are no `AC-N` ids.
   Supply `now` yourself (the script cannot call Date). Then emit the launch line:
   `SDD_FLEET_WORKFLOW_LAUNCHED: {"runId":"<id>","transcriptDir":"<path>","status":"async_launched","feature":"<slug>","cycle":<N>,"workflow":"change-review"}`.

8c. **Act on the workflow verdict** (key off the returned envelope, not your own reading of the diff):
   - `clean` → CHANGE_REVIEW passed. Continue to step 9 (devops handoff).
   - `revise` → the workflow set `PHASE: BUILD` (coder must re-implement to address the
     surviving blockers, incl. a failed counterfactual). Tell the user BUILD is open
     again: re-run `/sdd-fleet:feature-dev` (dispatch coder), then `/sdd-fleet:pr-review`.
     `CHANGE_CYCLE` persists. **STOP — do NOT run steps 9–12.** `.sdd/ACTIVE` stays set.
   - `escalate` → the workflow wrote `ESCALATION.md` and set `PHASE: ESCALATED`. Surface
     it; `/sdd-fleet:resolve-escalation` is the unblock path. **STOP.**
   - `incomplete` / `invalid-args` → a transient fault; PHASE/CHANGE_CYCLE unchanged and
     nothing was written — re-run `/sdd-fleet:pr-review`.
   - **Scribe-apply failure is a hard failure:** a return carrying `scribe_apply: "failed"`
     means REVIEW.md/PROGRESS.md did NOT land (release the marker if its content matches
     your run id) — report failure with `scribe_error`; never treat the verdict as applied
     or continue to step 9.

9. **Hand off to devops.** Set `PHASE: HANDOFF` in PROGRESS.md. Use the Task
   tool to launch `sdd-fleet:devops` with a prompt that:
   - Names the active feature.
   - Pointers to spec.md, acceptance.md, DECISIONS.md, IMPL_NOTES.md.
   - Asks for CI/CD updates, IaC if applicable, and release notes.
   - Reminds devops to refuse if PHASE isn't HANDOFF — defense in depth.
   - Reminds devops to end with its completion signal — `SDD_FLEET_DEVOPS_OK`
     on a genuine ship, `SDD_FLEET_DEVOPS_REFUSED` otherwise (per `agents/devops.md`).

   **Branch on the devops result before step 10 — key off its machine signal, not
   its prose.** devops emits exactly one terminal line (`agents/devops.md` →
   Completion signal): `SDD_FLEET_DEVOPS_OK: {…}` on a genuine ship, or
   `SDD_FLEET_DEVOPS_REFUSED: {…,"reason":…}` on any refusal/failure. **Proceed to
   step 10 ONLY if you see `SDD_FLEET_DEVOPS_OK`.** In every other case — `_REFUSED`,
   **or neither line present (a silent/ambiguous return counts as failure)** — emit:
   ```
   SDD_FLEET_HANDOFF_DEVOPS_FAIL: {"feature":"<slug>","reason":"<refused|deploy-failed|no-signal>"}
   ```
   then surface devops' output, **leave `PHASE: HANDOFF` and `.sdd/ACTIVE`
   untouched, and STOP.** **Steps 10–12 run ONLY on `SDD_FLEET_DEVOPS_OK`** — the
   feature is not shipped otherwise, so it must not be marked done and its `ACTIVE`
   must not be cleared. The user resolves the devops issue and re-runs
   `/sdd-fleet:pr-review`. *(Defaulting an unrecognized/missing signal to failure is
   deliberate — the safe default is "not shipped," never a false advance.)*

10. **On devops success.** Edit `spec.md` STATUS line to retain
    `FINALIZED` (no flip) and append a `## Implementation` section if not
    already present, noting the CHANGE_CYCLE that approved and the date.
    Tell the user the feature is shipped (or in the project's equivalent
    of shipped — opened PR, queued release, etc.).

11. **Flip the product backlog, if a product tier exists.** After a
    successful devops completion (step 10), if `.sdd/_product/backlog.md` exists,
    mark this feature done in it:
    - Find the row for the active slug — `- [ ] <slug> …`. If **no row matches**
      (the feature isn't a backlog item — e.g. an ad-hoc fix), **skip this step**
      and note `feature not in product backlog — nothing to flip`. Do not invent a
      row. (There is no `[>]`/active row state — "in flight" is derived from
      `.sdd/ACTIVE`, so a PENDING row is the only thing to flip.)
    - Flip the checkbox and state to:
      `- [x] <slug>   DONE   depends-on: <unchanged>   handoff:<iso-date>`.
      **Preserve any existing `depends-on:` token** (later features reference it);
      only change `- [ ]` → `- [x]`, the `PENDING` word → `DONE`, and append
      `handoff:<iso-date>`.
    - **Recompute the containing `## Phase N: … — STATUS:` line**: `complete` if
      every feature row in that phase is now `[x]`; else `in-progress` if at least
      one row in the phase is `[x]`; else `pending`.
    - Emit: `SDD_FLEET_BACKLOG_FLIP: {"feature":"<slug>","phase":"<phase name>","phase_status":"<complete|in-progress|pending>"}`.

    **Orchestrator-direct write** to `.sdd/_product/backlog.md` — a `.sdd/` path the
    hooks permit at HANDOFF (`block-source-before-finalized` allows anything under
    `.sdd/`; `restrict-reviewer-writes` only acts during REVIEW/CHANGE_REVIEW, and
    we are past that). It deliberately does **not** go through the scribe: the
    scribe is append-only and only workflows write through it.

12. **Advance the DEVELOPING loop.** This step runs **only** on the
    full-completion path — you reached it after devops **succeeded** (step 10) and the
    backlog flip (step 11). A CHANGE_REVIEW bounce-back to BUILD (step 8) and a devops
    refusal/failure (step 9 branch) both STOP earlier and never reach here, so an
    unshipped feature is never advanced.

    a. **Release the in-flight lock.** The shipped feature is no longer in flight —
       release via the shared script (it verifies the slug, removes `.sdd/ACTIVE.lock`,
       and empties `.sdd/ACTIVE` without deleting it; never hand-empty the file):
       ```bash
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" release "<slug>"
       ```
       This is **always** done on a successful ship, whether or not a product tier
       exists: it is the fix that lets the loop continue (`/sdd-fleet:jira-story`
       refuses while the lock is held, and nothing else releases it; leaving it held
       would deadlock the next feature). *(Safe: with no active feature,
       `block-source-before-finalized` and the per-reviewer hooks are simply inactive —
       correct between features.)*

    b. **Resolve the next unblocked feature (live).** Run the shared resolver — exactly
       one read-only call, the single source of truth for "what's next" (it returns
       `no-backlog` on its own when there is no product tier, so call it unconditionally):
       ```bash
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-feature.sh"
       ```
       It re-reads the **live** backlog (never a cached index) and emits one JSON line:
       `next` (slug+phase) | `complete` | `deadlocked` | `empty` | `no-backlog`. Do
       **not** re-derive the next feature in prose — use this output verbatim.

    c. **Surface, do not auto-start.** Report based on `status`:
       - `next` → name the next slug + its phase, and tell the user to start it with
         `/sdd-fleet:jira-story <slug>` (the loop surfaces; it does not auto-advance —
         starting the next feature stays an explicit act).
       - `complete` → the product backlog is fully shipped (`done/total`). Congratulate;
         note that appending features/phases to `backlog.md` re-opens the loop. ("Complete"
         is **derived** from the backlog — there is no terminal PHASE value to set.)
       - `deadlocked` → `<pending>` features remain but none are unblocked. Warn the user
         to check `depends-on` edges / dependency cycles in `backlog.md`. Do **not**
         escalate — the human reorders deps.
       - `empty` → a product backlog exists but **no feature rows parsed** (`total=0`).
         This is **not** "complete" — warn that the backlog has no parseable
         `- [ ] <slug> …` rows and to check its format. Do not congratulate.
       - `no-backlog` → the feature was not part of a product backlog (ad-hoc). Nothing
         to advance; skip silently.

    d. **Emit the machine-readable line** (headless contract):
       ```
       SDD_FLEET_LOOP_ADVANCE: {"completed":"<slug>","backlog":"<in-progress|complete|deadlocked|empty|none>","next":"<next-slug|null>"}
       ```
       Map resolver `status` → `backlog`: `next`→`in-progress`, `complete`→`complete`,
       `deadlocked`→`deadlocked`, `empty`→`empty`, `no-backlog`→`none`. `next` is the
       slug only for `status:next`; it is `null` for every other status.

## Refusal cases

- `.sdd/ACTIVE` empty → refuse.
- PHASE not in `{BUILD, CHANGE_REVIEW}` → refuse with the actual phase.
- ESCALATION.md exists → refuse.
- No tests, or test command fails → refuse with the failing output.
- `CHANGE_CYCLE` budget exhausted with open blockers → write ESCALATION.md
  and stop.

---

## Bug ship (folded from ship-fix)


<!-- Deliberately model-invocable (audit §3.22 evaluated): ship-fix is the
     bug-lane leg the orchestrator dispatches after /sdd-fleet:feature-dev, and it
     only advances on an explicit SDD_FLEET_DEVOPS_OK signal — the human
     decision points in this lane are the gates upstream of it. -->

# /sdd-fleet:pr-review

You are the **orchestrator**. The bug-lane HANDOFF — devops takes the verified fix to release.
Mirrors `/sdd-fleet:pr-review`'s devops leg and its lock-clear, **without** the product-backlog
flip or DEVELOPING-loop advance (a bug is not a backlog feature).

Rulebook: the `sdd-protocol` skill (`references/bug-lane.md`); `agents/devops.md` for the completion signal.

## What you do

1. **Resolve the active bug.** `.sdd/ACTIVE` non-empty; PROGRESS `LANE == bug`. Else refuse.

2. **Check phase + status.** `PHASE` must be `HANDOFF`; `diagnosis.md` STATUS must be `FIXED`.
   `ESCALATION.md` absent. Otherwise refuse and name the actual state
   (`SDD_FLEET_REFUSE: {"command":"ship-fix","code":2,"reason":"<kebab-slug>"}` — the stdout
   signal is the sole machine contract; a slash command cannot set a process exit code).

3. **Pre-flight.** Tests exist and the full suite passes. If not → refuse (re-run
   `/sdd-fleet:feature-dev`).

4. **Delegate to devops.** Use the Task tool to invoke `sdd-fleet:devops`:

   > HANDOFF for bug `<slug>` (severity `<SEV>`). Read `.sdd/<slug>/diagnosis.md` and
   > `IMPL_NOTES.md`. Ship the verified fix: CI/CD as applicable + release notes. For `sev0`,
   > treat this as a **hotfix** (expedited release notes / cherry-pick guidance — no new
   > infrastructure in this lane). Refuse if `PHASE` isn't `HANDOFF` (defense in depth). End
   > with your completion signal: `SDD_FLEET_DEVOPS_OK` on a genuine ship, else
   > `SDD_FLEET_DEVOPS_REFUSED`.

5. **Branch on the devops signal (key off the machine line; a missing/ambiguous return counts
   as failure — the safe default is "not shipped").**

   - **`SDD_FLEET_DEVOPS_OK`** → the fix shipped. Emit:
     ```
     SDD_FLEET_SHIP_FIX: {"slug":"<slug>","severity":"<sev0|sev1|sev2>"}
     ```
     Then **release the in-flight lock via the shared script** (it verifies the slug, removes
     `.sdd/ACTIVE.lock`, and empties `.sdd/ACTIVE` without deleting it; never hand-empty):
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" release "<slug>"
     ```
     so the next `/sdd-fleet:jira-story` or `/sdd-fleet:jira-story` is unblocked.
     **No backlog flip / next-feature resolve** — a bug has no backlog row (if the slug happens
     to match one, skip it; bugs are not backlog features). Report: fix shipped, lock cleared;
     for a `sev0` whose adversarial confirmation was skipped, remind that the post-hoc
     diagnosis confirmation is still owed.

   - **`_REFUSED` / no signal** → emit:
     ```
     SDD_FLEET_SHIP_FIX_FAIL: {"slug":"<slug>","reason":"<refused|deploy-failed|no-signal>"}
     ```
     Leave `PHASE: HANDOFF` and `.sdd/ACTIVE` untouched, surface devops' output, and stop. The
     fix is not shipped; the user resolves the devops issue and re-runs `/sdd-fleet:pr-review`.

## Refusal cases

- No active bug / active item is a forward feature.
- `PHASE` ≠ `HANDOFF`, or `diagnosis.md` STATUS ≠ `FIXED`, or `ESCALATION.md` present.
- No tests, or the suite fails.
