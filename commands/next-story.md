---
description: Resolve and gate the next ready story of an epic — the developer pull entry over the conductor's ready-frontier core
allowed-tools: Read, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-story.sh":*)
---

# /sdd-fleet:next-story

You are the **orchestrator**, running at the **workspace root** (the superproject
whose `.sdd/_epic/` holds the epics). The runtime rulebook is the `sdd-protocol`
skill (`references/workspace-tier.md`). This is the epic-tier analog of
`/sdd-fleet:next-feature` — the **developer pull entry** ADR-0001 anticipated: it
resolves the next **ready** story of an epic (one whose consumed contracts are all
published *now*), and emits a dispatch signal — collapsing the manual "run a
conductor sweep → read the frontier → type `/sdd-fleet:jira-story <key>`" into one
focused, gated step.

**It is convenience, not a second conductor.** It uses **only** the deterministic
resolver (`scripts/next-story.sh`, which reuses the conductor's own
`ready-frontier.sh` set-logic core and the live Jira snapshot — the pull entry and
the autonomous conductor can never disagree about readiness). It never reorders,
skips, or judges importance — the pick is the sorted frontier's first story. It is
**read-only against Jira**: it never transitions a story (the status advance
happens when `/sdd-fleet:jira-story` actually starts it) and never creates one.

**It does NOT run `/sdd-fleet:jira-story` itself.** This command resolves + gates
+ signals; the **dispatcher** starts the story — the upstream caller in headless
mode, you (telling the user) in interactive mode. Starting a story happens in the
target member repo, not here.

## Arguments

`$ARGUMENTS` — `<epic-slug>` (the `_epic/<slug>` directory name). If empty, refuse:

```
SDD_FLEET_NEXT_STORY_REFUSE: {"code":2,"reason":"missing-epic"}
```

## What you do

1. **Resolve the next ready story.** Run the shared resolver (the single source of
   truth; do not re-derive readiness in prose), supplying `--now` yourself (the
   script reads no clock):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/next-story.sh" "<epic-slug>" --now "<iso8601 now>"
   ```
   Branch on its `status`:
   - `next` → continue to step 2 with the resolved `story` / `key` / `repo`.
   - `waiting` → nothing is ready *now*: `not_started` stories are blocked on
     unpublished contracts and `in_flight` stories are already claimed
     (DISPATCHED / in progress). This is informational, not an error — an
     in-flight story's HANDOFF publishes the contract that releases the blocked
     ones. Emit
     `SDD_FLEET_NEXT_STORY: {"status":"waiting","not_started":<n>,"in_flight":<m>,"done":<d>,"total":<t>}`.
   - `complete` → every materialised story is done — the epic is complete
     (derived, exactly as `workspace-tier.md` defines it; there is no terminal
     stored phase). Congratulate. Emit
     `SDD_FLEET_NEXT_STORY: {"status":"complete","done":<n>,"total":<n>}`.
   - `empty` → the epic has no materialised stories in Jira. Refuse and point at
     `/sdd-fleet:epic-ratify` (materialisation is its deterministic step). Emit
     `SDD_FLEET_NEXT_STORY_REFUSE: {"code":2,"reason":"empty-epic"}`.
   - `not-materialised` → no `JIRA_LINK.md` epic key — the epic was never
     materialised into Jira. Refuse; the path is `/sdd-fleet:epic-plan` →
     `/sdd-fleet:epic-ratify`. Emit
     `SDD_FLEET_NEXT_STORY_REFUSE: {"code":2,"reason":"not-materialised"}`.
   - `deferred` → the Jira adapter is absent or unconfigured; readiness cannot be
     resolved without the live story set. Refuse and name the fix
     (`SDD_JIRA_DRYRUN=1` to preview, or `SDD_JIRA_LIVE=1` + `JIRA_*` creds). Emit
     `SDD_FLEET_NEXT_STORY_REFUSE: {"code":2,"reason":"<no-jira-adapter|jira-adapter-unconfigured>"}`.
   - `snapshot-error` / `frontier-error` → the live read failed. Refuse. Emit
     `SDD_FLEET_NEXT_STORY_REFUSE: {"code":1,"reason":"<snapshot-error|frontier-error>"}`.

2. **Emit the dispatch signal and hand off.** The story is ready — every contract
   it consumes is published. Emit exactly one line:
   ```
   SDD_FLEET_NEXT_STORY: {"status":"next","epic":"<slug>","story":"<id>","key":"<jira-key>","repo":"<repo>","ready":<n>}
   ```
   Then tell the **dispatcher** the next move — **do not run it here**:
   - **Interactive:** "Next ready story is `<story>` (`<key>`) in repo `<repo>` —
     `<ready>` story(ies) ready in total. **Nothing is started yet — this command
     only resolves and gates.** In that member repo, run
     `/sdd-fleet:jira-story <key>` to begin — it reads the Jira story as its
     starting context and syncs the story's Jira status as it advances."
   - **Headless:** the upstream caller reads `SDD_FLEET_NEXT_STORY` and dispatches
     `/sdd-fleet:jira-story <key>` in the target repo itself.

## Hard rules

- **No prioritization policy.** Resolver only; the pick is the sorted frontier's
  first story — never reorder/skip/judge importance. Any real prioritization is
  the human's: start a different ready story directly.
- **Read-only.** Never transition or create a Jira story here — this command is
  not a second conductor; the ADR-0001 boundary stands. The status advance is
  `/sdd-fleet:jira-story`'s phase sync.
- **Never run `/sdd-fleet:jira-story` inline** — the dispatcher does that, in the
  target member repo (this command runs at the workspace root; the story runs in
  its repo).
- **Headless contract.** Every branch emits exactly one `SDD_FLEET_NEXT_STORY*:`
  line before any prose.

## Refusal contract (machine-readable)

A slash command runs inside the model session and **cannot set a process exit
code** — the session exits 0 either way. The `SDD_FLEET_NEXT_STORY*` signal lines
on stdout are the **sole machine contract**: `SDD_FLEET_NEXT_STORY` (status
`next` / `waiting` / `complete`) = resolved or informational no-op; `_REFUSE` =
refused, the JSON carrying `"code"` (an integer preserving the legacy exit-code
semantics: `2` = refused precondition, `1` = live-read error) and `"reason"` (a
kebab-case slug). Orchestrators dispatch on the signal line, never on the process
exit status.
