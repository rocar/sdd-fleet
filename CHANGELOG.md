# Changelog

All notable changes to the build-fleet plugin. Follows [Keep a Changelog](https://keepachangelog.com/) conventions; semver bumps track the plugin's `version` in `.claude-plugin/plugin.json`.

## Compatibility

build-fleet's machine surface is versioned: scaffolded `.sdd/` state files carry an
`SDD_SCHEMA: 1` stamp, the status snapshot declares `build-fleet/status-snapshot@1`, and the
`BUILD_FLEET_*` signal-line grammar is at version 1. Any release that changes the `.sdd/` schema
or the signal grammar adds a **Compatibility** line to its entry below, describing the change and
any migration; additive changes keep the version, breaking changes bump it. **Finish or park
(`/build-fleet:park`) in-flight items before a major upgrade** — mid-flight `.sdd/` state is not
migrated automatically. build-fleet assumes a single driver per working tree: one orchestrator
session per worktree, with the `.sdd/ACTIVE` lock serializing acquisition within that worktree
only (never across clones).

## [0.8.0] — 2026-06-20

`/build-fleet:new-feature` gains a richer feature-detail intake: an optional inline detail
argument, an explicit source-precedence, and a bounded interactive clarify loop in place of the
old one-shot ask. Additive and backward-compatible — the slug-only invocation still works. No
`.sdd/` schema, signal-grammar, or config changes.

### Added

- **Inline feature-detail argument** — `/build-fleet:new-feature <slug> [feature details…]`. The
  first whitespace-delimited token is the slug; everything after it is an optional free-text
  description. When present it is the authoritative description for the run, and is the channel
  headless / `claude -p` callers use to supply detail (`commands/new-feature.md` Arguments + step 5;
  `argument-hint` updated).
- **Structured clarify loop** — when no usable description is found, `new-feature` now asks via
  `AskUserQuestion` (added to the command's `allowed-tools`) in a bounded loop that targets the
  missing components and repeats until the ≥2-of-3 quality floor is met, the user picks
  "proceed anyway", or a 3-round soft cap is reached. Replaces the previous single stop-and-ask.
- **Thin-description hand-off** — if the clarify loop ends below the floor, the architect
  delegation labels the description "best-effort / below the usual detail floor" and asks PO to
  surface the gaps in `## Self-review notes` rather than inventing requirements.

### Changed

- **Description sourcing is now an explicit precedence** — inline arg → conversation context →
  product-backlog intent, with **the inline arg winning** when present. The ≥2-of-3 quality floor
  (what the feature is / its scope boundary / its non-goals) now governs *all* sources: the
  deterministic `INTENT_VERDICT` from `intent-block.sh` for backlog intents, and an orchestrator
  judgment for free-text arg / conversation descriptions. The clarify loop fires on a description
  that is empty **or** below the floor (previously only when entirely absent).
- **`/build-fleet:new-feature` is interactive-only when no detail is provided.** With no inline
  arg and nothing usable in context, the clarify loop needs a human responder; in a headless /
  `claude -p` run, supply the description via the inline argument instead. The `BUILD_FLEET_*`
  signal grammar is unchanged.

## [0.7.1] — 2026-06-17

A correctness patch: a temporal-dead-zone (TDZ) crash made the **deep-build**, **diagnose**, and
**plan-review** workflows fail *every* scribe apply, so verdicts were computed but never written to
`.sdd/` and the in-flight marker was stranded. The deterministic determinism-lint now catches the
class so it can never recur silently. No schema, signal-grammar, or config changes.

### Fixed

- **Scribe-apply TDZ in `deep-build.js`, `diagnose.js`, and `plan-review.js`.** `SCRIBE_RESULT_SCHEMA`
  was declared below every `applyScribe()` call site. `applyScribe` is a hoisted function declaration,
  so the call resolved — but it reads the const via `agent(…, {schema})`, and because the script
  `return`s before reaching the declaration the const stayed in its temporal dead zone: every scribe
  apply threw `ReferenceError: Cannot access 'SCRIBE_RESULT_SCHEMA' before initialization`. The const
  is now hoisted above the first call site in all three, matching the fix `review.js` already received
  (commit `9e50f8a`, shipped in 0.7.0); the sibling workflows were missed by that sweep. `node --check`
  cannot see this — it is a runtime error, not a syntax error.

### Added

- **Determinism-lint rule `scribe-schema-tdz`** (`scripts/workflow-determinism-lint.sh`) — asserts
  `SCRIBE_RESULT_SCHEMA` is declared above the first `applyScribe()` call, so this TDZ class fails the
  lint (and CI) at authoring/pin time instead of reaching a run. With test-harness coverage, including
  a regression assertion that the three previously-broken workflows now pass.

**Compatibility.** None affected. No `.sdd/` schema or signal-grammar change — a correctness fix plus a
new static guard.

## [0.7.0] — 2026-06-15

The **dynamic-workflow enrichment**: build-fleet keeps its deterministic static core but gains
(1) per-item configurable review rosters and cycle budgets, and (2) a governed *generate-then-pin*
lane for novel work. Determinism/auditability is preserved throughout — new configuration is
validated and clamped, and generated workflows are linted, reviewed, and frozen before they can
run. Research + design: `docs/history/2026-06-15-layer2-scaffold-workflow.md`.

### Added

- **Configurable review rosters + cycle budgets (Layer 1).** All four workflows accept optional,
  validated config that defaults to the historical behavior exactly:
  - `review.js` — `roles` (≥2 of architect/qa/coder/architect; the structured-output role enum
    tracks the roster) and `cycle_budget` (1–3, clamped to the ceiling — configurable downward only).
  - `plan-review.js` — `roles` (≥2 of architect/architect/qa).
  - `deep-build.js`, `diagnose.js` — `cycle_budget` (1–3, clamped).
  The pure validators are unit-tested by verbatim extraction from each workflow.
- **Command wiring.** `/build-fleet:review`, `:plan-review`, `:deep-build`, and `:diagnose` resolve
  config as **flag > durable PROGRESS field > default** (`--roles` / `--cycle-budget`; `REVIEW_ROLES`,
  `REVIEW_CYCLE_BUDGET`, `BUILD_CYCLE_BUDGET`, `DIAGNOSE_CYCLE_BUDGET`, `PLAN_REVIEW_ROLES`), pass the
  resolved value through to the authoritative workflow validator, and emit a `BUILD_FLEET_*_CONFIG`
  audit line. `/build-fleet:new-feature` scaffolds the feature-lane fields at their defaults.
- **`/build-fleet:scaffold-workflow` — governed generate-then-pin lane (Layer 2)** for novel, large,
  unknown-shape tasks. *Draft*: Claude authors a candidate workflow into quarantine
  (`.sdd/_generated/<name>.js`), the determinism lint runs, and architect + qa interrogate it
  (advisory). *Ratify*: a hard, fail-closed lint gate (`scripts/pin-workflow.sh`) then freezes the
  candidate into the project's `.claude/workflows/<name>.js`, invokable as `/<name>`. The candidate is
  **never executed before pinning**; the pinned artifact is static and replayable.
- **`scripts/workflow-determinism-lint.sh`** — determinism + sandbox-safety gate (rejects
  `Date.now()` / `Math.random()` / argless `new Date()`, `require`/`import`/`process`/`fs`/`fetch`/
  `eval`, and a missing `export const meta`; strips comments/strings first). With test harness.
- **`scripts/pin-workflow.sh`** — fail-closed pin (lint gate + validated, traversal-rejecting copy
  into `.claude/workflows/`). With test harness.
- Optional PROGRESS fields `REVIEW_ROLES`, `REVIEW_CYCLE_BUDGET`, `BUILD_CYCLE_BUDGET` (feature lane;
  the bug/product analogs `DIAGNOSE_CYCLE_BUDGET` / `PLAN_REVIEW_ROLES` are read-with-default).
- `.sdd/_generated/` quarantine namespace (gitignored).
- Signals: `BUILD_FLEET_REVIEW_CONFIG`, `_PLAN_REVIEW_CONFIG`, `_DEEP_BUILD_CONFIG`, `_DIAGNOSE_CONFIG`,
  `_SCAFFOLD_DRAFT`, `_WORKFLOW_PINNED`, `_WORKFLOW_PIN_REFUSED`, and the lint's
  `_LINT_PASS` / `_LINT_FAIL` / `_LINT_VIOLATION`.

### Changed

- Slash commands 21 → 22 (`scaffold-workflow` added).
- README gains a generate-then-pin section + diagram and a configurable-rosters/budgets note;
  command reference, PROGRESS schema, and the `.sdd/` tree updated. The `sdd-protocol` skill's
  PROGRESS schema documents the new optional fields.

**Compatibility.** Additive only. New PROGRESS fields are optional (readers ignore unknown lines),
and the new `BUILD_FLEET_*` signal names are additive. `SDD_SCHEMA` stays `1`, the signal-line
grammar stays at version 1, and the status snapshot stays `build-fleet/status-snapshot@1`. No
migration required; in-flight `.sdd/` items are unaffected.

## [0.6.2] — 2026-06-11

### Fixed

- **README accuracy pass.** Version banner 0.5 → 0.6; intro rewritten in present tense (was
  framed as v0.4 release notes); the last surviving exit-code claim replaced with the
  `{"code","reason"}` refusal contract; hooks table now lists all ten gates (guard-bash-writes
  was missing) with the fail-closed and bounded-stop-tests semantics; PROGRESS schema gains
  `BUILD_CYCLE`, `PARKED`, and `SDD_SCHEMA`; release-channel CI description matches the
  tag-push design; headless signal list gains PARKED/RESOLVED/ACTIVE_CONFLICT. Docs only.

## [0.6.1] — 2026-06-11

### Fixed

- **Marker reaper broken on Linux.** GNU `stat -f %m <file>` does not fail — it runs in
  filesystem mode and prints the mount point, so the BSD-first probe order poisoned the age
  arithmetic and `reap-stale-workflow-markers.sh` died (exit 1) on every Linux session stop,
  leaving stale `.workflow-in-flight` markers unreaped. Probe order is now GNU-first with a
  numeric guard. Caught by the 0.6.0 CI matrix on its first run.
- **release-channel CI race.** The version≡tag check ran on main pushes and failed spuriously
  when the merge landed before the tag was pushed. It now runs on `v*` tag pushes and pins the
  tag to plugin.json's version — race-free.

## [0.6.0] — 2026-06-11

The professional-standard release: ships the pollable status snapshot (ROADMAP **v0.3a**)
and remediates all 66 findings of the 2026-06-09 end-to-end audit
(`docs/audits/2026-06-09-ultracode-audit.md`).

### Added

- **Pollable status snapshot (ROADMAP v0.3a).** `scripts/status-snapshot.sh` emits one
  machine-readable JSON object (`build-fleet/status-snapshot@1`) describing the full `.sdd/`
  state — for external orchestrators to poll. README gains an "Orchestrator integration"
  section (invocation outside Claude Code, signal stability policy).
- **`/build-fleet:build`** — BUILD orchestration split out of `/build-fleet:finalize`;
  finalize is now a pure, idempotent gate.
- **`/build-fleet:park`** and **`/build-fleet:resolve-escalation`** — the sanctioned sev0
  preemption path and the human escalation-resolution path (both `disable-model-invocation`).
- **Bash/NotebookEdit write gate** (`guard-bash-writes.sh`): shell-level source writes are
  blocked during locked phases; write-gate matchers extended to NotebookEdit.
- **Atomic `.sdd/ACTIVE` acquisition** (`scripts/acquire-active.sh`): noclobber lock with
  owner metadata; new-feature/triage acquire, handoff/ship-fix/park release.
- **Deterministic helpers replace prose:** `scripts/intent-block.sh` (backlog intent
  extraction + quality verdict), `scripts/product-memory-splice.sh` (marker-safe CLAUDE.md
  splicing — never clobbers content outside the markers).
- **Test infrastructure:** `scripts/run-tests.sh` single entrypoint (17 suites, 250+ cases),
  GitHub Actions CI (macOS bash-3.2 + Linux matrix, release-channel version≡tag check),
  suites for every previously untested gate, severity-rubric drift test.

### Changed

- **Gates fail closed.** Path-traversal (`..`) rejection in all path helpers; hooks anchor at
  `CLAUDE_PROJECT_DIR`; missing jq blocks (with install instructions) while an item is active;
  unexpected gate errors trap to exit 2. `stop-tests` honors `stop_hook_active`, retries are
  bounded (3) and escalate to ESCALATION.md instead of wedging the session.
- **Workflow contracts are honest.** `now` is a required arg (no more `UNKNOWN_TIME` in audit
  trails); cost previews parse the real `@cost-ceiling` header; deep-build enforces a
  3-cycle budget via the new `BUILD_CYCLE` field; scribe application is verified (a failed
  state write can no longer hide behind a success verdict); transient agent failures return
  `incomplete` for re-run instead of bricking the feature in ESCALATED; `.workflow-in-flight`
  markers carry a run token, are released by the owning run only, and orphans reap at 15 min.
- **Exit-code tables removed everywhere** — slash commands cannot set exit codes. Refusals
  carry `{"code": <int>, "reason": "<slug>"}` in the `BUILD_FLEET_REFUSE` JSON; the signal
  lines are the sole machine contract (CONTRACT.md updated).
- **Documentation describes the shipped system.** sdd-protocol restructured (321-line core +
  `references/{product-tier,bug-lane}.md`), present tense, classifier contradiction removed;
  adr skill supports product ADRs + `PROVISIONAL`; agent descriptions enumerate bug-lane
  roles; CLAUDE.md is now contributor instructions (v0.1 design spec archived in
  `docs/history/`); milestone jargon stripped from the user-facing surface.
- **verify counterfactual is snapshot-safe:** a `git stash create` SHA is recorded before any
  tree mutation and restore is verified before any verdict.

### Removed

- `workflows/hello.js` (dev probe; findings preserved in `docs/v0.2/hello-probe.md`).

### Compatibility

- Scaffolded `.sdd/` files now carry `SDD_SCHEMA: 1`; existing state without the stamp is
  read fine. New per-worktree coordination files (`ACTIVE.lock`, `.stop-test-retries`) are
  covered by the scaffolded `.sdd/.gitignore` policy.
- **Breaking for headless callers:** `/build-fleet:finalize` no longer runs BUILD — dispatch
  `/build-fleet:build` after it. Exit-code dispatch was never real; parse the
  `BUILD_FLEET_*` lines (now with `{code, reason}`). Review/deep-build/finalize dispatches
  must supply `now`. Signal grammar and snapshot schema remain at version 1 (additive).

## [0.5.1] — 2026-06-10

### Added

- **MIT license.** `LICENSE` file at the repo root, `license` fields in `plugin.json` and the
  marketplace entry, a License section in the README, and SPDX headers on the workflow scripts.
  Every prior tag shipped without a license (all-rights-reserved by default); v0.5.1 is the first
  legally adoptable release. No functional changes.

## [0.5.0] — 2026-06-05

### Added

- **Troubleshoot-fix bug lane** — a second, parallel state machine for diagnosing and fixing
  *unknown-cause* bugs, additive to the forward feature machine (a repo that never files a bug is
  byte-for-byte unchanged). Phases: `REPORT → REPRODUCE → DIAGNOSE → FIX → VERIFY → HANDOFF`. Its
  contract is a new **`diagnosis.md`** artifact (STATUS `REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED`),
  not a spec. Spec of record: `docs/v0.5/troubleshoot-fix-spec/`.
- **Artifact + validator (M0).** `skills/sdd-diagnosis-template` (the diagnosis.md contract);
  `hooks/scripts/validate-diagnosis-status.sh` (PostToolUse, keyed on `basename==diagnosis.md`; no
  cross-fire with the spec validator). `_lib.sh` gains `read_diagnosis_status`, `resolve_lane`,
  `tests_exist`, `path_in_tests`.
- **Source-write gates (M2).** `hooks/scripts/require-reproducing-test.sh` (NEW) — a bug source
  write is blocked unless `diagnosis.md` STATUS==CONFIRMED **and** ≥1 test exists under `tests/`
  (severity-independent — holds for sev0). `block-source-before-finalized.sh` gains a second unlock
  (CONFIRMED), the FINALIZED path byte-identical.
- **Entry (M1).** `/build-fleet:triage <symptom>` scaffolds the bug + runs the classifier in a new
  **bug mode** (`{severity, cause_known}`); a known-cause bug is bounced to the forward trivial path.
- **Diagnosis confirmation (M3).** `workflows/diagnose.js` — an inverted `review.js`: architect +
  coder try to refute the root-cause hypothesis citing the reproduction; CONFIRMED iff no refutation
  survives. Driven by `/build-fleet:reproduce` + `/build-fleet:diagnose`.
- **Fix tail (M4).** `/build-fleet:fix` (FIX gate — flips diagnosis.md→CONFIRMED, drives the coder),
  `/build-fleet:verify` (reuses the CHANGE_REVIEW counterfactual verbatim), `/build-fleet:ship-fix`
  (devops + clears `.sdd/ACTIVE`). sev0 hotfix fast-path. `/build-fleet:status` is bug-lane-aware.
- **New PROGRESS bug-lane fields:** `LANE: bug`, `SEV: sev0|sev1|sev2`, `FIX_CYCLE`. New signals
  include `BUILD_FLEET_TRIAGE`(`_KNOWN_CAUSE`), `BUILD_FLEET_REPRO_READY`,
  `BUILD_FLEET_DIAGNOSE_SEV0_SKIP`, `BUILD_FLEET_FIX_GATE`/`_DONE`, `BUILD_FLEET_VERIFY`,
  `BUILD_FLEET_SHIP_FIX`, `BUILD_FLEET_POSTHOC_DIAGNOSIS_DUE`.
- **Planted-bug smoke test** (`docs/v0.5/smoke/`) — a fixture (a paginator with a floor-division
  bug) + a driver that walks the bug through the lane's deterministic backbone (the hook gates +
  the STATUS lifecycle + RED→GREEN + the VERIFY counterfactual) against the **actual** hooks, plus
  a live-run `WALKTHROUGH.md` for the LLM-driven classifier + `diagnose.js` parts.

### Fixed

- **Hook fail-open under bash 3.2.** The `_lib.sh` STATUS/field readers ended in an unguarded `grep`
  pipeline that, under `set -euo pipefail`, aborted the hook with exit 1 (non-blocking) on a
  status-less file instead of reaching exit 2 — letting a source write slip the gate. Guarded all
  five readers (`read_diagnosis_status`, `read_spec_status`, `read_progress_field`,
  `read_product_field`, `resolve_product`); closes a latent `spec.md` bypass dating to v0.2.
- **Bug-lane `tests/` deadlock (AC-7).** `block-source-before-finalized` blocked a bug's `tests/`
  writes until CONFIRMED — but the reproducing test, written at REPRODUCE *before* CONFIRMED, is the
  precondition for ever reaching CONFIRMED, so the lane deadlocked at REPRODUCE. Taught the bug
  branch to permit `tests/` (mirroring `require-reproducing-test`). Caught by the new planted-bug
  smoke test; now a regression case in `block-source-before-finalized.test.sh`.

## [0.4.0] — 2026-06-05

> **Note:** 0.3.0 was never released. The ROADMAP's v0.3x items (status export,
> orchestrator-mediated human intervention) ship in later versions; the plugin version
> jumps 0.2.1 → 0.4.0.

