---
description: Park the active item and free the in-flight lock
argument-hint: "<reason>"
allowed-tools: Read, Write, Edit, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh":*)
disable-model-invocation: true
---

# /sdd-fleet:park

You are the **orchestrator**. Parking is a **human decision** — this command is
not model-invocable (`disable-model-invocation: true`); a human types it. It is
the **sanctioned sev0-preemption path**: sdd-fleet allows one item in flight,
and `/sdd-fleet:jira-story` refuses while `.sdd/ACTIVE` is occupied — when a sev0
lands mid-feature, the human parks the feature with this command, runs the bug
lane, and resumes later. It is also the sanctioned way to shelve a feature or
abandon a bug without hand-editing `.sdd/` state.

Parking does **not** delete anything. The `.sdd/<slug>/` workspace (spec,
reviews, notes, diagnosis) stays intact; only the in-flight lock is released
and the parked state is recorded.

## Arguments

`$ARGUMENTS` — the reason for parking (free text, **required**). If empty,
refuse: a park with no recorded reason is an audit hole.
`SDD_FLEET_PARK_REFUSE: {"code":2,"reason":"missing-reason"}`.

## What you do

1. **Resolve the active item.** Read `.sdd/ACTIVE`. If empty or absent, refuse —
   there is nothing to park:
   `SDD_FLEET_PARK_REFUSE: {"code":2,"reason":"no-active-item"}`.
   Verify `.sdd/<slug>/PROGRESS.md` exists; if not, refuse
   (`{"code":2,"reason":"missing-progress","feature":"<slug>"}`) — the state is
   already irregular and needs a human look, not an automated edit.

2. **Record the parked state in PROGRESS.md.** Edit `.sdd/<slug>/PROGRESS.md`:
   - Set the `PHASE:` field to `PARKED`.
   - Append a line at the end of the file:
     ```
     PARKED: <iso8601 now> — was PHASE <previous phase> — <reason verbatim>
     ```
     (Recording the pre-park phase is what makes an informed resume possible.)
   - Refresh `UPDATED:`.

3. **Release the lock via the shared script** (it verifies the slug, removes
   `.sdd/ACTIVE.lock`, and empties `.sdd/ACTIVE` without deleting it — never
   hand-empty the file). Do **not** delete `.sdd/<slug>/`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" release "<slug>"
   ```

4. **Emit the signal, then report.**
   ```
   SDD_FLEET_PARKED: {"feature":"<slug>","reason":"<reason>","was_phase":"<previous phase>"}
   ```
   Tell the user: the item is parked with its workspace intact; the in-flight
   lock is free, so `/sdd-fleet:jira-story` / `/sdd-fleet:jira-story` can start
   the next item. To resume the parked item later: re-acquire the lock —
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh" acquire "<slug>" --owner "human:resume" --now "<iso8601>"`
   — and restore the recorded pre-park `PHASE` in its PROGRESS.md (a deliberate,
   human act — there is no auto-resume).

## Hard rules

- **Never** delete or truncate anything under `.sdd/<slug>/`.
- **Never** park on your own initiative — this command exists for the human;
  the orchestrator's job when blocked is to surface the conflict
  (`item-in-flight`) and stop.
- **Headless contract.** Exactly one `SDD_FLEET_PARK*` signal line before any
  prose. A slash command cannot set a process exit code — the signal lines on
  stdout are the sole machine contract (`code` 2 = refused).
