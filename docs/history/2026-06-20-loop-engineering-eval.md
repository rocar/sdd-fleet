# Loop-engineering research + eval — Claude Code primitives vs build-fleet

**Status:** research + evaluation delivered 2026-06-20. This is a *research memo*, not an
approved design — it records findings and a prioritized recommendation set; nothing here is
ratified or implemented. The workflow contract authority remains the `sdd-protocol` skill.
Scope was set by the requester: two layers — (1) the core agentic harness & context
engineering, and (2) recurring / scheduling / long-running loop primitives.

## Method

- **Research half:** the `deep-research` workflow (5 search angles → 18 sources fetched → 90
  claims extracted → 25 adversarially verified with 3-vote refute panels; 24 confirmed, 1
  killed). All surviving claims are high-confidence, drawn from Anthropic primary sources
  (engineering/research blog, `docs.claude.com` / `code.claude.com`, the
  `anthropics/cwc-long-running-agents` repo).
- **Eval half:** a full read of `workflows/`, `agents/`, `skills/sdd-protocol/`, and
  `hooks/` to map build-fleet's current loop architecture and find the seams.

## TL;DR

build-fleet already implements Anthropic's **Layer-1** doctrine — it predates the published
guidance but converges on it (fresh-context no-Write evaluator subagents, structured-output
envelopes, filesystem-as-memory, bounded cycles, cost-disciplined rosters). The research
**validates** the v0.7 dynamic-workflow enrichment more than it challenges it.

The real gaps are all in **Layer 2 (recurring / long-running)**, which build-fleet
deliberately externalized to an orchestrator that was never built (ROADMAP v0.3b). Three
native Claude Code primitives now exist that didn't when that decision was made — **`/goal`**
(generator-evaluator Stop-hook loop), **cross-session `resumeFromRunId`**, and
**routines / scheduled-tasks + `ScheduleWakeup`**. They let build-fleet pull "autonomous
multi-feature progression" *inside* the plugin as an opt-in, bounded, evaluator-checked loop
— closing the v0.3b gap with a supported mechanism instead of a custom poller.

---

## Part A — Research findings (cited)

### Layer 1: core harness & context engineering