### Added

- **Product tier (M0)** — a reserved `.sdd/_product/` namespace (vision, phased backlog,
  `STACK.md`, product ADRs) inherited read-only by every feature. The **binding
  stack-of-record** prevents two features from picking conflicting stacks; greenfield
  ratifies a fresh stack, brownfield's observed baseline binds while the forward stack
  stays `PROVISIONAL`. Entry point: `/build-fleet:new-product`. The tier is optional and
  additive — a repo with no `.sdd/_product/` behaves exactly as before.
- **PLAN state machine (M3.1).** `PLAN → PLAN_REVIEW → PLAN_FINALIZE → DEVELOPING`,
  mirroring the feature machine one level up with an inverted temperament. New
  `workflows/plan-review.js` runs PLAN_REVIEW as **interrogation, not a survival vote**
  — architect / architect / qa surface questions, risks, and gaps (including intent
  quality); nothing is auto-killed and it never auto-escalates.
- **Human ratification gate.** `/build-fleet:plan-finalize` **never auto-passes** — even
  with zero findings. Bare invocation is a dry-run; `ratify` flips state only with zero
  open blockers; `ratify force` overrides them on the record. It never promotes a
  `PROVISIONAL` stack entry.
- **DEVELOPING loop (M2 + M3.2).** A successful `/build-fleet:handoff` flips the
  feature's backlog row to DONE and **clears `.sdd/ACTIVE`**; the next unblocked feature
  is re-resolved live by the new deterministic resolver `scripts/next-feature.sh`
  (with its own test harness) — never a cached index.
