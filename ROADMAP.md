# sdd-fleet — Roadmap

## v0.1 — shipped 2026-05-30

**What landed:** four role subagents (architect, coder, qa, devops), five SDD skills (sdd-protocol, sdd-spec-template, adr, review-rubric, test-plan), five slash commands (/sdd-fleet:jira-story, :review, :finalize, :handoff, :status), five hook scripts (block-source-before-finalized, restrict-reviewer-writes, validate-spec-status, check-review-written, stop-tests) enforcing the gate layer. State machine: SPEC → REVIEW → FINALIZE → BUILD → CHANGE_REVIEW → HANDOFF, with bounded review cycles (≤3) and ESCALATION.md as first-class outcome.

**Validation:** 7/7 a–g dry-run steps passed end-to-end on `smoke-test` and `escalation-test` features. Every gate fired correctly, including the escalation pathway under a manufactured-blocker stress case.

**Known gaps that v0.2 addresses:**
- Cycle-3 agent-team fallback in `/sdd-fleet:feature-dev` depends on an unstable platform feature gated by `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` env var.
- "All-approved" finalize gate is a binary proxy for what's really a judgment call (do the concerns survive scrutiny?), exposed by the escalation-test planted-blocker case.
- Single-track command pipeline can't proportionally scale to trivial fixes (over-ceremony) or to multi-file features (under-fan-out).
- BUILD has coder and qa run in parallel; no enforced tests-first ordering.

---

## v0.2 — workflows architecture (in design)

### Direction

Adopt Claude Code's [dynamic workflow primitive](https://code.claude.com/docs/en/workflows) as the orchestration substrate for multi-agent SDD phases. v0.1's hooks remain the tool-level safety backbone; workflow scripts host phase-transition logic and adversarial cross-examination. Plugin stays orchestrator-agnostic — Hermes-driven headless use is first-class from M1 onward.

### Principle of separation (the M0 lens)

- **Deterministic gates** (binary, mechanically checkable) stay as hooks: source-write block until FINALIZED, STATUS validity, tests-pass, "no open blockers."
- **Judgment convergence** (subjective, needs cross-examination) moves into workflow scripts: spec soundness, concern survival, implementation faithfulness.

Trying to hook-enforce a judgment (or vote on a binary) is the category error v0.2 corrects.

### Milestones

**M0 — Control inventory + workflow contract (design spike, no code shipped).**
Deliverables:
- `docs/v0.2/CONTROLS.md` — every existing control classified as gate-or-judgment; destination per control (hook / workflow script / subagent frontmatter / retired).
- `docs/v0.2/CONTRACT.md` — workflow ↔ command-layer state-mutation contract; headless-mode contract; cost-ceiling declaration format; structured-stdout schema.
- Empirical hook-firing matrix recorded from a minimal probe workflow.

Output gates M1–M4.

**M1 — Review workflow.** Replace `/sdd-fleet:feature-dev`'s parallel + agent-team-cycle-3 hybrid with a workflow that pattern-matches `/deep-research`: fan out reviewers, adversarial cross-check, survival vote, structured report. The convergence rule moves from "all-approved" to "a concern survives unless refuted by cross-examination." `check-review-written` (SubagentStop) re-homes as a workflow post-condition.

**M2 — Tests-first BUILD ordering.** Protocol-only change. QA authors failing tests against acceptance.md before coder implements; the failing tests become coder's convergence target. Small, but it's the prerequisite that makes M3's parallel coders possible.

**M3 — Build workflow.** `/sdd-fleet:feature-dev` for large/multi-file features: fan out coders across partitioned file ownership against M2's failing-test target, with the platform's launch prompt as the plan-approval gate (interactive mode) and the upstream orchestrator providing the equivalent in headless mode. Plan-approval gate is therefore *inherited from the runtime*, not custom code. Adversarial review sub-phase follows the fan-out.

**M4 — Routing front door.** Three-tier classifier: trivial → fast-path skip (skeleton spec straight to finalize); standard → v0.1 command pipeline; large → workflow dispatch to M3. Lands last; depends on M1 and M3 existing as concrete dispatch targets.

### First-class capabilities in v0.2