| # | Finding | When to use | Source |
|---|---------|-------------|--------|
| A1 | **The loop** = "LLMs using tools based on environmental feedback in a loop," terminating on completion *or a stopping condition (max iterations)*. | Open-ended problems where steps can't be predicted/hardcoded. | [Building effective agents](https://www.anthropic.com/research/building-effective-agents) |
| A2 | **Workflows ≠ agents.** 5 named workflow patterns: prompt-chaining, routing, parallelization (sectioning+voting), orchestrator-workers, evaluator-optimizer. | Prefer the simplest predefined path; reserve dynamic agency for genuinely open tasks. | Building effective agents |
| A3 | **Single agent is the default — multi-agent costs 3–10× more tokens** (duplicated context, coordination, handoff summaries). | Go multi-agent only when context truly isolates. | [Multi-agent: when & how](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them) |
| A4 | **Decompose context-centric, not problem-centric.** Good split = independent paths, no shared context. Bad split = sequential phases of the *same* work, or tightly-coupled components. | Choosing what to fan out. | Multi-agent: when & how |
| A5 | **Compaction** = summarize-near-limit then reinitialize a fresh window (auto, same as `/compact`; steerable with `focus`, wipe with `/clear`). | Long single sessions approaching the window. | [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [context-window docs](https://code.claude.com/docs/en/context-window.md) |
| A6 | **Structured note-taking / agentic memory** — write notes persisted *outside* the window. Shipped as a file-based memory tool (public beta, Sonnet 4.5). | Persistent progress with minimal token overhead. | Context engineering · [context-management](https://claude.com/blog/context-management) |
| A7 | **Subagents = fresh context, distilled return.** No parent history; only the prompt string goes in, only the final message (~1–2k tokens) comes back. Context isolation by construction. | Protect the main window from deep technical exploration. | [Agent SDK: subagents](https://code.claude.com/docs/en/agent-sdk/subagents) · Context engineering |
| A8 | **Subagents parallelize** — N concurrent finish in slowest-not-sum time (caps ~10, queued). | Independent checks (style/security/coverage) at once. | Agent SDK: subagents |
| A9 | **Subagents are resumable** via `session_id` + `agentId` → `resume:`; transcripts survive main-conversation compaction (separate files, 30-day cleanup). | Continue a subagent's full history later. | Agent SDK: subagents |
| A10 | **Workflow tool** moves orchestration into a script the runtime runs *outside* conversation context; scales to dozens–hundreds of agents (TS SDK v0.3.149+). | When per-turn subagent delegation won't scale. | [Workflows](https://code.claude.com/docs/en/workflows) · [Dynamic workflows blog](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code) |
| A11 | **Structured outputs** — schema-validated JSON at the end of a multi-turn loop; re-prompts on mismatch, errors out after retry limit. | Machine-consumable agent results. | [Structured outputs](https://code.claude.com/docs/en/agent-sdk/structured-outputs) |

### Layer 2: recurring / long-running / scheduling

| # | Finding | When to use | Source |
|---|---------|-------------|--------|
| B1 | **`/goal`** — built-in generator/evaluator loop. A separate fast model (Haiku) checks a completion condition after *every turn*; if unmet, Claude takes another turn; clears when met. Wrapper around a **session-scoped prompt-based Stop hook** (v2.1.139+). Headless: `-p` runs the loop to completion in one invocation. | Drive an agent toward a condition without re-prompting each turn. | [/goal docs](https://code.claude.com/docs/en/goal) · [cwc-long-running-agents](https://github.com/anthropics/cwc-long-running-agents) |
| B2 | **Two-agent long-running harness** — a one-time **initializer** + a **coder** that runs across discrete, *memoryless* sessions. Compaction alone is insufficient ("doesn't pass perfectly clear instructions to the next agent"). | Tasks spanning many sessions. | [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) |
| B3 | **Bridge memoryless sessions with durable EXTERNAL state**: `init.sh` + `PROGRESS.md` (## Done / In progress / Next / Notes) + git commits at checkpoints. One feature per session; re-read PROGRESS *first thing*; commit before ending. "Reconstruct state rather than rediscover it." | The canonical durable-loop recipe. | Long-running harness blog · cwc repo |
| B4 | **Adversarial fresh-context evaluator (judge)** — a separate subagent with **no Write/Edit** reviews the diff from a window that never saw the build, returns bare `PASS`/`NEEDS_WORK`. "The builder shouldn't grade its own work." | Verification you can trust. | cwc-long-running-agents |
| B5 | Newest guidance (Mar 24 2026): **Planner/Generator/Evaluator** three-agent GAN-style harness explicitly targeting long-running generator degradation ("context anxiety"). | Long app-dev builds. | [Anthropic engineering index](https://www.anthropic.com/engineering) |

**Caveats (from the verify pass).** Fast-moving surface — version gates *will* drift. `/goal`
needs **v2.1.139+** (~5 wks old as of 2026-06-20); the Workflow tool is **TS SDK v0.3.149+**;
the memory tool is still **public beta**. One refuted claim (1-2 vote): the "multi-agent
excels in *exactly three* scenarios" framing — treat as unsupported. Auto-compaction's exact
trigger threshold isn't in primary quotes (third-party cites ~83.5% of the window).

---

## Part B — Alignment scorecard

How build-fleet already maps to the doctrine (most of Layer 1 is **done**):

| Doctrine | build-fleet today | Verdict |
|----------|-------------------|---------|
| A1 loop w/ stopping condition | Every gate bounded `≤3 cycles → ESCALATE`; `stop-tests` 3-red-strike bound; `needs-iteration` carries `cycles_remaining` so a mechanical orchestrator "can never loop the 400k-token workflow forever" | ✅ Exemplary |
| A2 workflow patterns | Uses **routing** (classifier → TIER/BUILD_MODE), **parallelization+voting** (fan-out reviewers → survival vote), **evaluator-optimizer** (adversarial review). Closest to **orchestrator-workers** = deep-build's architect-designed file partition | ✅ 4 of 5 patterns |
| A3 cost discipline | Cost ceilings (`@cost-ceiling`), roster floor (≥2 distinct), `cycle_budget` clamped down to 3, trivial fast-path skips REVIEW | ✅ Validated by 3–10× finding |
| A4 context-centric split | Reviewers = independent context (the canonical *good* split); deep-build partitions by file **with overlap detection + boundary-violation gates** | ✅ Textbook |
| A6 structured note-taking | `.sdd/<feature>/` (spec, DECISIONS, TEST_PLAN, IMPL_NOTES, REVIEW, PROGRESS) IS agentic memory — better than the generic memory tool because it's audited + schema-validated | ✅ Ahead of the primitive |
| A7 fresh-context distilled return | Reviewer agents return schema-validated findings; the **envelope** is the 1–2k-token distilled handoff | ✅ |
| A8 parallelize | `parallel()` fan-out across all 4 workflows | ✅ |
| A11 structured outputs | Every `agent()` call uses a JSON schema; `BUILD_FLEET_*:` signal lines | ✅ |
| B2/B3 durable external state | `PROGRESS.md` + `.sdd/ACTIVE` lock + "one item in flight" + stateless re-read each run | ✅ matches the recipe |
| B4 no-Write evaluator | Reviewer roles omit Write/Edit inside workflows; survival vote requires a *different-role* refutation | ✅ This is build-fleet's core |
| B5 Planner/Gen/Eval | PO (planner) / coder (generator) / qa+architect (evaluator) | ✅ Already this shape |

**The gaps — all Layer 2 + two Layer-1 items:**

| Gap | Status today | Primitive that now closes it |
|-----|--------------|------------------------------|
| **G1 Autonomous multi-feature progression** | DEVELOPING loop "surfaces, does **not** auto-start" next feature; needs a human/external orchestrator | **`/goal`** (B1) — bounded generator-evaluator Stop-hook loop |
| **G2 Cross-session resume** | `resumeFromRunId` wired **same-session only**; cross-`claude -p` resume is forecast, unimplemented (`CONTRACT.md:703`) | **`resumeFromRunId` + runId in PROGRESS.md** (A9/A10) |
| **G3 Session re-orientation ritual** | `status-snapshot.sh` exists but nothing auto-orients a fresh orchestrator session | **SessionStart hook** reading `.sdd/` (B3 "read PROGRESS first thing") |
| **G4 Recurring/scheduled builds** | Deliberately externalized to a poller that was never built | **routines / scheduled-tasks + `ScheduleWakeup`** (Layer 2) |
| **G5 pipeline() unused** | None of 4 workflows use `pipeline()`; bug lane processes one bug at a time | **`pipeline()`** for *batch* bugs (A2 chaining) |
| **G6 No compaction safety net** | Orchestrator long product builds rely on `.sdd/` surviving (it does, on disk) | **PreCompact hook** re-emitting ACTIVE pointer (A5) — low priority |

---

## Part C — Recommendations (prioritized; nothing implemented)

### P1 — high leverage, native primitive now exists

**R1. `/goal`-driven autonomous DEVELOPING loop (opt-in).**
A `/build-fleet:auto-develop` command that sets a `/goal` whose completion condition =
"backlog has no unblocked features, or an escalation is open." The Haiku evaluator checks
after each turn (B1); each turn ships one feature via the existing lane and advances via
`BUILD_FLEET_NEXT_FEATURE` + `next-feature.sh`. Converts the human-paced multi-feature loop
into an autonomous one **without touching the audited per-feature gates** — the only thing
relaxed is the "surfaces, does not auto-start" human gate, and only on opt-in.
- *Seam:* `references/product-tier.md` DEVELOPING loop + `next-feature.sh` + `BUILD_FLEET_NEXT_FEATURE`.
- *Guardrails to keep:* escalation = hard stop condition; cost ceilings stay; the human-only
  stuck-state commands (`park`, `resolve-escalation`) keep `disable-model-invocation`.
- *Version gate:* `/goal` needs Claude Code **v2.1.139+** — feature-detect and degrade to
  today's "surface" behavior otherwise.
- *Effort:* M · *Risk:* M (autonomous spend) — ship behind explicit opt-in + visible cost preview.

**R2. Cross-session resumable workflows.**
Persist `runId` into `PROGRESS.md` when a workflow async-launches, and have the dispatch
commands attempt `Workflow({scriptPath, resumeFromRunId})` on restart before launching fresh.
Closes ROADMAP v0.3b's deferred `--resume-token`.
- *Seam:* `BUILD_FLEET_WORKFLOW_LAUNCHED` + the existing `TaskGet` liveness poll; `CONTRACT.md:692-705`.
- *Effort:* M · *Risk:* L (additive; falls back to fresh launch).

### P2 — solid, low-risk

**R3. SessionStart re-orientation hook.**
A `SessionStart` hook that runs `status-snapshot.sh` and prints the active `.sdd/` state
(PHASE, CYCLE, active feature, open escalation) so a fresh orchestrator reconstructs context
instead of rediscovering it (B3). Pure additive; aligns the existing filesystem-memory design
with the published long-running recipe.
- *Effort:* S · *Risk:* L.

**R4. Ship a scheduling *template*, keep the plugin scheduler-agnostic.**
Don't bake a scheduler into the audited lanes (the existing separation is correct and the
3–10× cost finding argues for it). Ship docs + a routine/`ScheduleWakeup` template that wires
the *existing signal lines* (`status-snapshot.sh` poll/diff → `/build-fleet:auto-develop`).
Turns the "external orchestrator that never got built" into a short supported recipe.
- *Seam:* `status-snapshot.sh` (read) + R1 (write).
- *Effort:* S · *Risk:* L.

### P3 — opportunistic / evaluate

**R5. Batch bug lane via `pipeline()`.**
A `/build-fleet:triage-batch` that takes N triaged bugs and `pipeline()`s each independently
through REPRODUCE→DIAGNOSE→FIX→VERIFY — bug A can be in FIX while bug B is still reproducing
(no barrier). **Nuance from A4:** pipeline *multiple bugs each through the full lane*
(independent context ✅) — do **not** pipeline the *stages of one bug* across subagents
(sequential phases of the same work = the bad split A4 warns against).
- *Effort:* M · *Risk:* M (concurrent worktree writes need `isolation:'worktree'`).

**R6. PreCompact safety net (low priority).** A `PreCompact` hook re-emitting the `.sdd/ACTIVE`
pointer + PROGRESS path. Mostly belt-and-suspenders since `.sdd/` is on disk — build-fleet is
compaction-robust *by design* (A5/A6), itself a validation. Defer unless long product builds
show context loss.

**R7. Do NOT adopt the file-based memory tool to replace `.sdd/`.** `.sdd/` is already
structured note-taking (A6) but auditable, schema-validated, and git-tracked — strictly better
here. Validation, no change.

### Guardrails to preserve (the research validates these — don't "modernize" them away)

- Cost discipline (cycle clamping, roster floors, ceilings) — backed by the **3–10× token**
  finding (A3).
- Context-centric decomposition + overlap/boundary gates — backed by A4.
- Fresh-context no-Write reviewers + different-role survival vote — backed by B4.

---

## Bottom line

No architectural rework — build-fleet got Layer 1 right before the playbook was written. The
opportunity is **Layer 2**: three primitives (`/goal`, cross-session `resumeFromRunId`,
routines/`ScheduleWakeup`) that didn't exist when build-fleet externalized scheduling now let
it own the autonomous, resumable, recurring loop as a bounded opt-in. **R1 + R2 + R3 are the
high-value, low-architectural-risk set** and naturally bundle into a single release (the
"v0.3b autonomous loop" the ROADMAP already forecasts). Step one of any plan is
feature-detection on `/goal` (v2.1.139+) + graceful degradation.
