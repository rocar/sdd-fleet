// SPDX-License-Identifier: MIT
// workflows/diagnose.js
//
// sdd-fleet v0.5 (troubleshoot-fix lane) — DIAGNOSE confirmation workflow.
//
// An INVERTED fork of review.js. Where review.js runs a survival vote on reviewer
// *concerns* (a concern survives unless refuted), diagnose.js runs the dual: a single
// root-cause *hypothesis* (recorded in diagnosis.md) is CONFIRMED iff it is NOT refuted
// by a substantive, different-role, reproduction-citing refutation. The "concern" set is
// the reviewers' refutations of the hypothesis; the hypothesis survives confirmation iff
// none of those refutations survives cross-examination.
//
// Reviewer roles are [architect, coder].
// Evidence is the REPRODUCTION (the failing test / diagnosis.md reproduction steps), not
// spec.md/acceptance.md — so the structured citation {file, locator} targets the reproduction.
//
// CONTRACT: docs/v0.2/CONTRACT.md (the scribe envelope is reused unchanged).
//
// @cost-ceiling {"input_tokens":90000,"output_tokens":24000}
//
// API NOTES (same as review.js): agent(prompt, opts) → text or validated object with
// opts.schema; parallel(thunks) is a BARRIER (errors → null); phase(title) groups agents;
// args may arrive as a JSON string; NO Date.now()/Math.random()/new Date() — now comes via args.

export const meta = {
  name: "sdd-fleet-diagnose",
  description: "Bug-lane diagnosis confirmation: reviewers try to refute the root-cause hypothesis citing the reproduction; the hypothesis is CONFIRMED iff no substantive refutation survives cross-examination",
  phases: [
    { title: "Refute", detail: "architect + coder attempt to refute the root-cause hypothesis, citing the reproduction" },
    { title: "Cross-examination", detail: "each reviewer challenges the other's refutation" },
    { title: "Survival vote", detail: "the hypothesis is CONFIRMED unless a refutation survives" },
    { title: "Apply", detail: "scribe writes REVIEW + PROGRESS deltas" },
  ],
};

// ---------- args: { slug, cycle, now, run_id, cycle_budget? } ----------
// `cycle_budget` (optional) is the escalation budget, integer 1..3; default 3,
// configurable DOWNWARD only (the workflow clamps anything above the ceiling).
// `run_id` is the token the command wrote into .sdd/<slug>/.workflow-in-flight
// at dispatch; the scribe releases the marker (empties it) only when its content matches.
const A = typeof args === "string" ? JSON.parse(args) : (args || {});
const slug = A.slug;
const cycle = typeof A.cycle === "string" ? parseInt(A.cycle, 10) : A.cycle;
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
// pure: no log()/agent()/args, deterministic, side-effect-free. The DIAGNOSE
// escalation budget is configurable DOWNWARD only — values above the ceiling are
// clamped, so the "escalate, don't loop forever" invariant holds no matter what a
// caller asks. Default reproduces the historical budget (3). Consts sit ABOVE the
// first call site (arg validation) to avoid a temporal-dead-zone read.
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
if (!slug || typeof slug !== "string") argErrors.push("slug: required non-empty string");
if (typeof cycle !== "number" || Number.isNaN(cycle)) argErrors.push("cycle: required integer");
if (!now || typeof now !== "string") argErrors.push("now: required iso8601 string (the dispatching command supplies it — the script cannot call Date)");
if (budgetResult.error) argErrors.push(budgetResult.error);
if (argErrors.length > 0) {
  log(`Invalid args: ${argErrors.join("; ")}. No state advanced.`);
  if (slug && typeof slug === "string") {
    await applyScribe(cleanupEnvelope(slug, typeof now === "string" ? now : null, runId));
  }
  return {
    verdict: "invalid-args",
    errors: argErrors,
    note: slug && typeof slug === "string"
      ? "Marker cleanup dispatched; PHASE/CYCLE unchanged. Fix the dispatch args and re-run /sdd-fleet:feature-dev."
      : "slug unknown — the dispatching command must delete .sdd/<slug>/.workflow-in-flight itself (only if its content matches the run_id it wrote).",
  };
}

const ROLES = ["architect", "coder"];
const cycleBudget = budgetResult.budget;
log(`Refuter roster: [${ROLES.join(", ")}]; cycle budget ${cycleBudget}.`);
if (budgetResult.clamped) {
  log(`cycle_budget requested ${JSON.stringify(A.cycle_budget)} exceeds the protocol ceiling — capped to ${MAX_CYCLE_BUDGET}.`);
}

