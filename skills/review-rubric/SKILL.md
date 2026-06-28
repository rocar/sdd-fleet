---
name: review-rubric
description: The shared severity vocabulary every reviewer uses in .sdd/<feature>/REVIEW.md — blocker, major, minor — with exact definitions and gate effects. Consult during /sdd-fleet:feature-dev and /sdd-fleet:pr-review, and whenever assigning a severity to a finding.
---

# Review Rubric

This skill is the canonical severity vocabulary used by architect, qa, and
coder in `.sdd/<feature>/REVIEW.md`. The `/sdd-fleet:feature-dev` and
`/sdd-fleet:pr-review` gates parse the severity tags to decide whether a
phase may advance.

The same table appears verbatim in `architect.md` and `qa.md` prompt bodies —
a deliberate duplication. In workflow REVIEW the workflow preloads this skill
into reviewer subagents via `AgentDefinition.skills: ["review-rubric"]`, so this
skill is the load-bearing source and the in-body copies are belt-and-suspenders.
On non-workflow paths (CHANGE_REVIEW, direct invocation of a role agent, and
agent-team mode — where per-agent frontmatter `skills` are ignored) the in-body
copies are the load-bearing ones. **Precedence:** if the copies ever disagree,
this skill's table is canonical; `scripts/rubric-drift.test.sh` fails the suite
on any drift.

## The vocabulary

| Severity | Definition | Gate effect |
|---|---|---|
| `blocker` | Correctness, security, data loss, or a contradiction of the spec/acceptance. | Blocks FINALIZE and HANDOFF. |
| `major`   | Scalability, maintainability, or missing acceptance coverage. | Must be resolved or explicitly accepted (as an ADR) before the gate opens. |
| `minor`   | Style, wording, nits. | Advisory; never blocks a gate. |

Use the exact strings `[blocker]`, `[major]`, `[minor]` — including the
square brackets — as item prefixes in REVIEW.md. The finalize gate uses a
literal substring search.

## REVIEW.md entry shape

```markdown
## Cycle <N> — <role> — <iso8601>
- [blocker] <one-line concern; expand below if needed>
- [major]   <concern>
- [minor]   <concern>
status: concerns-raised | approved
```

The `status:` line is mandatory. In workflow REVIEW the reviewer subagents
return structured concerns payloads which the workflow merges into the
canonical block shape above; the scribe appends them. On non-workflow paths
(CHANGE_REVIEW, direct invocation) the `check-review-written` SubagentStop hook
rejects a reviewer that stops without writing a block of this shape attributed
to its own role for the current cycle.

## How to choose a severity

Ask yourself, in order:

1. **Does this make the system wrong, unsafe, or contradict the spec?**
   → `[blocker]`.
2. **Does this make the system harder to scale, maintain, or extend?
   Or is there acceptance coverage missing?** → `[major]`.
3. **Otherwise (style, prose, naming, nits):** → `[minor]`.

If you're tempted to add a fourth category ("critical", "important"),
don't. Pick from the three above. Three is enough.

## How a major becomes an ADR

`[major]` items have two resolution paths:

- **Fix it** in the spec or the code, then approve in the next cycle.
- **Accept it** — PO and architect explicitly agree the trade-off stands.
  Architect writes a new ADR in `DECISIONS.md` capturing the decision, the
  alternatives, and the consequences. The ADR ID is cited in the
  approving REVIEW.md block.

A `[major]` that gets quietly dropped between cycles without a fix or an
ADR is a finding the next reviewer should re-raise — same content,
elevated to `[blocker]` for lack of audit trail.

## Hard rules

- One block per reviewer per cycle. Append; never edit prior blocks.
- A reviewer approving its own prior `[blocker]` without explanation is a
  red flag — the resolving fix should be visible (a spec revision, an
  ADR, or an explicit comment in the new block).
- `[minor]` items never block a gate. If you find yourself promoting a
  minor to a major to force resolution, the right move is to write it as
  what it actually is and accept that it won't gate.
