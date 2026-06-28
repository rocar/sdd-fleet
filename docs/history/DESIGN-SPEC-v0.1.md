> ARCHIVED 2026-06-11 (audit §3.20): this is the original v0.1 design spec that lived at the repo root as CLAUDE.md — preserved verbatim for design lineage; it no longer describes the shipped plugin.

> STATUS: This file is the design spec. We are now packaging this system as the
> "build-fleet" Claude Code PLUGIN. Where this file conflicts with the approved
> build plan or the build prompt, those resolved decisions win. Runtime workflow
> rules (§0 principles, §3 state machine, §8 conventions) are migrating into the
> sdd-protocol skill — do not treat a project CLAUDE.md as their home.


# CLAUDE.md — Spec-Driven Agent Software House

This repo **is** the agent fleet. Claude Code is both the *runtime* (it executes the
workflow) and the *builder* (it authors and edits the agents, skills, hooks, and
commands under `.claude/`). Treat `.claude/**` as production source code: review it,
version it, test it.

---

## 0. Operating principles

- **Native first.** Use Claude Code primitives (subagents, agent teams, hooks, skills,
  slash commands, CLAUDE.md memory) before reaching for external infra.
- **Spec is the contract.** No implementation begins until a spec is `FINALIZED`.
- **Gates are deterministic.** Phase transitions are enforced by hooks (exit code 2 =
  block + feedback), not by an agent "deciding" it's done.
- **Escalate, don't loop forever.** Review cycles are bounded (default **3**). On the
  4th unresolved cycle, STOP and write `escalation` to `.sdd/<feature>/ESCALATION.md`,
  then surface it to the human.
- **Filesystem is shared memory.** Subagent `memory` dirs are siloed and do not sync.
  Anything that must cross roles lives as a file in `.sdd/<feature>/`.

---

## 1. Roles (subagent definitions in `.claude/agents/`)

Each role is a reusable subagent. The **main session is the orchestrator** and writes
no production code itself — it routes work, enforces phase order, and synthesizes.

| Role | File | Writes | Reads | Model (suggested) |
|---|---|---|---|---|
| Product Owner | `architect.md` | `spec.md`, `acceptance.md` | requirements, prior specs | Opus |
| Architect | `architect.md` | `DECISIONS.md` (ADRs), review notes | spec, code | Opus |
| Coder | `coder.md` | source, `IMPL_NOTES.md` | spec, tests, ADRs | Sonnet |
| QA | `qa.md` | `tests/`, `TEST_PLAN.md` | spec, acceptance | Sonnet |
| DevOps | `devops.md` | CI/CD, IaC, release notes | finalized spec, code | Sonnet |

**Frontmatter pattern** (scope tools tightly per role):

```yaml
---
name: architect
description: Reviews specs and code for design soundness, scalability, and risk. Authors ADRs.
tools: Read, Grep, Glob, Edit   # no Bash for reviewers unless they run analysis
model: opus
---
You are the Architect in a spec-driven software house...
- Review against: scalability, failure modes, data integrity, security, blast radius.
- Output concerns as a checklist with severity (blocker | major | minor).
- Record every accepted design decision as an ADR in .sdd/<feature>/DECISIONS.md.
- Never approve a spec with open blocker-level concerns.
```

> Reviewers (`architect`, `qa`) should generally **not** have write access to source.
> Restrict `tools` so a review agent can't silently "fix" what it should flag.

---

## 2. Shared memory layer

```
.sdd/<feature>/
  spec.md          # PO-owned. Single source of truth. Has a STATUS line.
  acceptance.md    # PO-owned. Testable acceptance criteria.
  DECISIONS.md     # Architect-owned. Append-only ADR log.
  TEST_PLAN.md     # QA-owned.
  IMPL_NOTES.md    # Coder-owned.
  REVIEW.md        # Append-only review log: who, cycle #, concerns, status.
  PROGRESS.md      # Orchestrator-owned. Current phase + handoff state.
  ESCALATION.md    # Only exists if cycles exhausted. Triggers human gate.
```

- `spec.md` MUST start with: `STATUS: DRAFT | IN_REVIEW | FINALIZED | BLOCKED`
- `REVIEW.md` is **append-only** — it's the audit trail of every cycle.
- Layered memory: `CLAUDE.md` (this file, global rules) → per-role `memory:` dirs
  (role craft/lessons) → `.sdd/` files (the actual cross-role state).
- *Optional* semantic layer: expose MemPalace (ChromaDB+SQLite) as an MCP server if you
  want fuzzy recall across past features. Keep `.sdd/` as the source of truth regardless.

---

## 3. The workflow (state machine)

```
[SPEC]        PO drafts spec.md + acceptance.md            STATUS=DRAFT
   │
   ▼
[REVIEW]      architect + coder + qa review in parallel    STATUS=IN_REVIEW
   │          → concerns appended to REVIEW.md
   │          → PO revises. Repeat ≤ 3 cycles.
   │          → all concerns resolved? ── no & cycles>3 ──► [ESCALATE → human]
   │                                   └─ yes ─┐
   ▼                                           ▼
[FINALIZE]    PO sets STATUS=FINALIZED (gate: zero open blockers)
   │
   ▼
[BUILD]       parallel: qa writes tests  ‖  coder implements to spec
   │
   ▼
[CHANGE-REVIEW]  architect + PO review the diff
   │          → architect: design adherence + ADR compliance
   │          → PO: meets acceptance.md?
   │          → fail ──► back to [BUILD] (bounded, ≤3) or [ESCALATE]
   │          → pass ─┐
   ▼                  ▼
[HANDOFF→DEVOPS]  devops takes finalized + reviewed change → CI/CD, release
```

