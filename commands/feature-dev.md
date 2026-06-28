---
description: Drive the active per-repo item through its machine one phase at a time — forward REVIEW (review.js) -> FINALIZE gate -> BUILD (qa->coder or deep-build.js); bug REPRODUCE -> DIAGNOSE (diagnose.js) -> FIX -> VERIFY. Stops at any gate refusal or escalation. Ship with /sdd-fleet:pr-review.
allowed-tools: Read, Edit, Bash, Task, Workflow
---

# /sdd-fleet:feature-dev

You are the **orchestrator**. This command **drives the active item through its
per-repo machine, one phase per invocation**, stopping at any gate refusal or
escalation. Read `.sdd/ACTIVE` and `PROGRESS.md` (`LANE`, `PHASE`), then execute
the section matching the current phase below — **preserving every gate, workflow
dispatch, and `SDD_FLEET_*` signal exactly**. The dispatched workflows
(`review.js`, `deep-build.js`, `diagnose.js`) are unchanged.

- **Forward lane:** `PHASE` SPEC/REVIEW → **REVIEW**; review clean → **FINALIZE
  gate**; FINALIZE → **BUILD** (qa→coder, or `deep-build.js` when
  `BUILD_MODE=deep-build`).
- **Bug lane (`LANE: bug`):** REPORT→**REPRODUCE**, REPRODUCE→**DIAGNOSE**,
  DIAGNOSE (confirmed)→**FIX**, FIX→**VERIFY**.

Ship the finished item with `/sdd-fleet:pr-review`.

---

## REVIEW (folded from review)


# /sdd-fleet:feature-dev

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol` skill. The REVIEW phase runs as a Claude Code [dynamic workflow](https://code.claude.com/docs/en/workflows). This command validates preconditions, sets up the workflow handoff, and dispatches the workflow. The workflow (`workflows/review.js`) does the actual fan-out, cross-examination, survival vote, and state-mutation-via-scribe.

## Workflow runtime requirement

The `Workflow` tool must be available. This requires:

- Claude Code v2.1.154 or later
- Workflows enabled in `/config` (Pro plans) — or available by default on Max/Team/Enterprise
- `Workflow` in the session's `allowedTools` (e.g., for headless callers: `claude -p --allowedTools "Workflow,Read,Edit,Write,Bash,Agent" '/sdd-fleet:feature-dev'`)

There is no non-workflow fallback for REVIEW. If the runtime is missing, refuse with the `workflow-runtime-unavailable` signal below and tell the user how to enable workflows.

## What you do

1. **Verify the workflow runtime.** Check that the `Workflow` tool is available. If absent, refuse:
   > `SDD_FLEET_REFUSE: {"command":"review","code":3,"reason":"workflow-runtime-unavailable"}`
   then tell the user the review workflow requires Claude Code v2.1.154+ with workflows enabled (see ROADMAP.md).

2. **Resolve the active feature.** Read `.sdd/ACTIVE`. If empty, refuse with `SDD_FLEET_REFUSE: {"command":"review","code":2,"reason":"no-active-feature"}`.

3. **Check phase.** Read `.sdd/<slug>/PROGRESS.md`. If `PHASE` is not `SPEC` or `REVIEW`, refuse (`{"command":"review","code":2,"reason":"wrong-phase","phase":"<PHASE>"}`).

4. **Check for prior escalation.** If `.sdd/<slug>/ESCALATION.md` exists, refuse (`{"command":"review","code":2,"reason":"escalation-present"}`) — tell the user to read it and resolve it with `/sdd-fleet:resolve-escalation <decision>` (or park the feature).

5. **Resolve the review config, then check the cycle budget.**

   **The reviewer roster and the cycle budget are configurable** (default roster `architect, qa, coder`; default budget `3`). Resolve each from two sources — **a per-run flag wins over the durable PROGRESS.md default**:
   - **roster**: `--roles <r1,r2,...>` in `$ARGUMENTS` → else `REVIEW_ROLES:` in PROGRESS.md → else unset. A roster is a comma-separated, ≥2-element subset of `architect, qa, coder, architect`.
   - **budget**: `--cycle-budget <n>` flag → else `REVIEW_CYCLE_BUDGET:` in PROGRESS.md → else `3`. Call the resolved integer `effective_budget` (treat unset as `3`); clamp it to `1..3` for the precondition below — the workflow re-clamps anything above the 3-cycle ceiling.

   The **workflow is the authoritative validator**: pass the resolved values straight through (step 9) and let `review.js` reject a malformed roster/budget via its `invalid-args` path — do **not** re-implement the allowed-role list or bounds here (that would drift). Do **not** write these into PROGRESS.md; a flag override applies to this run only and is recorded by the config signal line in step 8.

   **Cycle-budget precondition.** The workflow escalates **on** the cycle that exhausts `effective_budget`: if blockers still survive the survival vote at `CYCLE == effective_budget`, that run writes ESCALATION.md and sets `PHASE: ESCALATED` (there is no separate "next cycle" — the exhausting cycle with surviving blockers *is* the escalation). This refusal is a belt-and-suspenders guard for the edge where `CYCLE` is already `>= effective_budget` without a recorded escalation: if `CYCLE >= effective_budget` AND the most recent REVIEW.md cycle still has open `[blocker]` items, refuse — a further run can only escalate, and the workflow owns that write. Refuse with: `SDD_FLEET_REFUSE: {"command":"review","code":2,"reason":"cycle-budget-exhausted","cycle":<n>,"cycle_budget":<effective_budget>}` — resolve blockers in spec.md or accept the escalation.

6. **Pick the new cycle number.** New cycle = `CYCLE + 1`. Pass to the workflow.

7. **Compose the run id and drop the workflow-in-flight marker.** Compose a run id: `review-<slug>-c<new_cycle>-<iso8601 now>` (the same `now` you pass to the workflow in step 9). Write `.sdd/<slug>/.workflow-in-flight` containing exactly that run id as its single line. The hooks `check-review-written` and `restrict-reviewer-writes` skip their gates while this marker exists. The marker is **owned by this run**: the workflow's scribe releases it only if its content still matches the envelope's `run_id`, so a stale or retried run can never release a newer dispatch's marker. Cleanup obligation: if you create this marker and the Workflow tool subsequently fails to launch, release the marker yourself — verify its content still matches your run id, then overwrite it with empty content (an empty marker counts as released; the Stop-hook reaper deletes it) — before exiting.

8. **Emit the cost preview (headless mode contract).** Parse the `@cost-ceiling` header comment at the top of `${CLAUDE_PLUGIN_ROOT}/workflows/review.js`. Write exactly one stdout line — JSON payload for parsability:

   ```
   SDD_FLEET_COST_PREVIEW: {"workflow":"review","feature":"<slug>","cycle":<N>,"input_ceiling":<N>,"output_ceiling":<N>}
   ```

   This substitutes for the interactive launch-prompt's token caution. Orchestrators (Hermes) parse this line and may surface it for human approval before the workflow runs.

   Then emit exactly one **review-config** line recording the effective roster + budget and where each came from — this is what makes a flag override (which is not persisted) auditable in the run log:

   ```
   SDD_FLEET_REVIEW_CONFIG: {"feature":"<slug>","cycle":<N>,"roles":<["..."] | "default">,"cycle_budget":<n | "default">,"roles_source":"flag"|"progress"|"default","budget_source":"flag"|"progress"|"default"}
   ```

9. **Invoke the Workflow tool.** Call `Workflow` with:
   - `scriptPath`: `${CLAUDE_PLUGIN_ROOT}/workflows/review.js`
   - `args`: `{ "feature": "<slug>", "cycle": <new_cycle>, "now": "<iso8601>", "run_id": "<run id from step 7>" }` — **plus** `"roles": [<resolved roster>]` and/or `"cycle_budget": <resolved int>` ONLY when they were resolved from a flag or a `REVIEW_*` PROGRESS.md field in step 5. **Omit a key entirely when unset** so the workflow applies its own default (omitting both reproduces the historical behavior exactly).
   - **Also pass `"prior_blockers": <n>` when `PROGRESS.md` carries a `SURVIVING_BLOCKERS:` field** (the count the previous review cycle recorded). It drives the workflow's count-must-fall regression guard: if the surviving-blocker count does not strictly fall versus that prior value, the workflow escalates **early** rather than burning the remaining budget. **Omit on cycle 1** (no `SURVIVING_BLOCKERS` field yet) so the guard is disabled for the first cycle.

   Supply `now` yourself (the script cannot call `Date`); the workflow refuses to run without it. The Workflow tool is async-launched: it returns immediately with a `runId`, `taskId`, and `transcriptDir`.

10. **Emit the launch line (headless mode contract).** Once the Workflow tool returns, write exactly one stdout line:

    ```
    SDD_FLEET_WORKFLOW_LAUNCHED: {"runId":"<id>","transcriptDir":"<path>","status":"async_launched","feature":"<slug>","cycle":<N>}
    ```

    Orchestrators consume this line to track the workflow's progress (poll via `TaskList`/`TaskGet` until completion).

11. **Verify the run is alive (marker ownership).** The marker from step 7 is normally deleted by the workflow's scribe. After emitting the launch line, poll the launched run once (`TaskGet` on the returned task). If the run has already died (errored/cancelled) before any scribe ran, release `.sdd/<slug>/.workflow-in-flight` yourself — **only if its content still matches your run id**, by overwriting it with empty content — then report the failure instead of step 12's success message. Orchestrators polling later must apply the same rule: dead run + marker content matching this run id → release the marker.

12. **Report and exit.** Tell the user:
    - The workflow is running in the background.
    - The effective reviewer roster and cycle budget for this run — and note if a `--roles`/`--cycle-budget` flag overrode the PROGRESS.md default (the override applies to this run only and is not persisted).
    - `/workflows` shows progress (in interactive mode).
    - Once it completes, `/sdd-fleet:status` will show the verdict.
    - Next legal command depends on the workflow's verdict:
      - `clean` → `/sdd-fleet:feature-dev` (the gate), then `/sdd-fleet:feature-dev`
      - `revise` → `/sdd-fleet:feature-dev` again after PO revises spec.md
      - `escalate` → human action on the ESCALATION.md the workflow writes (the budget is 3 cycles; the workflow escalates on the exhausting cycle)
      - `incomplete` / `invalid-args` → a transient agent fault or bad dispatch args; PHASE/CYCLE are unchanged and nothing was written — re-run `/sdd-fleet:feature-dev` (or fix the dispatch args).
    - **Scribe-apply failure is a hard failure.** If the completed run's return object carries `scribe_apply: "failed"`, the scribe could not write state even after a retry: REVIEW.md/PROGRESS.md did **not** land and the marker may remain (release it if its content matches your run id). Whoever reads that result (you, `/sdd-fleet:status`, or an orchestrator) must report the run as failed with its `scribe_error` — never treat the verdict as applied or advance to the next command.

## What this command does NOT do

- Does not bump `PHASE` or `CYCLE` in PROGRESS.md. The workflow's scribe writes those via the envelope's `state_delta` on completion. Pre-bumping by this command would trip the hooks before the workflow could write its marker bypass.
- Does not append to REVIEW.md. The workflow's reviewer subagents return structured payloads; the scribe appends the canonical entries.
- Does not write ESCALATION.md. The workflow detects budget-exhaustion and writes via the envelope.
- Does not release `.workflow-in-flight` on success. The scribe does that as the final phase (it empties the marker; the reaper deletes the empty file).
- Does not persist `REVIEW_ROLES` / `REVIEW_CYCLE_BUDGET`. The durable per-feature default lives in PROGRESS.md (set out-of-band — e.g. a human edit; the scribe preserves unknown fields across its state writes). A `--roles`/`--cycle-budget` flag overrides that default for the current run only.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_*` signal lines on
stdout are the **sole machine contract**. Every refusal emits exactly one
`SDD_FLEET_REFUSE:` line whose JSON carries `"code"` (an integer preserving
the legacy exit-code semantics: `2` = pre-dispatch validation refused, `3` =
workflow runtime unavailable, `1` = workflow tool launch error) and `"reason"`
(a kebab-case slug). Orchestrators dispatch on the signal line — and on the
`SDD_FLEET_WORKFLOW_LAUNCHED` line for success — never on the process exit
status.

