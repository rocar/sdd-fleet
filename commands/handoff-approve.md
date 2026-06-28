---
description: Approve a blast-radius-risky HANDOFF (bare call is a dry-run preview); pins the approval to the current blast radius
argument-hint: "[approve]"
allowed-tools: Read, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/blast-radius-signature.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/handoff-approve-record.sh":*)
disable-model-invocation: true
---

<!-- disable-model-invocation: this is the human-approval gate for a blast-radius-risky change.
     If the model could self-invoke `/sdd-fleet:handoff-approve approve`, the "a human signs off
     on a high-blast-radius / money-movement / PII change before it ships" guarantee would be
     fiction. A human (or the external orchestrator process) types this. (The residual that a
     model could hand-write HANDOFF_APPROVAL.md directly is the same harness-wide trust boundary
     RATIFICATION.md accepts — see references/service-catalog.md, "stated limit".) -->

# /sdd-fleet:handoff-approve

You are the **orchestrator**. The runtime rulebook is the `sdd-protocol` skill
(`references/service-catalog.md` — the blast-radius human gate). This is the **approval gate**:
the one place a human signs off on shipping a change whose blast radius trips the gate (≥ N
transitive consumers, or `money_movement`/`pii` on a reached consumer or on the changed service
itself).

The approval is **pinned to the blast radius it authorised** — a `BLAST_RADIUS_SIGNATURE` digest
of the current verdict (the tripping contracts, their consumer sets, and the sensitive classes).
If the blast radius later **widens or changes**, the recorded approval goes **stale** and the gate
re-blocks until a human re-approves. This gate **never auto-passes**: the bare command is a
*dry-run* that prints what would be approved and halts; recording requires the explicit `approve`
token.

Approving writes `.sdd/<feature>/HANDOFF_APPROVAL.md` (its presence + a matching signature is what
the `handoff-blast-radius-gate` hook reads to permit the `PHASE: HANDOFF` transition). The write
is a deterministic script — this command only gates, invokes, and reports.

## Arguments

`$ARGUMENTS` = `[approve]` (operates on the single active feature — `.sdd/ACTIVE`):
- *(empty)* — **dry-run**. Print the blast-radius verdict + signature, emit the dry-run signal,
  halt. No state changes.
- `approve` — **record** the approval for the current blast radius.

A second token that is not `approve` is treated as a dry-run.

## What you do

1. **Resolve the active feature.** Read `.sdd/ACTIVE`. If empty/absent, refuse:
   > `SDD_FLEET_HANDOFF_APPROVE_REFUSE: {"code":2,"reason":"no-active"}` — no active feature to approve.

2. **Compute the verdict** (deterministic, read-only):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/blast-radius-signature.sh"
   ```
   Parse `.required` and `.signature`. If `.required` is `false`, refuse — there is no gate to
   clear:
   > `SDD_FLEET_HANDOFF_APPROVE_REFUSE: {"feature":"<slug>","code":2,"reason":"not-required"}` — this change's blast radius does not trip the human gate; nothing to approve.

3. **Branch on the token.**

   **a. Dry-run (no `approve`).** Print the verdict for the human to review — each tripping
   `contract@major` with its consumer set + `money_movement`/`pii`, and any sensitive class on the
   changed service itself — plus the `signature`. Emit:
   ```
   SDD_FLEET_HANDOFF_APPROVE_DRYRUN: {"feature":"<slug>","signature":"<signature>"}
   ```
   End with: *To approve this blast radius, re-run `/sdd-fleet:handoff-approve approve`.* **Change
   no state.**

   **b. `approve`.** Record the approval (supply `--now` as the current ISO-8601 timestamp — you
   provide it; the script reads no clock):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/handoff-approve-record.sh" "<slug>" --now "<iso8601>"
   ```
   On `{"status":"recorded",...}` emit:
   ```
   SDD_FLEET_HANDOFF_APPROVE_PASS: {"feature":"<slug>","signature":"<signature>"}
   ```
   Any other status is surfaced verbatim and **stops**:
   `SDD_FLEET_HANDOFF_APPROVE_REFUSE: {"feature":"<slug>","code":2,"reason":"<status>"}`
   (`already-approved` = an approval already covers the current radius — benign, nothing to do;
   `not-required` / `signature-failed` as named).

4. **Report.** Tell the user the handoff is **approved for the current blast radius** — the
   `PHASE: HANDOFF` transition will now pass while the radius is unchanged. Note that if the blast
   radius widens before HANDOFF, the approval goes stale and they must re-approve.

## Hard rules

- **Never auto-pass.** The bare command must not write state; only an explicit `approve` records.
  This is the headless contract (`disable-model-invocation: true` makes it binding).
- **Do not hand-write `HANDOFF_APPROVAL.md`.** That is `handoff-approve-record.sh`'s job (it
  computes the signature via the single-home `blast-radius-signature.sh`). This command only gates,
  invokes, and reports — never fabricate or edit the signature.
- **Approve the current radius as computed.** Do not approve a radius the script did not report;
  if the change is wrong, fix it and re-run — this gate signs off on the blast radius **as
  computed**, it never reshapes it.
- **Touch nothing else.** Approval writes only `.sdd/<feature>/HANDOFF_APPROVAL.md`.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit code**. The
`SDD_FLEET_HANDOFF_APPROVE_*` lines on stdout are the **sole machine contract**: `_PASS` =
recorded, `_DRYRUN` = no-op preview, `_REFUSE` = refused (JSON carries `"code"` — `2` =
precondition refused — and a kebab-case `"reason"`). Orchestrators dispatch on the signal line,
never on the process exit status.
