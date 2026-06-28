# Product tier — reference

The product tier is the planning layer **above** the flat feature dirs. It lives in
the reserved `.sdd/_product/` namespace (the underscore prevents collision with any
feature slug). A repo with no `.sdd/_product/` is a plain feature-first repo — the
product tier is **purely additive**; its absence changes nothing.

## Layout and ownership

```
.sdd/
  _product/              # created by /sdd-fleet:new-product
    vision.md            # architect. Overview/Goals (+ Non-goals/FAQ/OUTCOME for standard|large).
    backlog.md           # architect. Phased feature list + completion markers + per-row intents.
    STACK.md             # architect. The stack-of-record — inherited READ-ONLY by every feature.
    DECISIONS.md         # architect. Append-only product ADR log (the *why* behind STACK.md).
    PROGRESS.md          # orchestrator. PRODUCT / SIZE / PHASE / CYCLE / UPDATED.
    REVIEW.md            # scribe (append-only). Interrogation reports from plan-review.
    ESCALATION.md        # human-written only. Halts the plan until resolved.
  PRODUCT                # one-line product slug marker (mirrors ACTIVE). resolve_product() reads it.
  ACTIVE                 # unchanged — the single active feature/bug.
  <feature>/             # unchanged — features stay flat, NOT nested under _product/.
```

`.sdd/_product/PROGRESS.md` carries `PHASE: PLAN | PLAN_REVIEW | DEVELOPING | ESCALATED`,
a `CYCLE` counter (plan-review cycles; mirrors the feature `CYCLE`), and `SIZE:
small | standard | large`. `/sdd-fleet:new-product` seeds `PHASE: PLAN`, `CYCLE: 0`.

## Greenfield vs brownfield

`/sdd-fleet:new-product` works on both. On a **greenfield** repo the architect
*ratifies* a new stack from the product description. On a **brownfield** repo (real
source/manifests already present) the architect *infers and records the actual stack*
from the code as the **binding stack-of-record** (a `## Baseline (current)` section) —
never hallucinating or silently rewriting it. A forward/migration direction is allowed
only as an explicitly **`PROVISIONAL` (unreviewed)** section + ADRs tagged
`STATUS: PROVISIONAL`; provisional forward entries are strategy that **do not bind
features** until ratified (at plan-review/plan-finalize, or an explicit human edit
promoting the ADR). `/sdd-fleet:new-product` writes only `.sdd/_product/`, never
source, so it is safe to run against an existing codebase; an existing root
`CLAUDE.md` is untouched (the product-memory block is generated at ratification).

## The inheritance contract

`.sdd/_product/STACK.md` is the product's stack-of-record. When
`/sdd-fleet:jira-story` runs and this file exists, it is read into the classifier +
architect prompts as read-only context. Features inherit the **binding** stack —
everything in STACK.md not marked provisional (a `## Forward direction (PROVISIONAL —
unreviewed)` section, or per-line `PROVISIONAL` tags); if nothing is marked
provisional, the whole stack binds (greenfield, or a fully-adopted brownfield).
Provisional forward entries are advisory and do **not** constrain a feature until
promoted. A feature's own `DECISIONS.md` must not contradict the binding product
stack. A genuine need for a different stack is a signal to **revise the product tier**
(edit STACK.md + append a product ADR), not a feature-local override — feature-scoped
`DECISIONS.md` has no cross-feature authority; product `DECISIONS.md` does.

## The PLAN state machine

The product tier carries an **outer state machine**, mirroring the feature tier one
level up but with an inverted temperament. A feature spec is a contract the machine
can **adversarially converge** (REVIEW's survival vote kills concerns refuted with a
section cite). A product plan is a **strategic bet** the machine must not converge —
it surfaces risk and a human chooses. So:

```
feature:   SPEC  →  REVIEW (survival vote)        →  FINALIZE (deterministic gate)  →  BUILD
product:   PLAN  →  PLAN_REVIEW (interrogation)   →  PLAN_FINALIZE (human ratifies) →  DEVELOPING
```

*(`PLAN_FINALIZE` names the ratification **gate**, not a persisted resting phase —
the gate is synchronous and writes `PLAN_REVIEW → DEVELOPING` directly; PROGRESS
never rests at `PLAN_FINALIZE`.)*

### PLAN_REVIEW (`/sdd-fleet:plan-review` → `workflows/plan-review.js`)