**Hard gates (enforced by hooks, §4):**
1. No `[BUILD]` until `spec.md` is `FINALIZED`.
2. No `[FINALIZE]` while `REVIEW.md` has an unresolved `blocker`.
3. No `[HANDOFF→DEVOPS]` until tests exist, pass, and change-review is `approved`.
4. Any cycle counter > 3 → write `ESCALATION.md` and halt that phase.

---

## 4. Hooks (`.claude/hooks/`) — the gate enforcers

Register in `.claude/settings.json`. Use exit code **2** to block and return feedback.

| Hook | Purpose |
|---|---|
| `PreToolUse` (Edit/Write on `src/**`) | Block writes to source while `spec.md` STATUS ≠ FINALIZED. |
| `PostToolUse` (Edit on `spec.md`) | Validate the STATUS line + required sections exist. |
| `SubagentStop` | On a reviewer finishing, verify it wrote to `REVIEW.md`; reject empty reviews. |
| `Stop` | Run lint + the test suite; block stop on failure. |
| `TaskCompleted` *(agent teams)* | Refuse completion of a review task if open blockers remain. |
| `TeammateIdle` *(agent teams)* | Keep a reviewer working if its assigned concerns are unaddressed. |

Sketch — block-source-before-finalized (`PreToolUse`):

```bash
#!/usr/bin/env bash
# stdin = JSON tool call; check the active feature's spec status
status=$(grep -m1 '^STATUS:' .sdd/"$FEATURE"/spec.md | awk '{print $2}')
if [ "$status" != "FINALIZED" ]; then
  echo "Blocked: spec is $status. No source edits until FINALIZED." >&2
  exit 2
fi
```

---

## 5. Subagents vs. Agent Teams — when to use which

- **Linear pipeline (default):** orchestrator delegates to role subagents via the Task
  tool, one phase at a time. Cheaper, deterministic, easy to audit. Use for SPEC,
  FINALIZE, BUILD, HANDOFF.
- **Parallel review rounds:** the REVIEW and CHANGE-REVIEW phases benefit from reviewers
  **talking to each other** (architect challenges QA's coverage, etc.). Promote to an
  **agent team** so teammates share the task list + mailbox and debate. Spawn them from
  the same role definitions (a subagent type can run as a teammate).
- Agent teams are experimental: one team per session, no nesting, set
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Always clean up the team via the lead.
- Reminder: when a role runs *as a teammate*, its `skills`/`mcpServers` frontmatter is
  ignored (loaded from project/user settings instead) — put review rules in the prompt
  body, not in a skill, if you rely on team mode.

---

## 6. Skills (`.claude/skills/`) & Commands (`.claude/commands/`)

Skills = reusable craft the roles invoke. Commands = workflow entry points you type.

Skills to build:
- `sdd-spec-template` — the canonical spec.md structure + STATUS contract.
- `adr` — ADR format for `DECISIONS.md`.
- `review-rubric` — severity definitions (blocker/major/minor) shared by all reviewers.
- `test-plan` — QA's test-design checklist mapped to acceptance criteria.

Commands to build:
- `/new-feature <name>` — scaffold `.sdd/<name>/`, set PO to draft.
- `/review` — kick the parallel review phase for the active feature.
- `/finalize` — run the finalize gate (fails if open blockers).
- `/handoff` — run change-review then hand to devops.
- `/status` — print PROGRESS.md + open concerns + cycle counts.

---

## 7. Bootstrap plan (build the fleet *with* Claude Code)

Run these in order; each is a normal Claude Code prompt against this repo:

1. **Scaffold** — "Create `.claude/agents/`, `.claude/hooks/`, `.claude/skills/`,
   `.claude/commands/`, and `.sdd/`. Add `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` to
   `.claude/settings.json`."
2. **Roles** — "Author the 5 role subagents per §1, with tight `tools` allowlists."
3. **Skills** — "Author the 4 skills in §6."
4. **Hooks** — "Author the hooks in §4 and register them in settings.json."
5. **Commands** — "Author the slash commands in §6."
6. **Dry run** — `/new-feature smoke-test` → walk one full cycle on a trivial feature;
   confirm every gate fires and escalation triggers when forced.
7. **Harden** — add a `Stop` hook running the real test/lint stack for your target repo.

---

## 8. Conventions

- One feature in flight per `.sdd/<feature>/` dir; the active one is named in `PROGRESS.md`.
- Reviewers append, never overwrite, `REVIEW.md`.
- Every design choice that survives review becomes an ADR — no silent decisions.
- The orchestrator never writes source; it only routes, gates, and synthesizes.
- Human escalation is a first-class outcome, not a failure.
