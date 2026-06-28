// SPDX-License-Identifier: MIT
// workflows/deep-build.js
//
// sdd-fleet v0.2 — M3 deep-build workflow (rewritten against the real Workflow
// API, grounded during Phase 6 against the Workflow tool's authoritative description).
//
// For features with file-ownership partitioning across multiple coders.
// Architect plans the partition; coders fan out in parallel against M2's
// pre-existing failing tests; in-workflow adversarial review catches gaps.
//
// CONTRACT: docs/v0.2/CONTRACT.md.
//
// @cost-ceiling {"input_tokens":400000,"output_tokens":100000}
//
// API NOTES — see workflows/review.js header. Same runtime contract:
//   agent(prompt, opts) → string, or validated object with opts.schema.
//   parallel(thunks: Array<() => Promise>) → barrier; errors → null.
//   phase(title) → void marker. No Date/Math.random — timestamps via args.now.

export const meta = {
  name: "sdd-fleet-deep-build",
  description: "Fan-out BUILD: architect plans partition, N coders implement in parallel, adversarial review",
  phases: [
    { title: "Plan partition", detail: "architect designs an N-way coder assignment" },
    { title: "Fan-out coders", detail: "coders implement assigned files against failing tests in parallel" },
    { title: "Adversarial review", detail: "architect (design) + qa (counterfactual) review the merged diff" },
    { title: "Apply", detail: "scribe aggregates into IMPL_NOTES + updates PROGRESS" },
  ],
};

// ---------- args ----------
// { feature, cycle, now, run_id, max_partitions?, partition_hint?, cycle_budget? }
// `cycle` is the BUILD cycle number, backed by the BUILD_CYCLE field in
// PROGRESS.md (the dispatching command reads BUILD_CYCLE, passes BUILD_CYCLE+1,
// and the scribe writes it back via the envelope's state_delta). `cycle_budget`
// (optional) is the escalation budget, integer 1..3; default 3, configurable
// DOWNWARD only — same semantics as review.js's REVIEW cycles: the run that
// exhausts the budget with surviving blockers escalates.
// `run_id` is the token the command wrote into .sdd/<feature>/.workflow-in-flight
// at dispatch; the scribe releases the marker (empties it) only when its content matches.

// The Workflow runtime may deliver `args` as a JSON string rather than a parsed
// object (confirmed empirically during Phase 6 validation). Normalize.
const A = typeof args === "string" ? JSON.parse(args) : (args || {});

const feature = A.feature;
const cycle = typeof A.cycle === "string" ? parseInt(A.cycle, 10) : A.cycle;
const maxPartitions = Math.min(A.max_partitions || 3, 8);
const partitionHint = A.partition_hint || null;
const now = A.now;
const runId = A.run_id || null;

// Scribe result schema — declared HERE, above the first applyScribe() call site.
// The applyScribe function declaration is hoisted, but SCRIBE_RESULT_SCHEMA is a
// const: if any call site runs before this line, reading the schema throws
// "Cannot access 'SCRIBE_RESULT_SCHEMA' before initialization" (temporal dead
// zone). scripts/workflow-determinism-lint.sh's scribe-schema-tdz rule guards this.
const SCRIBE_RESULT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["ok", "error"],
  properties: {
    ok: { type: "boolean" },
    error: { type: ["string", "null"] },
  },
};

// --- LAYER1-PURE-HELPERS START — configurable cycle budget ---
// Extracted VERBATIM by scripts/workflow-cycle-budget.test.sh, so this MUST stay
// pure: no log()/agent()/args, deterministic, side-effect-free. The BUILD escalation
// budget is configurable DOWNWARD only — values above the ceiling are clamped, so the
// "escalate, don't loop forever" invariant holds no matter what a caller asks. Default
// reproduces the historical budget (3). Consts sit ABOVE the first call site (arg
// validation) to avoid a temporal-dead-zone read.
const DEFAULT_CYCLE_BUDGET = 3;
const MAX_CYCLE_BUDGET = 3; // sdd-protocol ceiling — never exceed

