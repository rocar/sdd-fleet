---
description: Draft, review, and pin a project workflow for a novel task
argument-hint: "<name> \"<task>\" | ratify <name>"
allowed-tools: Read, Write, Task, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/workflow-determinism-lint.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/pin-workflow.sh":*)
---

# /sdd-fleet:scaffold-workflow

You are the **orchestrator**. This is sdd-fleet's **generate-then-pin** lane: for a
**novel, large, unknown-shape task** that fits none of the fixed lanes (review / plan-review /
deep-build / diagnose) — a repo-wide audit, a big migration, a multi-angle stress-test — you
AUTHOR a dynamic-workflow script on the fly, GOVERN it (determinism lint + adversarial review),
and only on an explicit `ratify` PIN it — frozen — into the target project's `.claude/workflows/`.
Dynamic generation is an **authoring accelerator**; the executing artifact is always static and
replayable.

**Determinism is non-negotiable.** This command **never executes** the candidate. The workflow
runs only *after* pinning, when you/the user invoke `/<name>` on the frozen artifact — never
inside sdd-fleet's audited `.sdd/` lanes. Design note:
`docs/history/2026-06-15-layer2-scaffold-workflow.md`.

## Modes

- `/sdd-fleet:scaffold-workflow <name> "<task>"` — **draft**: generate + lint + review. Never pins.
- `/sdd-fleet:scaffold-workflow ratify <name>` — **pin** the drafted candidate (hard lint gate).

`<name>` is a kebab-case slug (`[a-z0-9-]`, no path separators). The pinned workflow runs under
Claude Code's dynamic-workflow runtime (v2.1.154+); authoring/pinning here does not need it, but
running `/<name>` afterward does.

## What you do

1. **Parse the mode.** If the first `$ARGUMENTS` token is `ratify`, this is the **ratify** path
   with `<name>` = the second token. Otherwise it is the **draft** path: the first token is
   `<name>`, the remainder is the `"<task>"` description. `<name>` must be kebab-case. On a
   missing/invalid name (or, in draft, an empty task), refuse:
   > `SDD_FLEET_REFUSE: {"command":"scaffold-workflow","code":2,"reason":"bad-args"}`

2. **Require a clean slate (both modes).** Read `.sdd/ACTIVE`. If it is non-empty, refuse:
   > `SDD_FLEET_REFUSE: {"command":"scaffold-workflow","code":2,"reason":"item-in-flight","active":"<slug>"}`
   scaffold-workflow authors an out-of-band project workflow; running it mid-feature/bug would
   collide with the reviewer-write confinement and reviewer-stop hooks, and a pin write to
   `.claude/workflows/` (outside `.sdd/`) is blocked while an item is source-locked. Tell the user
   to finish the active item or `/sdd-fleet:park` it first. With nothing in flight, all of that
   is moot — proceed to **Draft** or **Ratify**.

## Draft

D1. **Ignore the quarantine.** Ensure `.sdd/.gitignore` exists and contains a `_generated/` line
   (append it if absent). The quarantine is per-worktree scratch and is never committed; the
   pinned `.claude/workflows/<name>.js` is the durable artifact.