---

## FINALIZE gate (folded from finalize)


# /sdd-fleet:feature-dev

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol`
skill. Consult it for the finalize gate definition.

This is a **gate**, not a request. You do not finalize on demand — you check
the conditions, and if they hold you flip the state. If they don't, you
refuse with an actionable diff.

**This command is the gate ONLY.** It checks the review record, flips
`spec.md` to `FINALIZED`, sets `PHASE: BUILD`, and stops. The BUILD
orchestration (qa-first test drafting, coder dispatch, deep-build routing)
lives in **`/sdd-fleet:feature-dev`** — run it after this gate passes. The split
keeps finalize **idempotent**: re-running it on an already-finalized feature
is a safe no-op.

**Trivial fast-path.** Trivial features (TIER=trivial, set by the classifier
at `/sdd-fleet:jira-story` time) skip the REVIEW phase entirely. Step 2
below recognizes this and finalizes without requiring a completed review
cycle.

## What you do

1. **Resolve the active feature.** Read `.sdd/ACTIVE`. If empty, refuse:
   `SDD_FLEET_FINALIZE_REFUSE: {"code":2,"reason":"no-active-feature"}`.

2. **Check phase + tier.** Read PROGRESS.md. Extract `PHASE`, `TIER`
   (defaults to `standard` if absent), and `STATUS` from spec.md.

   - **Already finalized (idempotent re-run).** If `STATUS=FINALIZED` and
     `PHASE=BUILD`, the gate has already passed — this re-run is a safe no-op.
     Emit:
     `SDD_FLEET_FINALIZE_PASS: {"feature":"<slug>","status":"FINALIZED","phase":"BUILD","already_finalized":true}`
     and tell the user the next move is `/sdd-fleet:feature-dev` (or
     `/sdd-fleet:pr-review` if BUILD already completed). Change nothing.

   - **Trivial fast-path.** If `TIER=trivial` AND `PHASE=SPEC` AND `CYCLE=0`:
     - The classifier already decided REVIEW is unnecessary; skip the
       review-cycle gate entirely.
     - **Still check `.sdd/<slug>/ESCALATION.md`.** Even on the trivial path, a
       human can write ESCALATION.md to halt a feature (e.g., "actually wait,
       I changed my mind"). If present, refuse with `SDD_FLEET_FINALIZE_REFUSE:
       {"feature":"<slug>","code":2,"reason":"escalation-present","tier":"trivial"}` and
       surface the ESCALATION.md contents.
     - Verify `spec.md` exists and has a valid STATUS line + required sections
       (the `validate-spec-status` hook would catch missing sections anyway).
     - Emit: `SDD_FLEET_FINALIZE_TRIVIAL_FAST_PATH: {"feature":"<slug>","tier":"trivial"}`
     - Skip step 4 (no review-cycle to validate). Jump directly to step 6 (pass output).

   - **Standard / large normal path.** `PHASE` must be `REVIEW`. If it's `SPEC`
     (no review has run) AND `TIER` is `standard` or `large`, refuse with:
     `SDD_FLEET_FINALIZE_REFUSE: {"feature":"<slug>","code":2,"reason":"no-review-cycle","tier":"<TIER>","detail":"run /sdd-fleet:feature-dev first"}`.

   - If `PHASE` is past `REVIEW` and not already-finalized (handled above), refuse
     and surface the actual phase
     (`{"code":2,"reason":"wrong-phase","phase":"<PHASE>"}`).

3. **Check ESCALATION.md.** If `.sdd/<active>/ESCALATION.md` exists, refuse —
   the feature is escalated and only a human can unblock it
   (`/sdd-fleet:resolve-escalation` is the sanctioned path).

4. **Check the most recent review cycle.** Read REVIEW.md. Find every block
   tagged with the current `CYCLE:` value. The gate requires:
   - Exactly three reviewer blocks for the current cycle (one each for
     architect, qa, coder). Missing reviewer → refuse.
   - Every block ends in `status: approved`. Any `status: concerns-raised`
     → refuse.
   - Zero open `[blocker]` items across all current-cycle blocks.
     (A `[blocker]` in a prior cycle that the reviewer's current-cycle
     block approves through is fine — what matters is the latest verdict.)
   - `[major]` items in the current cycle are acceptable **only** if each
     is cited by an ADR ID in DECISIONS.md, or resolved in the spec. If a
     `[major]` is neither fixed nor recorded as an ADR, refuse.

5. **Refusal output.** If the gate refuses, emit exactly one machine-readable line
   first (for headless orchestrators), then the human-readable structured list:

   ```
   SDD_FLEET_FINALIZE_REFUSE: {"feature":"<slug>","cycle":<N>,"code":2,"reasons":["missing-<role>","open-blockers","majors-without-adr"]}
   ```

   Reason codes (combine as needed):
   - `missing-<role>` — reviewer block absent for current cycle (one code per missing role)
   - `open-blockers` — current cycle has open `[blocker]` items
   - `majors-without-adr` — `[major]` items lacking ADR citations
   - `not-approved` — at least one reviewer block ends in `status: concerns-raised`

   Then the structured list (human-readable):
   - Reviewers missing their current-cycle block.
   - Open `[blocker]` items, verbatim, with the reviewer attribution.
   - `[major]` items lacking ADRs.
   - The recommended next command (`/sdd-fleet:feature-dev` to run another
     cycle, after PO has revised).

6. **Pass output — flip state and stop.** If the gate passes:

   - Edit `spec.md` so the STATUS line reads `STATUS: FINALIZED`.
   - Edit PROGRESS.md: set `PHASE: BUILD`, refresh `UPDATED:`. The
     source-write block lifts at this point.
   - Emit:

     ```
     SDD_FLEET_FINALIZE_PASS: {"feature":"<slug>","cycle":<N>,"status":"FINALIZED","phase":"BUILD"}
     ```

   - Tell the user: the spec is finalized; the next command is
     **`/sdd-fleet:feature-dev`**, which drives the BUILD sequence (qa drafts the
     failing test suite first, then coder implements — or routes to the
     deep-build workflow when `BUILD_MODE=deep-build`).

   Both edits are idempotent — flipping FINALIZED to FINALIZED is a no-op,
   and the step-2 already-finalized branch short-circuits before this point
   anyway.

## Hard rules

- This command **never** dispatches qa, coder, or any workflow. BUILD
  orchestration is `/sdd-fleet:feature-dev`'s job.
- This command **never** edits REVIEW.md. Reviewer blocks are append-only
  and owned by reviewers.
- This command **never** writes ADRs. If a `[major]` needs an ADR, the
  refusal output should say so and a subsequent `/sdd-fleet:feature-dev`
  cycle is where architect records it.
- A failing finalize is **not** a workflow failure — it's the gate doing
  its job. Report what's missing and let the user iterate.
- **Headless contract.** Every branch above emits exactly one `SDD_FLEET_*:` line
  before any human-readable prose.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_*` signal lines on