// normalizeCycleBudget(raw) → { budget: int|null, error: string|null, clamped: bool }
function normalizeCycleBudget(raw) {
  if (raw === undefined || raw === null) return { budget: DEFAULT_CYCLE_BUDGET, error: null, clamped: false };
  const n = typeof raw === "string" ? parseInt(raw, 10) : raw;
  if (typeof n !== "number" || Number.isNaN(n) || !Number.isInteger(n))
    return { budget: null, error: "cycle_budget: must be an integer between 1 and " + MAX_CYCLE_BUDGET, clamped: false };
  if (n < 1)
    return { budget: null, error: "cycle_budget: must be >= 1", clamped: false };
  const budget = Math.min(n, MAX_CYCLE_BUDGET);
  return { budget, error: null, clamped: budget !== n };
}
// --- LAYER1-PURE-HELPERS END ---

// Validation failures are NEVER a bare throw: a throw would strand the
// .workflow-in-flight marker the command dropped (this script has no filesystem
// access — only the scribe can release it). Dispatch a minimal scribe cleanup
// envelope, then return a structured invalid-args verdict for the orchestrator.
const budgetResult = normalizeCycleBudget(A.cycle_budget);

const argErrors = [];
if (!feature || typeof feature !== "string") argErrors.push("feature: required non-empty string");
if (typeof cycle !== "number" || Number.isNaN(cycle)) argErrors.push("cycle: required integer (BUILD_CYCLE + 1, read from PROGRESS.md by the dispatching command)");
if (!now || typeof now !== "string") argErrors.push("now: required iso8601 string (the dispatching command supplies it — the script cannot call Date)");
if (budgetResult.error) argErrors.push(budgetResult.error);
if (argErrors.length > 0) {
  log(`Invalid args: ${argErrors.join("; ")}. No state advanced.`);
  if (feature && typeof feature === "string") {
    await applyScribe(cleanupEnvelope(feature, typeof now === "string" ? now : null, runId));
  }
  return {
    verdict: "invalid-args",
    errors: argErrors,
    note: feature && typeof feature === "string"
      ? "Marker cleanup dispatched; PHASE/BUILD_CYCLE unchanged. Fix the dispatch args and re-run /sdd-fleet:feature-dev."
      : "feature unknown — the dispatching command must delete .sdd/<slug>/.workflow-in-flight itself (only if its content matches the run_id it wrote).",
  };
}

const CYCLE_BUDGET = budgetResult.budget;
log(`Build cycle budget ${CYCLE_BUDGET}.`);
if (budgetResult.clamped) {
  log(`cycle_budget requested ${JSON.stringify(A.cycle_budget)} exceeds the protocol ceiling — capped to ${MAX_CYCLE_BUDGET}.`);
}

// ---------- schemas ----------

const PARTITION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["partition", "planner_notes"],
  properties: {
    planner_notes: { type: "string" },
    partition: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["label", "files", "acceptance_criteria", "tests", "notes"],
        properties: {
          label: { type: "string" },
          files: { type: "array", items: { type: "string" } },
          acceptance_criteria: { type: "array", items: { type: "string" } },
          tests: { type: "array", items: { type: "string" } },
          notes: { type: "string" },
        },
      },
    },
  },
};

const CODER_SUMMARY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["label", "files_modified", "tests_passing", "tests_failing", "impl_notes"],
  properties: {
    label: { type: "string" },
    files_modified: { type: "array", items: { type: "string" } },
    tests_passing: { type: "integer" },
    tests_failing: { type: "integer" },
    impl_notes: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["kind", "text"],
        properties: {
          kind: { type: "string", enum: ["gap", "deviation", "todo"] },
          text: { type: "string" },
        },
      },
    },
  },
};

const BUILD_REVIEW_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "status", "concerns"],
  properties: {
    role: { type: "string", enum: ["architect", "qa"] },
    status: { type: "string", enum: ["concerns-raised", "approved"] },
    concerns: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "severity", "text"],
        properties: {
          id: { type: "string" },
          severity: { type: "string", enum: ["blocker", "major", "minor"] },
          text: { type: "string" },
        },
      },
    },
  },
};

// ---------- Phase 1: plan partition ----------

phase("Plan partition");

let partitionPlan;
if (partitionHint) {
  partitionPlan = {
    partition: partitionHint,
    planner_notes: "Used caller-supplied partition_hint (M4 classifier or manual).",
  };
} else {
  partitionPlan = await agent(partitionPrompt(feature, maxPartitions), {
    label: "plan-partition",
    phase: "Plan partition",
    agentType: "sdd-fleet:architect",
    schema: PARTITION_SCHEMA,
  });
}

