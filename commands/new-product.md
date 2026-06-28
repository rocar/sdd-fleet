---
description: Scaffold the product tier: vision, backlog, stack
argument-hint: "<product-slug>"
allowed-tools: Read, Write, Edit, Task
---

# /sdd-fleet:new-product

You are the **orchestrator**. You scaffold `.sdd/` state and route work; you do
not author the vision, choose the stack, or write source yourself.

The runtime rulebook is the `sdd-protocol` skill — its `references/product-tier.md`
covers the `.sdd/_product/` layout, file ownership, and the inheritance contract.
This command only scaffolds and drafts: the plan it produces is interrogated by
`/sdd-fleet:plan-review` and ratified by `/sdd-fleet:plan-finalize`; no gate
runs here.

## Arguments

`$ARGUMENTS` — the product slug. Kebab-case, no whitespace. If empty, refuse and
tell the user a slug is required.

## Refusal cases (check first, in order)

1. **`.sdd/_product/` already exists.** Refuse: a repo has one product tier.
   Tell the user to edit the existing `_product/` files directly, or to inspect
   them with `/sdd-fleet:status`. Stop.
2. **A feature is mid-review.** Read `.sdd/ACTIVE`; if non-empty, read
   `.sdd/<active>/PROGRESS.md` `PHASE`. If `PHASE` is `REVIEW` or `CHANGE_REVIEW`,
   refuse: the `restrict-reviewer-writes` hook confines **all** writes to
   `.sdd/<active>/` during those phases, so product-tier scaffolding would be
   blocked — and you should not reshape the product foundation while a feature
   review is converging. Tell the user to finish or escalate the active review
   first, then re-run. Stop.
   *(Any other active-feature phase — SPEC, FINALIZE, BUILD, HANDOFF — is fine:
   `/new-product` touches only `.sdd/_product/`, never `.sdd/ACTIVE`, and those
   phases do not engage the reviewer-write restriction.)*
3. **`$ARGUMENTS` is empty.** Refuse; require a slug. Stop.

## Establish the product description

Before scaffolding, determine *what the product is*. Look back through the
conversation for a description the user already gave. **If none exists, STOP and
ask** — do not infer a product from its slug. Ask for: the problem it solves,
who it's for, the rough feature set, and any stack the user already has in mind.
Wait for the answer. Carry it verbatim into the delegations below.

## Size the ceremony (classifier-gated)

Judge product size to keep small products lightweight (mirrors the feature-tier
`trivial | standard | large` axis):

- **small** — a single-purpose tool, a handful of features, one obvious stack.
  Collapse ceremony: `vision.md` may merge Overview/Goals and **omit** the
  `## FAQ` section and `OUTCOME:` field; `backlog.md` may use a single phase.
- **standard / large** — multiple phases or a non-obvious stack. Full ceremony:
  `vision.md` includes `## Non-goals`, `## FAQ`, and an `OUTCOME:` line.

You may reuse the `sdd-fleet:classifier` subagent for this sizing if the call
is non-obvious; otherwise size it inline from the description. Record the chosen
size in `_product/PROGRESS.md` (`SIZE:` field) so later milestones can read it.
Eight ceremony files before any code on a 3-feature tool is how a product gets
abandoned — bias small.

## What you do

1. **Scaffold `.sdd/_product/`** with these files. Write the scaffolds yourself
   (you have `Write`); the agents fill the bodies (mirrors `/new-feature`, where
   the orchestrator scaffolds and roles author):

   - `vision.md` — first line `STATUS: DRAFT`, then the section headings the
     chosen size requires (Overview, Goals; plus Non-goals, FAQ, and an
     `OUTCOME:` line for standard/large). Leave bodies empty — PO fills them.
     *(No hook validates `vision.md`'s STATUS — `validate-spec-status` fires
     only on files named `spec.md`. The `/sdd-fleet:plan-finalize` gate flips
     this STATUS line at ratification.)*
   - `backlog.md` — header:
     ```
     PRODUCT: <slug>
     STATUS: DRAFT

     ## Phase 1: <name> — STATUS: pending
     - [ ] <feature-slug>   PENDING   depends-on: none
           <intent (1-3 lines): what this feature is, its scope boundary, and any
           explicit non-goals / deferrals to sibling features>
     ```
     Leave the feature rows as a single placeholder — PO fills the real phases,
     each row followed by its indented 1-3 line intent.
   - `STACK.md` — first line `STATUS: DRAFT`, then headings: `## Languages & runtimes`,
     `## Frameworks & libraries`, `## Data & storage`, `## Infrastructure & deploy`,
     `## Conventions`. Empty bodies — architect fills them.
   - `DECISIONS.md` — `# Product Architecture Decisions — <slug>` then
     `Append-only ADR log. Product-wide decisions, inherited read-only by every feature.`
   - `PROGRESS.md` — product-tier state:
     ```
     SDD_SCHEMA: 1
     PRODUCT: <slug>
     SIZE: <small | standard | large>
     PHASE: PLAN
     CYCLE: 0
     UPDATED: <iso8601>
     ```
     `PHASE` seeds the outer PLAN state machine:
     `PLAN | PLAN_REVIEW | DEVELOPING | ESCALATED` (the `PLAN_FINALIZE` ratification
     gate is synchronous — it writes `PLAN_REVIEW → DEVELOPING` directly and is never
     a resting phase). A freshly scaffolded product starts at `PLAN` — vision/backlog/stack
     are being drafted.
     `CYCLE: 0` is the plan-review cycle counter (mirrors the feature-tier `CYCLE`);
     `workflows/plan-review.js` bumps it and the scribe writes it back. Both fields
     must be present so the product-scope scribe can replace them in place.
   - `.sdd/PRODUCT` — a one-line marker file containing the product slug, written
     at the `.sdd/` root (mirrors `.sdd/ACTIVE` for features). `resolve_product()`
     reads it; its presence flags the product tier as engaged.
   - `.sdd/.gitignore` — **only if absent**, with exactly these entries (the
     per-working-tree coordination files are never committed; the per-feature
     artifacts, `_product/`, and the `PRODUCT` marker are — see the
     `sdd-protocol` skill, ".sdd/ in version control"):
     ```
     ACTIVE
     ACTIVE.lock
     .workflow-in-flight
     .stop-test-retries
     .skip-stop-tests
     ```