stdout are the **sole machine contract**. Every refusal emits exactly one
`SDD_FLEET_FINALIZE_REFUSE:` line whose JSON carries `"code"` (an integer
preserving the legacy exit-code semantics: `2` = precondition refused) and
`"reason"`/`"reasons"` (kebab-case slugs). Orchestrators dispatch on the signal
line, never on the process exit status.

---

## BUILD (folded from build)


# /sdd-fleet:feature-dev

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol`
skill. This command drives the BUILD sequence for a feature whose spec the
`/sdd-fleet:feature-dev` gate has already flipped to `FINALIZED`. It was split
out of finalize (which is now the gate only) so the gate stays idempotent and
this orchestration owns its own preconditions.

**Architecture notes:**
- **Standard BUILD (sequential).** For `BUILD_MODE=standard`, the qa-then-coder
  orchestration below runs via sequential `Task` calls inside this command.
- **Deep-build routing.** For `BUILD_MODE=deep-build`, step 4 routes to
  `workflows/deep-build.js` via the `Workflow` tool — proper resumability and the
  platform's plan-approval gate.

## Preconditions (refuse with a signal line on any failure)

1. **Resolve the active feature.** Read `.sdd/ACTIVE`. If empty, refuse:
   `SDD_FLEET_BUILD_REFUSE: {"code":2,"reason":"no-active-feature"}`.
   Read `.sdd/<slug>/PROGRESS.md`; if it carries `LANE: bug`, refuse —
   the bug lane builds via `/sdd-fleet:feature-dev`
   (`{"code":2,"reason":"bug-lane-item"}`).

2. **Check the gate has passed.** `spec.md` STATUS must be `FINALIZED` and
   `PHASE` must be `BUILD` (tolerate a legacy `FINALIZE` phase value the same
   way). If not, refuse and name the actual state:
   `SDD_FLEET_BUILD_REFUSE: {"feature":"<slug>","code":2,"reason":"not-finalized","status":"<STATUS>","phase":"<PHASE>","detail":"run /sdd-fleet:feature-dev first"}`.

3. **Check ESCALATION.md.** If `.sdd/<slug>/ESCALATION.md` exists, refuse
   (`{"code":2,"reason":"escalation-present"}`) —
   `/sdd-fleet:resolve-escalation` is the sanctioned unblock path.

4. **Re-run guard (the orchestration is NOT idempotent).** If
   `.sdd/<slug>/IMPL_NOTES.md` already records BUILD activity, or a qa-authored
   failing suite for this feature is already in place under `tests/`, a re-run
   would re-dispatch qa over an existing suite. Refuse:
   `SDD_FLEET_BUILD_REFUSE: {"feature":"<slug>","code":2,"reason":"build-already-started"}`
   and tell the user how to proceed instead: dispatch coder manually for an
   iteration, run `/sdd-fleet:feature-dev` (which requires the existing failing
   suite and is resumable), or `/sdd-fleet:pr-review` if BUILD completed.

## What you do (tests-first ordering)

a. **Dispatch qa first.** Use the Task tool to invoke `sdd-fleet:qa` with this
   prompt:

   > PHASE=BUILD for feature `<slug>`. STATUS=FINALIZED. Draft `.sdd/<slug>/TEST_PLAN.md`
   > per the `test-plan` skill, then implement the failing test suite under `tests/`.
   > Every test must initially FAIL. When the full failing suite is in place, emit
   > exactly: `SDD_FLEET_QA_TESTS_READY: <count> failing tests in tests/`. Do NOT signal coder
   > or write any source — only tests.
   > If `.sdd/<slug>/SKILL_MANIFEST.md` exists, first load and apply the skills it
   > lists under the `qa` role (per the `skill-routing` skill); an unavailable
   > skill is a no-op — note it in TEST_PLAN.md and proceed.

b. **Wait for QA's signal and verify.** When qa's Task call returns, parse its
   output for the `SDD_FLEET_QA_TESTS_READY: <N>` line.

   **Branch — qa never emitted the signal.** If qa returns without `SDD_FLEET_QA_TESTS_READY:`
   (e.g., qa surfaced a spec gap, errored, or refused), do NOT dispatch coder. Emit:

   ```
   SDD_FLEET_QA_VERIFY_FAIL: {"feature":"<slug>","reason":"no-signal","qa_output_tail":"<last 200 chars>"}
   ```

   then surface qa's full output and stop. The spec stays FINALIZED, PHASE stays
   BUILD — coder is not dispatched. BUILD halts safely when qa cannot proceed.

   **Branch — signal present, verify the suite.** Run the project's test command
   (`npm test` / `pytest -q` / `make test` per stack detection). Confirm:
   - At least one test exists (count > 0).
   - All QA-authored tests currently fail.
   - The count in the `SDD_FLEET_QA_TESTS_READY: <N>` signal exactly matches the actually-failing
     count (no tolerance — strict counting; the deep-build workflow may relax this).

   **On verification success, lock the suite.** Add `TESTS_LOCKED: <count>` to
   `.sdd/<slug>/PROGRESS.md` (an `.sdd/` write, always gate-permitted) **before**
   dispatching coder or routing to deep-build. This freezes the qa-authored tests
   via the `write-lock-tests` hook — for the rest of BUILD the coder physically
   cannot edit the suite it is judged against (the design's oracle-trust
   guarantee). Idempotent: if `TESTS_LOCKED` is already present, leave it.

   If verification fails (zero tests, all pass, count mismatch), emit:

   ```
   SDD_FLEET_QA_VERIFY_FAIL: {"feature":"<slug>","reason":"<zero-tests|all-pass|count-mismatch>","claimed":<N>,"observed":<M>}
   ```

   then refuse to dispatch coder and surface the discrepancy. STATUS stays FINALIZED,
   PHASE stays BUILD. The user resolves the discrepancy externally (re-run qa
   manually or edit the test suite); a blind re-run of `/sdd-fleet:feature-dev` will
   refuse via the precondition-4 re-run guard.

c. **Route on BUILD_MODE.** Read `BUILD_MODE:` from PROGRESS.md.
   Absent or `standard` → standard sequential BUILD (this command continues with
   single coder dispatch below). `deep-build` → dispatch the deep-build workflow.

   The deep-build branch mirrors `/sdd-fleet:feature-dev`'s own dispatch shape
   so the workflow is invoked under identical preconditions regardless of entry
   point:

   i.   Verify `Workflow` tool availability. If absent, emit
        `SDD_FLEET_BUILD_REFUSE: {"feature":"<slug>","code":3,"reason":"workflow-runtime-unavailable","detail":"use BUILD_MODE=standard or upgrade Claude Code"}`
        and stop.

   ii.  Emit the route signal:
        ```
        SDD_FLEET_BUILD_ROUTE: {"feature":"<slug>","build_mode":"deep-build"}
        ```

   iii. **Resolve the BUILD cycle.** Read `BUILD_CYCLE:` from PROGRESS.md; if the
        field is absent, add `BUILD_CYCLE: 0` first (the scribe replaces fields in
        place, so it must exist before dispatch). If `BUILD_CYCLE >= 3`, refuse —
        mirror `/sdd-fleet:feature-dev`'s budget refusal (the budget is 3 build
        cycles; the workflow escalates on the exhausting cycle). New cycle =
        `BUILD_CYCLE + 1`.

   iv.  **Compose the run id and drop the workflow-in-flight marker.** Compose a
        run id `deep-build-<slug>-c<new_cycle>-<iso8601 now>` (the same `now` you
        pass in step vi) and write `.sdd/<slug>/.workflow-in-flight` containing
        exactly that run id as its single line. Hooks `check-review-written` and
        `restrict-reviewer-writes` skip while the marker is live; the scribe
        releases it (empties it) as the workflow's final phase — only if its
        content still matches the envelope's `run_id`. **Cleanup obligation:** if
        the Workflow tool subsequently returns an `error` (step vi) or fails to
        launch — or a post-launch poll shows the run died before any scribe ran —
        release the marker yourself (verify its content still matches your run
        id, then overwrite it with empty content) before reporting the failure.

   v.   **Emit cost preview** (headless contract parity with /sdd-fleet:feature-dev).
        Parse the `@cost-ceiling` header comment at the top of
        `${CLAUDE_PLUGIN_ROOT}/workflows/deep-build.js`:
        ```
        SDD_FLEET_COST_PREVIEW: {"workflow":"deep-build","feature":"<slug>","cycle":<N>,"input_ceiling":<N>,"output_ceiling":<N>}
        ```

   vi.  **Invoke the `Workflow` tool** with:
        - `scriptPath`: `${CLAUDE_PLUGIN_ROOT}/workflows/deep-build.js`
        - `args`: `{ "feature": "<slug>", "cycle": <new_cycle>, "now": "<iso8601>", "run_id": "<run id from step iv>" }`

        Supply `now` yourself (the script cannot call `Date`); the workflow
        refuses to run without `feature`, `cycle`, or `now`.

   vii. **Emit the launch line:**
        ```
        SDD_FLEET_WORKFLOW_LAUNCHED: {"runId":"<id>","transcriptDir":"<path>","status":"async_launched","feature":"<slug>","cycle":<N>,"workflow":"deep-build"}
        ```

   viii. Tell the user the deep-build workflow is running in the background;
        `/workflows` shows progress; next command after completion is
        `/sdd-fleet:pr-review` (for verdict=clean) or `/sdd-fleet:feature-dev` to
        iterate (for verdict=needs-iteration — the envelope carries
        `cycles_remaining` against the 3-cycle BUILD_CYCLE budget). A verdict of
        `incomplete`/`invalid-args` means PHASE/BUILD_CYCLE are unchanged — re-run
        after reading the result's `note` (partial worktree writes are possible if
        coders had fanned out). **Scribe-apply failure is a hard failure:** a
        return object carrying `scribe_apply: "failed"` means IMPL_NOTES.md/
        PROGRESS.md did NOT land — report the run as failed with its
        `scribe_error`; never treat the verdict as applied. **Stop here** —
        the workflow's scribe handles state writes; the BUILD-complete signal will
        come from the workflow's envelope, not from this command. Skip step d/e.

   Otherwise (BUILD_MODE absent or `standard`) — continue with single-coder
   dispatch:

d. **Dispatch coder.** Use the Task tool to invoke `sdd-fleet:coder` with this prompt:

   > PHASE=BUILD for feature `<slug>`. STATUS=FINALIZED. QA has authored
   > `<count>` failing tests under `tests/`. Per `agents/coder.md`, refuse-to-begin
   > if tests are absent or already passing. Implement source until every QA test
   > passes. Record `gap:` / `deviation:` / `todo:` markers in
   > `.sdd/<slug>/IMPL_NOTES.md`. Self-review against acceptance.md before
   > declaring BUILD complete.
   > If `.sdd/<slug>/SKILL_MANIFEST.md` exists, first load and apply the skills it
   > lists under the `coder` role (per the `skill-routing` skill); an unavailable
   > skill is a no-op — record `skill-unavailable: <name>` in IMPL_NOTES.md and
   > proceed with normal craft.

e. **Wait for coder's Task call to return, then branch.**

   **Branch — coder refused to begin.** Parse coder's output for
   `SDD_FLEET_CODER_REFUSE:`. If present, do NOT report BUILD complete. Emit:

   ```
   SDD_FLEET_BUILD_DISPATCH_FAIL: {"feature":"<slug>","reason":"coder-refused","coder_refusal":"<the SDD_FLEET_CODER_REFUSE line verbatim>"}
   ```

   then surface coder's output and stop. STATUS stays FINALIZED, PHASE stays BUILD.
   This is the tests-first violation check.

   **Branch — coder completed.** When coder's Task call returns and the source has
   been written, run the test suite one final time. If all tests pass, emit:

   ```
   SDD_FLEET_BUILD_COMPLETE: {"feature":"<slug>","tests_passing":<N>,"impl_notes_path":".sdd/<slug>/IMPL_NOTES.md"}
   ```

   then tell the user: BUILD complete (qa drafted the failing suite, coder drove them
   green); review `IMPL_NOTES.md` for `gap:` / `deviation:` / `todo:` markers; the
   next command is `/sdd-fleet:pr-review` (which runs CHANGE_REVIEW including QA's
   counterfactual gate).

   If the final test run shows failures, emit:

   ```
   SDD_FLEET_BUILD_INCOMPLETE: {"feature":"<slug>","failing_tests":<N>}
   ```

   then surface the failing tests. Coder needs to iterate — the user can dispatch
   coder again manually (this command does not auto-loop). STATUS stays FINALIZED,
   PHASE stays BUILD.

## Hard rules

- This command **never** flips `spec.md` STATUS — that is `/sdd-fleet:feature-dev`'s
  gate. It refuses if the gate has not already passed.
- This command **never** edits REVIEW.md or writes ADRs.
- **Non-idempotency.** The orchestration (steps a–e) is NOT idempotent: the
  precondition-4 re-run guard refuses rather than re-dispatching qa over an
  existing suite. The deep-build workflow path is the resumable variant
  (`workflows/deep-build.js` uses the platform's `resumeFromRunId`).
- **Headless contract.** Every branch above emits exactly one `SDD_FLEET_*:` line
  before any human-readable prose, so orchestrators can dispatch on machine-readable
  outcome codes without parsing the wider response.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_*` signal lines on
