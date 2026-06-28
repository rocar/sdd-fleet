---
name: adr
description: The Architecture Decision Record format for .sdd/<feature>/DECISIONS.md and the product-scope .sdd/_product/DECISIONS.md. Append-only entries, one per design decision that survived review; product ADRs may be PROVISIONAL until ratified. Consult whenever recording, citing, or reviewing ADRs.
---

# ADR Format

Architecture Decision Records are the **append-only** audit trail of every
design decision that survived review. The architect is the sole author.
ADRs live in one of **two homes**:

- **Feature scope** — `.sdd/<feature>/DECISIONS.md`: decisions local to one
  feature, made during its REVIEW/BUILD/CHANGE_REVIEW cycles.
- **Product scope** — `.sdd/_product/DECISIONS.md`: product-wide decisions
  (the *why* behind `STACK.md`), inherited read-only by every feature. A
  product ADR may only be overridden by revising the product tier — never by
  a feature-local ADR.

ADRs are immutable. To override or supersede an ADR, write a *new* ADR
that explicitly references and supersedes the old one — never edit the
original.

## When to write an ADR

- Any design choice that survives a REVIEW cycle (PO accepted a `[major]`
  trade-off, architect picked an approach over alternatives, etc.).
- Any deviation coder made during BUILD that PO or architect accepts
  rather than reverts.
- Any new design choice surfaced during CHANGE_REVIEW that wasn't already
  recorded.
- Any load-bearing stack choice made at `/sdd-fleet:new-product` or a
  product-tier revision (product scope — the *why* behind a STACK.md entry).

If a decision was made silently, it isn't a decision yet — it's a future
`[blocker]` waiting to be found.

## Entry format

Each ADR is a `##` block. Use sequential integer IDs starting at 1, **scoped
to the home file**: feature ADR IDs are per-feature, product ADR IDs are
per-product. When a feature document cites a product ADR, qualify it
(`product ADR-3`) so the two ID sequences cannot be confused.

```markdown
## ADR-<NNN>: <short imperative title>

- **Date:** <iso8601 date>
- **Status:** accepted | PROVISIONAL | superseded by ADR-NNN | deprecated
- **Cycle:** <CYCLE or CHANGE_CYCLE in which the decision was made — feature scope only; omit for product ADRs>

### Context
What forced the decision. What review concern surfaced it, or what
implementation reality made it necessary. Keep concrete.

### Decision
The decision in one or two sentences. What we are doing, stated as a
positive choice.

### Alternatives considered
The options that were rejected, with a one-line reason each. If only one
option was ever on the table, say so — that's also useful context.

### Consequences
What this decision makes easier, what it makes harder, what now becomes
load-bearing on this choice. Be honest; the next person reading this is
trying to understand whether they can change it.
```

## The PROVISIONAL status (product scope)

`STATUS: PROVISIONAL` marks a product ADR that records **unreviewed forward
strategy** — typically a brownfield migration direction the architect noted
while the binding stack stays the observed baseline. Provisional ADRs (and
any `## Forward direction (PROVISIONAL — unreviewed)` STACK.md section they
explain) do **not** bind features.

**Promotion rule:** `PROVISIONAL → accepted` happens only when the strategy
is ratified — at plan-review/plan-finalize (the human un-tags the forward
entries, re-runs `/sdd-fleet:plan-review`, and ratifies with
`/sdd-fleet:plan-finalize`), or by an explicit human edit promoting the
ADR. The architect records the promotion as an edit of that ADR's `Status:`
line by the human's instruction (or a new superseding ADR); the
`/sdd-fleet:plan-finalize` gate itself **never** promotes a PROVISIONAL
ADR. `PROVISIONAL` is meaningless on a feature-scope ADR — feature decisions
are made inside reviewed cycles and land as `accepted`.

## File header

The first time the architect writes to a `DECISIONS.md`, lead with (feature
scope):

```markdown
# Architecture Decisions — <feature>

Append-only log. Each ADR is immutable; supersede with a new ADR.
```

…or, product scope:

```markdown
# Product Architecture Decisions — <product>

Append-only ADR log. Product-wide decisions, inherited read-only by every feature.
```

## What "good" looks like

- The title is what the decision *is*, not what triggered it.
  Bad: "ADR-3: handle the rate limit issue". Good: "ADR-3: use token-bucket
  with per-tenant buckets".
- The context names the concern (e.g., "qa raised \[major\] coverage gap
  at Cycle 2") so the audit trail closes.
- Alternatives are real — if the section says "no alternatives considered",
  that itself is a finding architect should call out.
- Consequences are concrete. "Easier to scale" is vague; "tenants now
  share rate-limit state through Redis" is concrete.

## What "bad" looks like (flag as `[major]`)

- ADRs written after the fact for a decision that was already shipped.
- "Status: accepted" with no review-cycle citation (feature scope).
- "Status: PROVISIONAL" on a feature-scope ADR, or a feature treating a
  PROVISIONAL product ADR as binding.
- Vague titles that describe the symptom, not the choice.
- A supersession that edits the original ADR instead of writing a new one.
