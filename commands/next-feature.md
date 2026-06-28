---
description: Resolve and gate the next unblocked backlog feature
allowed-tools: Read, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-feature.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-block.sh":*)
---

# /sdd-fleet:next-feature

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol` skill
(`references/product-tier.md` — the DEVELOPING loop). This is the **advancement
convenience**: it resolves the
next unblocked backlog feature, confirms it is ready to start, and emits a dispatch
signal — collapsing the manual "read `/sdd-fleet:status` → type
`/sdd-fleet:jira-story <slug>`" into one focused, gated step.

**It is convenience, not policy.** It uses **only** the deterministic resolver
(`scripts/next-feature.sh` — first PENDING in the lowest phase whose `depends-on` are all
DONE). It never reorders, skips, or judges importance. Any real prioritization is yours:
reorder `backlog.md`, or run `/sdd-fleet:jira-story <slug>` directly. This is the
no-policy fast path.

**It does NOT run `/sdd-fleet:jira-story` itself.** This command resolves + gates +
signals; the
**dispatcher** starts the feature — the upstream caller in headless mode, you in
interactive mode. This keeps dispatch (and any caller-side policy/description) with the
orchestrator, and means it never duplicates new-feature's scaffolding/classifier/inheritance
logic (new-feature owns that, and self-seeds its description from the backlog intent via its
step 5).

## What you do

1. **Refuse if a feature is already in flight.** Read `.sdd/ACTIVE`. If non-empty, refuse —
   the protocol allows one feature at a time; finish it (through `/sdd-fleet:pr-review`,
   which clears `.sdd/ACTIVE` on ship) before advancing:
   ```
   SDD_FLEET_NEXT_FEATURE_REFUSE: {"code":2,"reason":"feature-in-flight","active":"<slug>"}
   ```

2. **Resolve the next feature.** Run the shared resolver (the single source of truth; do
   not re-derive in prose):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-feature.sh"
   ```
   Branch on its `status`:
   - `no-backlog` → no product tier exists; there is nothing to advance. Tell the user to
     use `/sdd-fleet:jira-story <slug>` directly. Emit
     `SDD_FLEET_NEXT_FEATURE: {"status":"no-backlog"}` (informational no-op).
   - `complete` → the product backlog is fully shipped (`done/total`). Nothing to advance;
     congratulate; note that appending features re-opens the loop. Emit
     `SDD_FLEET_NEXT_FEATURE: {"status":"complete","done":<n>,"total":<n>}`.
   - `deadlocked` → `<pending>` features remain but none are unblocked. Refuse and warn the
     user to check `depends-on` / cycles in `backlog.md`. Emit
     `SDD_FLEET_NEXT_FEATURE_REFUSE: {"code":2,"reason":"deadlocked","pending":<k>}`.
   - `empty` → the backlog has no parseable feature rows. Refuse; tell the user to check its
     format. Emit `SDD_FLEET_NEXT_FEATURE_REFUSE: {"code":2,"reason":"empty-backlog"}`.
   - `next` → continue to step 3 with the resolved `slug` + `phase`.

3. **Pre-check the intent (headless-safe gate).** Run the shared intent-block extractor —
   the SAME script `/sdd-fleet:jira-story` step 5 uses, so the two always reach the same
   verdict (one grammar, one quality floor, one implementation):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-block.sh" --slug "<slug>" .sdd/_product/backlog.md
   ```
   It prints the canonical intent block (the 1–3 indented lines under the feature row) and a
   final `INTENT_VERDICT: usable|too-thin` line. The quality floor it encodes: an intent is
   *usable* only with at least 2 of its 3 components (what / scope boundary / non-goals); a
   missing intent or a thin slug-restatement is `too-thin`. (The canonical prose definition
   of the floor lives in the `sdd-protocol` skill's `references/product-tier.md`.)

   If the verdict is `too-thin` (or the script errors), **do NOT advance** —
   `/sdd-fleet:jira-story` would STOP-and-ask for a description, which deadlocks an
   unattended (headless) run. Emit:
   ```
   SDD_FLEET_NEXT_FEATURE_NEEDS_DESC: {"code":2,"slug":"<slug>","reason":"intent-too-thin"}
   ```
   Tell the user: the next feature's backlog intent is too thin to start unattended — run
   `/sdd-fleet:jira-story <slug>` interactively and provide a description (new-feature
   will prompt). *(This honors new-feature's own STOP-and-ask floor up front, instead
   of discovering it mid-dispatch.)*

4. **Emit the dispatch signal and hand off.** The next feature is unblocked, ready, and has
   a usable intent. Emit exactly one line:
   ```
   SDD_FLEET_NEXT_FEATURE: {"status":"next","slug":"<slug>","phase":"<phase>"}
   ```
   Then tell the **dispatcher** the next move — **do not run it here**:
   - **Interactive:** "Next is `<slug>` (`<phase>`), ready to start. **Nothing is started
     yet — this command only resolves and gates.** Run `/sdd-fleet:jira-story <slug>` to
     begin — it will inherit the backlog intent + the product stack automatically."
   - **Headless:** the upstream caller reads `SDD_FLEET_NEXT_FEATURE` and dispatches
     `/sdd-fleet:jira-story <slug>` itself.

## Hard rules

- **No prioritization policy.** Resolver only; never reorder/skip/judge importance.
- **Never duplicate new-feature.** This command resolves + gates + signals; new-feature starts.
- **Never run `/sdd-fleet:jira-story` inline** — the dispatcher does that (preserves
  caller-side control; keeps the command mode-agnostic without needing to detect headless vs interactive).
- **Never advance past a thin intent** (would force new-feature to STOP-and-ask).
- **Headless contract.** Every branch emits exactly one `SDD_FLEET_NEXT_FEATURE*:` line
  before any prose.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_NEXT_FEATURE*` signal
lines on stdout are the **sole machine contract**: `SDD_FLEET_NEXT_FEATURE`
(status `next` / `complete` / `no-backlog`) = resolved or informational no-op;
`_REFUSE` / `_NEEDS_DESC` = refused, the JSON carrying `"code"` (an integer
preserving the legacy exit-code semantics: `2` = refused) and `"reason"` (a
kebab-case slug). Orchestrators dispatch on the signal line, never on the
process exit status.
