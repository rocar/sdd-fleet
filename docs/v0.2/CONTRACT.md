# CONTRACT.md — v0.2 workflow ↔ command-layer contract

STATUS: M0 OUTPUT (+ Phase 6 empirical corrections appended below)

## Phase 6 FINAL: install validation — GAP CLOSED (2026-05-30)

sdd-fleet installed from `https://github.com/rocar/sdd-fleet.git` via
`/plugin marketplace add` + `/plugin install sdd-fleet`. `/agents` then listed
all 7 role agents:
`sdd-fleet:architect (opus)`, `classifier (sonnet)`, `coder (sonnet)`,
`devops (sonnet)`, `architect (opus)`, `qa (sonnet)`, `scribe (sonnet)`.

This closes the one remaining Phase 6 gap: **`agentType: sdd-fleet:*` resolves
when the plugin is installed.** The workflow scripts' fan-out (`agentType:
sdd-fleet:architect|qa|coder`) and apply (`agentType: sdd-fleet:scribe`)
calls will therefore bind to the real role/scribe prompts in production —
the only thing the dev-session stripped-variant validation couldn't exercise.

Install transport note: the `owner/repo` shorthand resolves to SSH; on a machine
without a GitHub SSH key, use the full HTTPS URL (or a local path) with
`/plugin marketplace add`. Documented in README.

v0.2 status: **fully validated.** M1 review pipeline end-to-end (live), M3
deep-build orchestration + violation detection (live), hooks matrix (live),
and now agentType resolution on real install. The dedicated-scribe apply path
and tests-green-on-real-install are the natural first dogfood run, not a
validation blocker — the mechanism is proven.

---

## v0.2.1 full-cycle validation — CLOSED (2026-05-31, bf-smoke)

The complete SDD pipeline ran clean end-to-end on a real marketplace install
(plugin v0.2.1, project `~/build-projects/bf-smoke`, feature `celsius-converter`,
a pure `to_fahrenheit` library). This closes the last validation gap noted above:
the live agents executing the full state machine, not just resolving by name.

| Phase | Outcome |
|---|---|
| SPEC | Skeleton spec drafted (trivial fast-path) |
| REVIEW | Skipped (TIER=trivial) |
| FINALIZE | Spec → FINALIZED |
| BUILD | qa wrote **10 failing tests first**, then coder implemented to green |
| CHANGE_REVIEW | CHANGE_CYCLE 1 — architect + PO + qa reviewed the diff |
| HANDOFF | devops shipped (`.github/workflows/ci.yml`, CHANGELOG entry) |

Final state: spec `STATUS: FINALIZED`, `PHASE: HANDOFF`, `CHANGE_CYCLE: 1`,
final test run **`10 passed in 0.01s`**.

What this proves that no prior validation could:

- **M2 tests-first BUILD, live.** qa authored a failing suite before coder
  wrote any source; coder implemented to green; the Stop hook then ran a real
  (passing) suite. The 0.2.1 deadlock fix holds *and* the gate still has teeth.
- **Dedicated `sdd-fleet:scribe` apply path works.** Every `.sdd/` mutation
  across BUILD/CHANGE_REVIEW landed through the real scribe agent — the one
  thing the dev-session agentType-stripped variant could not exercise.
- **All 7 agents resolved and performed their roles** on a real install:
  classifier → PO → qa → coder → architect+PO (change-review) → devops.
- **CHANGE_REVIEW discriminates, not rubber-stamps.** All three reviewers
  independently flagged the `bool` pass-through (`to_fahrenheit(True) → 33.8`,
  since `bool` subclasses `int`) as advisory `[minor]` — a correct, subtle
  catch surfaced without blocking. Recommended follow-up: pin the `bool`
  behavior with a regression test before tightening the type guard.
- **Both 0.2.1 fixes confirmed live:** `new-feature` stops and asks for the
  feature description when none is in context; the SPEC phase no longer
  deadlocks on the empty-suite Stop hook.

---

## Phase 6 empirical findings (2026-05-30, Claude Code 2.1.158)

Grounding the workflow scripts against the LIVE runtime (Workflow tool, claude
2.1.158) surfaced corrections to the M0 assumptions. Both are now fixed in
`workflows/review.js` and `workflows/deep-build.js`.

1. **`args` is delivered to the script as a JSON STRING, not a parsed object.**
   M0's CONTRACT assumed `args.feature` worked directly. It does not — `typeof
   args === "string"`. Every workflow script must normalize:
   `const A = typeof args === "string" ? JSON.parse(args) : (args || {});`
   This would have broken 100% of workflow runs. Confirmed via an instrumented
   guard that dumped `typeof args`.

2. **`agentType: "<plugin>:<role>"` resolves ONLY when the plugin is installed.**
   In a dev session (editing plugin source in cwd, plugin not installed), the
   role agents `sdd-fleet:architect|qa|coder|scribe` are absent from the agent
   registry — the workflow errors with "agent type not found." In production the
   user installs sdd-fleet via `/plugin install` (or `--plugin-dir` at launch)
   and the agents resolve. IMPLICATION for headless: a `claude -p --plugin-dir
   <path>` invocation must load the plugin for in-workflow agentType resolution;
   confirm during headless validation.

3. **Workflow script body executes as an async function** (top-level `await` and
   top-level `return` are both legal). `node --check --input-type=module` gives
   a false "Illegal return statement" — validate with an AsyncFunction-wrapper
   parse check instead (see Phase 6 validation notes).

4. **`meta` must be a pure literal**; the runtime rejects computed values. Cost
   ceiling therefore lives in a `// @cost-ceiling {...}` header comment that the
   command layer parses, NOT in a `meta.estimatedCost` field (which M0 had
   proposed and would have been rejected).

