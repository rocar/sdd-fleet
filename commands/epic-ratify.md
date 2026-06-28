---
description: Ratify a cross-repo epic plan (bare call is a dry-run), then materialise it into Jira
argument-hint: "<epic-slug> [ratify]"
allowed-tools: Read, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/epic-ratify-record.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/epic-materialise.sh":*)
disable-model-invocation: true
---

<!-- disable-model-invocation: this is the human-ratification gate for a cross-repo epic.
     If the model could self-invoke `/sdd-fleet:epic-ratify <slug> ratify`, the "a human
     ratifies before fan-out" guarantee — the whole reason the estate has no model in
     dispatch — would be fiction. A human (or the external orchestrator process) types this. -->

# /sdd-fleet:epic-ratify

You are the **orchestrator** at the **workspace (estate) level**. The runtime rulebook is
the `sdd-protocol` skill (`references/workspace-tier.md` — the plan → human-ratify →
deterministic-dispatch spine). This is the **ratification gate**: the one place a human
commits to a cross-repo epic's dependency DAG + contract design, after which its stories
may be specced and dispatched.

**The estate is deliberately thin — there is no estate review engine.** This gate **never
auto-passes**: the bare command is a *dry-run* that prints the plan + contract design for
the human to read and halts; flipping state requires the explicit `ratify` token. In
headless mode this is the whole safety story — `claude -p '/sdd-fleet:epic-ratify <slug>'`
prints the plan and stops; it cannot ratify on its own.

Ratifying does two things, **vault first**: (1) records the human decision by writing
`.sdd/_epic/<slug>/RATIFICATION.md` (its existence *is* the ratified signal — read by the
`epic-ratified-before-fanout` gate and the conductor), then (2) **materialises** the epic
into Jira (creates the epic + one story per plan node). Both are deterministic scripts —
this command only gates and reports. A failed/deferred materialisation **never un-ratifies**
the epic.

## Arguments

`$ARGUMENTS` = `<epic-slug> [ratify]` (the slug is required — there are multiple epics):
- `<epic-slug>` *(alone)* — **dry-run**. Print the plan + contract design, emit the dry-run
  signal, halt. No state changes.
- `<epic-slug> ratify` — **ratify**: write `RATIFICATION.md`, then materialise into Jira.

A missing slug, or a second token that is not `ratify`, is treated as a dry-run (note the
recognized form).

## What you do

1. **Parse args.** First token = `<epic-slug>`. Second token = `ratify` (else dry-run). If
   no slug, refuse:
   > `SDD_FLEET_EPIC_RATIFY_REFUSE: {"code":2,"reason":"no-slug"}` — usage: `/sdd-fleet:epic-ratify <epic-slug> [ratify]`.

2. **Preconditions (each emits one `SDD_FLEET_EPIC_RATIFY_REFUSE:` line, then halt):**
   - `.sdd/_epic/<slug>/` absent →
     `{"epic":"<slug>","code":2,"reason":"no-epic"}` — run `/sdd-fleet:epic-plan <slug>` first.
   - `plan.md` or `contracts.md` missing →
     `{"epic":"<slug>","code":2,"reason":"not-planned"}` — the architect has not authored the plan yet.
   - `.sdd/_epic/<slug>/RATIFICATION.md` already exists →
     `{"epic":"<slug>","code":2,"reason":"already-ratified"}` — the epic is ratified; revise the
     `_epic/<slug>/` files directly only with care (re-ratification is a deliberate later concern).
   - `.sdd/_epic/<slug>/ESCALATION.md` exists →
     `{"epic":"<slug>","code":2,"reason":"escalation-present"}` — a human halted the epic; resolve it first.

3. **Branch on the second token.**

   **a. Dry-run (no `ratify`).** Read `.sdd/_epic/<slug>/plan.md` and `contracts.md` and print
   them for the human to review — the dependency DAG (stories, target repos, story→contract
   edges) and the contract design. Emit:
   ```
   SDD_FLEET_EPIC_RATIFY_DRYRUN: {"epic":"<slug>"}
   ```
   End with: *To ratify, re-run `/sdd-fleet:epic-ratify <slug> ratify`.* **Change no state.**
   This is the headless safety stop.

   **b. `ratify`.** Run the two deterministic scripts in order (supply `--now` as the current
   ISO-8601 timestamp — you provide it; the scripts read no clock):

   - **Record the ratification** (vault):
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/epic-ratify-record.sh" "<slug>" --now "<iso8601>"
     ```
     On `{"status":"recorded",...}` emit:
     ```
     SDD_FLEET_EPIC_RATIFY_PASS: {"epic":"<slug>","digest":"<digest>"}
     ```
     If it returns any other status (e.g. `already-ratified` from a race, `not-planned`),
     surface it as `SDD_FLEET_EPIC_RATIFY_REFUSE: {"epic":"<slug>","code":2,"reason":"<status>"}`
     and **stop** — do not materialise.

   - **Materialise into Jira** (best-effort, *after* the record):
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/epic-materialise.sh" "<slug>" --now "<iso8601>"
     ```
     Report its status verbatim — `materialised` (epic + stories created, keys in
     `JIRA_LINK.md`), `deferred` (no Jira adapter configured yet — the real backend slots in
     behind the `SDD_JIRA_ADAPTER` seam later), or `adapter-error`:
     ```
     SDD_FLEET_EPIC_RATIFY_MATERIALISE: {"epic":"<slug>","status":"<materialised|deferred|adapter-error>","jira_epic":"<key-or-empty>"}
     ```
     **A non-`materialised` result never un-ratifies the epic** — `RATIFICATION.md` is already
     written. Re-running `/sdd-fleet:epic-ratify <slug> ratify` later refuses with
     `already-ratified`; materialisation is then re-driven by re-running the materialise step
     once an adapter is configured (a deferred epic has no `JIRA_LINK.md`, so it is not yet
     `already-materialised`).

4. **Report.** Tell the user the epic is **ratified** (`RATIFICATION.md` written; its existence
   now permits spec'ing its stories and lets the conductor dispatch them), and whether Jira
   materialisation **succeeded, deferred, or errored**. If deferred, note that no story is in
   Jira yet — re-run once a Jira backend is wired behind `SDD_JIRA_ADAPTER`.

## Hard rules

- **Never auto-pass.** The bare command must not flip state. Only an explicit `ratify` token
  ratifies. This is the headless contract (`disable-model-invocation: true` makes it binding).
- **Vault first, Jira second.** Record `RATIFICATION.md` before materialising; a failed or
  deferred materialisation never un-ratifies.
- **Do not hand-write `RATIFICATION.md` or `JIRA_LINK.md`, and do not call Jira yourself.**
  Those are the deterministic scripts' jobs (`epic-ratify-record.sh`, `epic-materialise.sh` via
  the adapter seam). This command only gates, invokes, and reports.
- **Do not edit `plan.md` / `contracts.md` / `DECISIONS.md`** — ratification finalizes the plan
  **as written**. If the plan is wrong, the human edits it and re-runs; this gate never reshapes it.
- **Do not touch any member repo.** Estate ratification writes only under `.sdd/_epic/<slug>/`
  (plus the Jira side, via the adapter).

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit code**. The
`SDD_FLEET_EPIC_RATIFY_*` lines on stdout are the **sole machine contract**: `_PASS` =
ratified, `_MATERIALISE` = the Jira outcome, `_DRYRUN` = no-op report, `_REFUSE` = refused
(JSON carries `"code"` — `2` = precondition refused — and a kebab-case `"reason"`).
Orchestrators dispatch on the signal line, never on the process exit status.
