# Service catalog & cross-repo contract gates — reference

This is the **cross-repo contract governance** layer: the human-owned service descriptor,
the **derived** service catalog + blast radius, and the five fail-closed gates that let the
fleet reason about contracts *across* repos. Every consequence here is **code** — semver,
pinned-consumer lookup, blast-radius, and edge reconciliation are deterministic; the model
gets exactly one isolated call (semver soundness), and that call is a later-slice seam.

The record planes are unchanged (`./CLAUDE.md`): the **descriptor** declares edges + data
classes; the **registry** holds published contracts; the **catalog** is derived, never
hand-kept. Contract *design* still lives in the vault (`_epic/<slug>/contracts.md`); the
*published* contract is the registry's.

## `service.json` — the service descriptor (repo root; human-owned, gated)

JSON, not YAML — the harness parses it with `jq` (there is no YAML parser). A **consume edge
is declared only here**; the catalog is derived from descriptors + the registry.

```json
{
  "id": "payments-api",
  "team": "payments",
  "lifecycle": "production",
  "data_classes": ["money_movement", "pii"],
  "produces": ["payments.charge@2"],
  "consumes": ["ledger.post@1", "fraud.score@1"]
}
```

- `id` — `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (the catalog node key); `team` — non-empty.
- `lifecycle` — `experimental | production | deprecated`.
- `data_classes` — array; `money_movement` and `pii` drive the blast-radius human gate.
- `produces` / `consumes` — array of `<contract>@<major>` tokens
  (`^[a-z0-9]([a-z0-9._-]*[a-z0-9])?@[1-9][0-9]*$`; a consumer pins a major line).

The single home of this schema is `scripts/service-descriptor.sh`
(`validate <file>` / `read <file> <field>`); the **`validate-service-descriptor`** PostToolUse
hook blocks a `service.json` write that fails it (fail-closed; jq-missing fails closed).

## Registry — published contracts (append-only)

```
registry/<contract>/<semver>.json            # a published contract version
registry/<contract>/expectations/<consumer-id>.json   # a registered consumer expectation
```

A published artifact carries `contract`, `version` (full semver; the filename stem),
`kind` (`openapi|avro|proto`), an optional `client_signature` (a regex: how a call to this
contract appears in consumer source — the source-scan detector; absent ⇒ the contract is
**unscanned**, logged as a coverage gap, never silently dropped), and the declared
`operations` / `fields` the CDC check reads. A contract `<c>@<m>` is *published* iff any
`registry/<c>/<m>.*.json` exists.

## Catalog — derived dependency graph (`scripts/catalog-derive.sh`)

`catalog-derive.sh [root]` emits one JSON object (services, `reverse` edges,
`produced_by` edges, `published` set) derived from every `service.json` and the registry.
It is a **pure function** of the inputs — recomputed, never hand-kept; a malformed
`service.json` fails it closed. `catalog.json` is just `catalog-derive.sh > catalog.json`.

## Blast radius drives the human gate (`scripts/blast-radius.sh`)

`blast-radius.sh <contract>@<major> [--catalog f | --root d] [--threshold N]` walks the
catalog's reverse edges **transitively** (cycle-safe) to the consuming services, and emits
`{contract, major, consumers, count, money_movement, pii, human_gate_required}`.
`human_gate_required = count ≥ N  OR  any reached service carries money_movement/pii`
(default `N = 3`, override via `--threshold` / `BLAST_RADIUS_THRESHOLD`). The rule is
principled and computed — never a hardcoded "touches auth".

This decision is **wired** into the **blast-radius human gate** (below). That hook also adds a
**producer self-check**: it independently forces the gate when the *changed* service's own
`service.json` carries `money_movement`/`pii` (the script's `human_gate_required` inspects only
*reached* services), so a sensitive service with no sensitive consumers still gates.

## semver + pinned consumers — the one model call is a seam (`scripts/semver-check.sh`)

`semver-check.sh <contract> --old <semver> --new <semver> [--catalog|--root]` classifies the
bump (major/minor/patch/none; downgrade ⇒ error) and resolves the **pinned consumers** of the
old major from the catalog, all deterministically. It emits `model_call_required` — true only
for a minor/patch bump with pinned consumers (the single contested case: "is this diff
semantically breaking beyond its bump?"). The script makes **no model call**; the isolated,
logged model adjudication is a later slice. The decision is logged to stderr.

## The cross-service gates (fail-closed hooks)

Two fire on the `PROGRESS.md → PHASE: HANDOFF` transition (the ship chokepoint, set by
`/sdd-fleet:pr-review` before devops raises the PR); two fire on a `registry/<contract>/<semver>.json`
publish.

- **Dependency gate** (`hooks/scripts/dependency-gate.sh` → `scripts/dependency-check.sh`).
  PreToolUse on the HANDOFF transition. It scans the feature git-diff: a diff added-line matching a
  registry contract's `client_signature` whose contract is **not** in `consumes[]` is an undeclared
  client call → **block**; a `consumes[]` token with no published registry version is a dangling
  edge → **block**. Inert for standalone / non-git repos.
- **Blast-radius human gate** (`hooks/scripts/handoff-blast-radius-gate.sh` → `scripts/blast-radius-signature.sh`).
  PreToolUse on the HANDOFF transition. The verdict + a **signature** are computed by
  `blast-radius-signature.sh` — **THE single home**, also called by `handoff-approve-record.sh`, so
  the recorded approval digest and the digest the gate recomputes can never drift (the
  `plan-digest.sh` pattern, one layer up). A change is **risky** when the **producer self-check**
  trips (the changed service's own `money_movement`/`pii`) OR any produced contract reaches ≥ N
  transitive consumers / money_movement / pii. The estate catalog is derived from the
  **superproject** (reverse edges live in sibling repos), like the epic fan-out gate.
  **Allow-when-approved:** a risky change is permitted iff `.sdd/<slug>/HANDOFF_APPROVAL.md` records
  a `BLAST_RADIUS_SIGNATURE` equal to the **current** signature. The signature is pinned to the
  **consumer set + classes** of the tripping contracts (plus the producer's own classes), so a
  widened or otherwise changed blast radius yields a new signature ⇒ the recorded approval is
  **stale** ⇒ re-block (re-approve). The approval is written only by the human-only
  `/sdd-fleet:handoff-approve` command (`disable-model-invocation`; bare = dry-run preview,
  `approve` = record via `handoff-approve-record.sh`). The block→allow completion is guarded by the
  gate's prior unconditional-block cases (still green = "block when risky **and** no matching
  approval") plus the tamper cycle (approve→allow, widen→stale-block, re-approve→allow).
- **Publish-ordering gate** (`hooks/scripts/block-publish-before-handoff.sh`).
  PreToolUse on a publish: permitted **only** when the active feature's `PHASE` is `HANDOFF`, else
  **block**. This proves a contract cannot reach the registry before the HANDOFF transition (where
  the blast-radius human gate fires) — so the human gate cannot be bypassed by publishing early. It
  checks ordering only; the consumer-expectation check is cdc-gate's.
- **Consumer-driven contract gate** (`hooks/scripts/cdc-gate.sh` → `scripts/cdc-check.sh`).
  PreToolUse on a publish. The published version must satisfy **every** registered consumer
  expectation — same major, `required_operations ⊆ operations`, `required_fields ⊆ fields` — else
  **block**. Pure set logic, no model call.

**Stated limits of the blast-radius human gate.** (1) *Consumer-axis fail-open* — the gate is
fail-closed on what it sees but fail-open on whether it can **resolve the estate**: no superproject,
git unavailable, or a `catalog-derive` failure skips the consumer-count + reached-consumer-class
axes (the producer self-check still fires), mirroring the dependency gate's standalone/no-base
posture. (2) *Transition-chokepoint evasion* — like the dependency gate, this is a content-pattern
PreToolUse gate on the `PHASE: HANDOFF` write; a raw Bash write into `.sdd/<slug>/PROGRESS.md`, or a
narrow Edit replacing only the phase token, evades it. That is a **harness-wide** trust-boundary
limit that **every `.sdd` PreToolUse path gate shares — `dependency-gate`, `handoff-blast-radius-gate`,
and `link-discipline` alike**: each is fail-closed on what passes the `Write|Edit` chokepoint and
fail-open on a write that skips it (a Bash write into `.sdd/`, or a write whose tool/content the
matcher never sees). It is bounded by posture, not closed — the scribe has no Bash, the protocol
edits the full `PHASE` line via Write/Edit, and a one-time `link-sweep.sh` (see `workspace-tier.md`)
cleans pre-existing link violations the gate could not see at write time. By design (not closed by
slice 6b) — not a bug to fix at the gate layer. (3) *Approval is staleness-bound, not
anti-forge* — `/sdd-fleet:handoff-approve` is the **sanctioned** path (`disable-model-invocation`)
and the signature makes an approval go **stale** when the radius changes, but it is **not**
cryptographically anti-forge: a model could write `HANDOFF_APPROVAL.md` with a correct *current*
signature — the identical trust boundary `RATIFICATION.md` accepts (the tool layer has no
human-vs-model signal). 6b closes the **staleness** hole, not the forge hole.

All of these gates (plus the descriptor-validation gate above) anchor at `CLAUDE_PROJECT_DIR`,
reject `..`, require `jq` (fail-closed), and trap unexpected errors to `exit 2`. Each ships with a
committed `*.test.sh` harness.
