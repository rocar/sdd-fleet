// SPDX-License-Identifier: MIT
// workflows/change-review.js
//
// sdd-fleet — CHANGE_REVIEW workflow (audit B6). The forward machine's REVIEW runs
// the deterministic engine in review.js; CHANGE_REVIEW used to run a prose Task
// fan-out + a model-judged pass/fail in commands/pr-review.md — a consequence in
// prose, the exact thing the harness forbids. This is "the same engine, on the PR"
// the design draws (§02 band 4): fan-out → cross-examine → one neutral adjudicator
// survival vote → bounded, regression-guarded loop, all in code.
//
// FORK of review.js, deliberately self-contained (the sandbox forbids import, so
// every workflow duplicates the scribe/envelope shell; cf. plan-review.js,
// diagnose.js). The LAYER1-PURE-HELPERS and LAYER2-VOTE-HELPERS blocks are kept
// VERBATIM-identical to review.js so the vote logic cannot drift between REVIEW and
// CHANGE_REVIEW — scripts/workflow-change-review.test.sh asserts both parity and
// behavior.
//
// Divergences from review.js:
//   - reviewers review the IMPLEMENTED CHANGE (source + tests + IMPL_NOTES) against
//     acceptance.md, not the spec alone. Default roster [architect, qa].
//   - the deterministic counterfactual (run by the command via
//     scripts/counterfactual.sh, since the sandbox cannot exec) is a VOTE INPUT: a
//     "fail" verdict injects a blocker the model cannot wave off.
//   - state_delta keys CHANGE_CYCLE + CHANGE_SURVIVING_BLOCKERS; PHASE maps
//     clean→CHANGE_REVIEW (command ships), revise→BUILD (coder re-implements),
//     escalate→ESCALATED.
//
// @cost-ceiling {"input_tokens":120000,"output_tokens":30000}
// (Cost ceiling lives in this header comment, NOT meta. commands/pr-review.md parses
// this line to emit SDD_FLEET_COST_PREVIEW in headless mode.)
//
// API NOTES: agent(prompt,opts) → text or validated object (opts.schema); parallel
// (thunks) is a BARRIER (errors → null); phase(title) groups; args is the input;
// NO Date.now()/Math.random()/new Date() (they throw — timestamps via args.now); no
// filesystem/Node API from the script.

export const meta = {
  name: "sdd-fleet-change-review",
  description: "CHANGE_REVIEW: fan-out reviewers over the implemented change, adversarial cross-examination, neutral-adjudicator survival vote (counterfactual is a vote input), scribe applies state",
  phases: [
    { title: "Fan-out review", detail: "reviewers review the change vs acceptance in parallel (default architect, qa)" },
    { title: "Cross-examination", detail: "each reviewer challenges peers' concerns" },
    { title: "Survival vote", detail: "neutral adjudicator rules soundness + citation-resolves; counterfactual fail is a blocker" },
    { title: "Apply", detail: "scribe writes PROGRESS + REVIEW deltas" },
  ],
};

// ---------- args ----------
// { feature, cycle (CHANGE_CYCLE), now, run_id, roles?, cycle_budget?,
//   prior_blockers?, counterfactual? ("pass"|"fail"|"skip") }
const A = typeof args === "string" ? JSON.parse(args) : (args || {});

const feature = A.feature;
const cycle = typeof A.cycle === "string" ? parseInt(A.cycle, 10) : A.cycle;
const now = A.now;
const runId = A.run_id || null;
const counterfactual = typeof A.counterfactual === "string" ? A.counterfactual : null;

// Prior change-review cycle's surviving-blocker count, passed by the command from
// PROGRESS.md CHANGE_SURVIVING_BLOCKERS (recorded in state_delta below). Absent/NaN
// → null (no prior; e.g. the first change-review cycle), disabling the guard.
let priorBlockers = null;
{
  const v = typeof A.prior_blockers === "string" ? parseInt(A.prior_blockers, 10) : A.prior_blockers;
  if (typeof v === "number" && Number.isInteger(v) && v >= 0) priorBlockers = v;
}

// Acceptance-criterion ids the command read from acceptance.md, passed so the
// detection-floor completeness check can require a per-AC verdict from every
// reviewer (silence on a requirement is impossible). Empty/absent → inert.
const criteria = Array.isArray(A.criteria) ? A.criteria.filter((c) => typeof c === "string") : [];

