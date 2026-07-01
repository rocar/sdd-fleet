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
// `artifacts` (optional) — a flat map of artifact name → VERBATIM text the command
//   holds for this run, e.g. { "spec": "...", "acceptance": "...", "contract": "...",
//   "diff": "..." } (any subset; string values only). Feeds the deterministic
//   citation-existence check (ADR-0002 decision 4): a refutation whose verbatim
//   quote is not found — whitespace-normalized — in any held text is discarded by
//   code before adjudication. Absent/empty → the existence check is inert.

// The Workflow runtime may deliver `args` as a JSON string rather than a parsed
// object (confirmed empirically during Phase 6 validation). Normalize.
const A = typeof args === "string" ? JSON.parse(args) : (args || {});

const feature = A.feature;
const cycle = typeof A.cycle === "string" ? parseInt(A.cycle, 10) : A.cycle;
const now = A.now;
const runId = A.run_id || null;

// Prior cycle's surviving-blocker count, passed by the dispatching command from
// PROGRESS.md SURVIVING_BLOCKERS (this workflow records it in state_delta below).
// Drives the count-must-fall regression guard. Absent/NaN → null (no prior; e.g.
// cycle 1), which disables the guard for that run.
let priorBlockers = null;
{
  const v = typeof A.prior_blockers === "string" ? parseInt(A.prior_blockers, 10) : A.prior_blockers;
  if (typeof v === "number" && Number.isInteger(v) && v >= 0) priorBlockers = v;
}

// Acceptance-criterion ids (e.g. ["AC-1","AC-2"]) the command read from
// acceptance.md, passed so the detection-floor completeness check can require a
// per-AC verdict from every reviewer (silence on a requirement is impossible).
// Empty/absent → the check is inert (backward compatible).
const criteria = Array.isArray(A.criteria) ? A.criteria.filter((c) => typeof c === "string") : [];

// Cross-service-impact (design §03): the deterministic scripts/semver-check.sh result
// the command attaches when this repo's contract change reaches pinned consumers. It
// drives the cross-service concern and (only for the contested minor/patch-with-pinned
// case) the single "breaking beyond the bump?" model call. Absent → no such concern.
const semver = A.semver && typeof A.semver === "object" ? A.semver : null;

// Artifact text HELD by the workflow (ADR-0002 decision 4 — code checks what code
// can check). The dispatching command MAY pass the verbatim text of the reviewable
// artifacts (spec/acceptance/contract/diff) in A.artifacts; the citation-existence
// check (quoteFoundInArtifacts, in the vote helpers) verifies a refutation's
// verbatim quote against these texts. Absent/empty → the check is inert (backward
// compatible: quote PRESENCE is still required by validCitation).
const artifactTexts = [];
if (A.artifacts && typeof A.artifacts === "object" && !Array.isArray(A.artifacts)) {
  for (const k of Object.keys(A.artifacts)) {
    if (typeof A.artifacts[k] === "string" && A.artifacts[k].length > 0) artifactTexts.push(A.artifacts[k]);
  }
}

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
  required: ["role", "status", "concerns", "ac_verdicts"],
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
          // Optional: the acceptance-criterion id (e.g. "AC-3") this concern maps
          // to; omitted when none applies. blockerIdentity prefers it, so "same
          // blocker across cycles" compares the mapped criterion (ADR-0002), not
          // the concern's wording.
          criterion: { type: "string" },
        },
      },
    },
    // The detection floor: one explicit verdict per acceptance criterion, so a lens
    // cannot stay silent on a requirement. Completeness vs the passed criteria is
    // enforced in the post-condition below (uncoveredCriteria).
    ac_verdicts: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["criterion", "verdict"],
        properties: {
          criterion: { type: "string" },
          verdict: { type: "string", enum: ["pass", "fail", "concern"] },
          note: { type: "string" },
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
          // `quote` is a VERBATIM excerpt from the cited artifact — the harness
          // checks it deterministically against the artifact text it holds
          // (ADR-0002 decision 4) and DISCARDS the refutation when it is absent
          // or not found; existence is never a model verdict.
          citation: {
            type: "object",
            additionalProperties: false,
            required: ["file", "locator", "quote"],
            properties: {
              file: { type: "string" },
              locator: { type: "string" },
              quote: { type: "string" },
            },
          },
        },
      },
    },
  },
};

