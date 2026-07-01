# ADR-0002: The design document is the source of truth — ratified decisions and the alignment plan

- **Date:** 2026-07-01
- **Status:** accepted

## Context

A full verification of `docs/sdd-fleet-design.html` and `docs/sdd-fleet-concept.html`
against the implementation found 22 confirmed doc-vs-repo discrepancies. The owner
ruled that **the design document is the source of truth**: where the docs and the
implementation disagree, the design is corrected first, and the implementation is
then brought into line with it. This ADR records (a) the four contested design
decisions and their resolutions, and (b) the disposition of every discrepancy —
which side moves.

## Decisions

1. **HANDOFF's human gate is conditional, not universal.** HANDOFF is executed by
   the devops agent; a human approval is *forced* only when the computed blast
   radius is risky (≥ N transitive consumers, or `money_movement` / `pii` data
   classes). This upholds the `CLAUDE.md` hard rule ("blast radius drives the
   human gate — principled and computed, never hardcoded"). The design doc's
   spine figures, which drew HANDOFF as an unconditional human approve-and-merge,
   were corrected.

2. **CHANGE_REVIEW's roster is architect + qa.** The coder authored the diff under
   review; the design's own rule — "the refuter is never the concern's own
   author" — excludes a coder lens there. REVIEW keeps all three lenses. The
   design doc's band-4 figure and captions were corrected; coder participates in
   CHANGE_REVIEW only via the `revise` exit (re-implementation in BUILD).

3. **Every phase syncs status to Jira — implement it.** The design doc's per-phase
   "status → Jira" arrows are ratified design. `scripts/jira-adapter.sh` gains a
   phase-transition verb mapping SPEC / REVIEW / BUILD / CHANGE_REVIEW / HANDOFF /
   DONE to Jira statuses, and each command's phase flip triggers the deterministic
   sync. This also closes the gap where nothing could ever mark a story DONE,
   which epic completion (per `skills/sdd-protocol/references/workspace-tier.md`)
   depends on.

4. **Citation existence is checked by the harness; soundness stays with the model.**
   The survival vote's "citation resolves" filter is ratified as code: the
   deterministic in-workflow check verifies the cited quote/locator appears in
   the artifact text already passed to the workflow. The single neutral
   adjudicator keeps only the genuinely subjective call — does the citation
   *support* the refutation? Code checks what code can check.

## Disposition of the remaining findings

**Implementation catches up to the design** (the doc claims stand as ratified design):

- `/sdd-fleet:next-story <epic>` — the developer pull entry over the
  `ready-frontier.sh` core (the future addition ADR-0001 anticipated is adopted).
- `/sdd-fleet:jira-story <story id>` — Jira story-ID intake via a new
  `read-story` adapter verb (closes the deferral noted in workspace-tier.md).
- The **counterfactual** becomes a fail-closed gate at the HANDOFF flip: a
  recorded `verdict: pass` from `scripts/counterfactual.sh` is required, as the
  script's own header anticipated ("the fully fail-closed hook form").
- **No handoff on a failing or untraceable suite** becomes a hook: the HANDOFF
  flip requires a recorded green run of the write-locked, traceable suite.
- **Blocker identity hashes the mapped criterion**: `criterion` is added to the
  concern schema so `blockerIdentity`'s criterion branch is reachable, making
  "same blocker" a comparison of the mapped acceptance criterion, not concern text.

**The design document was corrected** (it contradicted the design's own rules or
its concrete examples were stale):

- The descriptor example is `service.json` — JSON, lifecycle
  `experimental | production | deprecated`, `produces`/`consumes` as
  `contract@major` tokens (full semver and spec artifacts live in the registry).
  The YAML/semver-range block was a stale iteration.
- Signal lines follow the machine contract: `SDD_FLEET_*_REFUSE` /
  `SDD_FLEET_*_PASS` with `{"code":<int>,"reason":"<slug>"}` payloads. The
  concept doc's invented `SDD_FLEET_FINALIZE:` / `SDD_FLEET_HANDOFF:` lines with
  `{"ok":false}` payloads were replaced.
- AC→test mapping and the write-lock happen in BUILD (tests-first), not SPEC;
  the dependency gate fires at the CHANGE_REVIEW→HANDOFF flip, not inside BUILD;
  Jira materialisation is `epic-ratify`'s deterministic step, not `epic-plan`.
- Coverage grounding is stated honestly: QA reads captured coverage output where
  tooling exists (hard-gated when a threshold is configured); the no-tooling
  fallback is explicitly labelled a model assessment.

## Consequences

- The implementation work lands as one aligned change set: next-story, the
  jira-adapter read/transition verbs and per-phase sync, the two new HANDOFF-flip
  gates (counterfactual, suite), the concern-schema `criterion` field, and the
  in-workflow citation-existence check — each gate change test-first, in the
  existing hermetic harness style.
- `skills/sdd-protocol` (and its references) and `CLAUDE.md`'s component lists
  are updated with the same change set, and the release moves atomically per the
  release checklist.
- Until that change set ships, the design documents intentionally describe
  behavior ahead of the implementation; this ADR is the record of that intent.
