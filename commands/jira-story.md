---
description: Open a Jira story as a forward feature or an unknown-cause bug — accept a Jira story key (e.g. PAY-1843, read via the jira-adapter as starting context) or a slug, scaffold .sdd/<slug>/, acquire the ACTIVE lock, run the classifier (tier / severity), and (feature) have the architect draft spec.md + acceptance.md. Syncs the story's Jira status (best-effort) at each phase flip it owns. The per-repo intent entry; advance the item with /sdd-fleet:feature-dev.
allowed-tools: Read, Edit, Bash, Task
---

# /sdd-fleet:jira-story

You are the **orchestrator**. This is the per-repo **intent entry**: open a Jira
story as either a forward **feature** or an unknown-cause **bug**, scaffold
`.sdd/<slug>/`, acquire the `.sdd/ACTIVE` lock, run the classifier, and (feature)
have the architect draft `spec.md` + `acceptance.md`. The runtime rulebook is the
`sdd-protocol` skill.

**Lane selection.** A capability/feature request → follow **Forward feature**
below (scaffolds `spec.md`). An unknown-cause bug → follow **Bug report**
(scaffolds `diagnosis.md`; a known-cause one-liner stays on the forward trivial
path). Then advance the item with `/sdd-fleet:feature-dev`.

## Forward feature (folded from new-feature)


# /sdd-fleet:jira-story

You are the **orchestrator**. You route work, enforce gates, and write `.sdd/`
state files. You do not author specs, write code, or run tests yourself.

The runtime rulebook is the `sdd-protocol` skill. Consult it for the workspace
layout, ownership of `.sdd/<feature>/` files, the PROGRESS.md schema, and the
spec STATUS contract.

## Arguments

`$ARGUMENTS` — `<slug | JIRA-KEY> [feature details…]`:

- The **first whitespace-delimited token is either a Jira story key or the feature
  slug**. If it matches a Jira issue key — uppercase project prefix, a dash, digits
  (`^[A-Z][A-Z0-9]*-[0-9]+$`, e.g. `PAY-1843`) — follow **Jira story-ID intake**
  below first. Otherwise it is the feature slug (kebab-case, no whitespace). If
  `$ARGUMENTS` is empty, refuse and surface that the user must supply a slug or a
  story key.
- **Everything after the first token is an optional inline feature description**
  (free text), trimmed. When present it is the authoritative description for this
  run (see step 5, "Establish the feature description") and is the channel headless
  / `claude -p` callers use to supply detail.

## Jira story-ID intake (key argument)

When the first token is a Jira story key, the Jira story is the **starting
context** (this is how a story dispatched by the conductor — or surfaced by
`/sdd-fleet:next-story` — is picked up in its member repo). Before step 1:

1. **Read the story via the adapter** (deterministic; never invent story content):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/jira-adapter.sh" read-story --key "<KEY>" --now "<iso8601 now>"
   ```
   - JSON with `.key` → intake succeeded. Continue below.
   - `{"status":"unconfigured"}` or a non-zero exit → the key cannot be read and a
     Jira key is not a usable slug. Refuse:
     ```
     SDD_FLEET_REFUSE: {"command":"jira-story","code":2,"reason":"jira-story-unreadable","key":"<KEY>"}
     ```
     Tell the user to configure the adapter (`SDD_JIRA_LIVE=1` + `JIRA_*` creds)
     or re-run with a slug + inline description. Stop.
2. **Derive the slug**: the story's `id` field (the `sdd-id` label — the epic
   plan's node slug) when non-empty; else the lowercased key (`pay-1843`).
3. **Seed the description**: the story's `summary` + `description` (the id + a
   vault pointer for materialised stories) become the starting description for
   step 5 — inline detail after the key, when present, still wins as the
   authoritative description (source 1); the story text then serves as inherited
   context. If the description names the workspace vault, read the governing
   epic's context only through the artifacts already available in this repo —
   never by `../` path-walking into the superproject.
4. **Carry the key forward**: record `JIRA_KEY: <KEY>` in PROGRESS.md (step 3) —
   the external-ID link (an identity, like `JIRA_LINK.md` at the estate level;
   **never** a status cache — Jira owns status) that the per-phase Jira sync
   keys off.
5. **Emit** (before prose):
   ```
   SDD_FLEET_JIRA_STORY_INTAKE: {"key":"<KEY>","slug":"<slug>","repo":"<repo|''>","status":"<jira status>"}
   ```
   Then continue with step 1 using the derived slug.

## What you do

1. **Acquire the in-flight lock (atomic).** Run the shared acquirer — never
   check-then-write `.sdd/ACTIVE` by hand (the read-modify-write race is what
   the script exists to close). Use the same iso8601 `now` you will stamp into
   `UPDATED:` in step 3:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" acquire "<slug>" --owner "sdd-fleet:jira-story" --now "<iso8601 now>"
   ```
   - **Exit 0** → the lock is held and the script has already written the slug
     into `.sdd/ACTIVE` (do not write it again later). Continue.
   - **Exit 1** → another item holds the lock (the script names the holder on
     its `SDD_FLEET_ACTIVE_CONFLICT` line): sdd-fleet allows exactly one
     feature in flight. Refuse:
     ```
     SDD_FLEET_REFUSE: {"command":"new-feature","code":2,"reason":"active-feature-conflict","active":"<held slug>"}
     ```
     Tell the user the active slug, how to inspect it (`/sdd-fleet:status`),
     and that `/sdd-fleet:park` is the sanctioned preemption path. Stop.