if (!partitionPlan || !Array.isArray(partitionPlan.partition) || partitionPlan.partition.length === 0) {
  // Agent fault / unusable plan — NOT a build outcome. Do not escalate
  // (ESCALATED + ESCALATION.md is reserved for genuine cycle exhaustion);
  // clean up the marker, leave PHASE/BUILD_CYCLE untouched, re-run.
  log("Deep-build incomplete: architect produced no usable partition. Cleaning up without advancing state.");
  const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
  return {
    verdict: "incomplete",
    reason: "partition-planning-failed",
    detail: (partitionPlan && partitionPlan.planner_notes) || "Architect produced no valid partition.",
    feature,
    cycle,
    scribe_apply: scribeResult.ok ? "applied" : "failed",
    scribe_error: scribeResult.error,
    note: "No coders were dispatched — the worktree is untouched. PHASE/BUILD_CYCLE unchanged. Re-run /sdd-fleet:feature-dev.",
  };
}

const partitions = partitionPlan.partition;

// Correctness gate: detect file overlap BEFORE coder fan-out. Two coders racing
// on the same file would silently overwrite each other.
// VERIFY: exact string match; globs (containing '*') are checked literally.
{
  const seen = new Map();
  const overlaps = [];
  for (const p of partitions) {
    for (const f of p.files || []) {
      if (seen.has(f)) overlaps.push({ file: f, owners: [seen.get(f), p.label] });
      else seen.set(f, p.label);
    }
  }
  if (overlaps.length > 0) {
    // Planning defect caught pre-fan-out — the worktree is untouched and the
    // partition is re-planned on every run, so this is recoverable by re-running,
    // not an escalation.
    log(`Deep-build incomplete: partition file overlap. Cleaning up without advancing state. ${JSON.stringify(overlaps)}`);
    const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
    return {
      verdict: "incomplete",
      reason: "partition-file-overlap",
      detail: `Partition has overlapping files; coders would race: ${JSON.stringify(overlaps)}`,
      feature,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "No coders were dispatched — the worktree is untouched. PHASE/BUILD_CYCLE unchanged. Re-run /sdd-fleet:feature-dev (the partition is re-planned each run).",
    };
  }
}

log(`Partition plan: ${partitions.map((p) => p.label).join(", ")} (${partitions.length} coders)`);

// ---------- Phase 2: fan out coders ----------

phase("Fan-out coders");

const coderRaw = await parallel(
  partitions.map((p) => () =>
    agent(coderPrompt(p, feature), {
      label: `coder:${p.label}`,
      phase: "Fan-out coders",
      agentType: "sdd-fleet:coder",
      schema: CODER_SUMMARY_SCHEMA,
    })
  )
);

const coderResults = partitions.map((p, i) => ({ label: p.label, summary: coderRaw[i] }));
for (const cr of coderResults) {
  if (!cr.summary || typeof cr.summary !== "object") {
    // Agent fault after coders ran — transient, NOT an escalation. But coders
    // have already written source, so warn about partial worktree writes.
    log(`Deep-build incomplete: partition '${cr.label}' returned no usable summary. Cleaning up without advancing state. Partial writes may exist in the worktree.`);
    const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
    return {
      verdict: "incomplete",
      reason: "coder-payload-malformed",
      label: cr.label,
      feature,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "WARNING: coders already ran — partial writes may exist in the worktree (inspect `git status` / `git diff` before re-running). No IMPL_NOTES.md entry was written; PHASE/BUILD_CYCLE unchanged. Re-run /sdd-fleet:feature-dev after inspecting the worktree.",
    };
  }
}

// Post-hoc partition-violation detection: did any coder touch files outside its
// declared partition? Surfaced as a synthetic concern for the review phase.
const violations = [];
for (let i = 0; i < partitions.length; i++) {
  const declared = new Set(partitions[i].files || []);
  for (const f of coderResults[i].summary.files_modified || []) {
    if (!declared.has(f)) violations.push({ partition: partitions[i].label, file: f });
  }
}
if (violations.length > 0) {
  log(`WARNING: ${violations.length} partition-boundary violations: ${JSON.stringify(violations)}`);
}

// ---------- Phase 3: adversarial review ----------

phase("Adversarial review");

const reviewRaw = await parallel([
  () =>
    agent(archReviewPrompt(partitions, coderResults, feature, violations), {
      label: "build-review:architect",
      phase: "Adversarial review",
      agentType: "sdd-fleet:architect",
      schema: BUILD_REVIEW_SCHEMA,
    }),
  () =>
    agent(qaReviewPrompt(partitions, coderResults, feature), {
      label: "build-review:qa",
      phase: "Adversarial review",
      agentType: "sdd-fleet:qa",
      schema: BUILD_REVIEW_SCHEMA,
    }),
]);

