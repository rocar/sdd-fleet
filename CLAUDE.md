This repo is the **sdd-fleet Claude Code plugin**: a spec-driven, multi-agent
development system for a **regulated bank's multi-repo estate**, optimized for
**audit and replay**, not raw speed. Claude Code is both the *runtime* (it
executes the workflow across the workspace and its member repos) and the
*builder* (it authors and edits the agents, skills, hooks, commands, workflows,
and reconciler scripts here). Treat everything in this repo as production
source: review it, version it, test it.

The runtime workflow rules (state machine, gates, escalation, the `.sdd/`
layout) live in the **`sdd-protocol` skill** — `skills/sdd-protocol/SKILL.md`
plus its `references/`. That skill is the authority on how the fleet runs; this
file only covers how to work on the plugin itself.

## The boundary that governs everything

sdd-fleet is **a deterministic harness over probabilistic generation**. Every
change you make keeps that line sharp:

- **Harness (code)** owns every *consequence* — phase gates, survival-vote
  counting, routing, the bounded loop, semver + blast-radius computation,
  workspace dispatch. Reproducible and fail-closed.
- **Model** judges only the irreducible *residue* — drafting, per-criterion
  review, the single contested soundness call. A model never decides a
  consequence and never curates memory.
- **Human** owns the *blast radius* — epic/contract ratification before fan-out,
  money-movement and PII gates, escalation resolution.

The operational rule that falls out of this: **every consequence lives in a hook
or a workflow** — pure code, identical on a re-run. A command's prose
precondition is advisory; it is never the only thing standing between a draft
and a consequence (a merge, a money gate, a contract publish). Move a gate into
command prose and you have moved a consequence into the model.

## Architecture — a control stack over record planes

Three control layers (who acts):

- **Layer 3 · workspace** — a parent folder with the member repos as git
  submodules and one Obsidian vault over them. `epic-plan` (model + human)
  authors the dependency DAG and contract design; the **conductor** dispatches.
- **Layer 2 · per-repo feature machine** — SPEC → REVIEW → FINALIZE → BUILD →
  CHANGE_REVIEW → HANDOFF, one machine per repository, single-worktree.
- **Layer 1 · hooks** — fail-closed, tool-level interception; the boundary the
  harness can't be talked past.

Four record planes, each owning **exactly one** fact (never add a second store
for a fact a plane already owns):

- **Workspace vault `.sdd/`** — epic plans, contract designs, specs, acceptance,
  ADRs, lessons. *The source of truth.*
- **Jira** — intent, business value, status, sign-off.
- **Contract registry** — published OpenAPI / Avro / proto, versioned,
  append-only.
- **Service catalog** — dependency graph, reverse edges, blast radius.
  *Derived, recomputed — never hand-kept.*

## Layout (what actually ships)

```
.claude-plugin/plugin.json    # manifest (+ marketplace.json)
agents/                       # role subagents: the three review lenses —
                              #   architect, coder, qa — plus scribe, the SOLE
                              #   writer of .sdd/ state. The conductor is NOT an
                              #   agent (it is deterministic — see Hard rules).
commands/                     # /sdd-fleet:* slash commands —
                              #   per-repo:  jira-story, feature-dev, pr-review
                              #   workspace: epic-plan
                              #   (the conductor has NO command — dispatch is plumbing)
skills/                       # sdd-protocol (+references/), review-rubric,
                              #   sdd-spec-template, adr, ... the runtime rulebook
hooks/hooks.json              # hook registration (the ONLY registration point)
hooks/scripts/                # fail-closed gate scripts + their *.test.sh, e.g.
                              #   block-source-before-finalized, testability,
                              #   traceability (AC->test), write-lock,
                              #   dependency-gate (service.yaml), counterfactual,
                              #   epic-ratified-before-fanout, money/PII gate
workflows/                    # dynamic workflows (isolated JS runtime):
                              #   the review engine (REVIEW + CHANGE_REVIEW),
                              #   the build workflow, epic planning
scripts/                      # deterministic, model-free helpers + their *.test.sh:
                              #   the CONDUCTOR reconciler (status-snapshot,
                              #   ready-frontier, lease acquire), semver check,
                              #   catalog/blast-radius derivation, run-tests
docs/                         # contracts, smoke fixtures, history
.github/workflows/ci.yml      # CI: test matrix + release-channel check
```

The orchestrator is the main session; lenses are dispatched via Task/workflows.
Workspace state is the vault `.sdd/` (the spine); each submodule carries its own
`.sdd/`. See the `sdd-protocol` skill for the `.sdd/` layout, ownership, policy.

## Running the tests

```bash
bash scripts/run-tests.sh        # every hook + script suite, then the smoke test
```

- Individual suites run directly: `bash hooks/scripts/<name>.test.sh`,
  `bash scripts/<name>.test.sh`. Each is a hermetic mktemp harness that feeds the
  real hook stdin contract and asserts exit codes + stderr.
- Workflows: `node --check workflows/*.js` after any edit. They run in an
  isolated runtime — **no `Date`, no `Math.random`, no filesystem**; timestamps
  come from `args.now`, and **all state writes go through the scribe**. That is
  the replayability guarantee — keep it intact.