2. **Scaffold `.sdd/<slug>/`** with the empty files the protocol expects:
   - `spec.md` — start with the STATUS line `STATUS: DRAFT` and the required
     section headings from the `sdd-spec-template` skill (Overview, Goals,
     Non-goals, Behavior, Interfaces / Contracts, Constraints, Risks,
     Acceptance Criteria). Leave bodies empty — architect fills them.
   - `acceptance.md` — empty, header `# Acceptance Criteria — <slug>`.
   - `DECISIONS.md` — `# Architecture Decisions — <slug>\n\nAppend-only log.`
   - `TEST_PLAN.md` — empty, header `# Test Plan — <slug>`.
   - `IMPL_NOTES.md` — empty, header `# Implementation Notes — <slug>`.
   - `REVIEW.md` — empty, header `# Review Log — <slug>\n\nAppend-only.`

3. **Initialize `PROGRESS.md`** with the schema from `sdd-protocol` (the classifier fills TIER + BUILD_MODE in step 7):

   ```
   SDD_SCHEMA: 1
   FEATURE: <slug>
   PHASE: SPEC
   CYCLE: 0
   CHANGE_CYCLE: 0
   BUILD_CYCLE: 0
   TIER: pending
   BUILD_MODE: pending
   REVIEW_ROLES: architect, qa, coder
   REVIEW_CYCLE_BUDGET: 3
   BUILD_CYCLE_BUDGET: 3
   UPDATED: <iso8601>
   ```

   The last three are **optional per-feature config**, seeded at their defaults so they
   are discoverable and editable: `REVIEW_ROLES` (the `/sdd-fleet:feature-dev` roster — a
   ≥2 subset of architect, qa, coder, architect) and `REVIEW_CYCLE_BUDGET` /
   `BUILD_CYCLE_BUDGET` (escalation budgets, 1–3, clamped to the 3-cycle ceiling). A
   command flag overrides these per run; the workflow validates them and falls back to
   these defaults if absent. Leaving them as-is reproduces the historical behavior.

   **Jira-keyed features only:** append `JIRA_KEY: <KEY>` (from the story-ID
   intake). It is the external-ID link the per-phase Jira status sync keys off;
   readers ignore unknown fields, and the scribe preserves it. Omit the line
   entirely for a slug-based feature — its absence means "no Jira story to sync."