A fork of `review.js` (fork, don't parameterize — a deliberate design decision).
Roles `[architect, qa]` **interrogate** the product artifacts
(`vision/backlog/STACK/DECISIONS.md`) from their lenses, each returning structured
`findings` (`kind: question|risk|gap`, `severity: blocker|major|minor`). The workflow
**consolidates by pure JS** (groups + counts) — there is **no cross-examination, no
survival vote, nothing auto-killed** — and the scribe appends an interrogation report
to `.sdd/_product/REVIEW.md`, setting `PHASE=PLAN_REVIEW`. The scribe writes the
product workspace via the envelope's `workspace_dir=".sdd/_product/"`. plan-review
**never auto-escalates**: a missing interrogator payload halts the run *without
writing* (re-run), and the only thing that writes `_product/ESCALATION.md` is a human.
Self-interrogation by the artifact's author (PO interrogating its own vision) is
fine — the act surfaces risk, it does not vote.

### PLAN_FINALIZE (`/sdd-fleet:plan-finalize`) — the ratification gate

A product plan is **ratified, never auto-decided**, so this gate **never auto-passes —
even with zero findings**:

- *Bare* `/sdd-fleet:plan-finalize` is a **dry-run**: it prints the latest
  interrogation report + open `[blocker]` count and **halts**. In headless mode
  (`claude -p`) this is the whole safety story — and the command additionally carries
  `disable-model-invocation: true`, so the model cannot ratify on its own.
- `ratify` flips state **iff** zero open blocker-severity findings; open blockers → refuse.
- `ratify force` flips over open blockers, recording them as consciously accepted.
- Small fast-path: `SIZE=small` + `PHASE=PLAN` + `CYCLE=0` may ratify without a prior
  plan-review (mirrors the trivial-feature fast-path; treats open-blocker count as 0).

On ratification it edits `vision.md` + `backlog.md` `STATUS: FINALIZED` and sets
`PHASE: DEVELOPING`. It also flips `STACK.md` `STATUS: FINALIZED` **conditionally** —
only when the stack is **fully binding** (no provisional/forward content); when
provisional content is present, `STACK.md` STATUS is **left untouched** (the file
still holds un-ratified strategy, so labelling it `FINALIZED` would be dishonest).
Either way it **does NOT promote** any forward direction or `STATUS: PROVISIONAL`
ADR — ratification finalizes the plan **as written**; the binding stack stays whatever
is currently un-tagged. Auto-promoting provisional strategy would be the machine
choosing direction, which this gate must never do. `DECISIONS.md` (per-ADR STATUS,
architect-owned) is never edited by the gate.

**Ratification is advisory.** Setting `PHASE=DEVELOPING` does **not** gate
`/sdd-fleet:jira-story` — features build against the binding stack regardless of
product phase. The product machine's "teeth" are the **DEVELOPING loop** (which
clears `.sdd/ACTIVE` on completion and arms the next backlog feature — see below),
not a feature-creation block.

## Product memory — the root CLAUDE.md block

On ratification, sdd-fleet seeds the repo's Claude memory with the ratified product
so **any** Claude Code session (not just sdd-fleet commands) inherits the vision +
**binding** stack. One algorithm, two callers: `/sdd-fleet:plan-finalize` triggers
it on the ratify-flip (best-effort), and `/sdd-fleet:product-memory` is the
standalone (re)generation path (refresh after editing the plan, or recover a deferred
write).

**The block** is a single delimited region in the repo-root `./CLAUDE.md`, bounded by
`<!-- BEGIN sdd-fleet:product -->` … `<!-- END sdd-fleet:product -->` markers. It
carries: the vision one-liner (first sentence of vision.md `## Overview`, or the
`OUTCOME:` line if present), the **binding stack** distilled to bullets (provisional/
forward entries excluded — they do not bind), the conventions, and a source-of-truth
pointer back to `.sdd/_product/` (edits between the markers are overwritten on
regeneration; notes outside the markers are preserved).

**Distillation rules:**
- **Exclude** any `## Forward direction (PROVISIONAL — unreviewed)` section and any
  `PROVISIONAL`-tagged lines from the binding-stack bullets.
- **Brownfield "all-provisional" fallback:** if STACK.md has *no* binding entries
  because everything is a provisional forward direction, use the `## Baseline
  (current)` content as the binding stack (the brownfield baseline *is* the
  stack-of-record) and add a one-line note that a forward direction exists but does
  not yet bind. Never emit an empty binding-stack section.

**Splicing is scripted, never model-driven.** The generating command produces the
block *content* (without markers) and pipes it to
`scripts/product-memory-splice.sh ./CLAUDE.md`, which handles all three cases
deterministically — no file (create), block present (replace the region in place,
detecting the BEGIN marker by **prefix**), block absent (append after the final line)
— preserving everything outside the markers byte-for-byte, and refusing (exit 1, no
write) on a corrupt marker pair. It prints `created` / `updated-in-place` /
`appended`.