const reviews = [
  { role: "architect", payload: reviewRaw[0] },
  { role: "qa", payload: reviewRaw[1] },
];
for (const r of reviews) {
  if (!r.payload || !Array.isArray(r.payload.concerns)) {
    // Agent fault after coders ran — transient, NOT an escalation. Coders have
    // already written source, so warn about partial worktree writes.
    log(`Deep-build incomplete: reviewer ${r.role} returned no usable concerns array. Cleaning up without advancing state. Partial writes may exist in the worktree.`);
    const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
    return {
      verdict: "incomplete",
      reason: "missing-reviewer-payload",
      role: r.role,
      feature,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "WARNING: coders already ran — partial writes may exist in the worktree (inspect `git status` / `git diff` before re-running). No IMPL_NOTES.md entry was written; PHASE/BUILD_CYCLE unchanged. Re-run /sdd-fleet:feature-dev after inspecting the worktree.",
    };
  }
}

// Survival: 2 reviewers, no cross-examination peer. Concerns survive as raised.
// Add partition-violation concerns as synthetic majors.
const surviving = mergeConcerns(reviews);
for (const v of violations) {
  surviving.push({
    id: `violation-${v.partition}`,
    severity: "major",
    raised_by: "workflow",
    text: `Coder for partition '${v.partition}' modified out-of-partition file '${v.file}'.`,
  });
}
const survivingBlockers = surviving.filter((c) => c.severity === "blocker");
// Cycle budget — same semantics as review.js's REVIEW cycles: blockers on the
// cycle that exhausts the budget (cycle >= 3) escalate; earlier cycles iterate.
const verdict =
  survivingBlockers.length > 0 ? (cycle >= CYCLE_BUDGET ? "escalate" : "needs-iteration") : "clean";
const cyclesRemaining = Math.max(0, CYCLE_BUDGET - cycle);

log(`Build review (cycle ${cycle}/${CYCLE_BUDGET}): ${surviving.length} concerns, ${survivingBlockers.length} blockers → ${verdict}`);

// ---------- Phase 4: apply via scribe ----------

phase("Apply");

const envelope = buildEnvelope({ feature, cycle, now, partitions, partitionPlan, coderResults, surviving, verdict, cyclesRemaining });
const scribeResult = await applyScribe(envelope);

return {
  verdict,
  feature,
  cycle,
  cycles_remaining: cyclesRemaining,
  partitions: partitions.map((p) => p.label),
  surviving_concerns: surviving.length,
  surviving_blockers: survivingBlockers.length,
  violations: violations.length,
  scribe_apply: scribeResult.ok ? "applied" : "failed",
  scribe_error: scribeResult.error,
  next: scribeResult.ok ? envelope.next_legal_commands : [],
  note: scribeResult.ok
    ? undefined
    : "SCRIBE APPLY FAILED after retry — IMPL_NOTES.md/PROGRESS.md did NOT land and the .workflow-in-flight marker may remain. Coders DID run: writes exist in the worktree without a recorded summary. The dispatching command must report failure, not success.",
};

// ================= helpers =================

function partitionPrompt(feature, maxPartitions) {
  return `You are the architect planning a file partition for up to ${maxPartitions} coders to implement this feature IN PARALLEL against pre-existing failing tests.

Read yourself (you have Read/Grep/Glob):
- .sdd/${feature}/spec.md, acceptance.md, TEST_PLAN.md
- the tests/ directory (what test files exist)
- the project layout (top-level dirs suggesting package/module boundaries)

Design a partition where each entry is one coder's assignment. Partitions MUST NOT share
writable files (coders run in parallel and cannot coordinate — shared files cause races).
Every existing test file must be covered by at least one partition.

Return the structured object:
- partition: array of { label (kebab-case), files (specific paths, NOT globs), acceptance_criteria, tests, notes }
- planner_notes: one paragraph on how you chose the partitions and the tradeoffs.

Hard constraints: at most ${maxPartitions} partitions; no shared writable files; no orphan tests.
If the feature is genuinely single-package, return 1 partition — the orchestrator treats that
as a signal that deep-build was the wrong choice, which is fine.`;
}