3b. **Sync the story's Jira status — SPEC (best-effort, deterministic).** If
   PROGRESS.md carries a `JIRA_KEY:`, run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/jira-adapter.sh" phase-transition --key "<JIRA_KEY>" --phase SPEC --now "<iso8601 now>"
   ```
   Emit `SDD_FLEET_JIRA_SYNC: {"key":"<KEY>","phase":"SPEC","result":"<transitioned|noop|skipped|error>"}`
   (`skipped` = no `JIRA_KEY` / adapter unconfigured; `error` = the adapter
   failed). **Best-effort by design: a Jira outage or refusal NEVER blocks the
   scaffold or any later step** — Jira is the intent/status record plane, not a
   gate (`CLAUDE.md`: one fact, one store; the vault stays the source of truth).
   Never retry-loop; note the miss and continue — the next phase flip re-syncs.

4. **Scaffold `.sdd/.gitignore`, if absent.** (`.sdd/ACTIVE` was already
   written by step 1's acquire — do not write it again.) If `.sdd/.gitignore`
   does not exist, write it with exactly these entries (the per-working-tree
   coordination files are never committed; the per-feature artifacts and
   `_product/` are — see the `sdd-protocol` skill, ".sdd/ in version control"):
   ```
   ACTIVE
   ACTIVE.lock
   .workflow-in-flight
   .stop-test-retries
   .skip-stop-tests
   ```

5. **Establish the feature description.** Before classifying or drafting,
   determine *what the feature actually is* — the slug alone is not a spec.
   Resolve the description from these sources, in precedence order (**an explicit
   inline arg wins**):

   1. **Inline detail arg.** If `$ARGUMENTS` carried text after the slug (see
      Arguments), that text is the authoritative description for this invocation —
      use it even if the conversation also holds detail (passing the arg is a
      deliberate "use *this*"). Headless / `claude -p` callers MUST use this
      channel; the clarify loop below cannot run without a human.
   2. **Conversation context.** If there was no inline arg, look back through the
      conversation for a description the user already gave (e.g. "build a
      celsius→fahrenheit converter that handles negatives", or the conclusions of a
      design/research discussion earlier in the same session).
   3. **Product backlog intent.** If neither of the above is present and
      `.sdd/_product/backlog.md` exists, run the shared intent-block extractor — the
      SAME script `/sdd-fleet:next-feature` uses, so the two always reach the same
      verdict (one grammar, one quality floor, one implementation):
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-block.sh" --slug "<slug>" .sdd/_product/backlog.md
      ```
      It prints the canonical intent block (the 1–3 indented lines under the feature
      row) and a final `INTENT_VERDICT: usable|too-thin` line. On `usable`, that
      intent is the **plan author's starting description** — carry it forward and
      label it to the PO as the inherited intent (step 8). (If the slug has no
      backlog row, the script errors — that just means there is no inherited intent;
      continue.)

   **Quality floor (≥2-of-3).** Whatever the source, the description must clear the
   floor: at least 2 of the 3 components — *what the feature is* / *its scope
   boundary* / *its non-goals*. For a backlog intent the floor is the script's
   deterministic `INTENT_VERDICT` (`usable` clears it; `too-thin` does not). For an
   inline arg or a conversation description there is no script — **you judge it
   against the same 3-component floor** (a judgment, not a deterministic gate —
   consistent with the `sdd-protocol` principle "gates are deterministic; judgments
   are adversarial"; the canonical prose definition lives in the `sdd-protocol`
   skill's `references/product-tier.md`). A bare slug-restatement ("the API client")
   or a one-word arg ("converter") is below the floor.

   **Clarify loop (interactive only) — run when the description is empty OR below the
   floor.** Do not infer requirements from the slug — a slug like `celsius-converter`
   names the feature but says nothing about behavior, inputs/outputs, edge cases, or
   constraints. Use **`AskUserQuestion`** to ask a structured, sectioned prompt
   targeting the *missing* components (behavior, inputs/outputs, edge cases,
   non-goals / scope boundary). **Repeat** until one of: the gathered description
   clears the ≥2-of-3 floor; the user chooses a "proceed anyway" option; or you have
   asked **3 rounds** — then proceed with whatever was gathered and tell the
   architect the description is thin (step 8). If an inline arg was present but
   thin while the conversation held detail, the arg stays the authoritative base; the
   loop may pre-fill or *suggest* answers from that context, but the user confirms.
   The classifier and architect both consume this description; classifying from a
   bare slug produces a hallucinated spec.

   > **Interactive-only.** This command is a human-driven entry point. In a headless
   > / `claude -p` run with no inline detail, `AskUserQuestion` has no responder and
   > the command cannot proceed — supply the description via the inline arg instead.

   - Carry the resolved description (from the arg, context, backlog, or the clarify
     loop) verbatim into the classifier prompt below and into the architect
     delegation in step 8.

5b. **Inherit the product stack, if a product tier exists.** Check for
   `.sdd/_product/STACK.md`. If it exists:
   - Read `.sdd/_product/STACK.md` and `.sdd/_product/DECISIONS.md`.
   - Pass both verbatim into the classifier prompt (step 6) and the architect
     delegation (step 8) as **inherited, read-only product context**.
   - Instruct architect (and, if it raises a stack concern in review, the
     architect): the feature **inherits the *binding* product stack** — the
     `## Baseline (current)` section on a brownfield product, or the ratified
     greenfield stack. Any `## Forward direction (PROVISIONAL — unreviewed)`
     entries are **advisory only** and do not constrain this feature unless the
     feature *is* the migration that promotes them. The feature's feature-local
     `DECISIONS.md` must not contradict the binding stack. If the feature
     genuinely needs a different binding stack, that is **not** a feature-local
     override — it is a signal to revise the product tier (edit
     `.sdd/_product/STACK.md` + append a product ADR). Surface that to the user
     rather than silently diverging.

   If `.sdd/_product/STACK.md` does **not** exist, this is a plain feature-first
   repo (no product tier) — proceed exactly as before. The product tier is
   additive; its absence changes nothing.

6. **Run the classifier.** Use the Task tool to spawn `sdd-fleet:classifier`
   with this prompt:

   > Classify this feature per `agents/classifier.md`. Emit a single JSON verdict
   > and stop.
   >
   > Feature description: <the description established in step 5 — paste it
   > verbatim; never substitute the slug for a missing description>.
   >
   > Inherited product stack (only if a product tier exists — from step 5b):
   > <paste the BINDING stack from .sdd/_product/STACK.md — i.e. everything EXCEPT
   > entries marked provisional (whether a `## Forward direction (PROVISIONAL —
   > unreviewed)` section or per-line `PROVISIONAL` tags). If nothing is marked
   > provisional, the whole file binds (greenfield, or a fully-adopted brownfield).
   > Write "none — no product tier" only if .sdd/_product/STACK.md is absent>. Use
   > it only to size the work (a feature that migrates the product stack is
   > larger); do not let provisional forward entries inflate the size.
   >
   > Project context: read whatever files in the current directory help you
   > size the work. Do not exhaustively read source.

   Parse the classifier's JSON verdict. Extract `tier`, `build_mode`, `skip_review`,
   `skeleton_spec_hint`, `confidence`, `skill_manifest` (may be `null`).

   **Parse-failure fallback.** If the classifier returns malformed JSON or omits
   any of the required fields above, do NOT write `undefined` to PROGRESS.md.
   Instead, default to `tier=standard` / `build_mode=standard` / `skip_review=false`
   and emit:

   ```
   SDD_FLEET_CLASSIFIER_FALLBACK: {"feature":"<slug>","reason":"<parse-error|missing-field|empty-output>","tier_assigned":"standard"}
   ```

   Continue to step 7 with the fallback values. Surface the raw classifier
   output tail to the user so they can re-run `/sdd-fleet:jira-story` for a
   re-classification if needed. This keeps trivial false-positives at bay (the
   safe default is standard) when the classifier itself misbehaves.

   On successful parse, emit the classification signal:

   ```
   SDD_FLEET_CLASSIFICATION: {"feature":"<slug>","tier":"<...>","build_mode":"<...>","skip_review":<bool>,"confidence":"<...>"}
   ```

   If `confidence=low`, surface the rationale to the user and *recommend* the
   verdict but proceed with it. Manual override is via post-hoc PROGRESS.md
   edit (or running `/sdd-fleet:jira-story` for a re-check before proceeding).

7. **Write classifier verdict to PROGRESS.md.** Edit PROGRESS.md:
   - `TIER:` ← classifier's `tier` (`trivial`, `standard`, or `large`)
   - `BUILD_MODE:` ← classifier's `build_mode` (`standard` for trivial/standard, `deep-build` for large)
   - `UPDATED:` ← current iso8601

7b. **Persist the skill manifest, if any.** The `skill-routing` skill is
   the convention. If the classifier's `skill_manifest` is **non-null and has at
   least one non-empty `roles` entry**, write it to `.sdd/<slug>/SKILL_MANIFEST.md`:
   a one-line header `# Skill Manifest — <slug>` followed by a fenced ```json block
   containing the manifest object with `"feature":"<slug>"` added. This routes
   domain-appropriate skills to coder/qa at BUILD (see the `skill-routing` skill
   for the schema and the load-if-available semantics). Emit:

   ```
   SDD_FLEET_SKILL_MANIFEST: {"feature":"<slug>","feature_type":"<...>","coder_skills":[...],"qa_skills":[...]}
   ```

   If `skill_manifest` is `null` or has only empty `roles`, **write no file** — its
   absence means "no routing," and BUILD proceeds unrouted. Do not scaffold an
   empty manifest. (Manifest routing is advisory and never gates anything.)

8. **Delegate to architect.** Use the Task tool to spawn the
   `sdd-fleet:architect` subagent. The prompt varies by tier:

   - **For `tier=trivial`:** include the classifier's `skeleton_spec_hint` and
     ask PO to draft a *minimal* `spec.md` (STATUS=DRAFT) and `acceptance.md`
     based on it. The skeleton spec satisfies the 8 required sections (Overview,
     Goals, Non-goals, Behavior, Interfaces / Contracts, Constraints, Risks,
     Acceptance Criteria) but each section is 1-3 sentences. PO does not need
     to run the full self-review — the trivial fast-path skips REVIEW.

   - **For `tier=standard` or `tier=large`:** ask for a complete first-pass `spec.md` (STATUS=DRAFT) and `acceptance.md`
     following the `sdd-spec-template` skill, with PO's self-review checklist.

   **Inherited product stack (both tiers — from step 5b).** If
   `.sdd/_product/STACK.md` exists, **prepend to the PO prompt**, verbatim and
   labeled "inherited, read-only product context": the **binding** stack and the
   product `DECISIONS.md`. The binding stack is everything in STACK.md NOT marked
   provisional (a `## Forward direction (PROVISIONAL — unreviewed)` section, or
   per-line `PROVISIONAL` tags); if nothing is marked provisional, the whole file
   binds (greenfield, or a fully-adopted brownfield). Instruct PO to draft the spec
   and acceptance so they **conform to the binding product stack** —
   the feature's stack choices must not contradict it.
   `## Forward direction (PROVISIONAL — unreviewed)` entries are advisory only and
   must not be treated as the stack unless this feature *is* the migration that
   promotes them. If the feature genuinely cannot fit the binding stack, PO must
   surface that as a product-tier revision signal (architect edits STACK.md +
   appends a product ADR), **not** a feature-local override.

   **Inherited feature intent.** If step 5 found a usable backlog
   **intent (1–3 lines)** for this slug, pass it to the PO labeled "inherited intent
   (the plan author's intended scope — a sketch, not the contract)". Instruct PO to **realize
   and elaborate** that intent into the full spec (Behavior / Interfaces / Acceptance
   Criteria), and to flag in `## Self-review notes` if the spec must deviate from the
   stated intent rather than silently drifting. If there was no intent line, omit this
   block — PO drafts from the established description as usual.

   **Thin description (clarify loop hit its cap).** If step 5's clarify loop ended
   below the quality floor (the 3-round cap or an explicit "proceed anyway"), say so
   plainly in the PO prompt — label the description "best-effort / below the usual
   detail floor" and instruct PO to surface the resulting gaps in `## Self-review
   notes` rather than inventing requirements. (Omit this block when the description
   cleared the floor.)

   Tell PO not to set STATUS=IN_REVIEW regardless of tier — that's `/sdd-fleet:feature-dev`'s
   job (which trivial features skip; standard/large run normally).

9. **Report back** to the user with the next-command hint based on tier:

   - **trivial:** "Spec drafted as a skeleton (TIER=trivial). REVIEW is skipped
     for this fast-path. Next commands: `/sdd-fleet:feature-dev` (which recognizes
     TIER=trivial and flips the spec without requiring a review cycle), then
     `/sdd-fleet:feature-dev`."
   - **standard:** "Spec drafted (TIER=standard). Next command: `/sdd-fleet:feature-dev`
     to run the adversarial review workflow (then finalize, then build)."
   - **large:** "Spec drafted (TIER=large; BUILD_MODE=deep-build). Next command:
     `/sdd-fleet:feature-dev` to run the adversarial review workflow. After
     `/sdd-fleet:feature-dev`, `/sdd-fleet:feature-dev` routes the BUILD phase to
     `workflows/deep-build.js` automatically (fan-out coders across file
     partitions)."

## Gates to honor

- The `block-source-before-finalized` hook will reject any write outside
  `.sdd/` while STATUS is DRAFT — that's expected; if it fires on you, you
  tried to write source, which means you misread the phase.
- The `validate-spec-status` hook will reject a `spec.md` write missing the
  STATUS line or required sections — fix the file and retry.

## Refusal cases

- `acquire-active.sh acquire` exits 1 (another item holds the lock) → refuse
  with `{"code":2,"reason":"active-feature-conflict"}`.
- `$ARGUMENTS` is empty → refuse.
- The first token is a Jira story key but `read-story` cannot read it (adapter
  unconfigured or errored) → refuse with
  `{"code":2,"reason":"jira-story-unreadable","key":"<KEY>"}` (a Jira key is not
  a usable slug; the sync steps, by contrast, are best-effort and never refuse).
- `.sdd/<slug>/` already exists → refuse; ask the user whether to resume or
  pick a new slug. (Release the lock you just acquired —
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" release "<slug>"` —
  so the refusal does not leave the slug locked.)

