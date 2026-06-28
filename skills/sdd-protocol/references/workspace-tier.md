# Workspace tier — reference

The workspace tier is the **estate** layer *above* the per-repo feature machine. A
workspace is a parent **superproject** with member repos as git **submodules** and one
Obsidian vault over the whole thing. It plans cross-repo work as an **epic** — a
dependency DAG of stories plus the contract design that wires the services together — has
a human **ratify** it, and lets a modelless **conductor** dispatch ready stories across
the estate.

It lives in the reserved `_epic/` namespace at the **workspace** `.sdd/` root (the
underscore prevents collision with any epic slug, mirroring `_product/`). A plain repo
with no workspace above it is unaffected — this tier is **purely additive**, and a member
repo's own `.sdd/` is untouched by it.

## Two levels, never flattened

There are **two distinct `.sdd/` levels**, and **each fact lives at exactly one** of them.
This is the spine of the tier — get it wrong and you have two stores that can disagree.

- **Estate level** — `workspace/.sdd/` (the superproject). Epic plans, contract design,
  estate ADRs, promoted cross-service lessons.
- **Repo level** — each submodule's own `.sdd/` (unchanged, governed by `SKILL.md`). That
  repo's specs, acceptance, per-story ADRs, reviews, PROGRESS.

Never put an estate-level fact in a repo `.sdd/`, or a repo-level fact in the estate
`.sdd/`. The estate plans *what crosses services*; each repo owns *how it builds its own
story*.

**One fact, one home:**

| Fact | Home |
|---|---|
| Epic dependency DAG (story↔contract edges, repo assignment) | estate `_epic/<slug>/plan.md` |
| Contract **design** (interface shape a story publishes/consumes) | estate `_epic/<slug>/contracts.md` |
| **Published** contract artifact (versioned, append-only) | contract **registry** — *not* the vault |
| Estate ADRs | estate `_epic/<slug>/DECISIONS.md` |
| Promoted cross-service lessons | estate `_epic/lessons/` |
| Story intent · business value · **status** · sign-off | **Jira** |
| Story→contract edges *as the conductor's input* | Jira story metadata (a *derived* projection of `plan.md`; the vault wins) |
| Repo-level spec / acceptance / per-story ADRs / reviews | that submodule's `.sdd/<story>/` |
| Derived dependency graph · reverse edges · blast radius | service **catalog** (derived; see `references/service-catalog.md`) |

Contract **design** is the vault's; the **published** contract is the registry's — the
design is authored before anything is published, and the two are never the same store.
Story **status** is Jira's; the dependency **edge** the conductor reads is a *projection*
of the vault DAG stamped onto the Jira story — regenerable, with `plan.md` authoritative on
any conflict (the same derived-projection pattern as the product-memory block in
`./CLAUDE.md`).

## Layout and ownership

```
workspace/                          # superproject — git parent; one Obsidian vault over all of it
  .sdd/                             # ESTATE vault — the spine
    _epic/
      <epic-slug>/
        plan.md         # architect (+human). The dependency DAG: nodes = stories (each tagged
                        #   with its target member repo), edges = story→contract publish/consume.
                        #   SOURCE OF TRUTH for the plan. No machine STATUS enum (see "Derived status").
        contracts.md    # architect (+human). The contract DESIGN — interface shape each story
                        #   publishes/consumes. Authored here BEFORE anything is published to the registry.
        DECISIONS.md    # architect. Append-only estate ADR log (the cross-service "why").
        RATIFICATION.md # the epic-ratify HUMAN gate, ONLY. The ratification record — who/when, whether
                        #   forced, accepted concerns, and a digest of the plan+contracts it ratified.
                        #   Its EXISTENCE is the ratified signal. The one thing that can't be re-derived.
        JIRA_LINK.md    # epic-materialise (deterministic), ONLY. The vault↔Jira link: the created Jira
                        #   epic key + the story keys it created. External IDs — also un-derivable.
        ESCALATION.md   # human-written only. An estate-level deadlock the human must break.
      lessons/          # PROMOTED cross-service lessons (human-confirmed; plain markdown, stable-ID
                        #   links only — no [[wikilinks]], no ../ paths; both die outside the vault).
    .gitignore          # the transient runtime files below — ignored, never committed.
                        #   _epic/<slug>/.conductor.lock   (the per-epic conductor lease)
                        #   _epic/<slug>/.workflow-in-flight (only if an optional interrogation aid is added)
  <member-repo>/  (submodule)       # has its OWN .sdd/ — UNCHANGED by this tier
    .sdd/<story>/{spec,acceptance,DECISIONS,REVIEW,PROGRESS}.md
```

