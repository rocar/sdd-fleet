// SPDX-License-Identifier: MIT
// workflows/review.js
//
// sdd-fleet v0.2 — M1 review workflow (rewritten against the real Workflow API,
// grounded during Phase 6 against the Workflow tool's authoritative description).
//
// SDD spec review with adversarial cross-examination and survival vote.
// Replaces v0.1's parallel-Task fan-out + agent-teams cycle-3 fallback.
//
// CONTRACT: docs/v0.2/CONTRACT.md.
//
// @cost-ceiling {"input_tokens":120000,"output_tokens":30000}
// (Cost ceiling lives in this header comment, NOT meta — meta must be a pure
// literal and the runtime ignores unknown meta fields. commands/review.md parses
// this line to emit SDD_FLEET_COST_PREVIEW in headless mode.)
//
// API NOTES (confirmed against the Workflow tool description):
//   - agent(prompt, opts) → returns final text (string), OR a validated object
//     when opts.schema is supplied. opts: {label, phase, schema, model, agentType, isolation}.
//   - parallel(thunks) → thunks is an Array<() => Promise>. BARRIER. Errors → null in result array.
//   - phase(title) → void marker; subsequent agent() calls group under it.
//   - args → the Workflow `args` input, verbatim.
//   - NO Date.now()/Math.random()/new Date() — they throw. Timestamps come via args.now.
//   - Scripts are plain JS, not TS. No filesystem/Node API from the script itself.

export const meta = {
  name: "sdd-fleet-review",
  description: "SDD spec review: fan-out reviewers, adversarial cross-examination, survival vote, scribe applies state",
  phases: [
    { title: "Fan-out review", detail: "reviewers review the spec in parallel (roster configurable; default architect, qa, coder)" },
    { title: "Cross-examination", detail: "each reviewer challenges peers' concerns" },
    { title: "Survival vote", detail: "retain concerns not refuted by a different-role reviewer" },
    { title: "Apply", detail: "scribe writes PROGRESS + REVIEW deltas" },
  ],
};

// ---------- args ----------
// { feature: "<slug>", cycle: <int>, now: "<iso8601>", run_id: "<marker token>",
//   roles?: string[], cycle_budget?: <int> }
// `now` is supplied by the command because the script cannot call Date.
// `run_id` is the token the command wrote into .sdd/<feature>/.workflow-in-flight
// at dispatch; the scribe releases the marker (empties it) only when its content matches.
// `roles` (optional) overrides the reviewer roster — a >=2-element subset of
//   {architect, qa, coder}. Default ["architect","qa","coder"].
// `cycle_budget` (optional) sets the escalation budget, an integer 1..3; default 3.
//   Configurable DOWNWARD only — the sdd-protocol 3-cycle ceiling is a hard cap.
//   Omitting BOTH reproduces the historical behavior exactly.

// The Workflow runtime may deliver `args` as a JSON string rather than a parsed
// object (confirmed empirically during Phase 6 validation). Normalize.
const A = typeof args === "string" ? JSON.parse(args) : (args || {});

const feature = A.feature;
const cycle = typeof A.cycle === "string" ? parseInt(A.cycle, 10) : A.cycle;
const now = A.now;
const runId = A.run_id || null;

// Scribe result schema — declared HERE, above the first applyScribe() call site
// (the invalid-args guard just below, and the survival-vote apply later). The
// applyScribe function declaration is hoisted, but SCRIBE_RESULT_SCHEMA is a
// const: if any call site runs before this line, reading the schema throws
// "Cannot access 'SCRIBE_RESULT_SCHEMA' before initialization" (temporal dead
// zone). Keep this declaration above line ~60.
const SCRIBE_RESULT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["ok", "error"],
  properties: {
    ok: { type: "boolean" },
    error: { type: ["string", "null"] },
  },
};

// --- LAYER1-PURE-HELPERS START — configurable reviewer roster + cycle budget ---
// Extracted VERBATIM by scripts/workflow-review-config.test.sh, so these MUST stay
// pure: no log()/agent()/args, deterministic, side-effect-free. They make the
// REVIEW roster and the escalation budget data-driven WITHOUT loosening an
// invariant — the survival vote is untouched (it keys off severity, not role) and
// the budget is configurable DOWNWARD only (the 3-cycle ceiling is a hard cap).
// Defaults reproduce the historical behavior exactly. These consts sit ABOVE the
// first call site (the arg-validation block) to avoid a temporal-dead-zone read.
const ALLOWED_REVIEW_ROLES = ["architect", "qa", "coder"];
const DEFAULT_REVIEW_ROLES = ["architect", "qa", "coder"];
const DEFAULT_CYCLE_BUDGET = 3;
const MAX_CYCLE_BUDGET = 3; // sdd-protocol ceiling — never exceed (escalate, don't loop forever)

