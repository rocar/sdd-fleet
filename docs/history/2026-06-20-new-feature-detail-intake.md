# `/build-fleet:new-feature` — richer feature-detail intake

**Status:** design approved (brainstorming) 2026-06-20; **not yet implemented**. This note
records the agreed design; the runtime contract authority remains the `sdd-protocol` skill.
Scope is a single command — `commands/new-feature.md` — plus its doc surface.

## Motivation

Today `new-feature` takes a **slug only** and sources the feature description from (a) the
conversation, then (b) a product-backlog intent, falling back to a **single** stop-and-ask
when neither is usable (`commands/new-feature.md:89-123`). Two gaps:

1. No explicit channel to pass the feature detail *with* the command — the slug is the only
   argument, so callers must seed the description in conversation first.
2. The fallback is a one-shot question, not an iterative clarification — a thin description
   either proceeds into a hallucinated spec or forces the user to re-run.

This change adds an explicit inline-detail argument and upgrades the one-shot ask into a
bounded, structured clarify loop, while preserving the existing conversation/backlog sourcing.

## The change (rewrite of the Arguments section + step 5)

### A. Arguments & parsing

`$ARGUMENTS` becomes `<slug> [detail…]`:

- **First whitespace-delimited token = the slug** (kebab-case, no whitespace — unchanged).
- **Everything after the first token = optional inline feature detail** (free text), trimmed.
- Empty `$ARGUMENTS` → refuse (unchanged).
- Frontmatter `argument-hint`: `"<feature-slug>"` → `"<feature-slug> [feature details]"`.
- **Parsing stays in command prose** — the orchestrator splits on first whitespace and
  validates the slug. **No parse helper script** (decided: trivial split, slug validated
  downstream; a script would be YAGNI here).

### B. Detail-source precedence + quality floor

Establish the description from these sources, **arg wins when present**:

1. **Inline detail arg** (A) — most deliberate, invocation-scoped → used whenever present.
2. **Conversation context** — used when no arg (e.g. running `new-feature` right after a
   deep-research/design discussion in the same session).
3. **Backlog intent** — `intent-block.sh --slug <slug> .sdd/_product/backlog.md`, product
   tier only — used when neither above is present.

**Decided:** an explicit arg **overrides** ambient conversation context. Rationale: passing
the arg is an explicit "use *this* for this invocation"; a caller who wants the richer
conversational context simply omits the arg.

**Thin-arg-with-context edge case (made explicit):** if an arg is present but below the floor
*and* the conversation also holds detail, the arg remains the authoritative base and the
clarify loop (C) runs — it does **not** silently fall back to context. The loop **may** use the
conversation context to pre-populate or suggest answers in its structured prompts, but the
caller confirms; the arg, not the ambient context, is the base description.

**Quality floor (≥2-of-3).** Whatever the source, the description is judged against the
existing floor — at least 2 of {*what the feature is* / *its scope boundary* / *its
non-goals*}:

- **Backlog intents** keep their **deterministic** verdict from `intent-block.sh`
  (`usable | too-thin`).
- **Arg / conversation descriptions** are judged against the **same 3-component floor by the
  orchestrator** (a judgment, not a deterministic script gate — consistent with the
  `sdd-protocol` principle "gates are deterministic; judgments are adversarial"). The prose
  definition of the floor lives in `references/product-tier.md`.

### C. Clarify loop (interactive-only, structured)

Replaces today's single stop-and-ask (`:114-121`). It fires when the established description
is **empty OR below the floor** ("loop on thin" — decided; a one-word arg like `"converter"`
must not sail through).

- Driven by **`AskUserQuestion`** with sectioned prompts that target the *missing* components
  (behavior, inputs/outputs, edge cases, non-goals/scope boundary).
- **Loops** until one of: the ≥2-of-3 floor is met; the user selects a **"proceed anyway"**
  escape; or a **soft cap of 3 rounds** is reached (then proceed with what was gathered and
  flag the thinness to the architect in the step-8 delegation).
- Add **`AskUserQuestion`** to the command's `allowed-tools` frontmatter (absent today).

**Interactivity boundary (decided): `new-feature` is an interactive-only entry point.** In a
headless / `claude -p` run with no detail provided, `AskUserQuestion` has no responder, so the
clarify loop cannot run — the command is *not* expected to be safe under `-p` when detail is
absent. The contract is therefore: **headless callers must pass the detail via the inline arg
(A), which is the headless escape hatch.** This is documented as an explicit limitation rather
than silently degrading to a refusal (the refuse-degradation alternative was considered and
rejected).

### D. Files touched & testing

- **`commands/new-feature.md`** — frontmatter (`argument-hint`; `allowed-tools +=
  AskUserQuestion`), the Arguments section, and the step-5 rewrite. This is the whole change.
- **`README.md`** — update the `new-feature` command-reference row (new arg hint / one-line
  note on inline detail + interactive clarify).
- **`CLAUDE.md`** — no change (no new command; the layout command count is unchanged at 22).
- **Testing** — this is orchestration *prose*, which build-fleet does not unit-test (only
  `scripts/` and `hooks/` carry `.test.sh`). No new harness. The `docs/v0.5/smoke` test is
  unaffected (it drives the deterministic backbone, not the interactive intake).

## Out of scope (YAGNI)

- **`/build-fleet:next-feature`** is untouched — it sources from the backlog, not an inline
  arg. Extending the clarify loop there (when a backlog intent is `too-thin`) is a possible
  follow-up, not part of this change.
- No new parse helper script (see A).
- No headless refuse-degradation (see C) — the inline arg covers the headless path.

## Risks / notes

- **Headless hang risk.** With the interactive-only decision, a headless run that reaches the
  clarify loop will block on an unanswerable `AskUserQuestion`. Mitigation is documentation +
  the inline-arg path; revisit if a headless caller actually hits this.
- **Floor-as-judgment for free text.** Unlike backlog intents (scored by `intent-block.sh`),
  the floor for arg/conversation text is an orchestrator judgment. This is consistent with how
  the command already treats a conversational description, but it is not a deterministic gate —
  worth stating plainly so no one mistakes it for one.