**Write boundaries.** `architect` authors `plan.md` + `contracts.md` + estate
`DECISIONS.md`. `RATIFICATION.md` is written **only** by the `epic-ratify` human gate.
`JIRA_LINK.md` is written **only** by the deterministic materialisation step.
`ESCALATION.md` and `lessons/` promotions are **human** acts. The conductor writes **only**
its transient `.conductor.lock` — never epic content, never a Jira story.

## Derived status, not a stored phase

The estate's whole value is **ground truth over recollection**. An epic therefore has **no
hand-bumped `PHASE:` field** — that would be a curated second source that drifts out of
sync with reality, the same trap as a hand-edited catalog. The set of epics is the set of
`_epic/*` dirs (not a singleton marker), and an epic's phase is a **pure function** of
artifacts that already exist for other reasons:

```
epic_phase(<slug>):
    if   any member story of this epic is ESCALATED   -> ESCALATED   # surfaced over whatever else holds
    elif RATIFICATION.md is absent                    -> PLAN        # authoring / awaiting the human
    elif no materialised story has started (per Jira) -> RATIFIED    # ratified, queued for the conductor
    elif every materialised story is DONE (per Jira)  -> (complete)  # derived; there is NO terminal stored phase
    else                                              -> DEVELOPING  # stories in flight
```

- **PLAN** ← `RATIFICATION.md` absent. The epic dir exists and the plan is being authored
  or is awaiting the human; there is no machine-meaningful intermediate, because there is
  no estate review engine (below).
- **RATIFIED** ← `RATIFICATION.md` present. *Ratified-ness is its existence*, read by the
  conductor and the fanout gate — nothing flips a status line to announce it.
- **DEVELOPING / complete** ← computed from Jira story states (resolved through the
  `JIRA_LINK.md` story keys). "Complete" is *all stories done*, derived exactly like the
  product backlog's completion — appending a story re-opens the epic automatically.
- **ESCALATED** ← any member story hitting its per-repo 3-cycle backstop. It is a derived
  **alarm** surfaced over the rest, not a phase someone sets.

`RATIFICATION.md` pins a **digest** of the `plan.md` + `contracts.md` it ratified, so a
post-ratification edit to the plan is *detectable* (ratified content ≠ current content)
rather than silently "still ratified." `JIRA_LINK.md` is the materialisation **receipt**
and the external-ID link — it is **not** the conductor's story list; the conductor reads
the story set live from Jira (ground truth), using `JIRA_LINK.md` only to resolve the Jira
epic key.

## The EPIC spine — plan → ratify → dispatch

Deliberately **thin**: author the vault, a human ratifies, code materialises and dispatches.
There is **no estate review machine** — see the box below before adding one.

```
/sdd-fleet:epic-plan <slug>          /sdd-fleet:epic-ratify <slug> [ratify|ratify force]        the conductor
        │ (model + human)                     │ (HUMAN gate; disable-model-invocation: true)      (modelless; scripts)
        ▼                                     ▼                                                   ▼
   STEP 1: author the vault       STEP 2: ratify ──► STEP 3: materialise into Jira      level-triggered dispatch
   (plan.md + contracts.md,         (write RATIFICATION.md)   (deterministic; write          of ready stories
    STATUS via authoring)                                      JIRA_LINK.md)
```

**STEP 1 — author the vault, and only the vault.** `/sdd-fleet:epic-plan <slug>` scaffolds
`_epic/<slug>/` and delegates to **architect** to author `plan.md` (the DAG) and
`contracts.md` (the contract design). It writes the **estate vault only** — no Jira, no
registry, no gate (mirrors `new-product`: vault-first, no external store).