// ---------- schemas ----------

// Structured citation shared by both phases: required (validated in JS) on any
// "refute" verdict; omitted on "affirm".
const CITATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["file", "locator"],
  properties: {
    file: { type: "string" },
    locator: { type: "string" },
  },
};

// Phase 1: each reviewer attempts to refute the single recorded hypothesis.
const REFUTE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "verdict", "reason"],
  properties: {
    role: { type: "string", enum: ["architect", "coder"] },
    verdict: { type: "string", enum: ["refute", "affirm"] },
    reason: { type: "string" },
    citation: CITATION_SCHEMA,
  },
};

// Phase 2: each reviewer defends-or-concedes the OTHER's refutation (cross-exam).
const CROSSEXAM_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "responses"],
  properties: {
    role: { type: "string", enum: ["architect", "coder"] },
    responses: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["challenge_id", "verdict", "reason"],
        properties: {
          challenge_id: { type: "string" },
          // "refute" = this peer refutation is itself unsound (defends the hypothesis);
          // "affirm" = the peer's refutation stands.
          verdict: { type: "string", enum: ["refute", "affirm"] },
          reason: { type: "string" },
          citation: CITATION_SCHEMA,
        },
      },
    },
  },
};

// ---------- Phase 1: refute the hypothesis ----------

phase("Refute");

const refuteResults = await parallel(
  ROLES.map((role) => () =>
    agent(refutePrompt(role, slug, cycle), {
      label: `refute:${role}`,
      phase: "Refute",
      agentType: `sdd-fleet:${role}`,
      schema: REFUTE_SCHEMA,
    })
  )
);

// Post-condition (mirrors review.js): every reviewer must return a usable payload.
// A null here is an agent error (timeout / crash / schema failure) — a transient
// runtime fault, NOT a diagnosis outcome. Do not escalate (ESCALATED +
// ESCALATION.md is reserved for genuine cycle exhaustion); clean up the marker,
// leave PHASE/CYCLE untouched, and tell the caller to re-run.
const refutals = ROLES.map((role, i) => ({ role, payload: refuteResults[i] }));
for (const r of refutals) {
  if (!r.payload || typeof r.payload.verdict !== "string") {
    log(`Diagnosis confirmation incomplete: ${r.role} returned no usable refutation payload. Cleaning up without advancing state.`);
    const scribeResult = await applyScribe(cleanupEnvelope(slug, now, runId));
    return {
      verdict: "incomplete",
      reason: "missing-reviewer-payload",
      role: r.role,
      slug,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "No REVIEW.md entries written; PHASE/CYCLE unchanged. Re-run /sdd-fleet:feature-dev.",
    };
  }
}

// A refutation becomes a live "challenge" only if it is substantive: verdict=refute,
// >=40 chars, and cites the reproduction. (Same substantiveness floor as review.js, with
// the evidence target retargeted from spec/acceptance to the reproduction.)
const challenges = toChallenges(refutals);

// ---------- Phase 2: cross-examination ----------

phase("Cross-examination");

let crossMap = {};
if (challenges.length > 0) {
  const xResults = await parallel(
    ROLES.map((role) => () =>
      agent(crossExamPrompt(role, challenges, slug, cycle), {
        label: `cross-exam:${role}`,
        phase: "Cross-examination",
        agentType: `sdd-fleet:${role}`,
        schema: CROSSEXAM_SCHEMA,
      })
    )
  );
  crossMap = mergeCrossExam(ROLES, xResults);
}

// ---------- Phase 3: survival vote (pure JS) ----------

phase("Survival vote");

const judged = applyHypothesisVote(challenges, crossMap);
const survivingRefutations = judged.filter((c) => !c.refuted);
const verdict =
  survivingRefutations.length > 0 ? (cycle >= cycleBudget ? "escalate" : "refuted") : "confirmed";

log(
  `Cycle ${cycle}: ${challenges.length} substantive refutation(s), ` +
  `${survivingRefutations.length} surviving → verdict=${verdict}`
);

// ---------- Phase 4: apply via scribe ----------

phase("Apply");

const envelope = buildEnvelope({ slug, cycle, cycleBudget, now, refutals, judged, verdict });
const scribeResult = await applyScribe(envelope);