5. **No `Date.now()` / `Math.random()` / argless `new Date()`** in scripts — they
   throw (would break resume). Timestamps are passed in via `args.now`, supplied
   by the dispatching command.

### Phase 6 LIVE END-TO-END RESULT (review workflow)

Ran `workflows/review.js` against a live `smoke-review` feature (STATUS=IN_REVIEW,
4 ACs). Result: **completed, 7 agents, verdict=clean, 9 concerns, 0 surviving
blockers, 195s, 173k subagent tokens.** Verified:
- scribe deleted `.workflow-in-flight`;
- scribe applied `state_delta` to PROGRESS.md;
- scribe appended 3 role-attributed cycle-1 blocks to REVIEW.md (append-only respected);
- structured-output schema validation held across all 7 agents;
- **cross-examination + survival vote worked on real output** — the architect
  refuted two peer concerns (qa's non-ASCII gap, coder's non-str gap) with
  spec-citing reasoning; the survival vote annotated both `refuted-by: architect`.

Note: the live run used an `agentType`-stripped variant because the role agents
(`sdd-fleet:architect|qa|coder|scribe`) only resolve when the plugin is
installed in the dispatching session. Production scripts retain `agentType`;
this only changes which system prompt each reviewer receives, not the pipeline.

**Observation (verdict vs. majors):** the workflow verdict gates only on surviving
*blockers*. The smoke run had 2 surviving `[major]` coverage gaps yet returned
`verdict=clean` → `next: /sdd-fleet:feature-dev`. This is correct by design — the
finalize gate (not the review verdict) is what refuses on `majors-without-adr`.
Minor UX wart: a user sees "clean → finalize" then finalize refuses on the
majors. Acceptable for v0.2; candidate for a verdict-includes-majors refinement
in a later pass.

### Phase 6 deep-build workflow — LOGIC validated; scribe-apply is harness-dependent

Ran `workflows/deep-build.js` against a live `smoke-build` feature (STATUS=FINALIZED,
BUILD_MODE=deep-build, 2 modules + 2 failing tests). The completed run (6 agents,
188k tokens, 452s) returned:
`{verdict:"clean", partitions:["strutil-slugify","numutil-clamp"],
surviving_concerns:9, surviving_blockers:0, violations:2, next:["/sdd-fleet:pr-review"]}`.

Confirmed working (the workflow logic, end to end):
- architect produced a clean 2-way partition (strutil-slugify / numutil-clamp);
- the partition file-overlap gate passed at plan time (disjoint declared files);
- 2 coders fanned out in parallel and WROTE REAL SOURCE (`strutil.py`,
  `numutil.py` with plausible implementations);
- **the post-hoc partition-violation detector FIRED CORRECTLY (violations:2)** —
  it caught that both coders wrote to paths (`.sdd/smoke-build/*.py`) outside
  their declared partition file lists, logged each, and folded them in as
  synthetic `[major]` concerns. This is exactly the M3-review hardening from
  Phase 3 working on real output;
- adversarial review (architect + qa) plus the 2 synthetic violation-majors gave
  9 concerns / 0 blockers → verdict `clean` (majors don't block the verdict; the
  finalize/handoff gate is where majors are adjudicated);
- the workflow returned the correct structured verdict and next-command.

The one apply-phase miss, and its true cause:
- **The scribe-apply effects did not land** — `.workflow-in-flight` still present,
  IMPL_NOTES.md not appended, PROGRESS.md `UPDATED` unchanged. Root cause: the
  **agentType-stripped validation harness**. With `agentType: sdd-fleet:scribe`
  removed, the scribe call went to a *generic* workflow agent carrying only the
  one-line inline prompt "apply this envelope per agents/scribe.md" — a generic
  agent does not reliably load and execute scribe.md's procedure. (In the M1
  review run the same generic-scribe path *happened* to perform its writes;
  here it did not — generic-agent scribe behavior is non-deterministic, which is
  exactly the argument FOR the dedicated `sdd-fleet:scribe` agentType in
  production.) The deep-build script itself is not implicated: it produced the
  correct envelope and returned the correct verdict.
- Note the irony that closes the loop: the coders' write-to-`.sdd/` mistake is the
  SAME generic-agent-without-its-real-prompt effect — and the workflow's own
  violation detector caught it. The machinery is sound; the stripped harness is
  what produced the off-spec agent behavior, and the machinery flagged it anyway.
- **Tests-green not demonstrated for deep-build:** coders wrote modules under
  `.sdd/smoke-build/` and the scaffold nested tests at `.sdd/<feature>/tests/`
  with no PYTHONPATH root, so pytest couldn't import them. This is a scaffold
  artifact (my unrealistic test layout) compounded by the coder prompt not
  pinning an explicit write-root. Real finding: **the deep-build coder prompt
  should pin a write-root** (Phase 5-style hardening item, now logged).