// Scribe result schema — declared HERE, above the first applyScribe() call site, to
// avoid a temporal-dead-zone read (the workflow-determinism-lint scribe-schema-tdz rule).
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
// .workflow-in-flight marker the command dropped. Dispatch a minimal scribe
// cleanup envelope, then return a structured invalid-args verdict.
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
      ? "Marker cleanup dispatched; PHASE/CHANGE_CYCLE unchanged. Fix the dispatch args and re-run /sdd-fleet:pr-review."
      : "feature unknown — the dispatching command must delete .sdd/<slug>/.workflow-in-flight itself (only if its content matches the run_id it wrote).",
  };
}

const ROLES = rolesResult.roles;
const cycleBudget = budgetResult.budget;
log(`CHANGE_REVIEW roster: [${ROLES.join(", ")}]; cycle budget ${cycleBudget}; counterfactual=${counterfactual || "n/a"}.`);
if (budgetResult.clamped) {
  log(`cycle_budget requested ${JSON.stringify(A.cycle_budget)} exceeds the protocol ceiling — capped to ${MAX_CYCLE_BUDGET}.`);
}

// ---------- schemas ----------

const CONCERNS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "status", "concerns", "ac_verdicts"],
  properties: {
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
    // The detection floor: one explicit verdict per acceptance criterion (silence
    // impossible). Completeness vs the passed criteria is enforced below.
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
        required: ["concern_id", "sound", "citation_resolves"],
        properties: {
          concern_id: { type: "string" },
          sound: { type: "boolean" },
          citation_resolves: { type: "boolean" },
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

// ---------- Phase 1: fan-out review ----------

phase("Fan-out review");

const reviewerResults = await parallel(
  ROLES.map((role) => () =>
    agent(reviewPrompt(role, feature, cycle, criteria), {
      label: `change-review:${role}`,
      phase: "Fan-out review",
      agentType: `sdd-fleet:${role}`,
      schema: CONCERNS_SCHEMA,
    })
  )
);

const reviews = ROLES.map((role, i) => ({ role, payload: reviewerResults[i] }));
for (const r of reviews) {
  if (!r.payload || !Array.isArray(r.payload.concerns)) {
    log(`Change-review incomplete: ${r.role} returned no usable concerns payload. Cleaning up without advancing state.`);
    const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
    return {
      verdict: "incomplete",
      reason: "missing-reviewer-payload",
      role: r.role,
      feature,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "No REVIEW.md entries written; PHASE/CHANGE_CYCLE unchanged. Re-run /sdd-fleet:pr-review.",
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
      log(`Change-review incomplete: ${r.role} left ${missing.length} acceptance criteria unaddressed (${missing.join(", ")}). Cleaning up without advancing state.`);
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
        note: "A reviewer did not return a verdict for every acceptance criterion; silence on a requirement is not allowed. PHASE/CHANGE_CYCLE unchanged. Re-run /sdd-fleet:pr-review.",
      };
    }
  }
}

const allConcerns = mergeConcerns(reviews);

// Dedicated adversarial pass — security / money_movement / pii hunted SEPARATELY
// (not folded into a general lens), required verdict per axis (silence impossible).
// Its non-clear findings enter the vote like any other concern. Null → incomplete.
const adversarial = await agent(adversarialPrompt(feature, cycle), {
  label: "adversarial",
  phase: "Fan-out review",
  schema: ADVERSARIAL_SCHEMA,
});
if (!adversarial) {
  log(`Change-review incomplete: the adversarial pass returned no usable payload. Cleaning up without advancing state.`);
  const scribeResult = await applyScribe(cleanupEnvelope(feature, now, runId));
  return {
    verdict: "incomplete",
    reason: "missing-adversarial-payload",
    feature,
    cycle,
    scribe_apply: scribeResult.ok ? "applied" : "failed",
    scribe_error: scribeResult.error,
    note: "The dedicated security/money/PII pass did not return — silence on those axes is not allowed. PHASE/CHANGE_CYCLE unchanged. Re-run /sdd-fleet:pr-review.",
  };
}
allConcerns.push(...adversarialConcerns(adversarial));

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

// ---------- Phase 3: survival vote ----------

phase("Survival vote");

// (a) structural prefilter (pure): different-role "refute"s carrying a citation.
const contested = collectContested(allConcerns, refutationMap);

// (b) the single model call in the vote: one neutral, stake-free adjudicator rules
// soundness + whether the citation resolves. Skipped when nothing is contested.
let adjudications = [];
if (contested.length > 0) {
  const adj = await agent(adjudicatePrompt(contested, feature, cycle), {
    label: "adjudicate",
    phase: "Survival vote",
    schema: ADJUDICATION_SCHEMA,
  });
  adjudications = adj && Array.isArray(adj.verdicts) ? adj.verdicts : [];
}

// (c) apply (pure): a concern dies iff its refutation was adjudicated sound + resolved.
const surviving = applyAdjudications(allConcerns, contested, adjudications);

// The deterministic counterfactual (run by the command via scripts/counterfactual.sh,
// because the sandbox cannot exec) is a VOTE INPUT: a "fail" — a test stays green when
// the change is reverted — is a blocker the model cannot wave off.
if (counterfactual === "fail") {
  surviving.push({
    id: "counterfactual",
    severity: "blocker",
    raised_by: "qa",
    text: "counterfactual failed: at least one test stays green when the change is reverted (decorative test — proves nothing).",
    refuted: false,
    refuted_by: null,
    refutation_reason: null,
  });
}

const survivingBlockers = surviving.filter((c) => c.severity === "blocker" && !c.refuted);
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
  `Change cycle ${cycle}: ${surviving.length} concerns, ${survivingBlockers.length} surviving blockers` +
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
  counterfactual,
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
You MUST return one ac_verdicts entry for EVERY criterion above — no "silent" option.
For each: "pass" (the IMPLEMENTED change satisfies it), "concern" (met with a
reservation), or "fail" (the change does not satisfy it). For any "fail"/"concern",
ALSO raise a matching item in concerns. A missing verdict makes the review incomplete
and it re-runs. IMPL_NOTES.md may carry a recorded \`real-coverage:\` line — ground any
coverage judgement in that captured number, not a guess.`
      : `\n\nNo acceptance-criterion ids were supplied — return ac_verdicts as an empty array.`;
  return `You are the ${role} reviewer in CHANGE_REVIEW, cycle ${cycle}. Active feature: ${feature}.

You are reviewing the IMPLEMENTED CHANGE (the PR), not the spec in the abstract. Read
yourself (you have Read/Grep/Glob; use Bash for \`git diff\` against the base if available):
- .sdd/${feature}/spec.md and acceptance.md   (what the change must satisfy)
- .sdd/${feature}/IMPL_NOTES.md                (coder's gap:/deviation:/todo: notes; real-coverage)
- .sdd/${feature}/TEST_PLAN.md                 (the AC→test coverage matrix)
- .sdd/${feature}/REVIEW.md                    (prior cycles)
- the source under the project root and tests/ (the implemented change)

Review through your role's lens. The review-rubric skill is preloaded — use it for
severity (blocker / major / minor):
- architect: design adherence, ADR compliance, blast radius of the change.
- qa: does the implementation actually MEET acceptance.md? Coverage gaps before handoff?${acBlock}

Return the structured object:
- role: "${role}"
- status: "concerns-raised" if you have any blocker/major items, else "approved"
- concerns: array of { id, severity, text }. Use stable IDs "${role}-1", "${role}-2", ...
  If the change is clean from your lens, return an empty concerns array and status "approved".
- ac_verdicts: array of { criterion, verdict ("pass"|"fail"|"concern"), note? } — one per acceptance criterion above.`;
}