- **Headless mode (`claude -p` / Agent SDK).** From M1 onward, every workflow command works headlessly. The launch-prompt plan-approval gate is replaced by the caller's between-phase approval (e.g., Hermes posts the workflow's structured output to Discord; Ray approves the next kanban task). Workflows declare cost ceilings the caller can surface upstream.
- **v0.1 hook backbone retained.** Tool-call hooks (`block-source-before-finalized`, `validate-spec-status`) fire on workflow subagents, preserving the source-write block and the spec-format gate.

### Drops from v0.2

- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` README step.
- Cycle-3 agent-team fallback branch in `/sdd-fleet:feature-dev`.
- Deferred `TaskCompleted` / `TeammateIdle` hooks (agent-teams-only, doubly moot).
- `hooks/scripts/restrict-reviewer-writes.sh` — workflow reviewer subagents declare `tools:` allowlists without `Write`/`Edit`; the restriction lives where it belongs (subagent definition) and the hook becomes redundant.

### v0.2 explicitly does NOT include

- Mid-workflow human intervention via external channels (Discord/Slack/email). Workflows can't pause for input mid-run by design. Intervention happens at phase boundaries.
- Discord/Hermes integration adapters inside the plugin. sdd-fleet stays orchestrator-agnostic.
- Marketplace registration.

---

## v0.3 — orchestrator integration

> Split in two. **v0.3a (status export)** ships the lightweight, one-directional
> observability slice — the plugin emits a machine-readable status snapshot an
> external orchestrator can poll. **v0.3b (human intervention)** is the original
> bidirectional forecast below, **deferred** (depends on platform pause/resume
> maturity; v0.4/v0.5 delivered first). v0.3a is the foundation v0.3b builds on —
> an orchestrator can't mediate review of work it can't see.

### v0.3a — pollable status snapshot (shipped in 0.6.0, 2026-06-11)

**Half A — plugin side (shipped, orchestrator-agnostic).** `scripts/status-snapshot.sh`:
a deterministic, LLM-free emitter of one JSON object (`schema:
sdd-fleet/status-snapshot@2`) describing a project's `.sdd/` state — product tier
(vision/stack one-liners, backlog counts + per-feature rows, next unblocked feature)
and the active item (feature or bug lane: phase, status, cycles, escalation). Backlog
**resolution + counts reuse `next-feature.sh`** (the v0.4 resolver — single source of
truth); the snapshot only adds the per-feature row listing, using the same matching
rules so the two never disagree. 48-case harness (`scripts/status-snapshot.test.sh`);
`/sdd-fleet:status` documents it as the machine-readable path. **The plugin ships no
publish path** — where the snapshot goes is the caller's concern.

**Half B — adapter (outside the plugin, e.g. Hermes; operator-gated).** A stateful
poller diffs successive snapshots into durable milestone events. Per project it keeps
**one** knowledge-base page (stable slug, overwrite-in-place, write-only-if-changed)
for current state, and appends a **timeline** on detected transitions —
`started` / `finalized spec` / `shipped` / `ESCALATED` (feature) and `bug confirmed` /
`fixed` (bug). First run sets a baseline (no event flood); state saved after the
timeline writes (at-least-once, deduped by date+text). The snapshot is the
current-state spine; the derived timeline is what plays to a synthesis/staleness-aware
KB's strengths. Activation (poll cron + KB namespace) lives entirely in the
orchestrator's config — never in the plugin.

### v0.3b — orchestrator-mediated human intervention (forecast, deferred)

### Direction

Open the integration surface between sdd-fleet workflows and external orchestrators (Hermes being the primary case) so mid-cycle human review can happen via Discord threads, kanban tasks, or other channels — without rendering sdd-fleet a Hermes-specific plugin. The plugin ships the *protocol*; the orchestrator ships the adapter.

### Candidate milestones

**M0 (v0.3) — Integration handshake protocol.** Define the contract by which an external orchestrator can: (a) hand a workflow a kanban task ID + human-channel handle, (b) receive a workflow's intermediate `WAITING_FOR_HUMAN` signal with a typed payload, (c) resume the workflow (likely as a fresh invocation with a `--resume-token` and the prior state) carrying the human verdict.

**M1 (v0.3) — Reference Hermes adapter.** Reference implementation: kanban task as the workflow handle, Discord thread as the gate surface, signal protocol for resume. Lives outside the plugin (Hermes config or a sibling repo). The plugin only ships the protocol contract.

**M2 (v0.3) — Mid-workflow gate primitives.** Once the protocol exists, add a `PAUSE_FOR_HUMAN` step type to sdd-fleet workflows that want it. May depend on platform-side capabilities (callback hooks, pause-and-resume primitives) maturing — track the workflows doc for changes.

### Deferred from v0.3 to even later

- Multi-orchestrator support (Hermes + Linear + Slack-as-orchestrator simultaneously).
- Plan-approval-via-Discord for headless launches. The v0.2 pattern ("caller surfaces cost ceiling on Discord before dispatch") likely covers 80% of the use case; revisit only if the gap shows in production.

### Gate-vs-judgment hardening candidates (version-flexible)

- **Reviewer-blocker disclaimer detection.** Lint for `[blocker]` items accompanied by self-disclaiming prose ("planted", "no new concerns", "for the escalation test") in the same review block. Surfaces manufactured blockers without softening the gate. Could land in v0.2 if a real failure mode surfaces; otherwise v0.3.
- **Survival-vote audit trail.** Structured `[refuted-by: <reviewer> reason: <prose>]` annotations on concerns that the cross-examination phase rejected, so escalation triage has the evidence.

---

## v0.4 — product tier (forecast)

> Own milestone group, not a v0.3 bolt-on. Source: post-v0.2 user testing surfaced
> four comments — (1) no new-product initialization phase, (2) no per-product-type
> skill/tool selection, (3) no CLAUDE.md for a from-scratch product, (4) no phased
> backlog / pick-next-feature. A multi-agent review (8-agent workflow, 2026-05-31)
> cross-checked these and the unifying "product tier" proposal against the live repo,
> the external framework landscape (Kiro, Agent OS, spec-kit, BMAD), and
> product-lifecycle practice. The findings below are that review's recommendation.

### Direction

sdd-fleet has nothing above the feature: every entrypoint presupposes a feature and
the state machine starts at SPEC. Add a **product tier** that records vision, stack, and
a phased backlog once, and inherits them read-only into features. Ship it as **three
separable units, smallest-first — not one monolith.** The recursion is partial: the
outer machine resembles the inner one but diverges (no terminal HANDOFF, long-lived
DEVELOPING, revisable backlog, and — crucially — a **human/caller ratification gate**
where the inner machine has an adversarial survival vote).

### Principle of separation (the v0.4 lens)

The inner machine's rule "gates deterministic, judgments adversarial" gains a third
category at product scope: **strategy is ratified, not voted.** Outcome, non-goals, and
stack-of-record are stake-bearing human calls. Adversarial review *interrogates* them
(risk-pokes the FAQ, cross-exams stack trade-offs, checks dependency soundness and
MVP-slice completeness); it does not *converge* them. A survival vote here would launder
strategy through a process that only looks rigorous — it picks *a* plan, not *the right*
plan. This inverts the automation emphasis of the original proposal.

### What the review corrected in the original proposal

- **Not one tier — three separable units.** Comments 1/3/4 collapse into "nothing above
  the feature"; comment 2 (skill routing) is independent and ships without the outer
  machine. The latent conflicting-stack bug ships first, alone, with no machinery.
- **Latent correctness bug (verified).** Per-feature `DECISIONS.md` is scoped strictly
  under `.sdd/<feature>/` (sdd-protocol), so two features can independently pick
  conflicting stacks. Hoisting stack/architecture ADRs to a product-level `DECISIONS.md`
  is a standalone fix — the keystone, M0.
- **CLAUDE.md generation is mostly already permitted.** `block-source-before-finalized.sh`
  exits 0 when there is no active feature; greenfield product-init has none. A hook
  carve-out is needed *only* to regenerate root config mid-feature — deferred.
- **Skill routing reuses the existing M4 classifier seam.** The classifier already
  inspects domain for sizing but emits no skill/tool manifest. The fix extends it to
  emit a manifest threaded into role prompts — not a second, parallel router.

### Milestones

**M0 — Product as inherited context (keystone; smallest value-bearing slice). Effort: S/M.**
Single stack-of-record + inherited ADRs; **fixes the conflicting-stack bug with no new
machinery.** Depends-on: nothing.
- New `commands/new-product.md`: scaffold `.sdd/_product/{vision.md, backlog.md, STACK.md, DECISIONS.md}` as plain DRAFT files. No gate, no workflow, no scribe.
- `agents/architect.md` owns `vision.md` + `backlog.md`; `agents/architect.md` owns `STACK.md` + product `DECISIONS.md`.
- `commands/new-feature.md`: if `_product/STACK.md` exists, read it + product `DECISIONS.md` into PO/architect prompts; refuse a feature stack choice contradicting STACK.md.
- `skills/sdd-protocol/SKILL.md`: document `_product/` as **inherited context only** — no outer state machine yet.
- `path_in_sdd` already matches `.sdd/_product/*` (glob `.sdd/*`, verified `_lib.sh:48-54`) — workspace carve-out is automatic.
- **Migration rule:** `/new-product` runs alongside an in-flight feature (touches only `_product/`, never `.sdd/ACTIVE`); STACK.md binds **only features created after it lands** — already-FINALIZED features are not retroactively re-validated.
- **vision.md ceremony is classifier-gated:** `## Non-goals` recommended for non-trivial (consistent with `validate-spec-status.sh:46`); `## FAQ` / `OUTCOME:` are net-new ceremony gated to non-trivial products — resolves the small-product-collapse contradiction.

**M1 — Dynamic skill/tool routing (comment 2's hard half). Effort: M.**
Domain-appropriate skills/tools at feature dispatch (e.g. frontend-design for frontend
work). Depends-on: **M0's `new-feature.md` STACK.md edit** — M1 routes through the *same*
classifier-threading block, so the two are serialized through one file, not parallel.
- Route through the existing M4 classifier seam — feed STACK.md + feature type in; emit a skill/tool **manifest** threaded into role prompts (the seam that threads `build_mode`/`skeleton_spec_hint` today). Do **not** build a second router.
- Plumbing constraint (CLAUDE.md §5): team-mode ignores per-agent `skills` frontmatter — put stack-keyed skill instructions in the prompt **body**. Borrow Kiro's declarative `fileMatch`/inclusion-mode shape.
- **Scope (as shipped):** skills-first. The classifier emits a `skill_manifest` (per-role **generic** role-craft skill names — `frontend-design`, not `react-hooks`, which no-op); `new-feature` persists it to `.sdd/<feature>/SKILL_MANIFEST.md`; coder/qa load-if-available at BUILD (advisory, non-gating). `tools_recommended` is **recorded only** — no path binds tools yet (a later increment would wire it into the deep-build workflow's `AgentDefinition.tools`). sdd-fleet ships **no** domain skills — pure mechanism; operators supply the skills.

**M1.1 (optional) — Marketplace skill-discovery. Effort: S/M.**
The complement to M1 routing: when a BUILD role hits `skill-unavailable: <name>`, an
optional step searches the official marketplace for a matching role-craft skill and
*suggests* a `claude plugin install …` command. Depends-on: M1. Deliberately **out of
M1's core path** — routing must stay offline-deterministic because the classifier has
no web/Bash tools and sdd-fleet is headless-first + orchestrator-agnostic; a live
marketplace call in the routing path breaks both. So discovery is a **separate,
optional, advisory** convenience keyed off the `skill-unavailable` signal, never a
dependency of routing. Caveat: pays off only once domain-craft skills actually exist in
the marketplace (today it is mostly tooling plugins) — M1 ships the mechanism; the skill
ecosystem is a separate question.

**M2 — Backlog completion-flip on feature HANDOFF (cheap half of comment 4). Effort: M.**
Cross-feature progress visibility. Depends-on: M0 (backlog artifact).
- `commands/handoff.md`/`finalize.md` flip `[ ]→[x]` in `_product/backlog.md` on HANDOFF.
- **Orchestrator-direct write** (keeps the scribe append-only per `scribe.md:114`; avoids touching the envelope contract). Keep the write path a thin helper that is **forward-compatible with M3's `workspace_dir` scheme**, or M3 rips it out.
- `commands/status.md` surfaces backlog completion state.
- **Scope (as shipped):** the flip lives in `handoff.md` step 11 only (devops-success-gated) — **not** `finalize.md`, which is BUILD *entry*, not completion. Flips `- [ ] <slug> PENDING` → `- [x] <slug> DONE … handoff:<date>`, preserves `depends-on`, and recomputes the containing phase `STATUS` (complete/in-progress/pending). **No `[>]`/active row marker** — "in flight" is derived from `.sdd/ACTIVE`, avoiding a second source of truth. Guarded: no product tier or no matching row → no-op (pure v0.2). `status.md` surfaces the backlog (phases, per-feature done/pending, active-derived) and, when no feature is active, names the next unblocked `PENDING` feature. Advancement stays manual (M4's optional `/next-feature`).

**M3 — The outer PLAN state machine (the product tier proper). Effort: L.**
PLAN → PLAN_REVIEW → PLAN_FINALIZE → DEVELOPING; plan review; validated backlog STATUS;
CLAUDE.md generation gated at PLAN_FINALIZE. Depends-on: M0–M2 **and three hard
prerequisites, none optional:**
- **Resolver contract (most dangerous flaw — fix first).** The entire gate layer keys off one mutable line, `.sdd/ACTIVE` (`_lib.sh:16-19`). A DEVELOPING loop toggling it either disables all gates (empty) or deadlocks `/new-feature` (set → it refuses). Add `resolve_product()` (reads `.sdd/PRODUCT`) + an atomic "complete N / arm N+1" transition that **re-resolves next from live backlog state, not a cached index** (backlogs get re-prioritized mid-flight).
- **Scribe envelope `workspace_dir`/`scope` field.** Scribe is hardwired to `.sdd/<feature>/` with an explicit "never write outside" constraint (`scribe.md:8,114`). Product-scope writes — **including product-level `.sdd/_product/ESCALATION.md`** — need the field + scribe path rewrite + CONTRACT.md §6 change. Ship escalation-write with it (else a ratification gate whose escalation silently can't be written).
- **`review.js` parameterization (not a param).** Hardcoded and verified: role enum `["architect","qa","coder"]` (`additionalProperties:false`); paths `.sdd/${feature}/spec.md`; the survival-vote citation regex `/(spec|acceptance)\.md\s*§|line\s+\d+/i` (`SECTION_REF`, line 259) — a `STACK.md §` citation fails it, so a plan-review concern survives unconditionally and **plan review never converges**; `phase:"REVIEW"`; `next_legal_commands`. Parameterize all four by `target`, or fork `plan-review.js`.
- Plan artifact must **not** be named `spec.md` — `validate-spec-status.sh` fires on any `spec.md` under `.sdd/` and demands 8 sections. Use `backlog.md`/`vision.md` + a new `validate-backlog-status.sh`.
- **PLAN_FINALIZE = human (or, headless, caller) ratification gate, not a survival vote.** Under `claude -p` it **emits its structured plan + cost ceiling and halts for the upstream caller's resume signal** (ROADMAP:50 pattern) — never auto-passes.
- **Cost ceiling.** The outer loop multiplies adversarial fan-outs; monotonic regression (feature N re-runs 1..N-1) is **O(N²)** — declare it against the existing `SDD_FLEET_COST_PREVIEW` seam (`review.js:14`) and make it opt-in past a backlog-size threshold.
- CLAUDE.md carve-out **only here, only if** regenerating mid-feature is wanted; greenfield needs none.

*Build approach (as building):* split into three sub-increments, smallest-first.
- **M3.0 — foundations (behavior-preserving). SHIPPED.** `resolve_product()` + `read_product_field()` + the `.sdd/PRODUCT` marker (`/new-product` writes it; dormant — no gate keys off it yet); scribe `workspace_dir` envelope field (CONTRACT §6) so product-scope workflows can apply state incl. `.sdd/_product/ESCALATION.md` — absent ⇒ byte-identical v0.2. **Decision: fork, don't parameterize.** Since `review.js` is left untouched (still the spec-review workhorse) and the forked `plan-review.js` is co-designed with its command, the "review.js parameterization" prerequisite is obviated — M3.0 is just the resolver + scribe primitives.
- **M3.1 — PLAN → PLAN_REVIEW → PLAN_FINALIZE. DRAFTED (review pending).** New
  `workflows/plan-review.js` (forked; **interrogation, not survival-vote** — roles
  `[architect, qa]` surface `question|risk|gap` findings, consolidated
  by pure JS, nothing auto-killed, never auto-escalates); `/sdd-fleet:plan-review` +
  `/sdd-fleet:plan-finalize`; product `PROGRESS` `PHASE` + `CYCLE` fields seeded by
  `/new-product`; `validate-backlog-status.sh` (keys on `_product/backlog.md`; PRODUCT +
  STATUS + ≥1 phase heading). **Locked decisions:**
  - **PLAN_FINALIZE = explicit `ratify` arg.** Bare call is a **dry-run** (prints report +
    open-blocker count, halts — the headless safety stop); `ratify` flips iff zero open
    blockers; `ratify force` overrides. **Never auto-passes, even with zero findings.**
    Does **not** promote PROVISIONAL→binding (finalizes the plan as written).
  - **Ratification is ADVISORY** — `PHASE=DEVELOPING` does **not** gate `/new-feature`
    (preserves M0/M1 inheritance behavior). The product machine's teeth are M3.2's loop.
  - **No hook taught about `_product`** — plan-review/plan-finalize refuse while a feature
    is in `REVIEW`/`CHANGE_REVIEW` (same guard `/new-product` uses), covering both
    `restrict-reviewer-writes` and `check-review-written`.
- **M3.1.1 — CLAUDE.md generation (split out of M3.1). DRAFTED (review pending).**
  Root `./CLAUDE.md` product block (`<!-- BEGIN/END sdd-fleet:product -->`; vision
  one-liner, **binding** stack, conventions) — **non-clobbering** (only the marked region
  is ever rewritten; an existing hand-authored CLAUDE.md keeps all its content) +
  **idempotent** (markers present → replace in place; absent → append at EOF; no file →
  create). One algorithm in the `sdd-protocol` skill, two callers: `/sdd-fleet:plan-finalize`
  generates best-effort on the ratify-flip; new `/sdd-fleet:product-memory` is the
  standalone regen/recover path. **Block-source caveat handled, not bypassed:** `./CLAUDE.md`
  is outside `.sdd/`, so generation is **pre-checked + deferred** (not forced) when an active
  feature's spec isn't FINALIZED — the gate stays uniform; `/sdd-fleet:product-memory`
  recovers a deferred write. Binding-only (PROVISIONAL/forward entries excluded).
- **M3.2 — DEVELOPING loop. DRAFTED (review pending).** The complete-N/arm-N+1 transition
  on full `/handoff` completion: (1) **clear `.sdd/ACTIVE`** — fixes the latent deadlock
  where handoff never cleared it and `/new-feature` refuses while it's set, so N+1 couldn't
  start without a manual `rm`; (2) re-resolve the next unblocked feature **live** via a new
  deterministic shared resolver `scripts/next-feature.sh` (first PENDING in lowest phase
  with all `depends-on` DONE; emits `next|complete|deadlocked|no-backlog`), used by
  `/handoff` + `/status` (+ M4 `/next-feature`) — one source of truth, no prose re-derivation;
  (3) **surface, don't auto-start** (advancement stays with the human/orchestrator). **Locked
  decisions:** deterministic shared resolver (not prose); M3.2 stops at surfacing (M4 keeps
  `/next-feature` separate); "complete" + "deadlock" are **derived** from the backlog (no
  terminal PHASE value, deadlock is a warning not an escalation). Resolver has a committed
  test harness (`scripts/next-feature.test.sh`, 18 cases) covering every branch + regressions
  (CRLF, empty-vs-complete, capital `[X]`/`None`, substring-dep, phase-crossing, forward deps,
  prose-line rejection, M3.3 single- and multi-line intent invisibility).
- **M3.3 — Per-feature intent in the backlog. DRAFTED (review pending).** Each backlog row
  gets an **indented 1–3 line intent** (what the feature is + scope boundary + explicit
  non-goals/deferrals to siblings — a sketch, *not* a spec) so intent survives the
  plan→feature boundary. PO authors it at `/new-product`; `/new-feature` step 5 seeds the
  feature description from it and step 8 hands it to the PO to *realize + elaborate*
  (deviations flagged in self-review). **PLAN_REVIEW explicitly interrogates intent quality**
  (clarity, clean sibling boundaries, dep justification) — result quality tracks intent
  quality, so intent is reviewed, not blindly trusted. **Parser-invisible** (no `- [`/`##`
  prefix → resolver, `validate-backlog-status`, and the M2 flip all ignore it; flip preserves
  it). Backward-compatible (slug-only rows still work). **Hard line:** intent stays
  boundary-level — no acceptance criteria/interfaces/behavior — to keep the spec-is-the-contract
  gate intact and avoid two rotting sources of truth.
- **Deferred out of M3:** the O(N²) monotonic regression — later opt-in, not core to the loop.

**M4 (optional) — `/next-feature` advancement convenience. DRAFTED (review pending). Effort: M.**
`/sdd-fleet:next-feature` resolves the next unblocked feature via the **same M3.2 resolver**
("First PENDING in lowest unblocked phase whose depends-on are all DONE"), pre-checks
readiness, and emits `SDD_FLEET_NEXT_FEATURE: {slug, phase}` — collapsing "read `/status` →
type `/new-feature <slug>`" into one gated step. Depends-on: M3.
- **Kept optional + convenience-not-policy** to preserve orchestrator-agnosticism: resolver
  only (no reorder/skip/judgement). **Locked decisions:** (A=a1) M4 **does not run
  `/new-feature` itself** — it emits the dispatch signal and the dispatcher (upstream caller
  in headless, human in interactive) starts the feature, keeping dispatch + caller policy with
  the orchestrator and avoiding any duplication of new-feature's logic; mode-agnostic (no
  headless-detection needed). (B) **pre-checks the next intent against the M3.3 quality floor**
  and refuses (`NEEDS_DESC`) rather than letting new-feature STOP-and-ask mid-dispatch.
  (C) no interactive confirmation — `/next-feature` is itself the explicit advance request.
- **Refusals:** feature-in-flight, `deadlocked`/`empty` backlog, intent-too-thin. No new
  resolver/hook/agent code — reuses `scripts/next-feature.sh` (+ its 18-case harness).

### Design decisions to lock

- **`_product/` namespace:** `.sdd/_product/` (inside `.sdd/`). `path_in_sdd` and the stale-marker reaper (`find -mindepth 2 -maxdepth 2`) already cover it; the resolver must distinguish product vs feature scope (`resolve_product` vs `resolve_active`).
- **STACK.md vs product DECISIONS.md:** STACK.md = current resolved state; product DECISIONS.md = append-only ADR log of *why*. Features read both read-only — with an **escalation path to challenge an inherited product ADR** (else inherited stack becomes tyranny forcing feature-local workarounds, and STACK.md becomes the v0.2 bug relocated).
- **CLAUDE.md gating:** generate at PLAN_FINALIZE while no inner feature is active (already-permitted path). A path-based "always allow CLAUDE.md" carve-out punches a permanent hole in the source-write gate — avoid.
- **Cross-feature dependency mechanism:** depend on published contracts/interfaces (`INTERFACES.md` / per-feature `contract.md`), not `IMPL_NOTES.md` (couples features to each other's internals).
- **Tier-awareness:** make the product tier classifier-gated (reuse trivial/standard/large) — small products collapse vision+backlog and STACK+DECISIONS and skip FAQ/OUTCOME. Eight ceremony files before any code on a 3-feature tool = abandonment.
- **Plugin self-testing:** per-milestone test obligation against the pytest harness — golden-envelope + hook-exit-code tests, non-negotiable for M3's `review.js` parameterization and the resolver "complete N / arm N+1" transition.

### Borrow from other frameworks (load-bearing only)

- **Kiro inclusion modes** (`fileMatch`/`always`/`manual`/`auto`, kiro.dev/docs/steering) — the model for M1 skill routing; its `product.md`/`tech.md`/`structure.md` trio is the convergent industry shape for the above-feature tier.
- **Agent OS phased now/next/later roadmap** (buildermethods.com/agent-os) — the backlog shape for M0/M2 (borrow structure; treat pick-next automation as under-documented).
- *Out of scope for these four asks:* BMAD sharding, Working Backwards PR-FAQ, OpenSpec dated-archive, Spec Kit constitution, Conductor worktree orchestration. Revisit only if a specific gap surfaces.

### Explicitly rejected from the original "product tier" proposal

- "One product tier" as a monolith (over-unifies; comment 2 and the stack-bug fix ship independently).
- PLAN_FINALIZE as an adversarial survival vote (converges to *a* plan, not *the right* plan).
- A second, stack-axis router for comment 2 (feed stack into the *one* classifier).
- A path-based "always allow CLAUDE.md" hook carve-out (permanent gate hole).
- Autonomous `/next-feature` advancement as default behavior (agnosticism); deferred to optional M4.
- Unbounded monotonic regression (cost bomb; make it opt-in past a size threshold).

---

## v0.5 — troubleshoot-fix bug lane (shipped 2026-06-05)

**What landed:** a second, parallel state machine for diagnosing and fixing *unknown-cause* bugs,
additive to the forward feature machine. `REPORT → REPRODUCE → DIAGNOSE → FIX → VERIFY → HANDOFF`,
with a new `diagnosis.md` contract (not a spec). Built in five milestones:
- **M0** — the `diagnosis.md` artifact + `sdd-diagnosis-template` skill + `validate-diagnosis-status`
  hook + dormant lane resolvers in `_lib.sh`.
- **M2** — the inviolable `require-reproducing-test` gate + a CONFIRMED second unlock on
  `block-source-before-finalized` (also fixed a latent fail-open in the `_lib.sh` STATUS readers).
- **M1** — `/sdd-fleet:jira-story` + a bug-mode classifier (`{severity, cause_known}`).
- **M3** — `diagnose.js`, an inverted `review.js` (refute the hypothesis citing the reproduction;
  CONFIRMED iff no refutation survives) + `/reproduce` + `/diagnose`.
- **M4** — the `/fix → /verify → /ship-fix` tail (the counterfactual reused verbatim) + the sev0
  hotfix fast-path + a bug-lane-aware `/status`.

**Design spine:** the gates-vs-judgments split is preserved — the reproducing-test gate and the
source-write unlock are deterministic **hooks**; diagnosis confirmation is an adversarial
**workflow**. The forward machine is untouched; a repo that never files a bug is byte-for-byte
unchanged.

---

## Future: command namespacing

The flat `commands/` directory is past the ~15-command guidance with confusable
pairs (`finalize`/`plan-finalize`, `new-feature`/`next-feature`, generic
`fix`/`verify`). Splitting into `commands/plan/` and `commands/bug/`
subdirectories (→ `/sdd-fleet:plan:finalize`, `/sdd-fleet:bug:fix`, …) is
the right shape — but it is a **breaking rename of the headless contract**
(every orchestrator dispatch string + ~30 cross-references), so it is
deliberately **deferred** to a major version where a migration window can be
documented, per the 2026-06-09 audit's own staging advice.

---

## Durable principles (apply to every version)

- **Spec is the contract.** No implementation begins until a spec is FINALIZED.
- **Gates are deterministic; judgments are adversarial.** The M0 classification is the rule, not a heuristic.
- **Escalation is a first-class outcome, not a failure.** Human review at boundaries is the correctness mechanism, not an exception path.
- **Filesystem is shared memory.** Subagent memories silo; the workspace `.sdd/<feature>/` does not.
- **Plugin is read-only machinery; `.sdd/` is per-project state.** Never let machinery and state interleave. The plugin tree is re-installable; `.sdd/` is the truth.
- **Orchestrator-agnostic.** sdd-fleet works from CLI, headless `claude -p`, Hermes, or any future orchestrator. No orchestrator-specific code lives in the plugin.