// normalizeRoles(raw) → { roles: string[]|null, error: string|null }
// absent/null → default roster; if present it must be a non-empty array of
// distinct ALLOWED roles, >= 2 (cross-examination needs a different-role refuter
// for a concern to survive the vote). Anything else is a structured arg error.
function normalizeRoles(raw) {
  if (raw === undefined || raw === null) return { roles: DEFAULT_REVIEW_ROLES.slice(), error: null };
  if (!Array.isArray(raw) || raw.length === 0)
    return { roles: null, error: "roles: must be a non-empty array of reviewer roles" };
  const seen = [];
  for (const r of raw) {
    if (typeof r !== "string" || ALLOWED_REVIEW_ROLES.indexOf(r) === -1)
      return { roles: null, error: `roles: unknown reviewer role ${JSON.stringify(r)} (allowed: ${ALLOWED_REVIEW_ROLES.join(", ")})` };
    if (seen.indexOf(r) === -1) seen.push(r);
  }
  if (seen.length < 2)
    return { roles: null, error: "roles: need at least 2 distinct roles so cross-examination has a different-role refuter" };
  return { roles: seen, error: null };
}

// normalizeCycleBudget(raw) → { budget: int|null, error: string|null, clamped: bool }
// absent/null → default; if present it must be an integer >= 1. Values above the
// ceiling are CLAMPED down (clamped:true, not an error) so the invariant holds no
// matter what a caller asks for.
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
const rolesResult = normalizeRoles(A.roles);
const budgetResult = normalizeCycleBudget(A.cycle_budget);

const argErrors = [];
if (!feature || typeof feature !== "string") argErrors.push("feature: required non-empty string");
if (typeof cycle !== "number" || Number.isNaN(cycle)) argErrors.push("cycle: required integer");
if (!now || typeof now !== "string") argErrors.push("now: required iso8601 string (the dispatching command supplies it — the script cannot call Date)");
if (rolesResult.error) argErrors.push(rolesResult.error);
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
      ? "Marker cleanup dispatched; PHASE/CYCLE unchanged. Fix the dispatch args and re-run /sdd-fleet:feature-dev."
      : "feature unknown — the dispatching command must delete .sdd/<slug>/.workflow-in-flight itself (only if its content matches the run_id it wrote).",
  };
}

// Effective configuration (validated above). ROLES drives the fan-out roster AND
// the schema role enums below; cycleBudget drives the escalation threshold.
const ROLES = rolesResult.roles;
const cycleBudget = budgetResult.budget;
// Record the effective config in the run log so a run is self-documenting no
// matter where the config came from (command flag, PROGRESS.md, or default).
log(`Reviewer roster: [${ROLES.join(", ")}]; cycle budget ${cycleBudget}.`);
if (budgetResult.clamped) {
  log(`cycle_budget requested ${JSON.stringify(A.cycle_budget)} exceeds the protocol ceiling — capped to ${MAX_CYCLE_BUDGET}.`);
}

// ---------- schemas (structured agent output) ----------

const CONCERNS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "status", "concerns"],
  properties: {
    // role enum tracks the configured reviewer roster (Layer 1) — not a fixed list.
    role: { type: "string", enum: ROLES },
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

const REFUTATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "refutations"],
  properties: {
    role: { type: "string", enum: ROLES },
    refutations: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["concern_id", "verdict", "reason"],
        properties: {
          concern_id: { type: "string" },
          verdict: { type: "string", enum: ["refute", "affirm"] },
          reason: { type: "string" },
          // Required (validated in JS) when verdict is "refute"; omitted on "affirm".
          citation: {
            type: "object",
            additionalProperties: false,
            required: ["file", "locator"],
            properties: {
              file: { type: "string" },
              locator: { type: "string" },
            },
          },
        },
      },
    },
  },
};

// ---------- Phase 1: fan-out review ----------

phase("Fan-out review");

const reviewerResults = await parallel(
  ROLES.map((role) => () =>
    agent(reviewPrompt(role, feature, cycle), {
      label: `review:${role}`,
      phase: "Fan-out review",
      agentType: `sdd-fleet:${role}`,
      schema: CONCERNS_SCHEMA,
    })
  )
);

