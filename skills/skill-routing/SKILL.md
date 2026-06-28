---
name: skill-routing
description: The sdd-fleet convention for routing domain-appropriate skills to role agents based on the product stack and feature type. Defines the SKILL_MANIFEST schema, the stack→skill mapping table, the classifier's emission rules, and the advisory load-if-available semantics. Consult it when the classifier emits a skill manifest, when new-feature persists it, and when coder/qa honor it during BUILD.
---

# Skill Routing

sdd-fleet is **process machinery**, not a domain-knowledge library. It does not
ship frontend/backend/data craft skills. What it ships is the **routing
convention**: a feature's stack + type are mapped to the *names* of domain skills
that the role agents should load and apply during BUILD, if those skills are
available in the operator's environment (user skills, marketplace, or a companion
plugin). A named skill that isn't installed is a **no-op** — routing is advisory,
never a gate.

This mirrors Kiro's inclusion-mode idea: a declarative rule ("for this kind of
work, include this skill") kept separate from the skill's content.

## Where the manifest lives and who touches it

```
classifier (new-feature)  ── emits ──►  skill_manifest (JSON, in its verdict)
        │
orchestrator (new-feature) ── persists ─►  .sdd/<feature>/SKILL_MANIFEST.md
        │
coder / qa (BUILD)        ── read + apply ─►  the per-role skills listed there
```

- **Classifier** derives the manifest (see "How the classifier derives it"). It
  writes no state — it only emits the `skill_manifest` field in its JSON verdict.
- **`/sdd-fleet:jira-story`** persists a non-empty manifest to
  `.sdd/<feature>/SKILL_MANIFEST.md`. An empty/null manifest writes no file
  (absence = no routing; BUILD then runs exactly as a manifest-less feature).
- **coder / qa** read `.sdd/<feature>/SKILL_MANIFEST.md` at BUILD and load+apply
  the skills listed under their role. **Loading mechanism, precisely:** the agent
  invokes each listed skill by name via the **Skill tool** in its own reasoning
  (not frontmatter `skills:`); where a role is dispatched inside a workflow, the
  workflow may additionally preload skills via **`AgentDefinition.skills`**. The
  Skill-tool path is what makes routing work in every execution mode — including
  agent-team mode, which ignores per-agent frontmatter skills.

## SKILL_MANIFEST.md format

A markdown file with one fenced JSON block. Schema:

```json
{
  "feature": "<slug>",
  "feature_type": "frontend-ui | backend-api | data | cli | infra | mobile | docs | mixed | unknown",
  "derived_from": "<one-line: the stack signal + feature cue that drove this>",
  "roles": {
    "coder": { "skills": ["<skill-name>", "..."], "tools_recommended": ["<capability>"], "rationale": "<why>" },
    "qa":    { "skills": ["<skill-name>", "..."], "tools_recommended": [], "rationale": "<why>" }
  },
  "advisory": true
}
```

Rules:
- `roles` keys are limited to `coder` and `qa` (the BUILD consumers). Consumers
  ignore unknown role keys.
- `skills` are **conventional names**, not guaranteed-present skills. Empty array =
  no domain skill for that role.
- `tools_recommended` is **recorded only / informational — it does not bind on any
  path.** (A `Task`-dispatched subagent cannot have its frontmatter tools
  overridden per invocation; the `deep-build` workflow *could* set
  `AgentDefinition.tools` from it, but nothing wires that today.) Record it so the
  signal exists for a future increment; do not rely on it binding.
- `advisory: true` always. Routing never blocks BUILD.
- **The classifier never includes a top-level `feature` field** —
  `/sdd-fleet:jira-story` stamps the slug when it persists the manifest.

## How the classifier derives it

Inputs the classifier already has at `/sdd-fleet:jira-story` time: the feature
description, the inherited product stack (the binding part of
`.sdd/_product/STACK.md`, threaded in by new-feature step 5b/6 when a product tier
exists), and a light read of the project. From these it determines a
`feature_type`, then maps to skills via the table below.

Determine `feature_type` from the strongest available signal, in order:
1. The **binding product stack** (if a product tier exists) — e.g. a Svelte/React/
   Vue/Angular or HTML/CSS/JS UI stack → `frontend-ui`; a Go/Node/Python HTTP
   service → `backend-api`; SQL/migrations/pipelines → `data`.