D2. **Author the candidate.** Write one self-contained workflow script to
   `.sdd/_generated/<name>.js` that accomplishes the task, following the Workflow runtime contract
   AND sdd-fleet's determinism conventions:
   - Begins with `export const meta = { name, description, phases }` — a **pure literal**.
   - Uses only `agent()` / `parallel()` / `pipeline()` / `phase()` / `log()` and the `args` global.
     Decompose the task; fan out where work is independent; keep fan-out **bounded** (no unbounded
     `while`/recursion — make every limit explicit and honor the runtime's caps).
   - **No `Date.now()` / `Math.random()` / argless `new Date()`** — take any timestamp from
     `args.now`. **No `require` / `import` / `process.` / `fs` / `fetch` / `eval`** — the sandbox
     has no filesystem or network; the script is pure orchestration.
   - Returns a structured result; put a `schema:` on `agent()` calls that must yield checkable data.
   This is the dynamic-generation step — you are authoring orchestration JS for an unforeseen task.

D3. **Lint (deterministic gate).** Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/workflow-determinism-lint.sh" .sdd/_generated/<name>.js
   ```
   On `SDD_FLEET_LINT_FAIL`, surface the `SDD_FLEET_LINT_VIOLATION` lines, fix the candidate,
   and re-lint until it passes. A candidate that cannot pass the lint cannot be pinned — do not
   proceed until it is clean.

D4. **Adversarial review (interrogation, advisory).** Fan out two reviewers in parallel via the
   Task tool — `sdd-fleet:architect` and `sdd-fleet:qa` — to **interrogate** the candidate
   (interrogation, not a vote: nothing is auto-killed; you record findings for a human):
   - architect lens: does the orchestration actually accomplish the task? Is the decomposition
     sound and the fan-out/cost bounded? Any non-determinism the lint cannot see (order-dependence,
     leaning on agent free-text instead of `schema:`)?
   - qa lens: are results validated with schemas? Is the return structured and checkable? What
     failure modes or unverified claims remain?
   Each returns findings `[{severity, text}]`. Append a consolidated report to
   `.sdd/_generated/<name>.review.md` (append-only; header `# Scaffold review — <name>`).

D5. **Report and stop.** Emit, before prose:
   ```
   SDD_FLEET_SCAFFOLD_DRAFT: {"name":"<name>","lint":"pass","findings":<N>,"candidate":".sdd/_generated/<name>.js"}
   ```
   Tell the user: the candidate and review are in `.sdd/_generated/`; read them, revise the
   candidate if needed (re-lint after any edit), and when satisfied run
   `/sdd-fleet:scaffold-workflow ratify <name>` to pin it. **Never pin in draft mode.**

## Ratify

R1. **Pin (hard lint gate + freeze).** Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/pin-workflow.sh" <name>
   ```
   The script re-runs the determinism lint as a fail-closed gate and, only on pass, copies
   `.sdd/_generated/<name>.js` → `.claude/workflows/<name>.js`. Surface its signal line verbatim:
   - `SDD_FLEET_WORKFLOW_PINNED` → success.
   - `SDD_FLEET_WORKFLOW_PIN_REFUSED` (with `reason`) → report the failure; do **not** claim the
     workflow was pinned. A `determinism-lint-failed` reason means the candidate regressed — fix and
     re-draft. A `no-candidate` reason means there is nothing drafted under that name.

R2. **Report.** On success, tell the user the workflow is frozen at `.claude/workflows/<name>.js`
   and runs as `/<name>` — a standard Claude Code dynamic workflow, replayable, **outside**
   sdd-fleet's audited `.sdd/` lanes. It is the project's artifact now; commit it with the repo.

## What this command does NOT do

- **Never executes the candidate.** Generation is authoring only; the workflow runs solely after
  pinning, when you invoke `/<name>`. No generated code ever runs inside an audited `.sdd/` lane.
- **Never auto-pins.** Pinning requires the explicit `ratify` token — the headless safety stop, so
  a `claude -p` run cannot pin without being told to.
- **Does not commit** the candidate or quarantine. `.sdd/_generated/` is gitignored scratch.
- **Does not generate a dispatching command.** The pinned workflow is invoked as plain `/<name>`.
- **Does not touch `.sdd/ACTIVE`** or the feature/bug state machines — it is orthogonal authoring.

## Refusal contract (machine-readable)

A slash command cannot set a process exit code; the `SDD_FLEET_*` stdout signal lines are the
sole machine contract. Refusals emit one `SDD_FLEET_REFUSE:` line carrying `"code"` (`2` =
validation / precondition refused) and `"reason"` (a kebab-case slug). The pin script's own
`SDD_FLEET_WORKFLOW_PIN_REFUSED` line is the gate's refusal signal. Dispatch on the signal lines,
never on a process exit status.