return {
  verdict,
  slug,
  cycle,
  substantive_refutations: challenges.length,
  surviving_refutations: survivingRefutations.length,
  scribe_apply: scribeResult.ok ? "applied" : "failed",
  scribe_error: scribeResult.error,
  next: scribeResult.ok ? envelope.next_legal_commands : [],
  note: scribeResult.ok
    ? undefined
    : "SCRIBE APPLY FAILED after retry — REVIEW.md/PROGRESS.md did NOT land and the .workflow-in-flight marker may remain. The dispatching command must report failure, not success.",
};

// ================= helpers =================

function refutePrompt(role, slug, cycle) {
  return `You are the ${role} reviewer in DIAGNOSIS CONFIRMATION, cycle ${cycle}. Active bug: ${slug}.

Read these yourself (you have Read/Grep/Glob):
- .sdd/${slug}/diagnosis.md   (the recorded root-cause hypothesis, blast radius, and fix strategy)
- the reproduction: the failing test(s) under tests/, and the "Symptom + reproduction steps" section

Your job is ADVERSARIAL: try to REFUTE the recorded root-cause hypothesis. A diagnosis is
confirmed only by surviving attack, so default to suspicion. ${role === "architect"
    ? "Lens: does the hypothesis actually explain the reproduced behavior? Is the blast radius honest? Is there a more likely cause the reproduction points to?"
    : "Lens: is the fix strategy feasible and does it address THIS root cause? Does the reproduction's actual failure match the claimed mechanism?"}

A refutation only counts if it is substantive: at least ~40 characters of reasoning AND a
structured citation of the reproduction as counter-evidence. On a "refute" verdict, set the
citation field to { file, locator } — e.g. { "file": "diagnosis.md", "locator": "§ Symptom" }
or { "file": "tests/test_login.py", "locator": "line 42" }. A refute without a citation is
discarded by the script. If you cannot substantively refute the hypothesis citing the
reproduction, AFFIRM it (that is the honest outcome when the diagnosis holds — no citation
needed on an affirm).

Return the structured object:
- role: "${role}"
- verdict: "refute" (the hypothesis is unsound) or "affirm" (it withstands your attack)
- reason: your reasoning
- citation: { file, locator } — REQUIRED when verdict is "refute".`;
}

function crossExamPrompt(role, challenges, slug, cycle) {
  const peers = challenges.filter((c) => c.raised_by !== role);
  return `You are the ${role} reviewer in CROSS-EXAMINATION, cycle ${cycle}. Active bug: ${slug}.

Read .sdd/${slug}/diagnosis.md and the reproduction (failing test(s) under tests/) yourself.

Below are refutations of the root-cause hypothesis raised by the OTHER reviewer. For each,
decide whether to REFUTE it (you believe the refutation itself is unsound — i.e. the hypothesis
actually still holds against the reproduction) or AFFIRM it (the refutation stands; the
hypothesis is genuinely in doubt).

A refutation-of-a-refutation only counts if substantive: at least ~40 characters AND a
structured citation of the reproduction. On a "refute" response, set the citation field to
{ file, locator } — e.g. { "file": "diagnosis.md", "locator": "§ Fix strategy" } or
{ "file": "tests/test_login.py", "locator": "line 42" }. A refute without a citation is
discarded by the script. If you cannot substantively defend the hypothesis, AFFIRM the
peer's refutation (the safe default — an unsupported hypothesis should not be confirmed;
no citation needed on an affirm).

Peer refutations:
${JSON.stringify(peers.map((c) => ({ challenge_id: c.id, raised_by: c.raised_by, reason: c.text, citation: c.citation })), null, 2)}

Return the structured object:
- role: "${role}"
- responses: array of { challenge_id, verdict ("refute"|"affirm"), reason, citation? }.
  citation = { file, locator } and is REQUIRED when verdict is "refute".
  One entry per peer refutation.`;
}

// A structured citation is valid when both file and locator are non-empty strings.
// (Deliberately NOT validated against a fixed file list — locators like
// "§ Symptom" or "line 42" against any cited reproduction artifact are acceptable.)
function validCitation(c) {
  return !!c &&
    typeof c.file === "string" && c.file.trim().length > 0 &&
    typeof c.locator === "string" && c.locator.trim().length > 0;
}