PROCESS ERROR (recorded honestly): I deleted `.sdd/` in the same cleanup batch
as the inspection, before retrieving the completion notification — destroying the
live evidence. The verdict was recoverable only via TaskOutput. Lesson: do not
clean up transient validation state until the run's completion is confirmed and
its artifacts inspected.

Net: deep-build's orchestration logic — partition, fan-out, overlap gate,
violation detection, adversarial review, verdict — is validated against the live
runtime. The **dedicated-scribe apply path and the tests-green property remain to
be confirmed with the plugin actually installed** (so `agentType: sdd-fleet:*`
resolves to the real role/scribe prompts). This is the same single remaining
integration gap as M1's: install sdd-fleet, then run review + deep-build with
real agentTypes and confirm scribe writes + green tests.

### Hardening item logged from this run
The deep-build coder prompt should pin an explicit project-root write target (and
the standard-BUILD coder prompt likewise), so coders never write modules into the
`.sdd/` workspace. The violation detector catches it after the fact; pinning the
write-root prevents it. → Phase 5 / M3.1 hardening backlog.

### Phase 6 hook matrix (live)

- `block-source-before-finalized`: STATUS=IN_REVIEW + source write → exit 2 (blocked) ✓;
  write inside `.sdd/` → exit 0 ✓; STATUS=FINALIZED + source write → exit 0 (lifted) ✓.
- `restrict-reviewer-writes` + `check-review-written`: `.workflow-in-flight` present → exit 0
  (bypassed) ✓ — confirms the workflow-marker bypass.

### Phase 6 NOT validated (environment-bound)

- **In-workflow `agentType` role resolution.** Validated with an agentType-stripped
  variant (default workflow agent + role-in-prompt). Production scripts retain
  `agentType: sdd-fleet:<role>`; resolution requires the plugin be installed in
  the dispatching session. The stale `sdd-fleet-inline` install in this dev box
  did not expose the role agents to the workflow registry — a real prod install
  (`/plugin install` or `claude --plugin-dir`) is the remaining integration check.
- **Headless `claude -p` parity.** Deferred — same `agentType`/install dependency;
  validate once the plugin installs cleanly.

---

STATUS: M0 OUTPUT
Date: 2026-05-30
Grounded against: `@anthropic-ai/claude-agent-sdk@0.3.158` (TypeScript SDK + Claude Code binary 2.1.158)
Companion: `CONTROLS.md` (gate-vs-judgment inventory)

This document is the spec that gates M1 implementation. Every section is either:
- **CONFIRMED** — verified against SDK `.d.ts` files at v0.3.158, or against published `AgentDefinition` docs.
- **DECIDED** — design choice that closed an M0 open question.
- **VERIFY-AT-M1** — assumption that M1's implementation kickoff spike must validate before code is locked.

---

## 1. Workflow tool invocation pattern (CONFIRMED schemas)

v0.2 commands invoke workflows by calling the SDK-provided `Workflow` tool. The schemas are reproduced verbatim from `sdk-tools.d.ts`:

### `WorkflowInput` (CONFIRMED, from `sdk-tools.d.ts:2267`)

```ts
export interface WorkflowInput {
  /**
   * Self-contained workflow script. Must begin with
   * `export const meta = { name, description, phases }` (pure literal, no
   * computed values) followed by the script body using
   * agent()/parallel()/pipeline()/phase().
   */
  script?: string;

  /**
   * Name of a predefined workflow (built-in or from .claude/workflows/).
   * Resolves to a self-contained script.
   */
  name?: string;

  /** Ignored — set the workflow description in the script's `meta` block. */
  description?: string;

  /** Ignored — set the workflow title in the script's `meta` block. */
  title?: string;

  /**
   * Optional input value exposed to the script as the global `args`, verbatim.
   * Pass arrays/objects as actual JSON values, NOT as a JSON-encoded string —
   * a stringified list breaks `args.filter`/`args.map` in the script.
   */
  args?: { [k: string]: unknown };

  /**
   * Path to a workflow script file on disk. Every Workflow invocation persists
   * its script under the session directory and returns the path in the tool
   * result. To iterate, edit that file with Write/Edit and re-invoke Workflow
   * with the same `scriptPath` instead of re-sending the full script.
   * Takes precedence over `script` and `name`.
   */
  scriptPath?: string;

  /**
   * Run ID of a prior Workflow invocation to resume from. Completed agent()
   * calls with unchanged (prompt, opts) return their cached results instantly;
   * only edited or new calls re-run. Same-session only.
   */
  resumeFromRunId?: string;
}
```

### `WorkflowOutput` (CONFIRMED, from `sdk-tools.d.ts:3111`)

```ts
export interface WorkflowOutput {
  status: "async_launched" | "remote_launched";
  taskId: string;
  /** Local workflow run identifier for resumeFromRunId. */
  runId?: string;
  summary?: string;
  /** Directory where subagent transcripts are written during execution. */
  transcriptDir?: string;
  /** Path to the persisted workflow script for this invocation. */
  scriptPath?: string;
  /** CCR session URL when status is remote_launched. */
  sessionUrl?: string;
  warning?: string;
  /** Set if syntax check failed. */
  error?: string;
}
```