// The single model call in the survival vote: a neutral, stake-free adjudicator
// rules, per contested concern, whether the refutation is SOUND — the reasoning
// holds AND the quoted citation genuinely SUPPORTS it. Citation EXISTENCE is NOT
// a model verdict: code already checked the verbatim quote against the artifact
// text the workflow holds (ADR-0002 decision 4 — the old citation_resolves
// verdict is gone), and a refutation whose quote was not found never reaches this
// call. A concern dies only on sound === true.
const ADJUDICATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["verdicts"],
  properties: {
    verdicts: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["concern_id", "sound"],
        properties: {
          concern_id: { type: "string" },
          sound: { type: "boolean" },
          note: { type: "string" },
        },
      },
    },
  },
};

// The dedicated adversarial pass: one required verdict per risk axis, so silence on
// a security/money/PII axis is impossible (the schema forces all three).
const ADVERSARIAL_AXIS = {
  type: "object",
  additionalProperties: false,
  required: ["verdict", "findings"],
  properties: {
    verdict: { type: "string", enum: ["clear", "concern", "blocker"] },
    findings: { type: "array", items: { type: "string" } },
  },
};
const ADVERSARIAL_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["security", "money_movement", "pii"],
  properties: {
    security: ADVERSARIAL_AXIS,
    money_movement: ADVERSARIAL_AXIS,
    pii: ADVERSARIAL_AXIS,
  },
};

// The single cross-service model call: "is this diff breaking beyond its version bump?"
const BREAKING_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["breaking", "reason"],
  properties: { breaking: { type: "boolean" }, reason: { type: "string" } },
};

// ---------- Phase 1: fan-out review ----------

phase("Fan-out review");