function adversarialPrompt(feature, cycle) {
  return `You are a DEDICATED ADVERSARIAL reviewer over the IMPLEMENTED CHANGE, cycle ${cycle}. Active feature: ${feature}.
Your ONLY job is to hunt three risk axes SEPARATELY in the actual code — NOT a general review:
- security: injection, broken authz/authn, secrets handling, unsafe deserialization, SSRF, path traversal, etc.
- money_movement: anything that creates / moves / refunds value — correctness, idempotency, double-spend, rounding, the audit trail.
- pii: personal-data handling — exposure in logs/errors, retention, consent, encryption at rest/in transit.

Read .sdd/${feature}/spec.md, acceptance.md, IMPL_NOTES.md, and the changed source/tests
yourself (you have Read/Grep/Glob; use Bash for \`git diff\` if available).

Return a verdict on EACH axis — there is NO silent option (a missing axis is a failure):
- verdict: "clear" / "concern" / "blocker"; findings: array (empty only when "clear").

Return the structured object { security:{verdict,findings}, money_movement:{verdict,findings}, pii:{verdict,findings} }.`;
}

function crossExamPrompt(role, allConcerns, feature, cycle) {
  const peers = allConcerns.filter((c) => c.raised_by !== role);
  return `You are the ${role} reviewer in CROSS-EXAMINATION (CHANGE_REVIEW), cycle ${cycle}. Active feature: ${feature}.

Read .sdd/${feature}/acceptance.md and the changed source/tests yourself if you need to cite them.

Below are concerns raised by OTHER reviewers (not your own). For each, decide whether to
REFUTE it (you believe it is not a real problem) or AFFIRM it (you agree it stands).

A refutation must carry a structured citation pointing at the evidence. On every "refute"
entry, set the citation field to { file, locator } — e.g. { "file": "acceptance.md",
"locator": "AC-3" } or { "file": "src/auth.py", "locator": "line 42" }. A refute without a
citation is discarded by the script. A NEUTRAL ADJUDICATOR then rules whether your
reasoning is SOUND and whether the cited line truly RESOLVES — so make the reasoning
genuinely support the citation; length/padding does not help. If you cannot substantively
refute, AFFIRM — the safe default (no citation needed on an affirm).
You cannot refute your own concerns (the script filters self-refutation).

Peer concerns:
${JSON.stringify(peers, null, 2)}

Return the structured object:
- role: "${role}"
- refutations: array of { concern_id, verdict ("refute"|"affirm"), reason, citation? }.
  citation = { file, locator } and is REQUIRED when verdict is "refute".
  Include one entry per peer concern.`;
}