- **Per-feature backlog intent (M3.3)** — a 1–3 line scope sketch (what + scope boundary
  + non-goals) inherited by `/build-fleet:new-feature` and reviewed at PLAN_REVIEW;
  seeds the spec so the PO realizes the plan's intent instead of re-guessing from the slug.
- **`/build-fleet:next-feature` (M4)** — optional advancement convenience: resolves +
  gates the next backlog feature and emits a dispatch signal. It surfaces, it doesn't
  auto-advance.
- **Product memory (M3.1.1).** Ratification (and `/build-fleet:product-memory`) writes a
  delimited `<!-- BEGIN/END build-fleet:product -->` block into the repo-root `CLAUDE.md`
  — non-clobbering (everything outside the markers is preserved) and idempotent.
- **Dynamic skill routing to BUILD roles (M1)** — new `skills/skill-routing` skill +
  classifier manifest rules route domain skills to coder/qa; routed skills are inherited
  by product-tier features.
- **New commands:** `/build-fleet:new-product`, `/build-fleet:plan-review`,
  `/build-fleet:plan-finalize`, `/build-fleet:next-feature`, `/build-fleet:product-memory`.
- **New hook:** `hooks/scripts/validate-backlog-status.sh` (validates backlog.md edits).
- **Scribe `workspace_dir` (M3.0)** — workflow state mutations can now target either
  `.sdd/<feature>/` or `.sdd/_product/`.