// Post-condition (replaces the retired check-review-written hook for workflow REVIEW):
// every reviewer must return a usable structured payload. A null (agent error /
// timeout / schema failure) is a transient runtime fault, NOT a review outcome —
// so it does NOT escalate (ESCALATED + ESCALATION.md is reserved for genuine
// cycle exhaustion). Clean up the marker, leave PHASE/CYCLE untouched, re-run.
const reviews = ROLES.map((role, i) => ({ role, payload: reviewerResults[i] }));
for (const r of reviews) {
  if (!r.payload || !Array.isArray(r.payload.concerns)) {
    log(`Review incomplete: ${r.role} returned no usable concerns payload. Cleaning up without advancing state.`);
    const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
    return {
      verdict: "incomplete",
      reason: "missing-reviewer-payload",
      role: r.role,
      feature,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "No REVIEW.md entries written; PHASE/CYCLE unchanged. Re-run /sdd-fleet:feature-dev.",
    };
  }
}

const allConcerns = mergeConcerns(reviews);

// ---------- Phase 2: cross-examination ----------

phase("Cross-examination");

const xaResults = await parallel(
  ROLES.map((role) => () =>
    agent(crossExamPrompt(role, allConcerns, feature, cycle), {
      label: `cross-exam:${role}`,
      phase: "Cross-examination",
      agentType: `sdd-fleet:${role}`,
      schema: REFUTATION_SCHEMA,
    })
  )
);

const refutationMap = mergeRefutations(ROLES, xaResults);

// ---------- Phase 3: survival vote (pure JS) ----------

phase("Survival vote");

const surviving = applySurvivalVote(allConcerns, refutationMap);
const survivingBlockers = surviving.filter((c) => c.severity === "blocker" && !c.refuted);
const verdict =
  survivingBlockers.length > 0 ? (cycle >= cycleBudget ? "escalate" : "revise") : "clean";

log(
  `Cycle ${cycle}: ${surviving.length} concerns, ${survivingBlockers.length} surviving blockers → verdict=${verdict}`
);

// ---------- Phase 4: apply via scribe ----------

phase("Apply");

const envelope = buildEnvelope({ feature, cycle, cycleBudget, now, reviews, surviving, verdict });
const scribeResult = await applyScribe(envelope);

return {
  verdict,
  feature,
  cycle,
  surviving_concerns: surviving.length,
  surviving_blockers: survivingBlockers.length,
  scribe_apply: scribeResult.ok ? "applied" : "failed",
  scribe_error: scribeResult.error,
  next: scribeResult.ok ? envelope.next_legal_commands : [],
  note: scribeResult.ok
    ? undefined
    : "SCRIBE APPLY FAILED after retry — REVIEW.md/PROGRESS.md did NOT land and the .workflow-in-flight marker may remain. The dispatching command must report failure, not success.",
};

// ================= helpers =================

function reviewPrompt(role, feature, cycle) {
  return `You are the ${role} reviewer. Cycle ${cycle}. Active feature: ${feature}.

Read these files yourself (you have Read/Grep/Glob):
- .sdd/${feature}/spec.md
- .sdd/${feature}/acceptance.md
- .sdd/${feature}/REVIEW.md   (prior cycles; may not exist on cycle 1)

Review the spec through your role's lens. The review-rubric skill is preloaded —
use it for severity definitions (blocker / major / minor).

Return your review as the structured object you are required to produce:
- role: "${role}"
- status: "concerns-raised" if you have any blocker/major items, else "approved"
- concerns: array of { id, severity, text }. Use stable IDs "${role}-1", "${role}-2", ...
  If you have no findings, return an empty concerns array and status "approved".`;
}

function crossExamPrompt(role, allConcerns, feature, cycle) {
  const peers = allConcerns.filter((c) => c.raised_by !== role);
  return `You are the ${role} reviewer in CROSS-EXAMINATION, cycle ${cycle}. Active feature: ${feature}.

Read .sdd/${feature}/spec.md and .sdd/${feature}/acceptance.md yourself if you need to cite them.

Below are concerns raised by OTHER reviewers (not your own). For each, decide whether to
REFUTE it (you believe it is not a real problem) or AFFIRM it (you agree it stands).

A refutation only counts if it is substantive: at least ~40 characters of reasoning AND a
structured citation pointing at the evidence. On every "refute" entry, set the citation
field to { file, locator } — e.g. { "file": "spec.md", "locator": "§ Constraints" } or
{ "file": "acceptance.md", "locator": "line 12" }. A refute without a citation is
discarded by the script. If you cannot substantively refute, AFFIRM — that is the safe
default (no citation needed on an affirm).
You cannot refute your own concerns (the script filters self-refutation).

Peer concerns:
${JSON.stringify(peers, null, 2)}

Return the structured object:
- role: "${role}"
- refutations: array of { concern_id, verdict ("refute"|"affirm"), reason, citation? }.
  citation = { file, locator } and is REQUIRED when verdict is "refute".
  Include one entry per peer concern.`;
}