function coderPrompt(partition, feature) {
  return `You are a coder in a deep-build fan-out. Your partition: '${partition.label}'.

Files you may write (ONLY these — other coders own the rest):
${JSON.stringify(partition.files, null, 2)}

Acceptance criteria you cover: ${JSON.stringify(partition.acceptance_criteria)}
Tests you must make pass (they EXIST and currently FAIL — qa wrote them under M2 ordering):
${JSON.stringify(partition.tests)}

Read .sdd/${feature}/spec.md and acceptance.md yourself for full context.
If .sdd/${feature}/SKILL_MANIFEST.md exists, load and apply the skills it lists
under the 'coder' role (per the skill-routing skill) before implementing; an
unavailable skill is a no-op — note it in your impl_notes and proceed.

Your job:
1. Run your partition's failing tests; confirm they fail initially.
2. Implement source ONLY in your assigned files until those tests pass.
3. Do NOT modify files outside your partition.
4. Record gap/deviation/todo notes for anything you couldn't resolve.

Return the structured object: { label, files_modified, tests_passing, tests_failing, impl_notes:[{kind,text}] }.`;
}

function archReviewPrompt(partitions, coderResults, feature, violations) {
  return `You are the architect reviewing a merged deep-build diff. ${partitions.length} coders worked in parallel.

Read .sdd/${feature}/spec.md, acceptance.md, DECISIONS.md yourself.

Partition plan: ${JSON.stringify(partitions, null, 2)}
Coder summaries: ${JSON.stringify(coderResults.map((r) => r.summary), null, 2)}
Detected partition-boundary violations (already flagged by the workflow): ${JSON.stringify(violations)}

Your lens: design adherence, scalability, failure modes, security, blast radius. Focus on the
SEAMS between partitions — single-partition correctness is easy; integration points (contracts,
error envelopes, type assumptions across partitions) are where parallel coding fails.

Return the structured object: { role:"architect", status, concerns:[{id,severity,text}] }.
Empty concerns + status "approved" if clean.`;
}

function qaReviewPrompt(partitions, coderResults, feature) {
  return `You are qa reviewing a merged deep-build diff. Lens: coverage gaps + the M2 counterfactual.

Read .sdd/${feature}/acceptance.md and TEST_PLAN.md yourself.

Partition plan + coder summaries: ${JSON.stringify({ partitions, summaries: coderResults.map((r) => r.summary) }, null, 2)}

Your job:
1. Each acceptance criterion → point at the test that exercises it. Missing → [blocker].
2. M2 counterfactual: would each test FAIL if its partition's source change were reverted?
   Tests that pass regardless of source are decorative → [blocker].
3. Failure paths covered? Missing → [major].
4. Integration tests spanning partitions — ownership gap → [major].

Return the structured object: { role:"qa", status, concerns:[{id,severity,text}] }.
Empty concerns + status "approved" if clean.`;
}

function mergeConcerns(reviews) {
  const out = [];
  for (const r of reviews) {
    for (const c of r.payload.concerns || []) {
      out.push({ id: c.id, severity: c.severity, raised_by: r.role, text: c.text });
    }
  }
  return out;
}

function buildEnvelope({ feature, cycle, now, partitions, partitionPlan, coderResults, surviving, verdict, cyclesRemaining }) {
  const lines = [];
  lines.push(`## Deep-build run — cycle ${cycle} — ${now}`);
  lines.push(``);
  lines.push(`**Partitions:** ${partitions.map((p) => p.label).join(", ")}`);
  lines.push(`**Planner notes:** ${partitionPlan.planner_notes || "(none)"}`);
  lines.push(``);
  for (const cr of coderResults) {
    const s = cr.summary;
    lines.push(`### Partition '${cr.label}'`);
    lines.push(`- Files modified: ${JSON.stringify(s.files_modified || [])}`);
    lines.push(`- Tests passing/failing: ${s.tests_passing}/${s.tests_failing}`);
    for (const n of s.impl_notes || []) lines.push(`  - ${n.kind}: ${n.text}`);
    lines.push(``);
  }
  lines.push(`### In-workflow build review`);
  if (surviving.length === 0) lines.push(`(no surviving concerns)`);
  else for (const c of surviving) lines.push(`- [${c.severity}] (${c.raised_by}) ${c.text}`);
  lines.push(``);
  lines.push(`**Verdict:** ${verdict}`);
  if (verdict === "needs-iteration") {
    lines.push(``);
    lines.push(`**Cycle budget:** ${cycle}/${CYCLE_BUDGET} used — ${cyclesRemaining} re-run(s) remaining before escalation.`);
  }

  // ESCALATED is reachable ONLY here, on genuine cycle exhaustion: blockers
  // survived the adversarial review on the cycle that exhausted the budget.
  const escalation_payload =
    verdict === "escalate"
      ? {
          reason: "build-cycle-budget-exhausted-with-open-blockers",
          cycle,
          surviving_blockers: surviving.filter((c) => c.severity === "blocker"),
          emitted_at: now,
        }
      : null;

  return {
    sdd_fleet_version: "0.2",
    feature,
    run_id: runId,
    workflow: "deep-build",
    phase: "BUILD",
    cycle,
    verdict,
    // The needs-iteration envelope carries the remaining budget so a mechanical
    // orchestrator can never loop the 400k-token workflow forever.
    cycles_remaining: cyclesRemaining,
    surviving_concerns: surviving,
    review_entries: [],
    impl_notes_appendix: lines.join("\n"),
    state_delta: {
      PHASE: verdict === "escalate" ? "ESCALATED" : "BUILD",
      BUILD_CYCLE: cycle,
      BUILD_MODE: "deep-build",
      UPDATED: now,
    },
    next_legal_commands:
      verdict === "clean"
        ? ["/sdd-fleet:pr-review"]
        : verdict === "escalate"
        ? []
        : ["/sdd-fleet:feature-dev"],
    escalation_payload,
  };
}