### Key implications

- **Workflows are async.** The Workflow tool returns immediately with `taskId` + `runId`. The actual run happens in the background. **Caller obtains results by polling `TaskOutput`/`TaskGet`/`TaskList`** (VERIFY-AT-M1 — exact tool names) until the workflow completes, then reading transcripts from `transcriptDir`.
- **`scriptPath` is the v0.2 distribution lever.** Plugin-shipped workflows live at `${CLAUDE_PLUGIN_ROOT}/workflows/<name>.js`; commands invoke the Workflow tool with `scriptPath` set. This avoids depending on plugin-side auto-discovery (undocumented).
- **The runtime persists every invocation's script** under the session dir. Edit-and-resume via `Write/Edit` on the returned `scriptPath` is a first-class iteration path.

---

## 2. Workflow script shape

### Required top-of-file (CONFIRMED structure):

```js
export const meta = {
  name: "review",
  description: "SDD spec review: fan-out → cross-examination → survival vote",
  phases: [
    "Read active feature state from .sdd/<feature>/",
    "Fan out reviewer subagents (architect · qa · coder) — 3 subagents",
    "Cross-examination: each reviewer challenges peers' concerns — 3 subagents",
    "Survival vote: retain concerns not refuted by cross-examination",
    "Apply state delta via scribe (1 subagent)",
  ],
};
// @cost-ceiling { "inputTokens": 120000, "outputTokens": 30000 }
// (cost lives in this header comment, NOT in meta — see §7)
```

The `meta` block must be a pure literal — no computed values. The runtime parses it before executing the script body. The `phases` array is shown verbatim in the launch prompt.

### Script body runtime globals

Names confirmed in `sdk-tools.d.ts:2269,2295`; **full signatures NOT in SDK type defs** — runtime-injected by the Claude Code binary:

| Global | Purpose | Signature (VERIFY-AT-M1) |
|---|---|---|
| `agent(...)` | Spawn a subagent | likely `agent(name: string, opts: AgentDefinitionLike) → Promise<AgentResult>` |
| `parallel(...)` | Fan out subagents | likely `parallel(...calls)` or `parallel(calls[])` |
| `pipeline(...)` | Chain stages | likely `pipeline(stage1, stage2, ...)` |
| `phase(...)` | Declare/wrap a phase boundary (likely controls what the launch-prompt phase tracker shows) | likely `phase(name, async () => { ... })` |
| `args` | Global containing the `WorkflowInput.args` value | confirmed as a global, structure passes through verbatim |

**M1 kickoff spike (mandatory before authoring `workflows/review.js`):**
1. Run `claude` in a scratch dir (use SDK-shipped binary at `~/tmp/bf-v0.2-sdk-probe/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude` if your installed Claude lacks workflows).
2. Trigger `/deep-research <something cheap>`.
3. At the approval prompt, press `Ctrl+G` to view the raw script in your editor.
4. Capture verbatim: `agent()`, `parallel()`, `pipeline()`, `phase()` call sites. Confirm signatures.
5. Update this CONTRACT.md §2 with confirmed signatures before writing M1 code.

### Subagent definitions inside the workflow

Workflow subagents follow the documented `AgentDefinition` schema (`/en/agent-sdk/subagents`):

| Field | Required | v0.2 usage |
|---|---|---|
| `description` | yes | Match the v0.1 frontmatter description |
| `prompt` | yes | System prompt body (copy v0.1 agent body) |
| `tools` | no | **Reviewer agents: `["Read","Grep","Glob"]` — no `Write`/`Edit`. This replaces the `restrict-reviewer-writes` hook.** |
| `disallowedTools` | no | Belt-and-suspenders if needed |
| `model` | no | `opus` for architect, `sonnet` for qa/coder/scribe |
| `skills` | no | **`["review-rubric"]` on reviewer agents — preloads the rubric so prompt bodies no longer duplicate it.** Resolves CONTROLS.md Open issue 4. |
| `memory` | no | omit (workflow subagents are stateless within a run) |
| `mcpServers` | no | omit unless a future v0.2 milestone needs one |
| `maxTurns` | no | bound at e.g. 10 to prevent runaway reviewers |
| `permissionMode` | no | `acceptEdits` is default for workflow subagents; explicit set not required |

> Constraint (CONFIRMED, `/en/agent-sdk/subagents`): *Subagents cannot spawn their own subagents.* Scribe and reviewers are peers under the workflow script — never nested.

---

## 3. State writer pattern (DECIDED — scribe subagent)

The workflow script cannot access the filesystem directly. State mutations to `.sdd/<feature>/` happen via a peer-spawned scribe subagent.

### Why scribe (not return-and-apply):
- Workflow returns an async handle, not a synchronous result. Pushing state mutation into the command body means the command must poll for completion and then apply; scribe applies in-band before the workflow's `transcriptDir` is read.
- Scribe's writes are auditable in the transcript trail; return-and-apply hides them in the command body.
- Scribe's tool allowlist (`Read, Write, Edit`) is more restrictive than the orchestrator command's tool surface — better blast-radius containment.

### `agents/scribe.md` (DECIDED frontmatter):