function mergeConcerns(reviews) {
  const out = [];
  for (const r of reviews) {
    for (const c of r.payload.concerns || []) {
      out.push({
        id: c.id,
        severity: c.severity,
        raised_by: r.role,
        text: c.text,
        refuted: false,
        refuted_by: null,
        refutation_reason: null,
      });
    }
  }
  return out;
}

function mergeRefutations(roles, xaResults) {
  const map = {};
  roles.forEach((role, i) => {
    const payload = xaResults[i];
    if (!payload || !Array.isArray(payload.refutations)) return;
    for (const ref of payload.refutations) {
      (map[ref.concern_id] ||= []).push({
        role,
        verdict: ref.verdict,
        reason: ref.reason,
        citation: ref.citation || null,
      });
    }
  });
  return map;
}

// A structured citation is valid when both file and locator are non-empty strings.
// (Deliberately NOT validated against a fixed file list — locators like
// "§ Constraints" or "line 12" against any cited artifact are acceptable.)
function validCitation(c) {
  return !!c &&
    typeof c.file === "string" && c.file.trim().length > 0 &&
    typeof c.locator === "string" && c.locator.trim().length > 0;
}

function applySurvivalVote(concerns, refutationMap) {
  const MIN_REFUTATION_CHARS = 40;
  return concerns.map((c) => {
    const refs = (refutationMap[c.id] || []).filter(
      (r) =>
        r.verdict === "refute" &&
        r.role !== c.raised_by &&
        typeof r.reason === "string" &&
        r.reason.length >= MIN_REFUTATION_CHARS &&
        validCitation(r.citation)
    );
    if (refs.length === 0) return c;
    const r = refs[0];
    return { ...c, refuted: true, refuted_by: r.role, refutation_reason: r.reason, refutation_citation: r.citation };
  });
}

function buildEnvelope({ feature, cycle, cycleBudget, now, reviews, surviving, verdict }) {
  const reviewEntries = reviews.map((r) => {
    const own = surviving.filter((c) => c.raised_by === r.role);
    const lines = [`## Cycle ${cycle} — ${r.role} — ${now}`];
    for (const c of own) {
      lines.push(`- [${c.severity}] ${c.text}`);
      if (c.refuted) {
        const cite = c.refutation_citation
          ? ` (cites ${c.refutation_citation.file} ${c.refutation_citation.locator})`
          : "";
        lines.push(`  refuted-by: ${c.refuted_by} — reason: ${c.refutation_reason}${cite}`);
      }
    }
    lines.push(`status: ${r.payload.status || "concerns-raised"}`);
    return lines.join("\n");
  });

  const escalation_payload =
    verdict === "escalate"
      ? {
          reason: "cycle-budget-exhausted-with-open-blockers",
          cycle,
          cycle_budget: cycleBudget,
          surviving_blockers: surviving.filter(
            (c) => c.severity === "blocker" && !c.refuted
          ),
          emitted_at: now,
        }
      : null;

  return {
    build_fleet_version: "0.2",
    feature,
    run_id: runId,
    phase: "REVIEW",
    cycle,
    verdict,
    surviving_concerns: surviving,
    review_entries: reviewEntries,
    state_delta: {
      PHASE: verdict === "escalate" ? "ESCALATED" : "REVIEW",
      CYCLE: cycle,
      UPDATED: now,
    },
    next_legal_commands:
      verdict === "clean"
        ? ["/sdd-fleet:feature-dev"]
        : verdict === "escalate"
        ? []
        : ["/sdd-fleet:feature-dev"],
    escalation_payload,
  };
}

// Minimal envelope for the incomplete/invalid-args paths (pattern ported from
// plan-review.js): releases the workflow marker (ownership-checked against
// run_id) and refreshes UPDATED only. state_delta deliberately OMITS PHASE and
// CYCLE so the scribe leaves them at their pre-run values; nothing is appended
// to REVIEW.md and no ESCALATION.md is written — ESCALATED is reserved for
// genuine cycle exhaustion.
function cleanupEnvelope(feature, now, runId) {
  return {
    build_fleet_version: "0.2",
    feature,
    run_id: runId,
    phase: "REVIEW",
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
        `Apply this sdd-fleet workflow envelope to .sdd/${envelope.feature}/ exactly per your instructions in agents/scribe.md.

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