// Minimal envelope for the incomplete/invalid-args paths (pattern ported from
// plan-review.js): releases the workflow marker (ownership-checked against
// run_id) and refreshes UPDATED only. state_delta deliberately OMITS PHASE and
// BUILD_CYCLE so the scribe leaves them at their pre-run values; nothing is
// appended to IMPL_NOTES.md and no ESCALATION.md is written — ESCALATED is
// reserved for genuine cycle exhaustion.
function cleanupEnvelope(feature, now, runId) {
  return {
    sdd_fleet_version: "0.2",
    feature,
    run_id: runId,
    workflow: "deep-build",
    phase: "BUILD",
    cycle: 0,
    verdict: "incomplete",
    surviving_concerns: [],
    review_entries: [],
    state_delta: now ? { UPDATED: now } : {},
    next_legal_commands: ["/sdd-fleet:feature-dev"],
    escalation_payload: null,
  };
}

// ---------- verified scribe application ----------
// (SCRIBE_RESULT_SCHEMA is declared near the top of this file, above the first
// applyScribe() call site, to avoid a temporal-dead-zone error.)

// The scribe returns a structured {ok, error} aligned with its
// SCRIBE_OK:/SCRIBE_ERROR: contract (agents/scribe.md). One retry on failure;
// if still failing, the caller must surface scribe_apply: "failed" — state did
// NOT land and the dispatching command must refuse/report, never claim success.
async function applyScribe(envelope) {
  let lastError = "scribe returned no usable result";
  for (let attempt = 1; attempt <= 2; attempt++) {
    let res = null;
    try {
      res = await agent(
        `Apply this sdd-fleet workflow envelope to .sdd/${envelope.feature}/ exactly per agents/scribe.md.

Marker ownership: RELEASE .sdd/${envelope.feature}/.workflow-in-flight by overwriting it with EMPTY content via the Write tool (you have no Bash; an empty marker counts as released and is reaped later) — ONLY if its current content matches the envelope's run_id${envelope.run_id ? ` ("${envelope.run_id}")` : " (null — legacy envelope: release unconditionally, best-effort)"}. If the content differs, leave the marker — it belongs to another run.

Return the structured object {ok, error}: ok=true when the WHOLE envelope landed (your SCRIBE_OK condition), with error=null. ok=false with error="<one-line reason>" otherwise (your SCRIBE_ERROR reason).

ENVELOPE:
${JSON.stringify(envelope, null, 2)}`,
        {
          label: attempt === 1 ? "scribe" : "scribe-retry",
          phase: "Apply",
          agentType: "sdd-fleet:scribe",
          schema: SCRIBE_RESULT_SCHEMA,
        }
      );
    } catch (e) {
      res = null;
      lastError = "scribe agent error: " + (e && e.message ? e.message : String(e));
    }
    if (res && res.ok === true) return { ok: true, error: null };
    if (res && typeof res.error === "string" && res.error) lastError = res.error;
    log(`Scribe apply attempt ${attempt}/2 failed: ${lastError}`);
  }
  return { ok: false, error: lastError };
}