2. The **feature description** cues — "page", "component", "screen", "form" →
   frontend; "endpoint", "API", "handler", "service" → backend; "CLI", "command",
   "flag" → cli; "migration", "schema", "ETL" → data.
3. The **project files** — framework manifests, directory shape.

**Client-side storage is `frontend-ui`.** IndexedDB / Dexie / `localStorage` /
in-browser persistence is part of a frontend feature — it is **not** `backend-api`
(there is no API) and **not** `data` (there is no data backend). A browser-only SPA
with local persistence is `frontend-ui`, full stop. `backend-api` requires an actual
server/HTTP service; `data` requires a real datastore/pipeline/migrations on a
backend.

If signals conflict or none is clear → `feature_type: "unknown"` and emit an empty
`roles` (no routing). **Bias to `null`/empty over a wrong route** — a mis-routed
skill wastes a load; a missing route just means an unrouted BUILD (the same
conservative instinct that biases tier toward `standard`). Sizing and routing are
independent outputs of the one classifier verdict — a "frontend" type must never
inflate `tier`/`build_mode`, and the manifest never changes any deterministic gate.

## Stack → skill mapping (starter table)

Conventional skill names. Operators supply the actual skills; absent = no-op.

| feature_type | coder skills | qa skills | typical tools_recommended (workflow-only) |
|---|---|---|---|
| `frontend-ui` | `frontend-design` | `frontend-testing` | browser/DOM-driving tools |
| `backend-api` | `api-design` | `api-testing` | HTTP client, schema tools |
| `data` | `data-modeling` | `data-testing` | DB/query tools |
| `cli` | `cli-design` | `cli-testing` | — |
| `infra` | `infra-iac` | `infra-testing` | IaC/cloud CLIs |
| `mobile` | `mobile-design` | `mobile-testing` | device/emulator tools |
| `docs` | `technical-writing` | — | — |
| `mixed` | pick the dominant type's skills; note the secondary in `rationale` | — | — |
| `unknown` | none (empty) | none (empty) | — |

**Use the generic names in this table.** They maximize the chance an
operator-provided skill actually matches — sdd-fleet ships none, so a name only
delivers value if the operator (or a marketplace/companion plugin) has created a
skill of that name, and operators create general role-craft skills
(`frontend-design`), not per-library ones. Do **NOT** emit library- or
framework-specific names (`react-hooks`, `dexie-indexeddb`, `vitest`): those almost
never match an installed skill, so routing silently no-ops and delivers nothing.
Capture all stack/library specificity in the manifest's `rationale` and
`derived_from` fields instead — that is where "React 18 + Dexie" belongs, not in
the skill name. Never invent tools or destructive capabilities, and never name more
than ~2 skills per role (focus over breadth). The table is extensible, but
additions must be generic role-craft names.

**Stay in-row.** Emit only the skills mapped to the **determined `feature_type`'s
row**. Do not borrow another row's skill (e.g. `api-design` on a `frontend-ui`
feature) — that is the most common misroute. Prefer one skill per role. Only emit a
second type's skill when the feature is genuinely `mixed` with a real second domain
present (an actual backend, not a local persistence layer), and say so in
`rationale`.

## How coder / qa apply it (advisory, non-blocking)

At BUILD, before implementing/testing:
1. Read `.sdd/<feature>/SKILL_MANIFEST.md` if it exists. If absent → proceed
   normally (no routing).
2. For your role's `skills`, load and apply each **if it is available** in this
   environment. Applying a skill = invoke it by name with the **Skill tool** so
   its guidance is in context (workflow-dispatched roles may also receive it via
   `AgentDefinition.skills` preload).
3. If a listed skill is **not available**, do not fail and do not block — proceed
   with your normal craft and record one line in `IMPL_NOTES.md` (coder) /
   `TEST_PLAN.md` (qa): `skill-unavailable: <name> (manifest-recommended)`. This
   leaves a trail so the operator can install it later.
4. `tools_recommended` is informational on **every** path — note it, do not block
   on it; nothing binds tools.

Routing must never change the deterministic gates (tests-first, source-write
block, review). It only enriches *how* a role does its job, never *whether* a gate
passes.
