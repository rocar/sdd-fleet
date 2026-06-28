# CONTROLS.md — v0.2 control inventory

STATUS: M0 OUTPUT
Date: 2026-05-30
Reviewers: feature-dev:code-explorer, feature-dev:code-architect, plugin-dev:plugin-validator, plugin-dev:skill-reviewer

Output of M0's gate-vs-judgment classification spike. Every v0.1 control plus every new v0.2 control gets one row. Sourced from the four-agent design review (code-explorer baseline, code-architect M1 proposal, plugin-validator structural check, skill-reviewer skill audit).

This document gates which hooks survive M1, what the new workflow script must own, and which agent/skill files need surgical edits.

## Definitions

- **Gate.** Binary, mechanically checkable rule. Either the condition holds or it doesn't; no judgment involved. Hooks are the natural enforcement layer.
- **Judgment.** Subjective convergence rule. Needs cross-examination, refutation, or human adjudication. Workflow scripts (with adversarial reviewer subagents) are the natural enforcement layer.
- **Hybrid.** A gate enforced on the output of a judgment process. Example: "concerns payload schema valid" is a gate; the payload's content was produced by judgment.

**The category error v0.2 corrects.** v0.1 had several "all-approved" rules implemented as command-layer checks or hooks. Those were gates on a judgment ("is the concern substantive?"). M1's survival-vote architecture moves the judgment into the workflow; the v0.1 binary proxy retires.

---

## v0.1 hooks (5)

| Control | Category | v0.1 location | v0.2 destination | Notes |
|---|---|---|---|---|
| `block-source-before-finalized` | Gate | PreToolUse `Write\|Edit` hook | **Unchanged** | Pure gate (is STATUS FINALIZED?). M0 probe must confirm it fires on workflow subagents — assumed yes. Critical to retain; the final backstop against any subagent drift, including workflow-spawned ones. |
| `restrict-reviewer-writes` | Gate (mis-located) | PreToolUse `Write\|Edit` hook | **Retired**; restriction moves to subagent frontmatter `tools:` allowlist | The "reviewer can't write outside `.sdd/`" rule belongs at the subagent-capability layer, not the runtime check. v0.2 reviewer subagents omit `Write`/`Edit` from their tools allowlist; the restriction enforces via tool unavailability. |
| `validate-spec-status` | Gate | PostToolUse `Write\|Edit` hook | **Unchanged** | Pure gate (STATUS valid + 8 required sections). Format check, not judgment. Fires on workflow subagent writes too. |
| `check-review-written` | Hybrid (gate on judgment) | SubagentStop hook | **Retired for workflow paths**; replaced by workflow post-condition | Hook is fail-open on subagent identity (5-key probe; missing identity → silent exit 0 — see code-explorer Finding 1). Replaced by deterministic workflow post-condition: any reviewer subagent that returns empty/malformed concerns payload halts the workflow before survival vote. Retain hook for non-workflow review paths until those retire (M4 closes this). |
| `stop-tests` | Gate | Stop hook | **Unchanged** | Pure gate (do tests pass?). Operates on parent session stop, unaffected by workflow runtime. Workflows that run tests internally will do so as a workflow phase; the Stop hook remains the final guard for non-workflow sessions. |

---

## v0.1 command-level rules

| Control | Category | v0.1 location | v0.2 destination | Notes |
|---|---|---|---|---|
| CYCLE budget (≥3 + open blocker → escalate) | Gate | `commands/review.md` body | Workflow script + envelope `escalation_payload`; scribe writes ESCALATION.md | Counter check is a gate; the **semantic** of "cycle" changes from command-invocation count to workflow-run count. Cross-examination rounds inside one workflow run do NOT bump CYCLE. |
| PROGRESS.md PHASE transition | Gate | review/finalize/handoff command bodies | Workflow returns `state_delta`; scribe applies | Mechanical field edit. Writer moves from command layer to scribe to keep workflow-internal and command-layer mutations consistent. |
| STATUS line transition (DRAFT → IN_REVIEW → FINALIZED) | Gate | review/finalize command bodies | Workflow returns `state_delta`; scribe applies | Transition rules stay deterministic; the writer changes. |
| Three-reviewer fan-out (architect + qa + coder) | Process (not a control) | `commands/review.md` parallel `Task` calls | Workflow's parallel `task()` calls | Not a gate or judgment — the orchestration pattern itself. Listed for completeness. |
| "All approved with zero blockers" convergence | **Judgment** (was mis-implemented as gate) | review.md body + sdd-protocol skill prose | Workflow's cross-examination + survival-vote logic | **The headline v0.2 reclassification.** v0.1 treated "is the spec ready?" as a binary check on reviewer status fields. v0.2 makes it a judgment with structural cross-examination. Skill prose rewrite per skill-reviewer's surgical edits. |
| ESCALATION.md creation | Gate (write-on-condition) | review/handoff command bodies | Workflow returns `escalation_payload`; scribe writes file | The file's existence IS the gate (halts subsequent workflow runs). Logic moves; semantics unchanged. |