function adjudicatePrompt(contested, feature, cycle) {
  return `You are a NEUTRAL ADJUDICATOR for the CHANGE_REVIEW survival vote, cycle ${cycle}. Active feature: ${feature}.
You are stake-free — you neither raised nor refuted any of these concerns. Judge impartially.

You have Read/Grep/Glob (and Bash for \`git diff\`). READ the cited artifacts and the
changed source/tests yourself before ruling:
- .sdd/${feature}/spec.md, acceptance.md, IMPL_NOTES.md, TEST_PLAN.md
- the source / tests a citation names.

Below are concerns whose refutations passed the structural filter (a DIFFERENT-role
reviewer refuted them WITH a citation). For each concern, rule on its candidate refutation(s):
- citation_resolves: does the cited file + locator actually EXIST and genuinely SUPPORT
  the refutation? (Not merely "is a citation present" — does it RESOLVE.)
- sound: does the refutation's reasoning actually hold — i.e. is the original concern
  truly NOT a real problem in the implemented change?
A concern is removed ONLY when BOTH are true. When in doubt, set sound=false — the safe
default keeps the concern (the floor under detection).

Contested concerns (each with its candidate refutations):
${JSON.stringify(contested, null, 2)}

Return the structured object:
- verdicts: array of { concern_id, sound, citation_resolves, note? } — exactly ONE entry per concern_id above.`;
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

// --- LAYER2-VOTE-HELPERS START — deterministic blocker identity + regression-guarded verdict ---
// Extracted VERBATIM by scripts/workflow-vote-logic.test.sh — keep PURE: no
// agent()/log()/args, deterministic, side-effect-free (so the real source is the
// thing tested, never a copy).
//
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

// validCitation: a structured citation is valid when file + locator are non-empty
// strings (NOT validated against a fixed file list — "§ Constraints"/"line 12"
// against any cited artifact is acceptable; whether it RESOLVES is the
// adjudicator's call, below).
function validCitation(c) {
  return (
    !!c &&
    typeof c.file === "string" && c.file.trim().length > 0 &&
    typeof c.locator === "string" && c.locator.trim().length > 0
  );
}

// collectContested(concerns, refutationMap): the structural prefilter (pure, no
// model). A refutation is ELIGIBLE only when it is a DIFFERENT-ROLE "refute"
// carrying a citation — the two code-side survival gates (different role + citation
// present). The old MIN_REFUTATION_CHARS length proxy is GONE: whether the
// reasoning is SOUND and the citation RESOLVES is the adjudicator's single model
// call, not a character count (design §02 — "replaces the char-count that only
// pretended to judge soundness").
function collectContested(concerns, refutationMap) {
  const out = [];
  for (const c of concerns) {
    const candidates = (refutationMap[c.id] || []).filter(
      (r) => r.verdict === "refute" && r.role !== c.raised_by && validCitation(r.citation)
    );
    if (candidates.length > 0) {
      out.push({ id: c.id, raised_by: c.raised_by, severity: c.severity, text: c.text, candidates });
    }
  }
  return out;
}

// applyAdjudications(concerns, contested, adjudications): apply (pure). A concern
// dies iff the neutral adjudicator ruled its refutation SOUND and its citation
// RESOLVES. A missing/false/garbled verdict leaves the concern standing —
// fail-safe: a concern survives unless it is PROPERLY refuted (the design's "floor
// under detection"). The record keeps the first eligible candidate's attribution.
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
    if (!ct || !v || v.sound !== true || v.citation_resolves !== true) return c;
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
        refuted: false,
        refuted_by: null,
        refutation_reason: null,
      });
    });
  }
  return out;
}
// --- LAYER2-VOTE-HELPERS END ---