**Why generation can be deferred.** `./CLAUDE.md` is **outside** `.sdd/`, so
`block-source-before-finalized` blocks the write whenever `.sdd/ACTIVE` names a
feature whose `spec.md` STATUS ≠ `FINALIZED`. The generating command **pre-checks**
this and, if the write would be blocked, **skips generation with a deferred note**
rather than fighting the gate — the ratification flip itself (all in `.sdd/_product/`)
always succeeds. The escape hatch is `/sdd-fleet:product-memory`, run once no
feature is mid-non-finalized. (`CLAUDE.md` is **not** whitelisted in the gate —
keeping the FINALIZED gate uniform is worth the occasional deferral.)

## Backlog completion

`.sdd/_product/backlog.md` rows track per-feature completion. Row format:
`- [ ] <slug>   PENDING   depends-on: <none|slug>`, optionally followed by an
**indented 1–3 line intent** (see below). On a successful `/sdd-fleet:pr-review`
(devops done), the orchestrator flips the matching row to
`- [x] <slug>   DONE   depends-on: <unchanged>   handoff:<iso-date>` and recomputes
the containing `## Phase N: … — STATUS:` line (`complete` when all its rows are
`[x]`, else `in-progress` if any are, else `pending`). This is an
**orchestrator-direct write** — not the scribe (the scribe is append-only). A feature
with no matching backlog row (an ad-hoc fix) is left untouched. "Active in flight" is
**derived from `.sdd/ACTIVE`**, not a backlog marker — there is no `[>]` state to
keep in sync.

## Per-feature intent

A backlog row carries only a slug + dependency; that loses the plan author's *intent*
for the feature across the tier boundary, so `/sdd-fleet:jira-story` would
re-guess the scope from a bare slug. Each row therefore carries an **indented 1–3
line intent**:

```
## Phase 1: Foundations — STATUS: pending
- [ ] cli-skeleton   PENDING   depends-on: none
      Cobra root command + global --format flag wiring; the app shell other commands hang
      off. No data commands, no rendering, no persistence (those are later features).
- [ ] api-client     PENDING   depends-on: cli-skeleton
      The internal/yahoo typed HTTP wrapper — the sole package that talks to Yahoo.
      Network only: rendering is output-formatter; config is local-config-store.
```

- **It is a sketch, not a spec.** What the feature is + its scope boundary + explicit
  non-goals/deferrals to sibling features. The boundary/deferral facts are the
  high-value part — they keep siblings from overlapping or leaving a gap, and they
  justify the `depends-on` edges. **No** acceptance criteria / interfaces / detailed
  behavior — those stay in the feature's `spec.md`, drafted by the PO and
  adversarially reviewed at `/sdd-fleet:jira-story` time. The intent is *inherited
  advisory context* (like the stack); the spec is the contract. Two sources of truth
  for behavior would rot apart and make the per-feature review redundant — so the
  line holds at boundary-level.
- **Authored** by the PO at `/sdd-fleet:new-product` (it already conceived each
  feature when phasing it). **Inherited** at `/sdd-fleet:jira-story`: the
  orchestrator seeds the feature description from the intent and hands it to the PO
  to *realize and elaborate* (the PO flags any deviation in `## Self-review notes`).
- **Reviewed, not blindly trusted.** Result quality tracks intent quality, so
  PLAN_REVIEW explicitly interrogates the intents — clarity (can it drive a spec?),
  clean sibling boundaries (no overlap/gap), and whether the stated boundaries
  justify the deps. A vague or wrongly-bounded intent is a finding to fix before
  ratifying, not silent input to a downstream spec.
- **Parser-invisible.** The intent lines have no `- [`/`##` prefix, so the resolver,
  `validate-backlog-status`, and the completion-flip (which edits only the `- [ ]`
  row line) all ignore them — the flip preserves the intent untouched.
- **Backward-compatible.** A legacy slug-only row (no intent) works exactly as
  before; the PO drafts from the user's description.
- **Quality floor (canonical definition — the commands defer here).** An intent is
  **usable** only if it carries at least **2 of its 3 components**: *what the feature
  is*, *its scope boundary*, *its non-goals/deferrals*. A missing intent, or a bare
  slug-restatement with no boundary ("the API client"), is **too thin** — it cannot
  seed a spec, and `/sdd-fleet:jira-story` STOP-and-asks instead. The single
  executable encoding of both the block grammar and this floor is
  `scripts/intent-block.sh` (`INTENT_VERDICT: usable|too-thin`), called by both
  `/sdd-fleet:jira-story` and `/sdd-fleet:next-feature` so they can never
  disagree. The command files deliberately carry only a short summary + a pointer to
  this paragraph — keep it the floor's single prose home.

## The DEVELOPING loop

The **complete-N → arm-N+1** transition closes the multi-feature loop (without it,
shipping feature N would leave `.sdd/ACTIVE` set and `/sdd-fleet:jira-story`
hard-refuses while it is non-empty).

On a **full** `/sdd-fleet:pr-review` completion (devops succeeded + the backlog flip
ran — *not* a CHANGE_REVIEW bounce-back to BUILD), when a product tier exists,
handoff:

