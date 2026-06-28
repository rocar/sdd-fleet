---
description: Scaffold a cross-repo epic: the dependency DAG + contract design
argument-hint: "<epic-slug>"
allowed-tools: Read, Write, Edit, Task
---

# /sdd-fleet:epic-plan

You are the **orchestrator** at the **workspace (estate) level**. You scaffold the
estate `.sdd/_epic/<slug>/` vault and route authoring to the architect; you do not
author the dependency DAG or design the contracts yourself, and you write no source.

The runtime rulebook is the `sdd-protocol` skill — its `references/workspace-tier.md`
covers the two-level `.sdd/` layout, the reserved `_epic/` namespace, file ownership,
and the plan → human-ratify → dispatch spine. This command only scaffolds and drafts:
the plan it produces is **ratified by a human** at `/sdd-fleet:epic-ratify` before any
story is specced; **no gate runs here**.

## Arguments

`$ARGUMENTS` — the epic slug. Kebab-case, no whitespace. If empty, refuse and tell the
user a slug is required.

## Refusal cases (check first, in order)

1. **`.sdd/_epic/<slug>/` already exists.** Refuse: one directory per epic. Tell the
   user to edit the existing `_epic/<slug>/` files directly, or to inspect them. Stop.
2. **`$ARGUMENTS` is empty.** Refuse; require a slug. Stop.

*(There is no "feature mid-review" refusal — the estate level has no single active
feature; that is a per-repo concept. Estate scaffolding writes only under
`workspace/.sdd/_epic/`, which no per-repo hook gates.)*

## Run at the workspace root

This command operates on the **estate** vault `workspace/.sdd/_epic/` — the parent
superproject over the member repos, **not** a member repo's own `.sdd/`. Run it at the
workspace root. Estate-level facts (the DAG, the contract design, estate ADRs) live
here; repo-level facts (specs, acceptance, per-story ADRs) stay in each member repo's
own `.sdd/`. The two `.sdd/` levels are never flattened — a fact lives at exactly one.

## Establish the epic description

Before scaffolding, determine *what the epic is* — the cross-repo capability or outcome,
which member repos it spans, the rough story breakdown, and any known contract
boundaries between the services. Look back through the conversation for a description
the user already gave. **If none exists, STOP and ask** — do not infer an epic from its
slug. Wait for the answer. Carry it verbatim into the delegation below.

## What you do

1. **Scaffold `.sdd/_epic/<slug>/`** with these files. Write the scaffolds yourself
   (you have `Write`); the architect fills the bodies (mirrors `/sdd-fleet:new-product`,
   where the orchestrator scaffolds and the architect authors):

   - `plan.md` — header `EPIC: <slug>`, then a `## Stories` skeleton and a
     `## Dependency DAG` note. **No STATUS enum** — ratified-ness is recorded later as a
     discrete artifact (`RATIFICATION.md`), never a status line here (see
     `references/workspace-tier.md`, "Derived status, not a stored phase"). Leave bodies
     for the architect:
     ```
     EPIC: <slug>

     ## Stories
     <!-- one block per story (the architect fills these):
     - id: <story-slug>
       repo: <member-repo>
       intent: <1-3 lines: what the story is, its scope boundary, explicit non-goals>
       publishes: [<contract-name@version>, ...]    # contracts this story makes available
       consumes:  [<contract-name@constraint>, ...]  # contracts it needs before it can start
     -->

     ## Dependency DAG
     <!-- the ordering the publish/consume edges above induce — which stories unblock
          which. A story is ready when every contract it consumes is published. This is
          a human-readable rendering of the per-story edges, which remain authoritative. -->
     ```
   - `contracts.md` — header `EPIC: <slug>`, then a `## Contracts` skeleton (one
     subsection per contract the epic introduces or changes), bodies for the architect:
     ```
     EPIC: <slug>

     ## Contracts
     <!-- one subsection per contract (the architect fills these):
     ### <contract-name>
     - kind: openapi | avro | proto
     - owning story: <story-slug>
     - version: <semver intent, e.g. 1.0.0>
     - interface: <the shape — endpoints / schema / messages; a sketch, NOT the
       published artifact (publishing to the registry is a later, post-ratification step)>
     - consumers: [<story-slug>, ...]
     -->
     ```
   - `DECISIONS.md` —
     ```
     # Estate Architecture Decisions — <slug>

     Append-only ADR log. Cross-service topology, contract-boundary, and sequencing
     decisions for this epic.
     ```
   - `.sdd/.gitignore` — **only if absent**, with the estate transient entries (the
     per-epic conductor lease and the in-flight marker are live coordination files,
     never committed — see the `sdd-protocol` skill, ".sdd/ in version control"):
     ```
     .conductor.lock
     .workflow-in-flight
     ```

   Do **not** scaffold `RATIFICATION.md` (only the `/sdd-fleet:epic-ratify` human gate
   writes it — its existence *is* the ratified signal), `JIRA_LINK.md` (only the
   deterministic materialise step writes it), a `PROGRESS.md`, or any singleton marker.
   The set of epics **is** the set of `_epic/*` dirs, and an epic's phase is **derived**
   from those artifacts and live Jira state — never stored or hand-bumped.

2. **Delegate the DAG + contract design to architect.** Spawn `sdd-fleet:architect` via
   the Task tool. Tell it: it owns `.sdd/_epic/<slug>/plan.md`, `.sdd/_epic/<slug>/contracts.md`,
   and `.sdd/_epic/<slug>/DECISIONS.md`. From the epic description, author —
   (a) the **dependency DAG** in `plan.md`: the stories, each tagged with its target
   member repo and a 1-3 line intent, plus the story→contract publish/consume edges that
   order them (a story is ready once every contract it consumes is published);
   (b) the **contract design** in `contracts.md`: the interface shape each story
   publishes or consumes, authored **before** anything is published to the registry;
   (c) **estate ADRs** in `DECISIONS.md` recording the topology / contract-boundary /
   sequencing *why* (per the `adr` skill). The architect uses `Edit` to fill the
   scaffolds (it has no `Write`); make sure the scaffold files exist from step 1. Pass
   the epic description verbatim. Keep estate-level facts in `_epic/<slug>/` — never put
   a repo-level fact (a spec, acceptance, a per-story ADR) here.

3. **Report back.** Summarize the epic's story count, the member repos it spans, the
   contracts it introduces or changes, and the top-level dependency edges. Tell the user
   the plan is authored but **not ratified**: review the `_epic/<slug>/` files directly,
   and when ready run `/sdd-fleet:epic-ratify <slug>` — the human gate that ratifies the
   plan + contract design before any story is specced. **Nothing is created in Jira and
   no contract is published until ratification.**

## Gates to honor

- All `.sdd/_epic/<slug>/*` writes are inside `.sdd/`, so `block-source-before-finalized`
  permits them (it allows any path under `.sdd/`, and exits early when there is no active
  feature — which there never is at the estate level).
- This command enforces **no** estate gate. Ratification is a human act at
  `/sdd-fleet:epic-ratify`; if you find yourself wanting to flip a "ratified" state or
  create a Jira story, stop — that is the ratify gate's and the materialise step's job.

## Hard "no"s

- Do not run any workflow or invoke the scribe — this is plain file scaffolding.
- Do not write `RATIFICATION.md`, `JIRA_LINK.md`, a `PROGRESS.md`, or any singleton /
  PHASE marker, and do not touch any member repo's `.sdd/`.
- Do not author the DAG or design the contracts yourself — delegate to the architect.
- Do not create anything in Jira or publish any contract — those are post-ratification
  consequences owned by deterministic code, not this command.