**STEP 2 — a human ratifies.** `/sdd-fleet:epic-ratify <slug>` carries
`disable-model-invocation: true` (the model cannot self-ratify — the headless safety story)
and **never auto-passes**. Bare command is a **dry-run**: it prints the plan + contract
design for the human to read, and halts. `ratify` writes `RATIFICATION.md`; `ratify force`
records consciously-accepted concerns. Ratification is the **one human decision the system
persists** — everything else is re-derived.

**STEP 3 — materialise into Jira, as deterministic code.** Creating Jira stories is a
*consequence*, so it lives in a **script, not command prose**
(`scripts/epic-materialise.sh`, run by the ratify command *after* `RATIFICATION.md` lands,
through the Jira adapter seam). It creates the Jira **epic**, then **one story per plan
node**, seeding each with high-level context, a **pointer back to the vault**, and the
**projected contract-edge metadata** the conductor reads. It records the created keys in
`JIRA_LINK.md`. It **does not copy the structured plan into Jira** — the vault owns the
plan, Jira owns intent + status. A failed/partial Jira write never un-ratifies the epic
(the vault flip already succeeded) — the same best-effort posture as `plan-finalize`'s
`./CLAUDE.md` write.

> **No estate review engine — decide this deliberately.** The product tier has
> `plan-review` because a product plan is a strategic bet worth interrogating. The estate
> spine omits the equivalent **on purpose**: the estate's value is having *no model in
> dispatch*, and `plan → human-ratify → deterministic dispatch` needs no review phase to be
> sound (the human reads the plan and ratifies). An optional model **interrogation** of the
> epic plan — architect + qa surfacing questions/risks/gaps, *no vote, no auto-decision*,
> the human still ratifies — is allowed (a model judging a draft is squarely inside the
> authority boundary) but is **purely additive future scope**, not a phase and not a gate.
> It must be *added deliberately*, never appear by default; until then there is no
> `EPIC_REVIEW` state and no `REVIEW.md` in `_epic/<slug>/`.

## The conductor — modelless, creation-free estate dispatch

The conductor is a **level-triggered reconciler, scripts only** — no agent, no slash
command, no model. It is the estate-wide generalization of `next-feature.sh`'s
*resolve → signal → let the dispatcher start the work* pattern. One **tick** is a pure
function of live state; the **loop** is the harness re-invoking the tick (the clock is
injected via `--now`; no `Date`, no randomness). It is **built** as `scripts/conductor-tick.sh`
(one tick), `scripts/ready-frontier.sh` (the pure set-logic core), and `scripts/conductor-loop.sh`
(the per-epic sweep), and its modelless/creation-free guarantee is **gated by committed,
running tests**, not asserted: `conductor-modelless-lint.test.sh` (a re-derive-from-source
lint — no `date`/`$RANDOM`, `--now` injected, no `jira-story`/`create-*`, no `plan.md`/
`contracts.md` read) plus `ready-frontier.test.sh` (frontier-subset + completeness, two-sided)
and `conductor-tick.test.sh` (count-invariant, crash-idempotency, re-read-not-recorded-flag,
level-triggered progress, the lease, and a creation-free runtime lock on the adapter log). It
satisfies these invariants:

- **Reads ground truth fresh every tick** — the Jira story set (status + projected edges)
  and the registry's published-contract set. No cache, no event subscription: a story
  waiting on contract `C` is released on whatever tick first re-reads `C` as published, so
  a missed publish event can never strand it.
- **Recomputes the ready frontier as pure set logic** — a story is ready iff every contract
  it consumes is published *now*. Never a severity, a soundness call, or any drafting.
- **Dispatches a subset of existing stories** — it emits a dispatch signal and advances the
  canonical Jira status (`NOT_STARTED → DISPATCHED`); it **never invokes `jira-story`
  itself, never creates a Jira story, and never reads `plan.md`/`contracts.md`** (it touches
  the vault only to resolve the Jira epic key and to hold its lease).
- **Holds no private mutable state** — `DISPATCHED` lives in Jira and is re-read each tick;
  a crash recovers forward-only from real status (idempotent re-signal, never a double).