---

## v0.1 agent-prompt rules

| Control | Category | v0.1 location | v0.2 destination | Notes |
|---|---|---|---|---|
| Severity rubric (blocker/major/minor) | Judgment vocabulary | Agent prompt bodies (duplicated) + `review-rubric` skill | Agent prompts (deduplicate, conditional on M0 probe) + skill | Duplication was necessary in agent-team mode because frontmatter didn't load skills. M0 probe must confirm whether workflow subagents load skills normally; if yes, drop duplication. |
| "Concerns must match rubric" output format | Judgment + gate-on-format | Agent prompt bodies | Agent prompt + workflow's structured-stdout schema validation | The judgment (severity assignment) stays in the agent; the format check (valid severity strings) is added to envelope schema validation. |
| "Do not approve with open blockers" | Gate disguised as judgment | Agent prompt bodies | Workflow's survival-vote logic | The v0.1 quirk that exposed the planted-blocker failure mode. v0.2 lets reviewers express judgment freely; the convergence rule lives in the workflow, not in each agent. |

---

## v0.1 skill prose rules (sdd-protocol)

| Control | Category | v0.1 location | v0.2 destination | Notes |
|---|---|---|---|---|
| State machine transitions (allowed edges) | Gate definitions | `sdd-protocol/SKILL.md` prose | Same location, updated content | Skill remains the rulebook; M1 rewrites convergence rule and CYCLE semantics per skill-reviewer's surgical edit list (lines 60–63, 86–88, 115–124, 145–160, 13–25). |
| Cycle budget bound (≤3) | Gate | sdd-protocol prose | Same location, semantics clarified | Workflow-run cycles, not command-invocation cycles. |
| Hard gates table | Gate definitions | sdd-protocol prose | Same location, hooks list pruned | Drop `restrict-reviewer-writes` and `check-review-written` from the workflow-path hard-gates list; retain notes for non-workflow paths until M4. |
| Append-only REVIEW.md | Integrity rule (gate) | sdd-protocol prose | Same location; scribe upholds in practice | Rule unchanged. Writer changes from per-role subagent to scribe; scribe must respect append-only by construction. |

---

## New v0.2 controls (introduced by workflows architecture)

| Control | Category | v0.2 location | Notes |
|---|---|---|---|
| Cross-examination round | Judgment | Workflow script | Each reviewer is prompted with all reviewers' concerns and must refute or affirm each. New judgment surface. Default 1 round per CYCLE; configurable. |
| Survival vote | Judgment + gate | Workflow script | Deterministic rule applied over judgment artifacts: concern survives unless refuted by ≥1 reviewer of a different role. Self-refutation filtered. |
| Refutation substantive-ness check | Gate on judgment output | Workflow script | Binary check on refutation prose (≥40 chars + must cite spec/acceptance section). Architect's mitigation against fluent-but-empty refutations. Threshold is heuristic — see Open issue 3. |
| Structured stdout envelope schema | Gate | Workflow script post-condition | Schema validation on the workflow's return value. Malformed envelope → command layer halts before scribe is invoked. |
| Cost ceiling declaration | Gate | Workflow JS header comment + command layer pre-flight | Each workflow declares `@cost-ceiling { input_tokens, output_tokens }` in a header comment. Command parses and emits to stdout in headless mode before workflow dispatches. Caller (Hermes) surfaces on Discord. |
| Reviewer-concerns-payload required | Gate (workflow post-condition) | Workflow script | Replaces `check-review-written` hook. Any reviewer returning empty or schema-invalid payload halts workflow before survival vote. Deterministic — no probing for subagent identity. |
| Headless-mode cost surfacing | Gate adjacent to caller | Command layer pre-flight | When detected as headless, command writes a one-line cost-summary to stdout *before* invoking workflow. Caller can refuse to proceed. Replaces the interactive launch-prompt's token caution. |
| Phase-list naming legibility | Judgment (legibility) | Workflow's `phases` array | Platform's launch-prompt shows these verbatim. Naming convention enforced by sdd-protocol rewrite: phases name (a) what reads from `.sdd/`, (b) which subagents fan out + approximate count, (c) where any source-writes happen. |
| Reviewer subagent tool allowlist (no `Write`/`Edit`) | Gate | Subagent frontmatter | Replaces `restrict-reviewer-writes` hook. Architect / qa reviewers declare `tools: Read, Grep, Glob` only. Coder dual-role is unresolved — see Open issue 1. |

---

## Open issues this inventory surfaces

1. **Coder dual-role.** v0.1's `agents/coder.md` is both a reviewer (in REVIEW phase) and a writer (in BUILD phase) with one tools allowlist. The "no Write/Edit during REVIEW" enforcement is currently the `restrict-reviewer-writes` hook. Retiring that hook in favor of frontmatter allowlists clashes with a single-file agent. CONTRACT.md must decide: (a) split into `coder-reviewer.md` + `coder-builder.md`; (b) keep one file and retain the hook for coder only; (c) the workflow spawns coder with explicit tool override at task time (if the platform supports per-`task()` tool restriction).