stdout are the **sole machine contract**. Every refusal emits exactly one
`SDD_FLEET_BUILD_REFUSE:` line whose JSON carries `"code"` (an integer
preserving the legacy exit-code semantics: `2` = precondition refused, `3` =
workflow runtime unavailable, `1` = workflow tool launch error) and `"reason"`
(a kebab-case slug). Orchestrators dispatch on the signal line, never on the
process exit status.

---

## BUILD deep-build (folded from deep-build)


# /sdd-fleet:feature-dev

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol` skill. BUILD for multi-file / multi-package features runs as a Claude Code [dynamic workflow](https://code.claude.com/docs/en/workflows). This command validates preconditions, sets up the workflow handoff, and dispatches `workflows/deep-build.js`.

The workflow itself: architect plans an N-way file partition, N coders fan out in parallel (each owning a disjoint file set, all writing against the pre-existing failing tests qa authored), then architect + qa run an adversarial review of the merged diff against `acceptance.md`. The scribe aggregates results into `IMPL_NOTES.md` and updates PROGRESS.md.

## When to use this vs. standard BUILD

- **`/sdd-fleet:feature-dev`** runs standard BUILD (qa first, then a single coder). Best for single-file or tightly coupled features where partitioning has no benefit.
- **`/sdd-fleet:feature-dev`** runs the fan-out workflow. Best for multi-package monorepos or features spanning many independent files where parallel coders give real time wins.

The classifier sets `BUILD_MODE: deep-build` in `PROGRESS.md` for features it routes here, and `/sdd-fleet:feature-dev` dispatches this workflow automatically. This command is the manual / iteration entry point.

## Workflow runtime requirement

Same as `/sdd-fleet:feature-dev`: `Workflow` tool must be available (Claude Code v2.1.154+ with workflows enabled). See ROADMAP.md.

## Arguments

- `$ARGUMENTS` — a leading optional integer overrides `max_partitions` (default 3, hard cap 8), e.g. `/sdd-fleet:feature-dev 5`.
- `--cycle-budget <1-3>` — optional override of the BUILD escalation budget (default 3, clamped to the 3-cycle ceiling), e.g. `/sdd-fleet:feature-dev 5 --cycle-budget 2`.

## What you do

1. **Verify the workflow runtime.** Check that the `Workflow` tool is available. If absent, refuse:
   > `SDD_FLEET_REFUSE: {"command":"deep-build","code":3,"reason":"workflow-runtime-unavailable"}`
   then tell the user the deep-build workflow requires Claude Code v2.1.154+ with workflows enabled.

2. **Resolve the active feature.** Read `.sdd/ACTIVE`. If empty, refuse with `SDD_FLEET_REFUSE: {"command":"deep-build","code":2,"reason":"no-active-feature"}`.

3. **Check phase.** Read `.sdd/<slug>/PROGRESS.md`. PHASE must be `BUILD`. STATUS in `spec.md` must be `FINALIZED`. If either fails, refuse and name the actual state (`{"command":"deep-build","code":2,"reason":"not-finalized","status":"<STATUS>","phase":"<PHASE>"}`).

4. **Check tests-first prerequisite.** List files under `tests/`. If empty or absent, refuse with: `SDD_FLEET_REFUSE: {"command":"deep-build","code":2,"reason":"no-failing-tests","detail":"run /sdd-fleet:feature-dev first so qa drafts the suite (tests-first ordering)"}`. If `TESTS_LOCKED` is absent in `.sdd/<slug>/PROGRESS.md`, add `TESTS_LOCKED: <count of test files>` now (the suite exists per this check) so the fan-out coders are write-locked out of the qa suite via the `write-lock-tests` hook.

5. **Check for prior escalation.** If `.sdd/<slug>/ESCALATION.md` exists, refuse (`{"command":"deep-build","code":2,"reason":"escalation-present"}`) — `/sdd-fleet:resolve-escalation` is the unblock path.

6. **Resolve the cycle budget, then check it.** The BUILD escalation budget is configurable (default 3). Resolve it — **a per-run flag wins over the durable default**: `--cycle-budget <n>` in `$ARGUMENTS` → else `BUILD_CYCLE_BUDGET:` in `.sdd/<slug>/PROGRESS.md` → else `3`. Call the resolved integer `effective_budget` (treat unset as `3`); clamp it to `1..3` (the workflow re-clamps anything above the ceiling). The **workflow is the authoritative validator** — pass the resolved value through (step 11) and let `deep-build.js` reject a malformed budget via its `invalid-args` path; do **not** persist `BUILD_CYCLE_BUDGET` (a flag override is per-run).

   Read `BUILD_CYCLE:` from `.sdd/<slug>/PROGRESS.md`. If the field is absent (a feature scaffolded before BUILD_CYCLE existed), add `BUILD_CYCLE: 0` to PROGRESS.md first — the workflow's scribe replaces fields **in place**, so the field must exist before dispatch (an `.sdd/` write; always gate-permitted). The workflow escalates **on** the cycle that exhausts `effective_budget`: blocker-severity concerns surviving the adversarial review at `BUILD_CYCLE == effective_budget` make that run write ESCALATION.md and set `PHASE: ESCALATED`. If `BUILD_CYCLE >= effective_budget` AND the last run left surviving blockers, refuse with: `SDD_FLEET_REFUSE: {"command":"deep-build","code":2,"reason":"build-cycle-budget-exhausted","build_cycle":<n>,"cycle_budget":<effective_budget>}` — resolve the surviving blockers or accept the escalation.

7. **Pick the new cycle number.** New cycle = `BUILD_CYCLE + 1`. Pass it to the workflow as `cycle`; the workflow's scribe writes it back to `BUILD_CYCLE` via the envelope's `state_delta`.

8. **Parse arguments.** A leading integer in `[1, 8]` is `max_partitions` (else default `3`). A `--cycle-budget <n>` token sets the budget already resolved in step 6. Both are optional and independent.

9. **Compose the run id and drop the workflow-in-flight marker.** Compose a run id: `deep-build-<slug>-c<new_cycle>-<iso8601 now>` (the same `now` you pass to the workflow in step 11). Write `.sdd/<slug>/.workflow-in-flight` containing exactly that run id as its single line. Hooks skip while the marker is live. The marker is **owned by this run**: the scribe releases it (empties it) only if its content still matches the envelope's `run_id`. Cleanup obligation: see "Cleanup obligation" below.

10. **Emit the cost preview (headless mode contract).** Parse the `@cost-ceiling` header comment at the top of `${CLAUDE_PLUGIN_ROOT}/workflows/deep-build.js`. Emit one stdout line:

   ```
   SDD_FLEET_COST_PREVIEW: {"workflow":"deep-build","feature":"<slug>","cycle":<N>,"max_partitions":<N>,"input_ceiling":<N>,"output_ceiling":<N>}
   ```

   Then emit one **config** line recording the effective budget and its source (so a non-persisted flag override is auditable in the run log):

   ```
   SDD_FLEET_DEEP_BUILD_CONFIG: {"feature":"<slug>","cycle":<N>,"cycle_budget":<n | "default">,"budget_source":"flag"|"progress"|"default"}
   ```

11. **Invoke the Workflow tool.** Call `Workflow` with:
   - `scriptPath`: `${CLAUDE_PLUGIN_ROOT}/workflows/deep-build.js`
   - `args`: `{ "feature": "<slug>", "cycle": <new_cycle>, "max_partitions": <N>, "now": "<iso8601>", "run_id": "<run id from step 9>" }` — **plus** `"cycle_budget": <resolved int>` ONLY when resolved from a flag or `BUILD_CYCLE_BUDGET` in step 6. **Omit it when unset** so the workflow uses its default (omitting it reproduces the historical behavior exactly).

   Supply `now` yourself (the script cannot call `Date`); the workflow refuses to run without `feature`, `cycle`, or `now`.

12. **Emit the launch line.** Once the Workflow tool returns:

    ```
    SDD_FLEET_WORKFLOW_LAUNCHED: {"runId":"<id>","transcriptDir":"<path>","status":"async_launched","feature":"<slug>","cycle":<N>,"workflow":"deep-build","max_partitions":<N>}
    ```

13. **Verify the run is alive (marker ownership).** Poll the launched run once (`TaskGet` on the returned task). If the run has already died (errored/cancelled) before any scribe ran, release `.sdd/<slug>/.workflow-in-flight` yourself — **only if its content still matches your run id**, by overwriting it with empty content — then report the failure. Orchestrators polling later must apply the same rule: dead run + marker content matching this run id → release the marker.

14. **Report and exit.** Tell the user:
    - The workflow is running in the background. Architect plans the partition first (visible in `/workflows` progress view); coders only fan out after partition is planned.
    - `/workflows` shows progress; press `x` to stop the workflow if the partition looks wrong.
    - Once it completes, `/sdd-fleet:status` shows the verdict. Next legal command depends on verdict:
      - `clean` → `/sdd-fleet:pr-review` (runs CHANGE_REVIEW + devops).
      - `needs-iteration` → `/sdd-fleet:feature-dev` again to re-run. The return envelope carries `cycles_remaining`; the budget is 3 build cycles tracked in PROGRESS.md's `BUILD_CYCLE` field. The workflow re-plans the partition each run, so iterations are expensive — read the surviving concerns in IMPL_NOTES.md before re-running.
      - `escalate` → genuine cycle exhaustion: blockers survived the adversarial review on the cycle that exhausted the 3-cycle budget. The scribe writes ESCALATION.md and sets `PHASE: ESCALATED`; human action required.
      - `incomplete` → a transient fault (architect/coder/reviewer returned no usable payload, or the partition plan was unusable/overlapping). PHASE/BUILD_CYCLE are unchanged, nothing was recorded, and the marker was cleaned up — but **if coders had already fanned out, partial writes may exist in the worktree**: surface the result's `note` and tell the user to inspect `git status`/`git diff` before re-running.
      - `invalid-args` → the dispatch args were malformed; nothing ran. Fix the dispatch and re-run.
    - **Scribe-apply failure is a hard failure.** If the completed run's return object carries `scribe_apply: "failed"`, the scribe could not write state even after a retry: IMPL_NOTES.md/PROGRESS.md did **not** land (though coders may have written source) and the marker may remain (release it if its content matches your run id). Whoever reads that result must report the run as failed with its `scribe_error` — never treat the verdict as applied or advance to `/sdd-fleet:pr-review`.

## What this command does NOT do

- Does not draft tests. `/sdd-fleet:feature-dev` already dispatched qa for that. Deep-build assumes the failing test suite exists.
- Does not bump PHASE, `BUILD_CYCLE`, or run CHANGE_REVIEW. The workflow's scribe writes `BUILD_CYCLE` (and the rest of the BUILD-completion delta) via the envelope's `state_delta`; this command only normalizes a missing `BUILD_CYCLE: 0` field pre-dispatch. CHANGE_REVIEW is `/sdd-fleet:pr-review`'s job.
- Does not write source. Only its coder subagents (inside the workflow) write source — each restricted to its partition.
- Does not release `.workflow-in-flight` on success. Scribe does that as the final phase (only when the marker still contains this run's id; it empties the marker and the reaper deletes the empty file).
- Does not persist `BUILD_CYCLE_BUDGET`. The durable default lives in `.sdd/<slug>/PROGRESS.md` (scaffolded by `/sdd-fleet:jira-story`; the scribe preserves it); a `--cycle-budget` flag overrides it for this run only.

## Cleanup obligation

If `.workflow-in-flight` was created and the Workflow tool fails to launch (returns `error`), release the marker — verify its content still matches your run id, then overwrite it with empty content — then report the failure with `SDD_FLEET_REFUSE: {"command":"deep-build","code":1,"reason":"workflow-launch-failed"}` and the tool's error. The same ownership rule applies to the post-launch liveness check (step 13): a dead run plus a marker still containing this run's id means you release it; a marker with different content belongs to a newer dispatch and must be left alone.

## The BUILD_CYCLE field

`BUILD_CYCLE: <n>` in `.sdd/<slug>/PROGRESS.md` counts completed deep-build runs for the active feature, exactly as `CYCLE` counts REVIEW cycles (and `CHANGE_CYCLE` counts CHANGE_REVIEW cycles). This command reads it and passes `BUILD_CYCLE + 1` as the workflow's `cycle` arg; the workflow's scribe writes the new value back. Budget: 3 — the workflow escalates on the exhausting cycle, and its `needs-iteration` envelope carries `cycles_remaining` so headless orchestrators cannot loop the workflow forever.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_*` signal lines on
stdout are the **sole machine contract**. Every refusal emits exactly one
`SDD_FLEET_REFUSE:` line whose JSON carries `"code"` (an integer preserving
the legacy exit-code semantics: `2` = pre-dispatch validation refused, `3` =
workflow runtime unavailable, `1` = workflow tool launch error) and `"reason"`
(a kebab-case slug). Orchestrators dispatch on the signal line — and on the
`SDD_FLEET_WORKFLOW_LAUNCHED` line for success — never on the process exit
status.

