---
layout: default
title: "ADR-0001 — The conductor is a stateless reconcile sweep"
---

# sdd-fleet Architecture Decisions

Append-only log of **plugin-level** design decisions (distinct from the runtime
`.sdd/DECISIONS.md` records the fleet writes inside member repos). Each ADR is
immutable; supersede with a new ADR rather than editing an old one.

---

## ADR-0001: The conductor is a stateless reconcile sweep — not a daemon, not per-session

- **Date:** 2026-07-01
- **Status:** accepted

### Context

The workspace-layer **conductor** is the piece that advances an epic's stories
across repos as their dependencies become satisfiable. Its shape is fixed by a
hard rule (`CLAUDE.md`): *the conductor stays modelless and command-less* — the
widest-blast-radius layer is the one where a model in the loop is most dangerous,
so it is deliberately not an agent and not a slash command.

That framing keeps generating the same three questions, because the name
"conductor / reconciler" implies more than it is:

1. **Does it run autonomously if the per-repo machine has human gates?**
2. **How is it actually executed — is there a daemon running somewhere?**
3. **If N developers each run Claude Code interactively, does each get a conductor?**

This ADR records the answers as one coherent execution & deployment model, so it
is not re-litigated. The authority for the mechanics remains
`skills/sdd-protocol/references/workspace-tier.md` and the scripts themselves;
this ADR is the *why* and the operational picture.

### Decision

**The conductor is a stateless, idempotent reconcile *sweep*, invoked one tick at
a time — not a long-running service and not something any developer hosts.**

- **One tick** (`scripts/conductor-tick.sh <epic> --now <ts>`) reads the live Jira
  story set + the contract registry **fresh**, computes the ready frontier as pure
  set logic (`scripts/ready-frontier.sh` — a story is ready iff it is
  `NOT_STARTED` and every contract it `consumes` is published), advances each ready
  story `NOT_STARTED → DISPATCHED` via the Jira adapter, emits one
  `SDD_FLEET_DISPATCH` signal per dispatch, and **exits**. It follows the
  `resolve → signal → never-invoke` pattern: it never starts the per-repo machine,
  never creates a story, never reads `plan.md`/`contracts.md`.
- **One sweep** (`scripts/conductor-loop.sh --now <ts>`) fires a tick per epic
  (the epics *are* the `.sdd/_epic/*/` dirs — ground truth, no index to drift), and
  also exits. **There is no daemon.** "Looping" is an *external* scheduler
  (cron / CI / `watch`) re-invoking the sweep, injecting a fresh `--now` each time.
  It reads no clock and keeps no state between runs.
- **It is workspace infrastructure, not per-developer.** Being command-less, it
  cannot live inside a model session. Developers do not each host one; they
  *consume* its output (dispatched stories).
- **Concurrency is safe by construction, not by a mutex.** Dispatch-once does
  **not** depend on the lease: the frontier is `NOT_STARTED`-only and the Jira
  transition is idempotent, so any number of concurrent ticks on the same epic
  compute the same frontier from the same shared ground truth (Jira + registry)
  and cannot double-dispatch. The per-epic lease
  (`_epic/<slug>/.conductor.lock`, atomic no-clobber, no auto-expiry) only makes
  redundant sweeps *defer* to each other — coordination, never correctness.
- **Human gates never block dispatch.** The one human "go" is collapsed up front
  into `epic-ratify` (a hard human gate; the conductor never dispatches an
  unratified epic, and the `epic-ratified-before-fanout` hook is the backstop).
  The remaining human gates (HANDOFF, money/PII / blast-radius, escalation) sit at
  the *end* of each story and block merge, not dispatch. Because the sweep is
  level-triggered and re-reads everything each tick, a human clearing a HANDOFF
  (which publishes a contract to the registry) is simply new world state that the
  *next* tick observes — releasing whatever was waiting on it. The conductor never
  waits on a human.

Two operating modes fall out of the same `ready-frontier.sh` core:

| Mode | Who runs the sweep | When to use |
|---|---|---|
| **Interactive / pull** | on-demand (a person, or `/sdd-fleet:status`) | dev-driven teams; the realistic default today |
| **Autonomous / cron** | one scheduler on shared infra | hands-off, at-scale, continuous release |

### Alternatives considered

- **A long-running conductor daemon.** Rejected: a daemon holds process state and a
  clock, which breaks replay (`--now` injection) and reintroduces "recollection" the
  design specifically forbids. A stateless sweep re-derived from ground truth each
  tick is strictly safer and testable.
- **A conductor as a slash command / in-session.** Rejected by the standing hard
  rule: a slash command runs in a model session and invites the model to editorialize
  dispatch across the whole estate — the one layer whose value is having no model.
  (A *deterministic-resolver-only* command like the product-tier `next-feature` is
  the sanctioned exception, and an epic-tier `next-story` could follow that precedent
  — but it would be sugar over this same core, not a different conductor.)
- **A model-driven orchestrator** that decides ordering/importance. Rejected: ordering
  is pure set logic over published contracts; a model there is non-determinism with
  no upside.
- **A conductor per developer / per session.** Rejected as a category error: it is
  estate infrastructure. Even if it happened, idempotency makes it harmless, but the
  intended topology is one shared frontier feeding many single-story worktrees.

### Consequences

**Easier / load-bearing guarantees**
- **Safe concurrency with no locking discipline.** N sweeps converge; the shared
  mutable state is *only* Jira status + the registry. Everything else is re-derived.
- **Replayable and testable.** No clock, no randomness, no creation — gated by
  `conductor-modelless-lint.test.sh` and `ready-frontier.test.sh`.
- **Autonomy that never bypasses a gate.** "Autonomous between gates" — like a CI/CD
  pipeline with manual-approval stages. The conductor approves nothing.

**Topology this commits us to**
```
  ESTATE PLANE  (shared, not per-dev)            REPO / WORKTREE PLANE  (per-dev, partitioned by repo)
  ───────────────────────────────────           ───────────────────────────────────────────────────
  conductor sweep (cron/CI or on-demand)         Dev A ─ claude -i ─ jira-story S1 → feature-dev → pr-review  (authoriser/, ACTIVE)
  · modelless bash, one tick per epic            Dev B ─ claude -i ─ jira-story S2 → feature-dev → pr-review  (checkout/,  ACTIVE)
  · resolve frontier → signal → never-invoke
              └──────────────  JIRA status  +  contract REGISTRY  (the ONLY shared mutable state)  ──────────────┘
```
- **Parallelism is across repos, not within one.** Single-worktree + the per-repo
  `.sdd/ACTIVE` lock serialize work inside a repo; different stories live in different
  repos. Cross-developer coordination is Jira status (kept current by every phase
  syncing to Jira), with the PR/merge as the hard serialization.

**Harder / honest limits**
- **The autonomous last mile is unwired.** The sweep *signals* dispatch; something
  still has to *start* `jira-story <id>` headless on each `SDD_FLEET_DISPATCH`.
  `workspace-tier.md` notes the cross-level dispatch token "is not planted yet …
  deferred." So today the honest operating mode is **pull**: run a sweep / `status`
  to get the frontier, developers start ready stories interactively.
- **Interactive teams typically don't run the loop at all** — which is fine, and is
  why an epic-tier `next-story` convenience (mirroring `next-feature`) is a
  reasonable future addition over this core, explicitly *not* a second conductor.

### References
- `scripts/conductor-tick.sh`, `scripts/conductor-loop.sh`, `scripts/ready-frontier.sh`
- `hooks/scripts/epic-ratified-before-fanout.sh`
- `skills/sdd-protocol/references/workspace-tier.md` (§ "The conductor — modelless, creation-free estate dispatch")
- `commands/next-feature.md` (the product-tier deterministic-resolver precedent)