2. **`check-review-written` partial retention.** Hook retires for workflow paths but stays for non-workflow paths until M4 routes everything through workflows. CONTRACT.md must specify how the hook detects "this is a workflow path" — likely by reading PROGRESS.md PHASE plus a workflow-active marker. Or it stays passively as belt-and-suspenders when the workflow's post-condition catches missing payloads first.

2a. ~~**`Workflow` tool input/output schema is not publicly documented.**~~ **RESOLVED.** SDK source inspection (`@anthropic-ai/claude-agent-sdk@0.3.158`, `sdk-tools.d.ts` lines 2267–3139) confirmed both `WorkflowInput` and `WorkflowOutput` schemas. Reproduced in CONTRACT.md §1. The runtime globals (`agent()`, `parallel()`, `pipeline()`, `phase()`, `args`) are documented by name in the SDK comment but their full signatures are runtime-injected by the Claude Code binary — verify-at-M1 spike inspects a real `/deep-research` raw script.

2b. ~~**Plugin-shipped workflow distribution path is undocumented.**~~ **RESOLVED.** `WorkflowInput.scriptPath` takes precedence over `script` and `name`. v0.2 commands invoke the Workflow tool with `scriptPath: ${CLAUDE_PLUGIN_ROOT}/workflows/<name>.js`. Auto-discovery of plugin-shipped workflows by `name` remains an open empirical question but is no longer a v0.2 blocker — the `scriptPath` pattern works regardless. The `workflows/hello.js` probe was deleted in the 2026-06 audit remediation; its findings are preserved in `docs/v0.2/hello-probe.md`.

3. **Refutation substantive-ness threshold.** The >40-char + section-citation rule is a heuristic, not a proof. CONTRACT.md declares this a *tunable*, not a constant, and reserves the right to revise based on M1 dry-run findings.

4. **Skill load behavior under workflow.** Whether workflow subagents load skills (so we can deduplicate the severity rubric) depends on the M0 empirical probe + the `/deep-research` raw script inspection. If skills don't load, rubric duplication stays; if they do, we deduplicate per the skill-reviewer recommendation.

---

## Resolved during M0

- **Cycle-3 agent-team fallback.** The agent-team promotion at CYCLE 3 in `/sdd-fleet:feature-dev` was conditional on `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. M1's survival-vote architecture replaces it outright; v0.2 Phase 5 cleanup removes the README env-var step and the fallback branch. **Confirmed deleted at M0 — not an open issue.**

- **Workflows are SDK-side, not plugin-auto-discovered.** Per `/en/agent-sdk/subagents`, workflows are invoked via the `Workflow` tool (TypeScript Agent SDK v0.3.149+). The plugin-components reference (`/en/plugins-reference`) has zero mentions of workflows. The workflows doc itself only auto-discovers from `.claude/workflows/` (project) and `~/.claude/workflows/` (personal). The implication: plugin-shipped workflow `.js` files are *static assets*; the entry point is a plugin's slash command whose body invokes the `Workflow` tool with the script. v0.2 distribution path follows this pattern — not "drop a file in `workflows/` and let auto-discovery do the work."

- **Subagent definitions inside workflows follow the documented `AgentDefinition` schema** (`/en/agent-sdk/subagents` § AgentDefinition configuration). Fields: `description`, `prompt`, `tools`, `disallowedTools`, `model`, `skills`, `memory`, `mcpServers`, `maxTurns`, `background`, `effort`, `permissionMode`. Critically: subagents define `skills: string[]` to preload skills — answering Open issue 4: workflow subagents CAN load skills, so the v0.1 rubric duplication can be retired in v0.2 by setting `skills: ["review-rubric"]` on the reviewer subagents.

- **Subagents cannot spawn their own subagents.** Documented constraint. The scribe pattern works because the scribe is a peer of the reviewers, both spawned by the workflow script — not a sub-subagent of a reviewer.

---

## What this gates

**CONTROLS.md as written gates:**
- M1 hook retirement list (3 of 5 v0.1 hooks survive intact; 2 retire for workflow paths).
- M1 workflow script's required post-conditions (envelope schema, reviewer-payload presence, refutation substantive-ness).
- The scribe subagent's exclusive write authority over PROGRESS.md and REVIEW.md.
- The sdd-protocol skill rewrite scope (per skill-reviewer's surgical edits).

**CONTROLS.md does NOT decide:**
- The exact workflow JS API surface (waiting on `/deep-research` raw script inspection).
- Plugin packaging for `workflows/<name>.js` discovery (resolved by the hello.js empirical probe — findings preserved in `docs/v0.2/hello-probe.md`).
- The coder dual-role resolution (Open issue 1).
- The reviewer-skill-load behavior (Open issue 4).

These are CONTRACT.md's job once the probes return.