---

## Bug REPRODUCE (folded from reproduce)


# /sdd-fleet:feature-dev

You are the **orchestrator** for the bug lane's REPRODUCE phase. You route and gate; you do
not write the test or source yourself. **Headless-first:** emit the machine signal before prose.

Rulebook: the `sdd-protocol` skill (`references/bug-lane.md`). The `diagnosis.md` contract is the
`sdd-diagnosis-template` skill. This is the bug-lane analog of qa's tests-first BUILD work.

## Preconditions (refuse with a `SDD_FLEET_REFUSE: {"command":"reproduce","code":2,"reason":"<kebab-slug>"}` line — the stdout signal is the sole machine contract; a slash command cannot set a process exit code)

1. **Active bug.** Read `.sdd/ACTIVE`. If empty → refuse (`no active item`). Read
   `.sdd/<slug>/PROGRESS.md`; if `LANE` is not `bug` → refuse (`<slug> is a forward feature —
   use the feature commands`).
2. **Phase.** `PHASE` must be `REPORT`. Otherwise refuse and name the actual phase (e.g. a bug
   already at `REPRODUCE` has its test; one at `DIAGNOSE` is past this step).
3. **Diagnosis status.** `diagnosis.md` STATUS must be `REPORTED`.

## What you do

1. **Delegate to qa.** Use the Task tool to spawn `sdd-fleet:qa` with this prompt:

   > You are qa in the troubleshoot-fix **bug lane**, REPRODUCE phase, for bug `<slug>`.
   > Read `.sdd/<slug>/diagnosis.md` (the symptom is under `## Symptom + reproduction steps`).
   >
   > Author **at least one failing test under `tests/`** that **reproduces the bug** — it must
   > fail *because of the defect*, not because of a missing fixture or import. Run the suite and
   > confirm the new test(s) are RED for the right reason. (Writing under `tests/` is always
   > permitted; you must NOT write source — `require-reproducing-test` blocks source until the
   > diagnosis is CONFIRMED, which is later.)
   >
   > Then edit `.sdd/<slug>/diagnosis.md`: sharpen `## Symptom + reproduction steps` with the
   > concrete steps / the test's path, and flip the STATUS line `REPORTED → REPRODUCING`
   > (keep all four `##` sections — `validate-diagnosis-status` enforces them).
   >
   > Signal when done: `SDD_FLEET_REPRO_READY: <count> failing test(s) reproducing <slug>`.