// Phase-1 refutations → live challenges (substantive refute verdicts only).
function toChallenges(refutals) {
  const MIN = 40;
  const out = [];
  for (const r of refutals) {
    const p = r.payload;
    if (
      p && p.verdict === "refute" &&
      typeof p.reason === "string" && p.reason.length >= MIN && validCitation(p.citation)
    ) {
      out.push({
        id: `${r.role}-refutation`,
        severity: "blocker",   // a surviving refutation blocks CONFIRMED (renders in ESCALATION.md)
        raised_by: r.role,
        text: p.reason,
        citation: p.citation,
        refuted: false,
        refuted_by: null,
        refutation_reason: null,
      });
    }
  }
  return out;
}

function mergeCrossExam(roles, xResults) {
  const map = {};
  roles.forEach((role, i) => {
    const payload = xResults[i];
    if (!payload || !Array.isArray(payload.responses)) return;
    for (const resp of payload.responses) {
      (map[resp.challenge_id] ||= []).push({
        role,
        verdict: resp.verdict,
        reason: resp.reason,
        citation: resp.citation || null,
      });
    }
  });
  return map;
}

// A challenge (refutation of the hypothesis) is itself REFUTED — i.e. the hypothesis is
// defended — only by a substantive, different-role, reproduction-citing response. A
// challenge that survives means the hypothesis is genuinely in doubt.
function applyHypothesisVote(challenges, crossMap) {
  const MIN = 40;
  return challenges.map((c) => {
    const defenses = (crossMap[c.id] || []).filter(
      (d) =>
        d.verdict === "refute" &&
        d.role !== c.raised_by &&
        typeof d.reason === "string" &&
        d.reason.length >= MIN &&
        validCitation(d.citation)
    );
    if (defenses.length === 0) return c;
    const d = defenses[0];
    return { ...c, refuted: true, refuted_by: d.role, refutation_reason: d.reason, refutation_citation: d.citation };
  });
}

function buildEnvelope({ slug, cycle, cycleBudget, now, refutals, judged, verdict }) {
  const reviewEntries = refutals.map((r) => {
    const p = r.payload;
    const lines = [`## Cycle ${cycle} — ${r.role} — ${now}`];
    lines.push(`- verdict: ${p.verdict}`);
    const cite = validCitation(p.citation) ? ` (cites ${p.citation.file} ${p.citation.locator})` : "";
    lines.push(`  ${(p.reason || "").replace(/\n+/g, " ")}${cite}`);
    const own = judged.find((c) => c.raised_by === r.role);
    if (own && own.refuted) {
      const dcite = own.refutation_citation
        ? ` (cites ${own.refutation_citation.file} ${own.refutation_citation.locator})`
        : "";
      lines.push(`  refutation-overturned-by: ${own.refuted_by} — ${own.refutation_reason}${dcite}`);
    }
    return lines.join("\n");
  });

  const escalation_payload =
    verdict === "escalate"
      ? {
          // field name `surviving_blockers` matches the reused scribe's ESCALATION renderer
          reason: "diagnosis-not-confirmed-cycle-budget-exhausted",
          cycle,
          cycle_budget: cycleBudget,
          surviving_blockers: judged.filter((c) => !c.refuted),
          emitted_at: now,
        }
      : null;

  // PHASE advance (the scribe writes PROGRESS PHASE, like review.js — it never writes the
  // diagnosis.md body): `confirmed` advances to FIX; the /sdd-fleet:feature-dev gate then flips
  // diagnosis.md STATUS → CONFIRMED (the content write the scribe must not do, mirroring how
  // /sdd-fleet:feature-dev flips spec.md after review). `refuted` stays at DIAGNOSE for a
  // re-run; `escalate` is terminal.
  return {
    sdd_fleet_version: "0.5",
    feature: slug,            // scribe targets .sdd/<feature>/ — here the bug slug
    run_id: runId,
    phase: "DIAGNOSE",
    cycle,
    verdict,
    surviving_concerns: judged,
    review_entries: reviewEntries,
    state_delta: {
      PHASE: verdict === "escalate" ? "ESCALATED" : verdict === "confirmed" ? "FIX" : "DIAGNOSE",
      CYCLE: cycle,
      UPDATED: now,
    },
    next_legal_commands:
      verdict === "confirmed"
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
function cleanupEnvelope(slug, now, runId) {
  return {
    sdd_fleet_version: "0.5",
    feature: slug,
    run_id: runId,
    phase: "DIAGNOSE",
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