### Fixed

- **Hooks resolve `.sdd` paths under a symlinked cwd.**
- **Product-stack inheritance keystone hardened (M0)** — brownfield forward stack is
  `PROVISIONAL`, the observed baseline binds.
- **Skill-routing precision + dispatch parity (M1).**

## [0.2.1] — 2026-05-30

### Fixed

- **Stop-hook deadlock at SPEC phase.** `hooks/scripts/stop-tests.sh` ran the
  test suite in every phase and treated `pytest` exit code 5 ("no tests
  collected") as a failure. Pre-BUILD there are no tests yet — and the
  `block-source-before-finalized` gate makes it impossible to write any — so the
  session could neither stop nor pass. The hook now (a) only enforces the suite
  in `BUILD | CHANGE_REVIEW | HANDOFF`, and (b) tolerates `pytest` exit 5 as a
  non-failure. Surfaced by the first real install dogfood (bf-smoke).
- **`new-feature` classified from the bare slug.** With no description in
  conversation context, the command let the classifier infer requirements from
  the slug name alone, producing a hallucinated spec. New step 5 ("Establish the
  feature description") stops and asks the user what the feature should do when
  no description exists in context; subsequent steps renumbered.

## [0.2.0] — 2026-05-30

### Added

- **Dynamic workflow for REVIEW phase** (M1). `workflows/review.js` runs 5 phases: read state → fan-out reviewers (architect/qa/coder) → adversarial cross-examination → survival vote → scribe applies state delta. Replaces the v0.1 parallel-Task fan-out + cycle-3 agent-teams fallback.
- **`workflows/deep-build.js` for fan-out BUILD** (M3). Architect plans a file partition; up to 8 coders fan out in parallel; in-workflow adversarial review (architect + qa) catches integration gaps before BUILD declares complete. Partition overlap detection prevents concurrent coders from racing on shared files.
- **Three-tier M4 routing.** New `agents/classifier.md` (read-only subagent emitting JSON verdicts) + new `commands/dispatch.md` (query-only classifier wrapper). `/build-fleet:new-feature` now invokes the classifier and writes `TIER` + `BUILD_MODE` to PROGRESS.md. Trivial features skip REVIEW; large features get `BUILD_MODE=deep-build` for automatic routing through finalize.
- **`agents/scribe.md` subagent** — write-only state applier; the canonical writer of workflow-driven `.sdd/` state mutations (workflows can't touch the filesystem directly).
- **Headless mode first-class.** Every command emits `BUILD_FLEET_*:` JSON-line signals before any human-readable prose. New signals: `BUILD_FLEET_REFUSE`, `BUILD_FLEET_CLASSIFICATION`, `BUILD_FLEET_CLASSIFIER_FALLBACK`, `BUILD_FLEET_COST_PREVIEW`, `BUILD_FLEET_WORKFLOW_LAUNCHED`, `BUILD_FLEET_FINALIZE_PASS/REFUSE`, `BUILD_FLEET_FINALIZE_TRIVIAL_FAST_PATH`, `BUILD_FLEET_BUILD_ROUTE`, `BUILD_FLEET_QA_TESTS_READY`, `BUILD_FLEET_QA_VERIFY_FAIL`, `BUILD_FLEET_CODER_REFUSE`, `BUILD_FLEET_BUILD_COMPLETE/INCOMPLETE/DISPATCH_FAIL`.
- **Tests-first BUILD ordering** (M2). `/build-fleet:finalize` now sequences qa-first then coder for `BUILD_MODE=standard`. coder refuses to begin until QA's failing tests exist (emits `BUILD_FLEET_CODER_REFUSE:` machine-readable). CHANGE_REVIEW adds the M2 counterfactual gate ("would each test fail without coder's source change?").
- **`hooks/scripts/reap-stale-workflow-markers.sh`** — Stop hook that removes `.workflow-in-flight` markers older than 1 hour (handles orphan markers from failed workflow launches; preserves safety property of per-reviewer hooks).
- **PROGRESS.md schema fields:** `TIER` (M4: `trivial | standard | large | pending`), `BUILD_MODE` (M3+M4: `standard | deep-build | pending`).
- **`docs/v0.2/CONTROLS.md`** — M0 gate-vs-judgment control inventory.
- **`docs/v0.2/CONTRACT.md`** — workflow ↔ command-layer contract, grounded against `@anthropic-ai/claude-agent-sdk@0.3.158`. Reproduces `WorkflowInput`/`WorkflowOutput` schemas verbatim from SDK type definitions.
- **`ROADMAP.md`** — v0.2 milestones + v0.3 forecast (orchestrator-mediated human intervention via Hermes).

### Changed

- **`hooks/scripts/check-review-written.sh` and `restrict-reviewer-writes.sh`** add a `.sdd/<slug>/.workflow-in-flight` marker bypass. The hooks skip while a workflow is running (workflow's envelope post-condition replaces them for workflow paths); they still fire on non-workflow review paths (CHANGE_REVIEW via `/build-fleet:handoff`).
- **CYCLE semantics:** v0.2 cycles count workflow runs (not command invocations). Cross-examination rounds inside one workflow run do NOT bump CYCLE.
- **Severity rubric (review-rubric skill) preloaded into workflow reviewer subagents** via `AgentDefinition.skills: ["review-rubric"]` instead of v0.1's duplication into agent prompt bodies.
- **`commands/finalize.md` is now a gate AND orchestrator** for the BUILD sequence (M2 sequential or M3 deep-build, routed on BUILD_MODE; M4 trivial fast-path skips review-cycle gate but still honors ESCALATION.md).
- **`agents/scribe.md`** also writes IMPL_NOTES.md when envelope has `impl_notes_appendix` (used by deep-build workflow). Tight constraint: scribe only writes files whose corresponding envelope field is present and non-empty.
- **Signal rename: `QA_TESTS_READY:` → `BUILD_FLEET_QA_TESTS_READY:`** for namespace consistency with the rest of the `BUILD_FLEET_*` family.
- **`.claude-plugin/plugin.json`** version bumped to `0.2.0`.

### Deprecated

- **`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` env var** — no longer needed. The cycle-3 agent-teams fallback in `/build-fleet:review` is gone; workflow cross-examination replaces it. The README section that asked for this env var has been removed.

### Decisions deferred to a future version

- **`hooks/scripts/restrict-reviewer-writes.sh` is retained** despite the v0.2 plan's (`docs/history/V0.2-PLAN.md`) "retire entirely" guidance. CHANGE_REVIEW (`/build-fleet:handoff`) is still v0.1-style and depends on the hook for its reviewer-write-boundary enforcement. The hook will be retired when CHANGE_REVIEW becomes a workflow.
- **`check-review-written.sh` is similarly retained** for the same non-workflow CHANGE_REVIEW path.
- Several **VERIFY-AT-M1 markers** remain in `workflows/review.js` and `workflows/deep-build.js` — runtime-global signature assumptions (`agent()`, `parallel()`, `phase()`) that will be confirmed against a real `/deep-research` raw script at first dispatch.

### Notes for v0.2 users

- **Requires Claude Code v2.1.154 or later** with dynamic workflows enabled (`/config` → "Dynamic workflows" on Pro plans). Hard requirement; no v0.1 fallback if workflows are unavailable.
- **Headless callers** (`claude -p`, Agent SDK / Hermes) must include `Workflow` in `--allowedTools`. The orchestrator is responsible for human approval between workflow runs (no mid-workflow gates in v0.2; that's v0.3's scope).
- The `BUILD_FLEET_*:` signal grammar is documented in `README.md`; the full contract is in `docs/v0.2/CONTRACT.md` § 8.

## [0.1.0] — 2026-05-30

Initial release. Five role subagents (architect, coder, qa, devops) executing the deterministic SPEC → REVIEW → FINALIZE → BUILD → CHANGE_REVIEW → HANDOFF state machine. Five hooks enforce gate boundaries: `block-source-before-finalized`, `restrict-reviewer-writes`, `validate-spec-status`, `check-review-written`, `stop-tests`. Five skills (sdd-protocol, sdd-spec-template, adr, review-rubric, test-plan), five commands (new-feature, review, finalize, handoff, status). Bounded review cycles (≤3 then ESCALATE); first-class human escalation.

Validated end-to-end via the a–g dry-run matrix on 2026-05-30.