2. **Verify and advance.** Confirm qa signalled `SDD_FLEET_REPRO_READY` with ≥1 failing test
   and that `diagnosis.md` STATUS is now `REPRODUCING`. Then edit `.sdd/<slug>/PROGRESS.md`:
   `PHASE: REPORT → REPRODUCE`, refresh `UPDATED`.

3. **Emit** the signal (before prose):
   ```
   SDD_FLEET_REPRO_READY: {"slug":"<slug>","failing_tests":<int>}
   ```

4. **Report** the next command: `/sdd-fleet:feature-dev` — record a root-cause hypothesis in
   `diagnosis.md`, then run the adversarial confirmation workflow.

## Notes

- You do not flip `diagnosis.md` STATUS yourself — qa owns the artifact's content in this phase
  (it writes the reproduction steps and the `REPORTED→REPRODUCING` flip). You own `PROGRESS.md`.
- All `tests/` and `.sdd/` writes are gate-permitted at any bug phase; only *source* is gated.

## Refusal cases

- No active item / active item is a forward feature → refuse.
- `PHASE` ≠ `REPORT`, or `diagnosis.md` STATUS ≠ `REPORTED` → refuse, naming the actual state.

---

## Bug DIAGNOSE (folded from diagnose)


# /sdd-fleet:feature-dev

You are the **orchestrator**. The DIAGNOSE phase runs as a Claude Code dynamic workflow
(`workflows/diagnose.js`) — the bug-lane analog of `/sdd-fleet:feature-dev` → `review.js`, with
the survival vote **inverted**: a root-cause *hypothesis* is CONFIRMED iff no substantive,
different-role, reproduction-citing refutation survives. This command validates preconditions,
records the DIAGNOSED transition, and dispatches the workflow. The workflow does the fan-out,
cross-examination, vote, and state-mutation-via-scribe.

Rulebook: the `sdd-protocol` skill (`references/bug-lane.md`); `sdd-diagnosis-template` for the
artifact.

## Workflow runtime requirement

The `Workflow` tool must be available (Claude Code v2.1.154+, workflows enabled; in
`allowedTools` for headless callers). If absent, refuse:
> `SDD_FLEET_REFUSE: {"command":"diagnose","code":3,"reason":"workflow-runtime-unavailable"}`
then tell the user the bug lane's DIAGNOSE phase requires Claude Code v2.1.154+ with workflows enabled.

## What you do

1. **Verify the workflow runtime.** Absent → refuse (as above).

2. **Resolve the active bug.** Read `.sdd/ACTIVE`. Empty → `SDD_FLEET_REFUSE: {"command":"diagnose","code":2,"reason":"no-active-item"}`.
   Read `.sdd/<slug>/PROGRESS.md`; if `LANE` ≠ `bug` → refuse (`{"command":"diagnose","code":2,"reason":"not-a-bug","detail":"<slug> is a forward feature — use /sdd-fleet:feature-dev"}`).

3. **Check phase.** `PHASE` must be `REPRODUCE` or `DIAGNOSE` (first run advances from
   REPRODUCE; a re-run after a `refuted` verdict is already at DIAGNOSE). Otherwise refuse and
   name the actual phase (`{"command":"diagnose","code":2,"reason":"wrong-phase","phase":"<PHASE>"}`).

4. **Check for prior escalation.** If `.sdd/<slug>/ESCALATION.md` exists → refuse
   (`{"command":"diagnose","code":2,"reason":"escalation-present"}`); tell the user to read it
   and either resolve it with `/sdd-fleet:resolve-escalation <decision>` (revising the
   hypothesis) or abandon the bug with `/sdd-fleet:park <reason>`.

5. **Gate on a recorded hypothesis.** Read `.sdd/<slug>/diagnosis.md`. The
   `## Root-cause hypothesis`, `## Blast radius`, and `## Fix strategy` sections must each be
   **non-empty** — i.e. real content, not the `_(empty until DIAGNOSE)_` placeholder. If the
   **hypothesis** section is still empty/placeholder, refuse with a one-line reason naming the
   missing section:
   > `SDD_FLEET_REFUSE: {"command":"diagnose","code":2,"reason":"hypothesis-empty","detail":"record a root-cause hypothesis (and blast radius + fix strategy) in diagnosis.md before diagnosing"}`
   (Whoever holds the reproduction writes the hypothesis into `diagnosis.md` first.)

6. **Advance to DIAGNOSED.** If `diagnosis.md` STATUS is `REPRODUCING`, flip it to `DIAGNOSED`
   (keep all four `##` sections). Edit `.sdd/<slug>/PROGRESS.md` `PHASE: → DIAGNOSE`, refresh
   `UPDATED`. (Both are `.sdd/` writes — always gate-permitted.)

6b. **sev0 hotfix fast-path — skip the confirmation workflow.** Read `SEV` from
   PROGRESS.md. If `SEV == sev0`, the hotfix path **may skip** the adversarial confirmation. After
   the DIAGNOSED advance (step 6), do **not** drop the marker or dispatch `diagnose.js`. Emit:
   ```
   SDD_FLEET_DIAGNOSE_SEV0_SKIP: {"slug":"<slug>","reason":"sev0 hotfix — adversarial confirmation deferred to post-ship"}
   ```
   and tell the user to run **`/sdd-fleet:feature-dev`** directly — it takes the bug from
   `PHASE: DIAGNOSE` / STATUS `DIAGNOSED`, flips `diagnosis.md` → `CONFIRMED` via the fast-path, and
   records the post-hoc obligation (`SDD_FLEET_POSTHOC_DIAGNOSIS_DUE`). The reproducing-test gate
   still holds. **Stop here** (no workflow). `sev1`/`sev2` continue to step 7. *(An operator who
   wants full confirmation on a `sev0` can lower `SEV` in PROGRESS.md before re-running.)*