- **One conductor per epic** — an atomic noclobber lease (`_epic/<slug>/.conductor.lock`,
  the `lease_acquire`/`lease_release` helpers in `_lib.sh`: the `set -C` noclobber idiom
  with owner metadata, `--now` injected, no auto-expiry, **same-owner re-entrant** for
  crash recovery). The lease is **separate runtime state** — the epic list is never folded
  into it. **Dispatch-once does not depend on the lease**: it comes from the NOT_STARTED-only
  frontier plus the idempotent transition, so even two conductors on one epic cannot
  double-dispatch; the lease is coordination only.

**Adapter seam (read + transition).** The conductor reaches Jira behind the
`SDD_JIRA_ADAPTER` seam (the same env-var seam as `epic-materialise`), adding two verbs to
the existing write-only `create-epic`/`create-story`:

- `jira-snapshot --epic-key <k> --now <iso>` → `{"epic":"<k>","stories":[{"id","key","status","consumes":["<c>@<major>"],"repo"}]}` — the live story set; the conductor reads `status` + the projected `consumes` edges **only from here**, never from `plan.md`.
- `jira-transition --epic-key <k> --story <id> --to DISPATCHED --now <iso>` → `{"status":"transitioned"|"noop"}` — **idempotent** (a no-op when already dispatched).

**Stated limits.**

- *Adapter modelless-ness is out of the source lint's reach* (the adapter is behind the
  seam, not shipped) — bounded instead by the **creation-free runtime lock**: the tick's
  adapter-call log is asserted to contain only `jira-snapshot` + `jira-transition`, never a
  `create-*`.
- *No lease auto-expiry* (inherited from the `acquire-active` posture): a crash by a
  **different-owner** conductor strands dispatch until a human removes
  `_epic/<slug>/.conductor.lock`; a **same-owner** restart recovers automatically.
- *The cross-level dispatch token is not planted yet* — a dispatch is observable via the
  `SDD_FLEET_DISPATCH` signal plus the Jira status advance; the fanout gate today re-derives
  ratification from the superproject + `RATIFICATION.md` rather than consuming a
  conductor-planted token. Planting a token is deferred to that hook's mechanism.
- *Real contract-edge projection is deferred* — `epic-materialise` does not yet stamp
  `consumes` onto Jira stories; the conductor reads whatever the adapter projects (the test
  fixture supplies it), with `plan.md` authoritative on any conflict.

A dispatched story is picked up by the per-repo `/sdd-fleet:jira-story <id>` machine, which
reads its Jira story as starting context, pulls structured detail from the vault, and runs
the §2 (per-repo) state machine.

## Promotion of lessons is human-confirmed

A lesson that turns out to be cross-service is **promoted** from a member repo's `.sdd/`
up to `workspace/.sdd/_epic/lessons/` by an **explicit human step** — never an automatic
copy. The model may *propose* a promotion; a human confirms it. The model never curates
estate memory (the authority boundary in `CLAUDE.md`: a model never decides a consequence
and never curates memory). Promoted lessons are plain markdown with **stable-ID links
only** (contract name, Jira key, registry URL) — no `[[wikilinks]]`, no `../` paths, both
of which resolve in the vault but break in a member repo's view.

## Hook interactions and anchoring

- **`epic-ratified-before-fanout` (fail-closed).** Refuses to spec a story whose epic is
  not ratified — the code consequence that guarantees STEP 3 cannot precede STEP 2 even
  under direct invocation. It runs inside a **member repo**, so it must learn the *parent*
  epic's ratified status; the recommended mechanism is a **dispatch token** the conductor
  drops at dispatch (the conductor only ever dispatches ratified epics, so the token's
  existence is the proof — no `../` cross-level path-walking). Built on the
  `block-source-before-finalized.sh` skeleton (prologue + `ERR`→`exit 2` trap, slug-naming
  stderr, `exit 0` = deliberate allow). Final mechanism is settled in that hook's sub-plan.
- **Two anchoring roots.** Estate commands and the conductor run at the **workspace**
  `CLAUDE_PROJECT_DIR` (the superproject) and read `workspace/.sdd/_epic/`; the per-repo
  machine runs in each **submodule**'s `CLAUDE_PROJECT_DIR`. Neither reaches across the
  boundary by `../` path-walking — the only cross-level signal is the dispatch token the
  conductor plants in the target repo.
```