const reviewerResults = await parallel(
  ROLES.map((role) => () =>
    agent(reviewPrompt(role, feature, cycle, criteria), {
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

// Detection floor: every reviewer must return a verdict for EVERY acceptance
// criterion — silence on a requirement is impossible. A reviewer that leaves a
// criterion unaddressed is incomplete (re-run), exactly like a null payload.
if (criteria.length > 0) {
  for (const r of reviews) {
    const missing = uncoveredCriteria(r.payload, criteria);
    if (missing.length > 0) {
      log(`Review incomplete: ${r.role} left ${missing.length} acceptance criteria unaddressed (${missing.join(", ")}). Cleaning up without advancing state.`);
      const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
      return {
        verdict: "incomplete",
        reason: "uncovered-acceptance-criteria",
        role: r.role,
        missing,
        feature,
        cycle,
        scribe_apply: scribeResult.ok ? "applied" : "failed",
        scribe_error: scribeResult.error,
        note: "A reviewer did not return a verdict for every acceptance criterion; silence on a requirement is not allowed. PHASE/CYCLE unchanged. Re-run /sdd-fleet:feature-dev.",
      };
    }
  }
}

const allConcerns = mergeConcerns(reviews);

// Dedicated adversarial pass — security / money_movement / pii hunted SEPARATELY
// (not folded into a general lens), with a required verdict per axis so silence on a
// security/money/PII axis is impossible. Its non-clear findings enter the vote like
// any other concern (subject to cross-exam + the adjudicator). A null payload is a
// transient fault → incomplete (re-run), never a silent skip of those axes.
const adversarial = await agent(adversarialPrompt(feature, cycle), {
  label: "adversarial",
  phase: "Fan-out review",
  schema: ADVERSARIAL_SCHEMA,
});
if (!adversarial) {
  log(`Review incomplete: the adversarial pass returned no usable payload. Cleaning up without advancing state.`);
  const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
  return {
    verdict: "incomplete",
    reason: "missing-adversarial-payload",
    feature,
    cycle,
    scribe_apply: scribeResult.ok ? "applied" : "failed",
    scribe_error: scribeResult.error,
    note: "The dedicated security/money/PII pass did not return — silence on those axes is not allowed. PHASE/CYCLE unchanged. Re-run /sdd-fleet:feature-dev.",
  };
}
allConcerns.push(...adversarialConcerns(adversarial));

// Cross-service impact: the deterministic semver + pinned-consumer result is already
// computed (by the command via scripts/semver-check.sh). The model gets at most ONE
// call — and only for the contested minor/patch-with-pinned-consumers case — "is this
// diff breaking beyond its version bump?". A major bump reaching consumers is a
// deterministic blocker; no pinned consumers → no concern.
let crossServiceBreaking = false;
if (semver && semver.model_call_required) {
  const v = await agent(crossServicePrompt(semver, feature), {
    label: "cross-service",
    phase: "Fan-out review",
    schema: BREAKING_SCHEMA,
  });
  crossServiceBreaking = !!(v && v.breaking === true);
}
allConcerns.push(...crossServiceConcerns(semver, crossServiceBreaking));

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

// (a) Structural prefilter (pure, no model): different-role "refute"s carrying a
// citation whose verbatim quote is FOUND in the artifact text the workflow holds
// (the deterministic existence check, ADR-0002 decision 4). The char-count proxy
// is gone — soundness is judged next, by a model.
const contested = collectContested(allConcerns, refutationMap, artifactTexts);

// (b) The SINGLE model call in the vote: one neutral, stake-free adjudicator rules
// whether each contested refutation is SOUND (reasoning holds AND the quoted
// citation genuinely supports it — existence was already checked by code).
// Skipped entirely when nothing is contested (no cost). A null/garbled result is
// fail-safe — applyAdjudications leaves the concern standing (a concern survives
// unless properly refuted).
let adjudications = [];
if (contested.length > 0) {
  const adj = await agent(adjudicatePrompt(contested, feature, cycle), {
    label: "adjudicate",
    phase: "Survival vote",
    schema: ADJUDICATION_SCHEMA,
  });
  adjudications = adj && Array.isArray(adj.verdicts) ? adj.verdicts : [];
}

// (c) Apply (pure): a concern dies iff its refutation was adjudicated SOUND.
const surviving = applyAdjudications(allConcerns, contested, adjudications);
const survivingBlockers = surviving.filter((c) => c.severity === "blocker" && !c.refuted);
// Stamp a deterministic identity on each surviving blocker so "same blocker
// across cycles" is a deterministic comparison in the record (design §02).
survivingBlockers.forEach((c) => {
  c.id_hash = blockerIdentity(c);
});
const verdict = computeVerdict({
  survivingBlockerCount: survivingBlockers.length,
  cycle,
  cycleBudget,
  priorBlockerCount: priorBlockers,
});
const escalationReason =
  verdict !== "escalate"
    ? null
    : cycle >= cycleBudget
    ? "cycle-budget-exhausted-with-open-blockers"
    : "blocker-count-did-not-strictly-fall";

log(
  `Cycle ${cycle}: ${surviving.length} concerns, ${survivingBlockers.length} surviving blockers` +
    (typeof priorBlockers === "number" ? ` (prior ${priorBlockers})` : "") +
    ` → verdict=${verdict}${escalationReason ? " [" + escalationReason + "]" : ""}`
);

// ---------- Phase 4: apply via scribe ----------

phase("Apply");

const envelope = buildEnvelope({ feature, cycle, cycleBudget, now, reviews, surviving, verdict, escalationReason, survivingBlockerCount: survivingBlockers.length });
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

function reviewPrompt(role, feature, cycle, criteria) {
  const acBlock =
    criteria && criteria.length > 0
      ? `\n\nThe acceptance criteria are: ${criteria.join(", ")}.
You MUST return one ac_verdicts entry for EVERY criterion above — there is no
"silent" option. For each: verdict "pass" (the spec satisfies it cleanly), "concern"
(addressed but with a reservation), or "fail" (the spec does not satisfy it). For any
"fail"/"concern", ALSO raise a matching item in concerns, with its criterion field set
to that criterion's id. A missing verdict for any
criterion makes the whole review incomplete and it re-runs.`
      : `\n\nNo acceptance-criterion ids were supplied — return ac_verdicts as an empty array.`;
  return `You are the ${role} reviewer. Cycle ${cycle}. Active feature: ${feature}.

Read these files yourself (you have Read/Grep/Glob):
- .sdd/${feature}/spec.md
- .sdd/${feature}/acceptance.md
- .sdd/${feature}/REVIEW.md   (prior cycles; may not exist on cycle 1)

Review the spec through your role's lens. The review-rubric skill is preloaded —
use it for severity definitions (blocker / major / minor).${acBlock}

Return your review as the structured object you are required to produce:
- role: "${role}"
- status: "concerns-raised" if you have any blocker/major items, else "approved"
- concerns: array of { id, severity, text, criterion? }. Use stable IDs "${role}-1", "${role}-2", ...
  Set criterion to the acceptance-criterion id (e.g. "AC-2") the concern maps to —
  it is the concern's stable identity across cycles — and OMIT it when no criterion
  applies. If you have no findings, return an empty concerns array and status "approved".
- ac_verdicts: array of { criterion, verdict ("pass"|"fail"|"concern"), note? } — one per acceptance criterion above.`;
}

function crossServicePrompt(semver, feature) {
  return `You are judging CROSS-SERVICE IMPACT for feature ${feature} — exactly ONE call.
The harness already did the deterministic part: contract ${semver.contract} is bumping
${semver.old} -> ${semver.new} (a ${semver.bump} bump), and ${semver.pinned_count} consumer(s)
are pinned to the old major: ${(semver.pinned_consumers || []).join(", ")}.

A ${semver.bump} bump CLAIMS to be non-breaking. Your single judgement: read the contract
spec/diff (.sdd/${feature}/, contracts/, the published registry entry) and decide whether the
ACTUAL change is SEMANTICALLY BREAKING beyond what the version bump admits — e.g. a field type
changed, a required field added, an enum value removed, semantics altered — anything that would
break a pinned consumer despite the ${semver.bump} bump.

Return { breaking: <true|false>, reason: "<one line>" }. When in doubt, breaking=true (the safe
default protects the pinned consumers).`;
}

function adversarialPrompt(feature, cycle) {
  return `You are a DEDICATED ADVERSARIAL reviewer, cycle ${cycle}. Active feature: ${feature}.
Your ONLY job is to hunt three risk axes SEPARATELY — this is NOT a general review:
- security: injection, broken authz/authn, secrets handling, unsafe deserialization, SSRF, path traversal, etc.
- money_movement: anything that creates / moves / refunds value — correctness, idempotency, double-spend, rounding, the audit trail.
- pii: personal-data handling — exposure in logs/errors, retention, consent, encryption at rest/in transit.

Read .sdd/${feature}/spec.md, .sdd/${feature}/acceptance.md, and any relevant source under
the project root yourself (you have Read/Grep/Glob).

Return a verdict on EACH axis — there is NO silent option (a missing axis is a failure):
- verdict: "clear" (no issue you can find), "concern" (a real risk worth a human's eye),
  or "blocker" (a concrete vulnerability / defect on that axis).
- findings: array of specific findings (empty only when verdict is "clear").

Return the structured object { security:{verdict,findings}, money_movement:{verdict,findings}, pii:{verdict,findings} }.`;
}

function crossExamPrompt(role, allConcerns, feature, cycle) {
  const peers = allConcerns.filter((c) => c.raised_by !== role);
  return `You are the ${role} reviewer in CROSS-EXAMINATION, cycle ${cycle}. Active feature: ${feature}.

Read .sdd/${feature}/spec.md and .sdd/${feature}/acceptance.md yourself if you need to cite them.

Below are concerns raised by OTHER reviewers (not your own). For each, decide whether to
REFUTE it (you believe it is not a real problem) or AFFIRM it (you agree it stands).

A refutation must carry a structured citation pointing at the evidence. On every "refute"
entry, set the citation field to { file, locator, quote } — e.g. { "file": "spec.md",
"locator": "§ Constraints", "quote": "Refunds must be idempotent across retries." }.
quote is a VERBATIM excerpt copied from the cited artifact: the harness checks it
against the artifact text it holds and DISCARDS the refutation when the quote is
missing or not found (existence is code-checked, never adjudicated). A refute without
a citation is discarded by the script. A NEUTRAL ADJUDICATOR then rules whether your
reasoning is SOUND — i.e. the quoted evidence genuinely supports the refutation;
length/padding does not help. If you cannot substantively
refute, AFFIRM — the safe default (no citation needed on an affirm).
You cannot refute your own concerns (the script filters self-refutation).

Peer concerns:
${JSON.stringify(peers, null, 2)}

Return the structured object:
- role: "${role}"
- refutations: array of { concern_id, verdict ("refute"|"affirm"), reason, citation? }.
  citation = { file, locator, quote } and is REQUIRED when verdict is "refute".
  Include one entry per peer concern.`;
}

function adjudicatePrompt(contested, feature, cycle) {
  return `You are a NEUTRAL ADJUDICATOR for the survival vote, cycle ${cycle}. Active feature: ${feature}.
You are stake-free — you neither raised nor refuted any of these concerns. Judge impartially.

You have Read/Grep/Glob. READ the cited artifacts yourself before ruling:
- .sdd/${feature}/spec.md
- .sdd/${feature}/acceptance.md
- any contract a citation names.

Below are concerns whose refutations passed the structural filter (a DIFFERENT-role
reviewer refuted them WITH a citation whose verbatim quote the harness already
verified exists in the artifact text it holds — existence is settled; do not re-rule
it). For each concern, rule on its candidate refutation(s):
- sound: does the refutation actually hold — the reasoning is valid, the quoted
  citation genuinely SUPPORTS it, and the original concern is truly NOT a real
  problem?
A concern is removed ONLY when sound is true. When in doubt, set sound=false — the
safe default keeps the concern (the floor under detection).

Contested concerns (each with its candidate refutations):
${JSON.stringify(contested, null, 2)}

Return the structured object:
- verdicts: array of { concern_id, sound, note? } — exactly ONE
  entry per concern_id listed above.`;
}

// --- LAYER2-VOTE-HELPERS START — concern merge, deterministic blocker identity, citation-existence check + regression-guarded verdict ---
// Extracted VERBATIM by scripts/workflow-vote-logic.test.sh — keep PURE: no
// agent()/log()/args, deterministic, side-effect-free (so the real source is the
// thing tested, never a copy).
//
// mergeConcerns(reviews): flatten the reviewers' structured payloads into the
// single concern list the vote operates on. Carries the optional mapped
// acceptance criterion (ADR-0002 — blockerIdentity prefers it); absent/blank → null.
function mergeConcerns(reviews) {
  const out = [];
  for (const r of reviews) {
    for (const c of r.payload.concerns || []) {
      out.push({
        id: c.id,
        severity: c.severity,
        raised_by: r.role,
        text: c.text,
        criterion: typeof c.criterion === "string" && c.criterion.trim().length > 0 ? c.criterion : null,
        refuted: false,
        refuted_by: null,
        refutation_reason: null,
      });
    }
  }
  return out;
}

// mergeRefutations(roles, xaResults): flatten the cross-examination payloads into
// a concern_id → candidate-refutation map. The citation (file/locator/quote) rides
// along verbatim for the code-side gates below.
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

// blockerIdentity(concern): a stable hash of the concern's identity so "same
// blocker across cycles" is a deterministic comparison (design §02). Prefers the
// mapped acceptance criterion when the reviewer supplied one, else the normalized
// concern text. djb2 — no Date/Math.random (the runtime forbids both).
function blockerIdentity(concern) {
  const raw = (concern && (concern.criterion || concern.text)) || "";
  const key = raw.toLowerCase().replace(/\s+/g, " ").trim();
  let h = 5381;
  for (let i = 0; i < key.length; i++) h = ((h * 33) ^ key.charCodeAt(i)) >>> 0;
  return "blk-" + h.toString(16);
}

// computeVerdict: the bounded, regression-guarded loop decision (design §02 +
// CLAUDE.md "the review loop is bounded and regression-guarded"). clean when no
// blocker survives; escalate when the cycle budget is exhausted OR the
// surviving-blocker count fails to STRICTLY fall vs the prior cycle (the
// "converging on something worse" guard — escalate EARLY, do not burn the budget);
// else revise. priorBlockerCount null (no prior, e.g. cycle 1) disables the guard.
function computeVerdict(o) {
  const cur = o.survivingBlockerCount;
  if (cur <= 0) return "clean";
  if (o.cycle >= o.cycleBudget) return "escalate";
  if (typeof o.priorBlockerCount === "number" && o.priorBlockerCount >= 0 && cur >= o.priorBlockerCount)
    return "escalate";
  return "revise";
}

// validCitation: a structured citation is valid when file + locator + quote are
// non-empty strings (NOT validated against a fixed file list — "§ Constraints"/
// "line 12" against any cited artifact is acceptable). The quote is the verbatim
// excerpt the existence check below verifies; whether the citation SUPPORTS the
// refutation is the adjudicator's call.
function validCitation(c) {
  return (
    !!c &&
    typeof c.file === "string" && c.file.trim().length > 0 &&
    typeof c.locator === "string" && c.locator.trim().length > 0 &&
    typeof c.quote === "string" && c.quote.trim().length > 0
  );
}

// normalizeQuoteText(s): collapse whitespace runs and trim so a verbatim quote
// matches across line wraps / re-indentation. Case is PRESERVED — the quote is
// verbatim, not a paraphrase.
function normalizeQuoteText(s) {
  return typeof s === "string" ? s.replace(/\s+/g, " ").trim() : "";
}

// quoteFoundInArtifacts(quote, artifactTexts): the deterministic citation-existence
// check (ADR-0002 decision 4 — code checks what code can check). True iff the
// whitespace-normalized quote is a substring of a whitespace-normalized held
// artifact text. When the command passed NO artifact text, the check is inert
// (true) — existence is unverifiable here and stays with the adjudicator's support
// judgement; quote PRESENCE is still required by validCitation.
function quoteFoundInArtifacts(quote, artifactTexts) {
  const texts = Array.isArray(artifactTexts)
    ? artifactTexts.filter((t) => typeof t === "string" && t.length > 0)
    : [];
  if (texts.length === 0) return true;
  const q = normalizeQuoteText(quote);
  if (!q) return false;
  for (const t of texts) {
    if (normalizeQuoteText(t).indexOf(q) !== -1) return true;
  }
  return false;
}

// collectContested(concerns, refutationMap, artifactTexts): the structural
// prefilter (pure, no model). A refutation is ELIGIBLE only when it is a
// DIFFERENT-ROLE "refute" carrying a citation whose verbatim quote is FOUND in the
// held artifact text — the three code-side survival gates (different role +
// citation present + quote exists). A refutation whose quote is not found is
// DISCARDED here, before adjudication — the same consequence as a missing
// citation. The old MIN_REFUTATION_CHARS length proxy is GONE: whether the
// reasoning is SOUND is the adjudicator's single model call, not a character count
// (design §02 — "replaces the char-count that only pretended to judge soundness").
function collectContested(concerns, refutationMap, artifactTexts) {
  const out = [];
  for (const c of concerns) {
    const candidates = (refutationMap[c.id] || []).filter(
      (r) =>
        r.verdict === "refute" &&
        r.role !== c.raised_by &&
        validCitation(r.citation) &&
        quoteFoundInArtifacts(r.citation.quote, artifactTexts)
    );
    if (candidates.length > 0) {
      out.push({ id: c.id, raised_by: c.raised_by, severity: c.severity, text: c.text, candidates });
    }
  }
  return out;
}

// applyAdjudications(concerns, contested, adjudications): apply (pure). A concern
// dies iff the neutral adjudicator ruled its refutation SOUND (citation existence
// was already verified by code in collectContested — ADR-0002 decision 4). A
// missing/false/garbled verdict leaves the concern standing — fail-safe: a concern
// survives unless it is PROPERLY refuted (the design's "floor under detection").
// The record keeps the first eligible candidate's attribution.
function applyAdjudications(concerns, contested, adjudications) {
  const byId = {};
  for (const v of adjudications || []) {
    if (v && typeof v.concern_id === "string") byId[v.concern_id] = v;
  }
  const contestedById = {};
  for (const c of contested) contestedById[c.id] = c;
  return concerns.map((c) => {
    const v = byId[c.id];
    const ct = contestedById[c.id];
    if (!ct || !v || v.sound !== true) return c;
    const r = ct.candidates[0];
    return {
      ...c,
      refuted: true,
      refuted_by: r.role,
      refutation_reason: r.reason,
      refutation_citation: r.citation,
    };
  });
}

// uncoveredCriteria(payload, criteria): the detection floor's "silence is
// impossible" check (design §02). Returns the acceptance-criterion ids that a
// reviewer's payload did NOT return a verdict for. The workflow rejects (re-runs)
// any reviewer that leaves a criterion unaddressed, so a lens cannot stay silent on
// a requirement. Inert when criteria is empty (no AC ids passed by the command).
function uncoveredCriteria(payload, criteria) {
  const seen = {};
  for (const v of (payload && payload.ac_verdicts) || []) {
    if (v && typeof v.criterion === "string") seen[v.criterion] = true;
  }
  return criteria.filter((c) => !seen[c]);
}

// adversarialConcerns(adv): the dedicated adversarial pass's output (security,
// money_movement, pii — hunted SEPARATELY, not folded into a general lens, design
// §02). Turns each NON-clear axis verdict into a concern that enters the survival
// vote: a "blocker" axis → blocker concern, a "concern" axis → major. The required
// per-axis verdict (enforced by the schema) means silence on a security/money/PII
// axis is impossible. Pure; null adv → [] (the caller treats a missing pass as incomplete).
function adversarialConcerns(adv) {
  if (!adv) return [];
  const out = [];
  const axes = ["security", "money_movement", "pii"];
  for (const ax of axes) {
    const a = adv[ax];
    if (!a || a.verdict === "clear") continue;
    const sev = a.verdict === "blocker" ? "blocker" : "major";
    const findings = Array.isArray(a.findings) && a.findings.length ? a.findings : ["(unspecified)"];
    findings.forEach((f, i) => {
      out.push({
        id: `adversary-${ax}-${i + 1}`,
        severity: sev,
        raised_by: "adversary",
        text: `[${ax}] ${f}`,
        // A risk-axis finding has no mapped acceptance criterion — its identity is
        // its normalized text (blockerIdentity's fallback).
        criterion: null,
        refuted: false,
        refuted_by: null,
        refutation_reason: null,
      });
    });
  }
  return out;
}

// crossServiceConcerns(semver, breakingVerdict): the cross-service-impact concern
// (design §03). semver is the deterministic scripts/semver-check.sh result (run by
// the command — the sandbox cannot exec); breakingVerdict is the single model call
// ("breaking beyond the bump?"), only meaningful when semver.model_call_required.
// No pinned consumers → no concern. A MAJOR bump reaching pinned consumers is a
// declared-breaking blocker (deterministic). A minor/patch reaching pinned consumers
// is a blocker ONLY if the model judged it breaking beyond its bump. Pure.
function crossServiceConcerns(semver, breakingVerdict) {
  if (!semver || typeof semver !== "object") return [];
  const pc = typeof semver.pinned_count === "number" ? semver.pinned_count : 0;
  if (pc <= 0) return [];
  const who =
    Array.isArray(semver.pinned_consumers) && semver.pinned_consumers.length
      ? semver.pinned_consumers.join(", ")
      : `${pc} consumer(s)`;
  const base = `[cross-service] ${semver.contract} ${semver.old}->${semver.new} (${semver.bump}) reaches ${pc} pinned consumer(s): ${who}.`;
  // criterion: null — a contract-bump concern maps to no acceptance criterion;
  // its identity is its normalized text (blockerIdentity's fallback).
  const mk = (text) => [{ id: "cross-service-1", severity: "blocker", raised_by: "cross-service", text, criterion: null, refuted: false, refuted_by: null, refutation_reason: null }];
  if (semver.bump === "major") {
    return mk(`${base} A major (breaking) bump breaks pinned consumers — re-spec additively or coordinate a migration via ADR.`);
  }
  if (semver.model_call_required && breakingVerdict === true) {
    return mk(`${base} The ${semver.bump} bump claims non-breaking, but the diff is semantically breaking beyond its version bump — bump major or re-spec additively.`);
  }
  return [];
}
// --- LAYER2-VOTE-HELPERS END ---

function buildEnvelope({ feature, cycle, cycleBudget, now, reviews, surviving, verdict, escalationReason, survivingBlockerCount }) {
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
    const av = r.payload.ac_verdicts || [];
    if (av.length > 0) {
      const nonpass = av.filter((v) => v.verdict !== "pass");
      lines.push(
        nonpass.length === 0
          ? `acceptance: all ${av.length} criteria pass`
          : `acceptance: ${nonpass.map((v) => `${v.criterion}=${v.verdict}`).join(", ")} (${av.length - nonpass.length}/${av.length} pass)`
      );
    }
    lines.push(`status: ${r.payload.status || "concerns-raised"}`);
    return lines.join("\n");
  });

  // The dedicated adversarial pass's surviving findings (raised_by "adversary" — not
  // a roster role, so they need their own block).
  const adv = surviving.filter((c) => c.raised_by === "adversary");
  if (adv.length > 0) {
    const al = [`## Cycle ${cycle} — adversarial (security/money/pii) — ${now}`];
    for (const c of adv) al.push(`- [${c.severity}] ${c.text}${c.refuted ? ` (refuted-by: ${c.refuted_by})` : ""}`);
    al.push(`status: ${adv.some((c) => !c.refuted) ? "concerns-raised" : "approved"}`);
    reviewEntries.push(al.join("\n"));
  }

  // The cross-service-impact concern (raised_by "cross-service" — not a roster role).
  const xs = surviving.filter((c) => c.raised_by === "cross-service");
  if (xs.length > 0) {
    const xl = [`## Cycle ${cycle} — cross-service impact — ${now}`];
    for (const c of xs) xl.push(`- [${c.severity}] ${c.text}${c.refuted ? ` (refuted-by: ${c.refuted_by})` : ""}`);
    xl.push(`status: ${xs.some((c) => !c.refuted) ? "concerns-raised" : "approved"}`);
    reviewEntries.push(xl.join("\n"));
  }

  const escalation_payload =
    verdict === "escalate"
      ? {
          reason: escalationReason || "cycle-budget-exhausted-with-open-blockers",
          cycle,
          cycle_budget: cycleBudget,
          surviving_blockers: surviving.filter(
            (c) => c.severity === "blocker" && !c.refuted
          ),
          emitted_at: now,
        }
      : null;

  return {
    sdd_fleet_version: "0.2",
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
      // Recorded so the NEXT cycle's dispatch can pass prior_blockers and the
      // count-must-fall guard can fire (the workflow has no filesystem to read it).
      SURVIVING_BLOCKERS: typeof survivingBlockerCount === "number" ? survivingBlockerCount : 0,
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
    sdd_fleet_version: "0.2",
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