- CI runs the suite on macOS (bash 3.2) and Linux, and pins every pushed `v*`
  tag to plugin.json's version. Keep every hook script bash-3.2 AND
  GNU-coreutils compatible (probe GNU flags first — GNU `stat -f` "succeeds"
  with the wrong meaning rather than failing).
- TDD for gates: any hook behavior change gets a failing test case first, in the
  existing harness style.

## Hard rules

- **One fact, one store.** Vault `.sdd/` = source of truth, Jira = intent/status,
  registry = contracts, catalog = derived. Never introduce a second home for a
  fact a plane already owns — two stores that can disagree is the classic failure.
- **The conductor stays modelless and command-less.** Workspace dispatch is a
  level-triggered reconciler — no agent, no slash command, no shared mutable
  state. It reads live status + the registry each tick and recomputes the ready
  frontier; ground truth always beats its own recollection. A command there
  would put a model back into the one layer whose value is having none.
- **Cross-repo gates are deterministic; the model gets one call.** semver,
  pinned-consumer lookup, and blast-radius are code. The model judges only "is
  this diff semantically breaking beyond its version bump?" A consume edge is
  declared **only** in `service.yaml`; the catalog is derived from descriptors +
  published contracts, never hand-edited.
- **Blast radius drives the human gate.** A change reaching N transitive
  consumers — or any service carrying `money_movement` / `pii` data_classes —
  forces a human gate regardless of the machine verdict. The rule is principled
  and computed, never a hardcoded "touches auth."
- **Memory is plain markdown; links are the record.** Standard markdown links
  only — **no `[[wikilinks]]`** (they die on GitHub and to the gate parsers).
  Forward links are authored fact; backlinks and the graph are derived and
  regenerate exactly. A per-repo doc references anything outside its own tree by
  **stable ID** (contract name, Jira key, registry URL), never `../../` (it
  resolves in the vault but 404s in that repo's PR view). A semantic/embedding
  index may sit on top for discovery but **never feeds a gate**.
- **The oracle stays trustworthy.** Every acceptance criterion maps to a test
  *before* implementation; test paths are **write-locked** for the run; each
  lens returns an explicit pass/fail/concern on *every* criterion; a dedicated
  adversarial pass hunts security, money, and PII; QA is grounded in real
  coverage/mutation output, not the model's opinion of it.
- **The review loop is bounded and regression-guarded.** fan-out ->
  cross-examine -> survival vote, ≤3 rounds, blocker count must strictly fall or
  it escalates to a human early. A blocker's identity is a hash of its mapped
  criterion, so "same blocker" is a deterministic comparison.
- **Hooks fail closed.** Gate scripts anchor at `CLAUDE_PROJECT_DIR`, reject `..`
  traversal, require jq while an item is active, and trap unexpected errors to
  exit 2. Deliberate allows are explicit `exit 0`. Keep it that way.
- **Signal lines are the machine contract.** Commands cannot set process exit
  codes; orchestrators dispatch on the `SDD_FLEET_*:` stdout lines (refusals
  carry `{"code":<int>,"reason":"<slug>"}`). Never document an exit-code table.
- **The scribe has no Bash.** It is the sole writer of `.sdd/` state and releases
  the `.workflow-in-flight` marker by overwriting it with empty content; the gate
  hooks treat an empty marker as absent and the Stop-hook reaper deletes it. Keep
  agent tool allowlists tight.
- **The release checklist is atomic.** A release moves these together or not at
  all: the git tag, `plugin.json` version, `marketplace.json`, a CHANGELOG
  entry, README component counts, and the `description:` frontmatter for any
  agent whose body changed. The plugin cache is version-keyed — a content change
  without a version bump never reaches installed users. Main always equals the
  latest tag.
- **A lane that touches an agent's body must touch its description.** The
  description is the delegation surface; a stale one misroutes work.
- **Severity rubric is mirrored on purpose.** The blocker/major/minor table is
  canonical in `skills/review-rubric/SKILL.md` and mirrored verbatim in the lens
  prompt bodies (a teammate's frontmatter `skills:` are ignored in team mode, so
  review rules that must survive team mode live in the body, not only in a
  skill). Never deduplicate; `scripts/rubric-drift.test.sh` fails the suite if
  they drift. Run it after any `agents/` edit.

## Where things are decided

- Workflow/gate semantics + the `.sdd/` layout -> `skills/sdd-protocol/SKILL.md`.
- The authority boundary (harness / model / human) -> this file, top.
- The four record planes (vault / Jira / registry / catalog) -> this file + the
  `sdd-protocol` skill.
- Envelope schema + headless signal contract -> the contract doc under `docs/`.
- Severity vocabulary -> `skills/review-rubric/SKILL.md`.
- Service descriptor + blast-radius rules -> the `service.yaml` schema and the
  catalog/blast-radius scripts.
- Spec / acceptance / ADR structure -> `skills/sdd-spec-template`, `skills/adr`.
- Design lineage -> `docs/history/` and the original sdd-fleet design doc.