function buildEnvelope({ feature, cycle, cycleBudget, now, reviews, surviving, verdict, escalationReason, survivingBlockerCount }) {
  const reviewEntries = reviews.map((r) => {
    const own = surviving.filter((c) => c.raised_by === r.role);
    const lines = [`## Change Cycle ${cycle} — ${r.role} — ${now}`];
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

  // A synthetic counterfactual blocker has no reviewer block; surface it explicitly.
  const cf = surviving.filter((c) => c.id === "counterfactual" && !c.refuted);
  if (cf.length > 0) {
    reviewEntries.push(
      [`## Change Cycle ${cycle} — counterfactual — ${now}`, `- [blocker] ${cf[0].text}`, "status: concerns-raised"].join("\n")
    );
  }

  // The dedicated adversarial pass's surviving findings (raised_by "adversary").
  const adv = surviving.filter((c) => c.raised_by === "adversary");
  if (adv.length > 0) {
    const al = [`## Change Cycle ${cycle} — adversarial (security/money/pii) — ${now}`];
    for (const c of adv) al.push(`- [${c.severity}] ${c.text}${c.refuted ? ` (refuted-by: ${c.refuted_by})` : ""}`);
    al.push(`status: ${adv.some((c) => !c.refuted) ? "concerns-raised" : "approved"}`);
    reviewEntries.push(al.join("\n"));
  }

  const escalation_payload =
    verdict === "escalate"
      ? {
          reason: escalationReason || "cycle-budget-exhausted-with-open-blockers",
          cycle,
          cycle_budget: cycleBudget,
          surviving_blockers: surviving.filter((c) => c.severity === "blocker" && !c.refuted),
          emitted_at: now,
        }
      : null;

  // PHASE transitions: clean → CHANGE_REVIEW (the command ships from here);
  // revise → BUILD (coder re-implements); escalate → ESCALATED.
  const nextPhase = verdict === "escalate" ? "ESCALATED" : verdict === "revise" ? "BUILD" : "CHANGE_REVIEW";

  return {
    sdd_fleet_version: "0.2",
    feature,
    run_id: runId,
    phase: "CHANGE_REVIEW",
    cycle,
    verdict,
    surviving_concerns: surviving,
    review_entries: reviewEntries,
    state_delta: {
      PHASE: nextPhase,
      CHANGE_CYCLE: cycle,
      // Recorded so the NEXT change cycle's dispatch can pass prior_blockers and the
      // count-must-fall guard can fire (the workflow has no filesystem to read it).
      CHANGE_SURVIVING_BLOCKERS: typeof survivingBlockerCount === "number" ? survivingBlockerCount : 0,
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

// Minimal envelope for the incomplete/invalid-args paths: releases the workflow
// marker (ownership-checked against run_id) and refreshes UPDATED only. state_delta
// deliberately OMITS PHASE and CHANGE_CYCLE so the scribe leaves them at their
// pre-run values; nothing is appended to REVIEW.md and no ESCALATION.md is written.
function cleanupEnvelope(feature, now, runId) {
  return {
    sdd_fleet_version: "0.2",
    feature,
    run_id: runId,
    phase: "CHANGE_REVIEW",
    cycle: 0,
    verdict: "incomplete",
    surviving_concerns: [],
    review_entries: [],
    state_delta: now ? { UPDATED: now } : {},
    next_legal_commands: ["/sdd-fleet:pr-review"],
    escalation_payload: null,
  };
}

// ---------- verified scribe application ----------
// (SCRIBE_RESULT_SCHEMA is declared near the top of this file, above the first
// applyScribe() call site, to avoid a temporal-dead-zone error.)

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
