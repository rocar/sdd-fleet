---
name: sdd-diagnosis-template
description: The canonical diagnosis.md structure for the sdd-fleet troubleshoot-fix bug lane. Defines the required STATUS line (REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED), the required section headings, and the contract the validate-diagnosis-status PostToolUse hook enforces. Consult whenever drafting, advancing, or reviewing a diagnosis.md for an active bug.
---

# SDD Diagnosis Template

This skill defines the **only** acceptable structure for `.sdd/<bug-slug>/diagnosis.md`,
the bug lane's source-of-truth artifact — the analog of `spec.md` for the forward
feature machine. The `validate-diagnosis-status` hook parses for the STATUS line and the
required section headings; a write that omits any of them is rejected (exit 2).

Unlike `spec.md` (authored once, up front, by the architect), `diagnosis.md` is filled
**progressively across phases** — the Symptom at REPORT, the hypothesis / blast radius /
fix strategy at DIAGNOSE — and its STATUS advances monotonically as the lane progresses.

## STATUS line (first non-blank line)

```
STATUS: REPORTED
```

…the value MUST be one of: `REPORTED`, `REPRODUCING`, `DIAGNOSED`, `CONFIRMED`, `FIXED`.
No other tokens, no prefix, no trailing comment. The validator scans the first ~30 lines.

The lifecycle is monotonic — each transition has a precondition:

| STATUS | Set when | Phase |
|---|---|---|
| `REPORTED` | the bug is filed (`/sdd-fleet:jira-story`) | REPORT |
| `REPRODUCING` | a failing reproduction test exists under `tests/` | REPRODUCE |
| `DIAGNOSED` | a root-cause hypothesis is written | DIAGNOSE |
| `CONFIRMED` | the hypothesis survived adversarial refutation **and** a reproducing test exists | DIAGNOSE→FIX |
| `FIXED` | VERIFY passed (the counterfactual holds) | VERIFY→HANDOFF |

`CONFIRMED` is the load-bearing one: it is the bug-lane analog of `FINALIZED`, the point at
which source writes unlock (see the `sdd-protocol` skill, B7/B8).

## Required sections (in this order)

```markdown
STATUS: <REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED>

# Bug: <short title>

## Symptom + reproduction steps
The observed failure — verbatim from the triage <symptom> — and the concrete steps or
failing test that reproduce it. Filled at REPORT; sharpened at REPRODUCE when the test lands.

## Root-cause hypothesis
The single best explanation of *why* the symptom occurs. Empty until DIAGNOSE; this is the
claim the diagnose.js workflow adversarially confirms.

## Blast radius
What else this touches — code paths, data, callers — and the regression surface a fix risks.

## Fix strategy
The intended change and why it addresses the root cause without widening the blast radius.
```

## What the validator checks

`validate-diagnosis-status` (PostToolUse on `diagnosis.md`) rejects the write if:

- The STATUS line is missing or not one of the five tokens.
- Any of these headings is absent: `## Symptom + reproduction steps`,
  `## Root-cause hypothesis`, `## Blast radius`, `## Fix strategy`.

The validator is **syntactic** — it checks the sections exist, never that the diagnosis is
*sound*. Soundness is a judgment, confirmed adversarially by the `diagnose.js` workflow
(the REPORTED→…→CONFIRMED progression), never by a hook. (The category error to avoid —
hook-enforcing "is this the real root cause?" — is the same one the forward machine avoids.)

## What "good" looks like

- The Symptom is reproducible by someone else from the steps alone.
- The Root-cause hypothesis names a *mechanism*, not a restatement of the symptom.
  Bad: "login returns 500." Good: "an empty email bypasses the validator and the DB driver
  throws on the NULL insert."
- Blast radius is concrete (named callers / tables / paths) so a reviewer can attack it.
- Fix strategy is the smallest change that kills the root cause.

## What "bad" looks like (a reviewer should refute in diagnose.js)

- A hypothesis that merely re-describes the symptom ("it crashes because it's broken").
- "Blast radius: none" on a change to shared code — every fix has a regression surface.
- A fix strategy that treats the symptom (catch-and-swallow) rather than the cause.