7. **Resolve the cycle budget, then check it.** The DIAGNOSE escalation budget is configurable
   (default 3). Resolve it — **a per-run flag wins over the durable default**: `--cycle-budget <n>`
   in `$ARGUMENTS` → else `DIAGNOSE_CYCLE_BUDGET:` in `.sdd/<slug>/PROGRESS.md` → else `3`. Call the
   resolved integer `effective_budget` (treat unset as `3`); clamp it to `1..3` (the workflow
   re-clamps anything above the ceiling). The **workflow is the authoritative validator** — pass the
   resolved value through (step 11) and let `diagnose.js` reject a malformed budget via its
   `invalid-args` path; do **not** persist `DIAGNOSE_CYCLE_BUDGET` (a flag override is per-run).

   Read `CYCLE`. If `CYCLE >= effective_budget` and the most recent diagnose cycle in `REVIEW.md`
   still records a surviving refutation, refuse — the next run would escalate; let the workflow own
   that write only on a fresh attempt:
   > `SDD_FLEET_REFUSE: {"command":"diagnose","code":2,"reason":"cycle-budget-exhausted","cycle":<n>,"cycle_budget":<effective_budget>}`
   then tell the user: revise the hypothesis in diagnosis.md or accept the escalation.

8. **Pick the new cycle.** `new_cycle = CYCLE + 1`.

9. **Compose the run id and drop the workflow-in-flight marker.** Compose a run id:
   `diagnose-<slug>-c<new_cycle>-<iso8601 now>` (the same `now` you pass in step 11). Write
   `.sdd/<slug>/.workflow-in-flight` containing exactly that run id as its single line. The
   marker is **owned by this run**: the scribe releases it (empties it) in the workflow's final
   phase only if its content still matches the envelope's `run_id`. **Cleanup obligation:** if
   you create the marker and the `Workflow` tool then fails to launch, release the marker —
   verify its content still matches your run id, then overwrite it with empty content (an empty
   marker counts as released; the reaper deletes it) — before exiting.

10. **Emit the cost preview** (parse the `@cost-ceiling` header comment of
    `${CLAUDE_PLUGIN_ROOT}/workflows/diagnose.js`):
    ```
    SDD_FLEET_COST_PREVIEW: {"workflow":"diagnose","slug":"<slug>","cycle":<N>,"input_ceiling":<N>,"output_ceiling":<N>}
    ```
    Then emit one **config** line recording the effective budget and its source (so a non-persisted
    flag override is auditable in the run log):
    ```
    SDD_FLEET_DIAGNOSE_CONFIG: {"slug":"<slug>","cycle":<N>,"cycle_budget":<n | "default">,"budget_source":"flag"|"progress"|"default"}
    ```

11. **Invoke the Workflow tool** with:
    - `scriptPath`: `${CLAUDE_PLUGIN_ROOT}/workflows/diagnose.js`
    - `args`: `{ "slug": "<slug>", "cycle": <new_cycle>, "now": "<iso8601>", "run_id": "<run id from step 9>" }` — **plus** `"cycle_budget": <resolved int>` ONLY when resolved from a flag or `DIAGNOSE_CYCLE_BUDGET` in step 7. **Omit it when unset** so the workflow uses its default.

12. **Emit the launch line** once the tool returns:
    ```
    SDD_FLEET_WORKFLOW_LAUNCHED: {"runId":"<id>","transcriptDir":"<path>","status":"async_launched","slug":"<slug>","cycle":<N>,"workflow":"diagnose"}
    ```

13. **Verify the run is alive (marker ownership).** Poll the launched run once (`TaskGet` on
    the returned task). If the run has already died (errored/cancelled) before any scribe ran,
    release `.sdd/<slug>/.workflow-in-flight` yourself — **only if its content still matches
    your run id**, by overwriting it with empty content — then report the failure. Orchestrators
    polling later must apply the same rule: dead run + marker content matching this run id →
    release the marker.

14. **Report and exit.** The workflow runs in the background (`/workflows` shows progress;
    `/sdd-fleet:status` shows the verdict on completion). Next legal command by verdict:
    - `confirmed` → **`/sdd-fleet:feature-dev`** — the FIX gate reads the confirmed verdict, flips
      `diagnosis.md` → `CONFIRMED` + `PHASE` → `FIX`, then implements the fix.
    - `refuted` → revise `diagnosis.md`'s hypothesis, then re-run `/sdd-fleet:feature-dev`.
    - `escalate` → human action on the `ESCALATION.md` the workflow's scribe writes.
    - `incomplete` / `invalid-args` → a transient agent fault or bad dispatch args; PHASE/CYCLE
      are unchanged and nothing was written — re-run `/sdd-fleet:feature-dev` (or fix the
      dispatch args).

    **Scribe-apply failure is a hard failure.** If the completed run's return object carries
    `scribe_apply: "failed"`, the scribe could not write state even after a retry: REVIEW.md/
    PROGRESS.md did **not** land and the marker may remain (release it if its content matches
    your run id). Whoever reads that result must report the run as failed with its
    `scribe_error` — never treat the verdict as applied or advance to `/sdd-fleet:feature-dev`.

## The CONFIRMED flip is the FIX gate's job (not this command)

The `diagnose.js` workflow is **async-launched**: this command dispatches it and returns; the
scribe records the verdict (`REVIEW.md` + `PROGRESS.md` CYCLE) on completion. The
`diagnosis.md` STATUS → `CONFIRMED` + `PHASE` → `FIX` flip is applied by **`/sdd-fleet:feature-dev`**
when it reads a `confirmed` verdict — exactly as `/sdd-fleet:feature-dev` (not `/sdd-fleet:feature-dev`)
flips a spec to `FINALIZED` after the async review. This keeps the deterministic STATUS flip in a
synchronous gate command rather than inside the fire-and-forget workflow.

## What this command does NOT do

- Does not flip `diagnosis.md` to `CONFIRMED` — that is `/sdd-fleet:feature-dev`'s gate (above).
- Does not append to `REVIEW.md` or write `ESCALATION.md` — the workflow's scribe does, via the envelope.
- Does not release `.workflow-in-flight` on success — the scribe does, as the final phase.
- Does not persist `DIAGNOSE_CYCLE_BUDGET`. Set the durable default out-of-band in `.sdd/<slug>/PROGRESS.md` (the scribe preserves unknown fields); a `--cycle-budget` flag overrides it for this run only.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_*` signal lines on
stdout are the **sole machine contract**. Every refusal emits exactly one
`SDD_FLEET_REFUSE:` line whose JSON carries `"code"` (an integer preserving
the legacy exit-code semantics: `2` = pre-dispatch validation refused, `3` =
workflow runtime unavailable, `1` = workflow tool launch error) and `"reason"`
(a kebab-case slug). Orchestrators dispatch on the signal line — and on the
`SDD_FLEET_WORKFLOW_LAUNCHED` line for success — never on the process exit
status.

---

## Bug FIX (folded from fix)


# /sdd-fleet:feature-dev

You are the **orchestrator**. This is the bug-lane analog of `/sdd-fleet:feature-dev` — a
**gate**, not a request. The `diagnose.js` workflow advances a confirmed bug to `PHASE: FIX`;
this command applies the deterministic `diagnosis.md` STATUS → `CONFIRMED` *content* flip (the
write the scribe must not do, mirroring how `/sdd-fleet:feature-dev` flips `spec.md` after
review), which unlocks source writes (`block-source-before-finalized`'s second unlock +
`require-reproducing-test`: CONFIRMED **and** the reproducing test from REPRODUCE both hold),
then drives the coder to turn the reproducing test GREEN.

Rulebook: the `sdd-protocol` skill (`references/bug-lane.md`).

## What you do

1. **Resolve the active bug.** Read `.sdd/ACTIVE` (empty → `SDD_FLEET_REFUSE: {"command":"fix","code":2,"reason":"no-active-item"}`).
   Read `.sdd/<slug>/PROGRESS.md`; `LANE` must be `bug` (else refuse — use the forward commands).

2. **Check ESCALATION.** If `.sdd/<slug>/ESCALATION.md` exists → refuse
   (`{"command":"fix","code":2,"reason":"escalation-present"}`) — `/sdd-fleet:resolve-escalation` is the unblock path.

3. **The gate — determine the path.** Read `PHASE` + `SEV` from PROGRESS.md and the
   `diagnosis.md` STATUS:

   - **Confirmed (normal).** `PHASE == FIX` → the `diagnose.js` workflow CONFIRMED the
     hypothesis. Proceed.
   - **sev0 hotfix fast-path.** `PHASE == DIAGNOSE` **and** `SEV == sev0` **and**
     `diagnosis.md` STATUS == `DIAGNOSED` → sev0 may skip the adversarial confirmation
     workflow. Proceed via the fast-path (step 4b records the post-hoc obligation). This
     **never** skips the reproducing-test gate.
   - **Re-entry after a verify bounce.** `PHASE == FIX` with STATUS already `CONFIRMED` →
     proceed (re-dispatch the coder).
   - **Otherwise** (`PHASE == DIAGNOSE` and not sev0, or any other phase) → refuse:
     `SDD_FLEET_REFUSE: {"command":"fix","code":2,"reason":"diagnosis-not-confirmed","detail":"run /sdd-fleet:feature-dev first (sev0 may use the fast-path)"}`.

4. **Pre-flight: the reproducing test must exist.** Confirm ≥1 file under `tests/` (REPRODUCE
   produced it). If none → refuse: `SDD_FLEET_REFUSE: {"command":"fix","code":2,"reason":"no-reproducing-test","detail":"run /sdd-fleet:feature-dev first"}`. (The gate would block source anyway; refusing here is clearer.)

5. **Apply the confirm flip.**
   a. If `diagnosis.md` STATUS ≠ `CONFIRMED`, flip it → `CONFIRMED` (keep all four `##`
      sections). Ensure PROGRESS `PHASE: FIX`; refresh `UPDATED`. Source writes are now permitted.
   b. **sev0 fast-path only:** append a note under `## Fix strategy` that adversarial
      confirmation was skipped and is **owed post-ship**, and emit:
      ```
      SDD_FLEET_POSTHOC_DIAGNOSIS_DUE: {"slug":"<slug>"}
      ```
   Emit:
   ```
   SDD_FLEET_FIX_GATE: {"slug":"<slug>","sev":"<sev>","path":"confirmed|sev0-fast-path"}
   ```