2. **Delegate vision + backlog to architect.** Spawn `sdd-fleet:architect`
   via the Task tool. Tell it: it owns `.sdd/_product/vision.md` and
   `.sdd/_product/backlog.md`; draft the vision from the description (size-gated
   sections per above) and a **phased** feature backlog. Each backlog feature row
   is `- [ ] <slug>   PENDING   depends-on: <none | other-slug>`, **followed by an
   indented 1-3 line intent** — what the feature is, its scope boundary,
   and explicit non-goals/deferrals to sibling features; a sketch the feature's spec
   later elaborates, **not** acceptance criteria/interfaces/behavior. This intent is
   inherited by `/sdd-fleet:jira-story` (so the spec realizes the plan's intent
   rather than re-guessing) and is interrogated at PLAN_REVIEW. It must NOT set
   any STATUS beyond `DRAFT` (only the `/sdd-fleet:plan-finalize` ratification
   gate flips a product STATUS). Pass the
   product description verbatim. **Brownfield note:** the backlog is
   *forward-looking* — features that already exist in the codebase are not backlog
   rows; only planned/next work goes in `backlog.md`.

3. **Delegate stack + product ADRs to architect.** Spawn `sdd-fleet:architect`
   via the Task tool. It owns `.sdd/_product/STACK.md` and `.sdd/_product/DECISIONS.md`,
   and records the *why* of each load-bearing choice as a product ADR (per the
   `adr` skill). This stack is **inherited read-only by every feature** — the
   single source of truth that prevents two features picking conflicting stacks.
   The architect uses `Edit` to fill the scaffolds you created (it has no
   `Write`); make sure the scaffold files already exist from step 1.

   **Tell the architect which mode it is in** — greenfield vs brownfield — based
   on whether real source already exists in the repo:

   - **Greenfield** (no meaningful source — e.g. only `.sdd/`, README, config):
     *ratify* a stack-of-record from the product description and the user's stated
     preferences. This is a forward design decision.
   - **Brownfield** (real source/manifests already exist — `package.json`,
     `go.mod`, `Cargo.toml`, `requirements.txt`, `pyproject.toml`, a populated
     `src/`, etc.): **infer and record the *actual* stack from the code** as the
     **binding stack-of-record** — a `## Baseline (current)` section in STACK.md
     describing what the codebase *is*. Read the manifests and representative
     source; never hallucinate a stack that isn't there, and never silently
     rewrite the baseline.

     A **forward / migration direction is allowed** when the product vision calls
     for evolution — but it is *unratified strategy*, so it must not land as
     binding. Record it in a separate
     `## Forward direction (PROVISIONAL — unreviewed)` section plus product ADRs
     tagged `STATUS: PROVISIONAL`. **Provisional forward entries do NOT bind
     features** — features inherit the binding *baseline* until the migration is
     ratified (plan-review/plan-finalize, or an explicit human edit promoting a
     PROVISIONAL ADR). Frame forward changes as incremental (migrate/wrap, not rewrite); a
     concern about the existing stack is a finding to the user, not a unilateral
     rewrite of reality.

   Detect brownfield cheaply before delegating: if the repo contains source
   manifests or a non-trivial source tree outside `.sdd/`, pass `mode=brownfield`
   and name the manifest files you saw; otherwise `mode=greenfield`. (A repo that
   has prior `.sdd/<feature>/` dirs but no source yet is still greenfield for stack
   purposes — those features haven't been built.)

4. **Report back.** Summarize the vision one-liner, the phases and feature count,
   and the chosen stack. Tell the user the product tier is now **inherited
   context**: subsequent `/sdd-fleet:jira-story` runs will read `_product/STACK.md`
   and `_product/DECISIONS.md` and hold features to the product stack. Note that
   editing `_product/` files is done directly; when the plan is ready, run
   `/sdd-fleet:plan-review` to interrogate it and `/sdd-fleet:plan-finalize`
   to ratify it (which also seeds the root CLAUDE.md product-memory block).

## Gates to honor

- All `.sdd/_product/*` writes are inside `.sdd/`, so `block-source-before-finalized`
  permits them (it allows any path under `.sdd/`, and exits early when there is no
  active feature). The only blocker is the mid-review refusal in case 2 above —
  honor it rather than fighting the hook.
- This command enforces **no** product gate. If you find yourself wanting to
  enforce a product STATUS transition, that is `/sdd-fleet:plan-finalize`'s
  job — stop and surface it.

## Hard "no"s

- Do not run any workflow or invoke the scribe — this command is plain file
  scaffolding; the workflow runs at `/sdd-fleet:plan-review`.
- Do not touch `.sdd/ACTIVE` or any `.sdd/<feature>/` directory.
- Do not author the vision or choose the stack yourself — delegate.