```yaml
---
name: scribe
description: >
  Write-only state applier. Receives a structured JSON delta from a workflow
  script and applies it to PROGRESS.md and REVIEW.md. Invoked as the final
  phase of any v0.2 workflow that mutates SDD state. Never interprets the
  delta — only applies it faithfully.
tools: Read, Write, Edit
model: sonnet
---
You are the Scribe. You receive a JSON delta block as your only input.

Apply it exactly:
1. For each key in `state_delta`: edit the matching field in
   .sdd/<feature>/PROGRESS.md (in-place field edit, preserve other fields).
2. For each item in `review_entries`: append verbatim to
   .sdd/<feature>/REVIEW.md (append-only — never modify existing entries).
3. If `escalation_payload` is non-null: write
   .sdd/<feature>/ESCALATION.md with the payload's content.
4. Confirm in one sentence what you wrote.

Do not invent content. Do not reformat. Do not edit any other file. If the
JSON is malformed, halt and say "SCRIBE_ERROR: malformed delta".
```

### Workflow → scribe flow (review workflow example):

```
workflow review.js
  ├── phase("Read active feature state from .sdd/<feature>/")
  │     → agent("read-state", { tools: ["Read"], prompt: "..." })
  │     ← state object (feature, cycle, spec_status, phase)
  │
  ├── phase("Fan out reviewer subagents")
  │     → parallel(
  │         agent("architect", { tools:["Read","Grep","Glob"], skills:["review-rubric"], ... }),
  │         agent("qa",        { tools:["Read","Grep","Glob"], skills:["review-rubric"], ... }),
  │         agent("coder",     { tools:["Read","Grep","Glob"], skills:["review-rubric"], ... })
  │       )
  │     ← three concerns payloads
  │
  ├── phase("Cross-examination")
  │     → parallel(
  │         agent("architect-xa", { ... }),
  │         agent("qa-xa",        { ... }),
  │         agent("coder-xa",     { ... })
  │       )
  │     ← refutations
  │
  ├── phase("Survival vote")  // pure script logic, no agent
  │     ← surviving concerns + verdict (clean/revise/escalate)
  │
  └── phase("Apply state delta via scribe")
        → agent("scribe", { tools:["Read","Write","Edit"], prompt: "<envelope JSON>" })
        ← scribe confirms write
```

The script ends after scribe confirms. Transcripts persist in `WorkflowOutput.transcriptDir`.

---

## 4. PROGRESS.md ownership + schema changes

### Ownership (CONFIRMED for v0.2)