6. **Delegate to coder.** Use the Task tool to invoke `sdd-fleet:coder`:

   > PHASE=FIX for bug `<slug>`. `diagnosis.md` is CONFIRMED and a failing reproduction test
   > exists under `tests/`. Read `.sdd/<slug>/diagnosis.md` — implement the recorded **fix
   > strategy** so the reproducing test(s) turn GREEN **without breaking the existing suite**.
   > Stay within the stated **blast radius**; do not widen it. Record `gap:`/`deviation:`/`todo:`
   > markers in `.sdd/<slug>/IMPL_NOTES.md`. When the reproducing test(s) pass and the suite is
   > green, emit exactly: `SDD_FLEET_FIX_DONE: <count> tests green`.

7. **Verify and report.** When coder returns, run the project's test command (per
   `stop-tests.sh` detection). 
   - All green (reproducing test(s) now pass, suite passes) → emit:
     ```
     SDD_FLEET_FIX_DONE: {"slug":"<slug>","tests_green":<N>}
     ```
     Next command: `/sdd-fleet:feature-dev` (the counterfactual gate).
   - Still failing → emit `SDD_FLEET_FIX_INCOMPLETE: {"slug":"<slug>","failing_tests":<N>}`,
     surface the failures; coder iterates (no auto-loop). PHASE stays `FIX`.

## What this does NOT do

- Does not run the `diagnose.js` workflow (that is `/sdd-fleet:feature-dev`).
- For `sev1`/`sev2`, does **not** bypass confirmation — it refuses unless `PHASE == FIX`.

## Refusal cases

- No active bug / active item is a forward feature / `ESCALATION.md` present.
- `PHASE == DIAGNOSE` and not `sev0` → confirm via `/sdd-fleet:feature-dev` first.
- No reproducing test under `tests/`.

---

## Bug VERIFY (folded from verify)


# /sdd-fleet:feature-dev

You are the **orchestrator**. This is the bug-lane analog of CHANGE_REVIEW, and it **reuses the
counterfactual gate verbatim**: a reproducing test that passes *regardless* of the fix is
decorative, not a regression guard. The fix is verified only when each reproducing test would
**fail if the coder's change were reverted**.

Rulebook: the `sdd-protocol` skill (`references/bug-lane.md`; the CHANGE_REVIEW counterfactual).

## What you do

1. **Resolve the active bug.** `.sdd/ACTIVE` non-empty; PROGRESS `LANE == bug`. Else refuse.

2. **Check phase + status.** `PHASE` must be `FIX`; `diagnosis.md` STATUS must be `CONFIRMED`.
   `ESCALATION.md` absent. Otherwise refuse and name the actual state.

3. **Pre-flight.** ≥1 test exists under `tests/` and the **full suite passes** (the fix made
   the reproducing test green). If the suite fails → refuse: the fix isn't done; run
   `/sdd-fleet:feature-dev`.

3b. **Snapshot the fix BEFORE any counterfactual (mandatory).** The working tree holds the
   *uncommitted, only copy* of the fix — reverting it without a recoverable snapshot is how
   a fix gets destroyed. Run:
   ```bash
   git stash create "verify-counterfactual snapshot <slug>"
   ```
   It snapshots the working tree **without modifying it** and prints a commit SHA. Record
   that SHA in `.sdd/<slug>/IMPL_NOTES.md` as a line:
   `counterfactual-snapshot: <sha> (<iso8601>)`.
   **If the command fails or prints nothing** (e.g. not a git repo, or nothing to snapshot —
   which would mean there is no uncommitted fix to protect and the state needs a human look),
   **refuse to proceed**: `SDD_FLEET_REFUSE: {"command":"verify","code":2,"reason":"snapshot-failed"}`.
   No counterfactual runs without a recorded snapshot SHA.

4. **Run the counterfactual + blast-radius review (parallel Task calls).**

   - **qa — the counterfactual, against the recorded snapshot.** Pass qa the snapshot SHA
     from step 3b. For each reproducing test: revert the coder's source change with
     `git stash` (recoverable — the stash plus the recorded SHA both hold the fix), run the
     test, and confirm it now **FAILS** for the bug's reason; then **restore** the fix
     (`git stash pop`, or `git stash apply <sha>` from the recorded snapshot if anything
     goes wrong). **A bare `git checkout` of the fixed files is FORBIDDEN** — it destroys
     the uncommitted fix with no recovery path. A reproducing test that still **passes**
     with the fix reverted is decorative — qa records it as a `[blocker]`. qa appends its
     findings to `.sdd/<slug>/REVIEW.md`.
   - **architect — blast radius.** Review the diff against `diagnosis.md`'s `## Blast radius`:
     did the fix stay within the stated surface, or did it touch more than the diagnosis
     justified? Out-of-radius changes are a `[major]`/`[blocker]` per severity. Append to `REVIEW.md`.

4b. **Verify the restore BEFORE evaluating (mandatory).** After qa returns and before you
   read any verdict: confirm the working tree again matches the step-3b snapshot —
   `git status` shows the same set of modified files, and `git diff <recorded-sha>` over the
   fix's files is empty. If the tree does NOT match, **stop — do not evaluate**: restore the
   fix from the snapshot (`git stash apply <recorded-sha>` / `git stash pop`), re-verify, and
   only then continue. Emit `SDD_FLEET_VERIFY_RESTORE_FAIL: {"slug":"<slug>","snapshot":"<sha>"}`
   if the restore itself fails — that is a hard stop for a human; the recorded SHA in
   IMPL_NOTES.md is the recovery handle (`git stash apply <sha>`).

5. **Evaluate.**

   - **Clean** — every reproducing test fails when reverted (counterfactual satisfied) **and**
     no surviving `[blocker]`. Flip `diagnosis.md` STATUS → `FIXED`; set PROGRESS `PHASE:
     HANDOFF`; refresh `UPDATED`. Emit:
     ```
     SDD_FLEET_VERIFY: {"slug":"<slug>","verdict":"clean","counterfactual_ok":true}
     ```
     Next command: `/sdd-fleet:pr-review`.

   - **Bounce** — a reproducing test passes with the fix reverted (counterfactual fails) **or**
     a surviving `[blocker]`. Increment `FIX_CYCLE`; set PROGRESS `PHASE: FIX`. 
     - If `FIX_CYCLE >= 3` → **escalate**: write `.sdd/<slug>/ESCALATION.md` (the failing
       counterfactual / surviving blockers), set `PHASE: ESCALATED`, stop. Emit
       `SDD_FLEET_VERIFY: {"slug":"<slug>","verdict":"escalate","counterfactual_ok":false}`.
     - Else emit:
       ```
       SDD_FLEET_VERIFY: {"slug":"<slug>","verdict":"bounce","counterfactual_ok":false}
       ```
       Next command: `/sdd-fleet:feature-dev` — the coder iterates.

## Refusal cases

- No active bug / active item is a forward feature.
- `PHASE` ≠ `FIX`, or `diagnosis.md` STATUS ≠ `CONFIRMED`, or `ESCALATION.md` present.
- No tests, or the suite fails (the fix isn't complete).
- `git stash create` fails or returns no SHA (no recorded snapshot → no counterfactual).

A slash command cannot set a process exit code; the `SDD_FLEET_*` signal lines on stdout
are the sole machine contract (refusals carry `{"code":2,"reason":"<kebab-slug>"}`).