1. **Releases the in-flight lock** (`scripts/acquire-active.sh release <slug>` —
   removes `.sdd/ACTIVE.lock` and empties `.sdd/ACTIVE`; the shipped feature is no
   longer in flight). This is what unblocks the next `/sdd-fleet:jira-story`. Safe: with no
   active feature, `block-source-before-finalized` and the per-reviewer hooks are
   simply inactive — correct between features.
2. **Re-resolves the next unblocked feature from the LIVE backlog** — *first
   `PENDING` row in the lowest phase whose `depends-on` are all `DONE`* — via the
   shared deterministic resolver `scripts/next-feature.sh`. Re-resolving live (never
   a cached index) means a mid-flight backlog re-prioritization is always honored.
   The resolver is the **single source of truth**: `/sdd-fleet:pr-review`,
   `/sdd-fleet:status`, and `/sdd-fleet:next-feature` all call it instead of
   re-deriving dependency math in prose.
3. **Surfaces — does not auto-start.** Advancement policy stays with the
   human/orchestrator: handoff *reports* the next slug; running
   `/sdd-fleet:jira-story <slug>` is an explicit act.

**The advancement convenience — `/sdd-fleet:next-feature`.** Optional. It calls the
**same resolver**, pre-checks readiness (no item in flight; the next feature's intent
passes the quality floor), and emits a dispatch signal `SDD_FLEET_NEXT_FEATURE:
{slug, phase}` — collapsing "read `/status` → type `/new-feature <slug>`" into one
gated step. It is **convenience, not policy**: resolver only (no
reorder/skip/judgement), and it **does not run `/sdd-fleet:jira-story` itself** —
the dispatcher (the upstream caller in headless, the human in interactive) starts the
feature. If the next feature's intent is too thin to start unattended it refuses
(`NEEDS_DESC`) rather than letting new-feature STOP-and-ask mid-dispatch.

**Resolver outcomes** (`scripts/next-feature.sh` emits one JSON line):
`next` (slug + phase) · `complete` (all rows `[x]`, `total>0`) · `deadlocked`
(`PENDING` rows remain but none unblocked — a dependency cycle / unsatisfiable edge)
· `empty` (a backlog with no parseable feature rows, `total=0` — distinct from
`complete` so an unparseable backlog never reads as "fully shipped") · `no-backlog`
(file absent). The resolver strips `\r` (CRLF-safe) and tolerates
`[x]`/`[X]`/`-`/`*`/`none`/`None`; it has a committed test harness
(`scripts/next-feature.test.sh`).

**Terminal & deadlock are derived, not stored:**
- **Complete** is computed from the backlog (every row `[x]`) — there is **no
  terminal `PHASE` value**. Appending features/phases to `backlog.md` re-opens the
  loop automatically.
- **Deadlock** is a runtime **warning** (check `depends-on` / cycles), **not** an
  escalation — the human reorders deps; nothing auto-halts.

**`PHASE=DEVELOPING`** is the product state during this loop. The arming engages
whenever a product backlog is present; the phase is reported for context, not used as
a hard gate (a feature can be shipped before ratification too — the loop just tracks
it).

## Hook interactions

- `block-source-before-finalized` permits all `.sdd/_product/*` writes (any path
  under `.sdd/` is allowed; and it exits early when there is no active feature).
- `restrict-reviewer-writes` confines **all** writes to `.sdd/<active>/` while the
  active feature's `PHASE` is `REVIEW` or `CHANGE_REVIEW` (phase-based, not
  role-based). Therefore `/sdd-fleet:new-product`, `/sdd-fleet:plan-review`, and
  `/sdd-fleet:plan-finalize` all **refuse to run** while a feature is in those two
  phases — the product foundation is not reshaped mid-review, and the product scribe
  could not write `.sdd/_product/` anyway. The interrogator roles also overlap the
  feature-reviewer set, so a mid-review feature would mis-fire `check-review-written`.
  This single guard covers both hooks. All other active-feature phases are fine;
  none of these commands touch `.sdd/ACTIVE`.
- `validate-backlog-status` (PostToolUse) keys on `basename==backlog.md` under
  `.sdd/_product/` — feature dirs have no `backlog.md`, so no collision. It requires
  a `PRODUCT:` header, a valid `STATUS` line, and ≥1 `## Phase N:` heading
  (structural presence, not per-row grammar).
- No hook validates `vision.md`/`STACK.md` STATUS (`validate-spec-status` fires only
  on files named `spec.md`); their STATUS lines are flipped by the plan-finalize gate.
- The product scribe releases `.sdd/_product/.workflow-in-flight` (resolved under the
  envelope's `workspace_dir`); `reap-stale-workflow-markers` reaps it if orphaned (it
  scans depth-2, which includes `_product/`).