| Writer | When |
|---|---|
| `commands/new-feature.md` (direct edit) | Initial scaffold; first PROGRESS.md creation |
| Scribe subagent (via workflow envelope's `state_delta`) | All in-workflow phase + cycle bumps |
| `commands/finalize.md` (direct edit) | STATUS=FINALIZED, PHASE=BUILD transition (non-workflow command) |
| `commands/handoff.md` (direct edit) | PHASE=HANDOFF after CHANGE_REVIEW workflow returns |

### Schema (CYCLE semantics changed in v0.2)

```
FEATURE: <slug>
PHASE: <SPEC|REVIEW|FINALIZED|BUILD|CHANGE_REVIEW|HANDOFF|ESCALATED>
CYCLE: <int>            # v0.2: number of REVIEW Workflow invocations; cross-examination rounds inside one workflow do NOT bump CYCLE
CHANGE_CYCLE: <int>     # v0.2: number of CHANGE_REVIEW Workflow invocations
UPDATED: <ISO 8601>
BUILD_MODE: <standard|deep-build>   # NEW v0.2 field, set by M4 routing classifier; absent for v0.1-style features
```

Open: `BUILD_MODE` lands in M4. Until then, treat absent field as `standard`.

---

## 5. `.sdd/<feature>/` file ownership matrix (CONFIRMED for v0.2)

| File | Workflow-mutated? | Writer (v0.2) | Append-only? |
|---|---|---|---|
| `spec.md` | No | PO subagent (direct from command, not workflow) | No |
| `acceptance.md` | No | PO subagent | No |
| `PROGRESS.md` | Yes (via scribe) | scribe (workflow phases), commands (non-workflow phases) | No |
| `REVIEW.md` | Yes (via scribe) | scribe | **Yes** |
| `DECISIONS.md` | Maybe (ADR-emitting reviewer phase) | architect subagent (inside workflow, via dedicated `agent("architect-adr",...)` call) | **Yes** |
| `TEST_PLAN.md` | No (M2 makes this BUILD-phase, qa subagent direct) | qa subagent | No |
| `IMPL_NOTES.md` | No (BUILD phase, coder direct) | coder subagent | Append semantically |
| `ESCALATION.md` | Yes (when survival vote escalates) | scribe (writes once on escalation_payload) | Write-once |

**M3 (deep-build) adds:** `PARTITION_PROGRESS.md` for per-coder progress tracking, scribe-mutated.

---

## 6. Structured envelope schema (DECIDED — v0.2 NEW control)

Every workflow's *final phase* produces this envelope and passes it to the scribe. The envelope is the contract between workflow internals and state mutation:

```jsonc
{
  "build_fleet_version": "0.2",       // string — schema version guard
  "feature": "my-feature",            // string — subject slug (feature from .sdd/ACTIVE; product slug for product-scope)
  "workspace_dir": null,              // string | null — v0.4 M3.0. Directory the scribe writes to. null/absent ⇒ ".sdd/<feature>/" (feature scope, v0.2 behavior). ".sdd/_product/" for product-scope workflows (plan-review). Generalizes the scribe off the hardwired feature dir; absent ⇒ byte-identical v0.2 behavior.
  "run_id": "review-<slug>-c2-<iso>", // string | null — v0.6 marker ownership. The token the dispatching command wrote into .sdd/<...>/.workflow-in-flight. The scribe deletes the marker ONLY if its content still matches this value; null (legacy) ⇒ best-effort unconditional removal.
  "phase": "REVIEW",                  // string — PROGRESS.md PHASE value at run-start
  "cycle": 2,                         // int — CYCLE value AFTER this run's increment
  "verdict": "clean|revise|escalate", // string — terminal outcome of survival vote
  "surviving_concerns": [             // array — concerns that survived cross-examination
    {
      "id": "arch-1",                 // string — stable within-run ID
      "severity": "blocker|major|minor",
      "raised_by": "architect",
      "text": "...",
      "refuted": false,
      "refuted_by": null,             // string | null — reviewer role that refuted it
      "refutation_reason": null       // string | null — prose from cross-examination
    }
  ],
  "review_entries": [                 // array — verbatim REVIEW.md blocks scribe appends
    "## Cycle 2 — architect — 2026-05-30T...\n- [blocker] ...\nstatus: concerns-raised"
  ],
  "state_delta": {                    // object — fields scribe writes to PROGRESS.md
    "PHASE": "REVIEW",
    "CYCLE": 2,
    "UPDATED": "2026-05-30T..."
  },
  "next_legal_commands": ["/sdd-fleet:feature-dev"],  // string[] — caller UX hint
  "estimated_cost_actual": {          // object — actual vs declared ceiling
    "input_tokens": 118432,
    "output_tokens": 27991
  },
  "escalation_payload": null          // object | null — populated only if verdict=escalate
}
```

#### Product-scope variant (v0.4 M3.1 — `plan-review`)

`workflows/plan-review.js` emits the same envelope shape with these scope-specific
values (the scribe handles them uniformly via `workspace_dir`):
- `workspace_dir`: `".sdd/_product/"` — the scribe writes the product tier, and
  `feature` carries the **product slug** (used for `SCRIBE_OK` + any ESCALATION title).
- `verdict`: `"interrogated"` — informational only. Plan-review holds **no survival
  vote**, so `surviving_concerns` is always `[]` and the `verdict` never gates anything;
  the human ratifies at `/sdd-fleet:plan-finalize`.
- `escalation_payload`: **always `null`** — plan-review never auto-escalates. A missing
  interrogator payload halts the run *without writing any envelope* (the workflow returns
  `verdict:"incomplete"` and the command surfaces it); only a human writes
  `.sdd/_product/ESCALATION.md`.
- `state_delta.PHASE`: `"PLAN_REVIEW"`; `state_delta.CYCLE`: the bumped plan-review cycle.
- `review_entries`: the interrogation report blocks (one per role, grouped by
  `kind: question|risk|gap`, plus a consolidated summary block) — append-only to
  `.sdd/_product/REVIEW.md`.

### Envelope post-conditions (replaces `check-review-written` hook for workflow paths)

The workflow script validates before passing to scribe:
1. Every reviewer subagent returned a non-empty `concerns` payload. Empty → workflow halts; verdict = `escalate` with `escalation_payload.reason = "missing-reviewer-payload"`.
2. Refutation substantive-ness check on each refutation: ≥40 characters AND must contain a section reference (regex `/(spec|acceptance)\.md\s*§|line\s+\d+/i`). Failing refutations are treated as absent — the concern survives.
3. Envelope schema validity (the JSON above). Malformed → workflow halts.

VERIFY-AT-M1: refutation threshold (40 chars) is a tunable, not a constant. May need adjustment based on first dry-run findings.

### Workflow return object (schema-of-record, v0.6 — the audit-remediation hardening)

Distinct from the scribe envelope: this is what the *workflow script returns* to
whoever polls the run (the dispatching command, `/sdd-fleet:status`, or an
external orchestrator). Every workflow (review / deep-build / diagnose /
plan-review) returns:

```jsonc
{
  "verdict": "clean|revise|escalate|needs-iteration|confirmed|refuted|interrogated|incomplete|invalid-args",
                                      // "incomplete"  — a transient agent fault (missing/unusable payload):
                                      //                 PHASE/CYCLE untouched, marker cleaned via a minimal
                                      //                 cleanup envelope, re-run is safe. NOT an escalation.
                                      // "invalid-args" — the dispatch args were malformed; nothing ran
                                      //                 beyond marker cleanup. Fix the dispatch and re-run.
  "cycles_remaining": 1,              // int — present on bounded workflows (e.g. deep-build
                                      //       needs-iteration) so headless orchestrators cannot
                                      //       loop a workflow past its 3-cycle budget.
  "scribe_apply": "applied|failed",   // "failed" = the scribe could not write state even after one
                                      //            retry: REVIEW.md/IMPL_NOTES.md/PROGRESS.md did NOT
                                      //            land and the marker may remain. The reader MUST
                                      //            report the run as failed with scribe_error — never
                                      //            treat the verdict as applied or advance.
  "scribe_error": null,               // string | null — scribe failure detail when scribe_apply=failed
  "note": null                        // string | null — caller guidance (e.g. deep-build incomplete:
                                      //                 partial worktree writes may exist; inspect
                                      //                 git status/diff before re-running)
}
```

---

## 7. Cost ceiling declaration (DECIDED)

The `meta` block must be a pure literal and carries no extra fields, so the cost
ceiling lives in a `// @cost-ceiling {...}` JS header comment at the top of each
workflow script, parsed by the command layer before dispatch:

```js
// @cost-ceiling { "inputTokens": 120000, "outputTokens": 30000 }
```

### Surfacing path

- **Interactive mode**: the platform's launch prompt already shows token caution. The `phases` array names + subagent counts (in phase strings) give human reviewers the picture. The `@cost-ceiling` comment is supplementary.
- **Headless mode**: the command body parses the `@cost-ceiling` header comment from the script file *before* invoking the Workflow tool and writes a one-line summary to stdout:
  ```
  SDD_FLEET_COST_PREVIEW: workflow=review feature=<slug> input_ceiling=120000 output_ceiling=30000
  ```
  Orchestrator (Hermes) parses this line and surfaces on Discord before the workflow dispatches.

---

## 8. Headless-mode contract (DECIDED — first-class v0.2 capability)

### Caller responsibilities (Hermes-style orchestrator)

1. **Dispatch.** Invoke the command:
   ```bash
   claude -p '/sdd-fleet:feature-dev' \
     --allowedTools "Workflow,Read,Edit,Write,Bash,Agent" \
     --output-format json
   ```
   The `Workflow` allowlist entry is required (per `/en/agent-sdk/subagents`, the Workflow tool is gated like other tools).

2. **Read cost preview.** Capture the `SDD_FLEET_COST_PREVIEW` stdout line emitted by the command body before workflow dispatch. Optionally gate via human approval (Discord poll on Hermes side).

3. **Capture `runId` and `transcriptDir`.** The command body emits these from `WorkflowOutput` as machine-readable JSON before exiting:
   ```
   SDD_FLEET_WORKFLOW_LAUNCHED: {"runId":"...","transcriptDir":"...","status":"async_launched"}
   ```

4. **Poll for completion.** Hermes polls workflow status via a `claude -p` follow-up (using `TaskList` / `TaskGet` — VERIFY-AT-M1). When `taskId` shows completed:

5. **Read results.** Hermes reads the scribe's writes from `.sdd/<feature>/` (PROGRESS.md, REVIEW.md, ESCALATION.md). The structured envelope is captured in the workflow transcript at `transcriptDir/scribe.*.json` or similar (VERIFY-AT-M1 — exact transcript layout).

### Command outcome signals (the SOLE machine contract — supersedes the v0.2 exit-code table)

**A slash command cannot set a process exit code.** The command body is a prompt
executed inside the model session; `claude -p` exits 0 whether the command
refused or succeeded. The original v0.2 exit-code table here was unenforceable
fiction (audit §3.24) — an orchestrator mapping exit codes to kanban transitions
would mark every refusal successful.

The **`SDD_FLEET_*` signal lines on stdout are the sole machine contract.**
Every refusal emits exactly one `SDD_FLEET_*REFUSE*:` line whose JSON carries:

| Field | Meaning |
|---|---|
| `code` | Integer preserving the legacy exit-code semantics: `1` = workflow tool launch error, `2` = pre-dispatch validation refused, `3` = workflow runtime unavailable |
| `reason` | kebab-case slug (e.g. `no-active-feature`, `cycle-budget-exhausted`, `workflow-runtime-unavailable`) |

Success paths emit their command-specific signal (`SDD_FLEET_WORKFLOW_LAUNCHED`,
`SDD_FLEET_FINALIZE_PASS`, `SDD_FLEET_PLAN_FINALIZE_PASS`, …).

Hermes (or any orchestrator) maps **signal lines** — `code`/`reason` on refusal,
the success signal otherwise — to kanban task state transitions, and must treat
the process exit status as meaningless. For async workflows, completion outcomes
come from the workflow **return object** (§6: `verdict`, `cycles_remaining`,
`scribe_apply`) polled via TaskGet, plus the scribe's `.sdd/` writes.

### v0.2 does NOT support headless plan-approval gating

Per the workflows doc, headless mode skips the launch prompt entirely. Build-fleet v0.2 substitutes the upstream cost-preview line (§7) for this gate. **Mid-workflow human intervention is not supported in v0.2** — deferred to v0.3 (per ROADMAP).

---

## 9. Hook interaction (CONFIRMED — backed by `sdk.d.ts` BaseHookInput)

### `BaseHookInput` subagent identity fields (CONFIRMED, `sdk.d.ts:156`)

```ts
agent_id?: string;
agent_type?: string;
```

> `agent_id` — Subagent identifier. Present only when the hook fires from within a subagent.
> `agent_type` — Agent type name. Present when the hook fires from within a subagent (alongside `agent_id`).

This *resolves* CONTROLS.md's "fail-open" finding on `check-review-written.sh`. The 5-key probe was over-engineered guessing — real fields are exactly `agent_id` and `agent_type`. **But the hook is still retired for workflow paths** per CONTROLS.md — replaced by the workflow's envelope post-conditions (§6). The hook stays for non-workflow paths until M4.

### Final hook fates (cross-referenced from CONTROLS.md)

| Hook | Fate for workflow paths | Fate for non-workflow paths |
|---|---|---|
| `block-source-before-finalized.sh` | Survives unchanged. Fires on workflow subagent Write/Edit calls (VERIFY-AT-M1 expected yes). | Survives unchanged. |
| `restrict-reviewer-writes.sh` | **Retired** — replaced by reviewer subagent frontmatter `tools:` allowlist. | Retired entirely. |
| `validate-spec-status.sh` | Survives unchanged. | Survives unchanged. |
| `check-review-written.sh` | **Retired** — replaced by workflow envelope post-condition. | Survives until M4 (M4 closes the non-workflow path). |
| `stop-tests.sh` | Workflow runs tests internally (M2 / M3 BUILD workflows). Hook still fires on parent-session Stop as final guard. | Survives unchanged. |

---

## 10. Resume semantics (NEW v0.2 capability — confirmed from `WorkflowInput.resumeFromRunId`)

The Workflow tool supports `resumeFromRunId`. Completed `agent()` calls with unchanged `(prompt, opts)` return cached results instantly. Editing the script via `Write/Edit` re-runs only edited / new calls.

### v0.2 use cases

1. **REVIEW phase, escalation pathway.** Workflow returns verdict=escalate → PO revises spec.md → re-run `/sdd-fleet:feature-dev` with the new runId → cross-examination of unchanged concerns returns cached, only the new (post-revision) concerns re-run. Token savings on the back half of a cycle budget.
2. **CHANGE_REVIEW re-runs.** Same shape.

### Constraint

`resumeFromRunId` is **same-session only**. Across `claude -p` invocations (Hermes-driven), the session ID changes. Cross-session resume requires either (a) storing the prior `runId` in PROGRESS.md and the orchestrator passing it explicitly back, OR (b) accepting that headless cross-session = no resume.

VERIFY-AT-M1: does `resumeFromRunId` work in the same `claude -p` *worktree* across sequential invocations, or only inside one long-running Claude Code session?

---

## 11. Open items deferred to M1 implementation kickoff spike

Concrete verifications M1 must complete before locking workflow scripts:

| Item | How to verify | Blocks |
|---|---|---|
| `agent()` signature | Capture `/deep-research` raw script via Ctrl+G | Whole script-authoring |
| `parallel()` signature | Same | Fan-out phases |
| `pipeline()` signature | Same | Stage chaining (M3) |
| `phase()` signature | Same | Phase boundaries (launch-prompt visibility) |
| `meta.estimatedCost` accepted by runtime | Try a workflow with the field, observe runtime behavior | Cost ceiling declaration mechanism |
| `BaseHookInput` fires on workflow subagents | Run M0 probe workflow with PreToolUse Write/Edit; observe hook output | Hook retention plan |
| Headless transcript layout / how to read envelope post-completion | `claude -p` with a workflow that emits a known payload; inspect `transcriptDir` | Hermes integration spec |
| `TaskList`/`TaskGet` for workflow polling — exact tool names + outputs | SDK source on TaskList tool (`sdk-tools.d.ts`) | Headless polling loop |
| `resumeFromRunId` cross-`claude -p` behavior | Two sequential `claude -p` invocations; second passes runId | Resume use case |
| Coder dual-role resolution (CONTROLS.md Open issue 1) | Try `disallowedTools: ["Write","Edit"]` on coder reviewer instance | Coder workflow integration |

M1 schedules ~1 day of kickoff spike work to close these. None of them block the rest of M1's design — the workflow script structure (§2, §3, §6) is sound regardless of signature details.

---

## What this contract commits

CONTRACT.md as written commits v0.2 to:

1. **Scribe subagent state-writer pattern** with `agents/scribe.md` as the canonical writer of PROGRESS.md, REVIEW.md, ESCALATION.md for workflow paths.
2. **`scriptPath` distribution.** Plugin ships `.js` files; commands point the Workflow tool at them.
3. **Async / launched workflow model.** Caller polls; results land via transcripts + scribe's filesystem mutations.
4. **AgentDefinition-based subagent declarations** with `skills: ["review-rubric"]` deduplicating v0.1's rubric.
5. **Envelope schema** as the workflow ↔ scribe interface.
6. **Hook retention plan** (CONTROLS.md): block-source-before-finalized + validate-spec-status + stop-tests survive; restrict-reviewer-writes + check-review-written retire for workflow paths.
7. **Headless first-class** via cost-preview line + structured launch line + exit-code semantics.
8. **No mid-workflow human intervention** — deferred to v0.3.

CONTRACT.md does NOT commit:

- Exact runtime-global signatures (agent/parallel/pipeline/phase) — M1 kickoff spike.
- Plugin auto-discovery for `workflows/<name>.js` by `name` — not required (scriptPath wins).
- Cross-session resume semantics — VERIFY-AT-M1.
- Coder dual-role mechanism — VERIFY-AT-M1 (Open issue 1 from CONTROLS.md).