---

## Bug report (folded from triage)


# /sdd-fleet:jira-story

You are the **orchestrator** for the troubleshoot-fix bug lane. You route, gate, and write
`.sdd/` state; you do not diagnose or write source yourself. **Headless-first:** emit the
machine signal line **before** any human prose.

The runtime rulebook is the `sdd-protocol` skill (`references/bug-lane.md`). The `diagnosis.md`
structure is the `sdd-diagnosis-template` skill. This command is the bug-lane analog of
`/sdd-fleet:jira-story` and is the lane's **sole entry point** (the `REPORT` phase).

## Arguments

`$ARGUMENTS` — the bug **symptom** (free text: what's wrong, where, how it shows up). If
empty, refuse — you cannot triage without a symptom. Emit `SDD_FLEET_REFUSE` and stop.

## What you do

1. **Derive a bug slug.** kebab-case, prefixed `bug-`, a ≤6-word summary of the symptom
   (e.g. `bug-login-500-on-empty-email`). If `.sdd/<bug-slug>/` already exists, append a short
   disambiguator.

2. **Acquire the in-flight lock (atomic).** Run the shared acquirer — never check-then-write
   `.sdd/ACTIVE` by hand. Use the same iso8601 `now` you will stamp into `UPDATED:` in step 3:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" acquire "<bug-slug>" --owner "sdd-fleet:jira-story" --now "<iso8601 now>"
   ```
   - **Exit 0** → the lock is held and the script has already written the bug slug into
     `.sdd/ACTIVE` (do not write it again later). Continue.
   - **Exit 1** → another item holds the lock (the script names the holder on its
     `SDD_FLEET_ACTIVE_CONFLICT` line): sdd-fleet allows exactly one item in flight, and
     **a bug and a forward feature share the `.sdd/ACTIVE` lock**. Refuse — name the active
     slug and how to inspect it (`/sdd-fleet:status`). Emit:
     ```
     SDD_FLEET_REFUSE: {"command":"triage","reason":"item-in-flight","active":"<slug>"}
     ```
     Stop. (A sev0 cannot preempt a mid-flight feature here; the human parks the feature
     first with `/sdd-fleet:park <reason>` — the sanctioned preemption path — then re-runs
     the triage.)

3. **Scaffold `.sdd/<bug-slug>/`** — exactly two files (the bug lane has **no** `spec.md`,
   `acceptance.md`, REVIEW.md, or TEST_PLAN.md at entry):

   - `diagnosis.md` per `sdd-diagnosis-template` — first non-blank line `STATUS: REPORTED`,
     then `# Bug: <short title>`, then the four required sections. Put the `$ARGUMENTS`
     symptom **verbatim** under `## Symptom + reproduction steps`; leave the other three as
     placeholders:
     ```
     STATUS: REPORTED

     # Bug: <short title>

     ## Symptom + reproduction steps
     <$ARGUMENTS, verbatim>

     (Concrete reproduction steps / a failing test land at /sdd-fleet:feature-dev.)

     ## Root-cause hypothesis
     _(empty until DIAGNOSE)_

     ## Blast radius
     _(empty until DIAGNOSE)_

     ## Fix strategy
     _(empty until DIAGNOSE)_
     ```
   - `PROGRESS.md`:
     ```
     SDD_SCHEMA: 1
     FEATURE: <bug-slug>
     PHASE: REPORT
     LANE: bug
     SEV: pending
     CYCLE: 0
     FIX_CYCLE: 0
     UPDATED: <iso8601>
     ```
     A bug PROGRESS carries **no** `TIER`/`BUILD_MODE` (forward-machine fields); the bug-lane
     hooks never read them.

4. **Scaffold `.sdd/.gitignore`, if absent** (a bug-first repo creates `.sdd/` fresh here).
   If `.sdd/.gitignore` does not exist, write it with exactly these entries (the
   per-working-tree coordination files are never committed — see the `sdd-protocol` skill,
   ".sdd/ in version control"):
   ```
   ACTIVE
   ACTIVE.lock
   .workflow-in-flight
   .stop-test-retries
   .skip-stop-tests
   ```
   (`.sdd/ACTIVE` itself was already written by step 2's acquire.)

5. **Run the triage classifier.** Use the Task tool to spawn `sdd-fleet:classifier` in
   **bug mode** (see `agents/classifier.md` § Bug-mode):

   > Classify this BUG for the troubleshoot-fix lane per the "Bug-mode" section of
   > `agents/classifier.md`. Emit the bug-mode JSON verdict
   > (`{severity, cause_known, rationale, confidence}`) and stop.
   >
   > Symptom: <the `$ARGUMENTS` symptom, verbatim>.
   >
   > Project context: read whatever files help you judge severity and whether the root cause
   > is already obvious from the report. Do not exhaustively read source.

   Parse `severity`, `cause_known`, `confidence`.

   **Parse-failure fallback.** If the verdict is malformed or missing a field, default to
   `severity=sev1`, `cause_known=false` (stay in the lane — the dangerous miss is bouncing a
   genuine unknown-cause bug onto the trivial fast-path), and emit:
   ```
   SDD_FLEET_CLASSIFIER_FALLBACK: {"slug":"<bug-slug>","reason":"<parse-error|missing-field>","cause_known":false,"severity":"sev1"}
   ```

6. **Route on `cause_known`.**

   - **`cause_known == true`** → the cause is obvious from the report; there is nothing to
     diagnose. This is **not** a bug-lane bug — it belongs on the forward trivial path. Emit:
     ```
     SDD_FLEET_TRIAGE_KNOWN_CAUSE: {"symptom":"<text>","recommended":"/sdd-fleet:jira-story","reason":"cause is known — use the forward path"}
     ```
     Then **undo the scaffold** so the known-cause bug does not occupy the lock: `rm -rf` the
     `.sdd/<bug-slug>/` directory (Bash) and **release the lock via the script** (it verifies
     the slug, removes `.sdd/ACTIVE.lock`, and empties `.sdd/ACTIVE`):
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" release "<bug-slug>"
     ```
     Tell the user to run `/sdd-fleet:jira-story <slug>` instead. Stop. (This is the sharp
     boundary with the trivial fast-path.)

   - **`cause_known == false`** → stay in the bug lane. Edit `PROGRESS.md`: set
     `SEV: <severity>` and `UPDATED:` (keep `PHASE: REPORT`). Emit:
     ```
     SDD_FLEET_TRIAGE: {"slug":"<bug-slug>","severity":"<sev0|sev1|sev2>","cause_known":false,"phase":"REPORT"}
     ```
     If `confidence == low`, surface the rationale and recommend the verdict but proceed.

7. **Report** the next command: `/sdd-fleet:feature-dev` — qa authors a failing reproduction
   test under `tests/` and flips `diagnosis.md` to `REPRODUCING`.

## Signals (emitted before prose)

```
SDD_FLEET_TRIAGE:             {"slug":"<bug-slug>","severity":"sev0|sev1|sev2","cause_known":false,"phase":"REPORT"}
SDD_FLEET_TRIAGE_KNOWN_CAUSE: {"symptom":"<text>","recommended":"/sdd-fleet:jira-story","reason":"cause is known — use the forward path"}
SDD_FLEET_CLASSIFIER_FALLBACK:{"slug":"<bug-slug>","reason":"<...>","cause_known":false,"severity":"sev1"}
SDD_FLEET_REFUSE:             {"command":"triage","reason":"<item-in-flight|empty-symptom>", ...}
```

## Gates to honor

- All `.sdd/` writes are always permitted (`block-source-before-finalized` and
  `require-reproducing-test` short-circuit on `.sdd/` paths), so scaffolding never trips a gate.
- The `diagnosis.md` you write is validated by `validate-diagnosis-status`: it must carry
  `STATUS: REPORTED` and all four `##` headings — the template above satisfies both.

## Refusal cases

- `acquire-active.sh acquire` exits 1 — another item holds the lock → refuse (one item in
  flight).
- `$ARGUMENTS` is empty → refuse (no symptom to triage).
