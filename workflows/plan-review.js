// SPDX-License-Identifier: MIT
// workflows/plan-review.js
//
// sdd-fleet v0.4 — M3.1 product-tier PLAN_REVIEW workflow.
//
// FORK of workflows/review.js, deliberately diverged (the M3.0 decision: fork,
// don't parameterize). The product plan is a STRATEGIC BET, not a contract the
// machine can converge — so this workflow INTERROGATES (surfaces questions,
// risks, gaps from each role's lens) and never holds a survival vote. Nothing is
// auto-refuted; nothing auto-escalates. The output is an interrogation report
// appended to .sdd/_product/REVIEW.md and PHASE := PLAN_REVIEW. A human ratifies
// at /sdd-fleet:plan-finalize — the machine never votes a vision into being.
//
// Divergences from review.js:
//   - reviewers INTERROGATE product artifacts (vision/backlog/STACK/DECISIONS),
//     not spec.md/acceptance.md.
//   - roles are [architect, qa] — product lenses, not [architect,qa,coder].
//     Self-interrogation is fine: the act surfaces risk, it does not vote.
//   - NO cross-examination phase. NO survival vote. Findings are consolidated by
//     pure JS (grouped + counted), never killed.
//   - verdict is informational ("interrogated"), never clean/revise/escalate.
//   - scribe writes the PRODUCT workspace via the envelope's workspace_dir.
//
// CONTRACT: docs/v0.2/CONTRACT.md §6 (envelope + workspace_dir).
//
// @cost-ceiling {"input_tokens":90000,"output_tokens":24000}
// (Cost ceiling lives in this header comment, NOT meta. commands/plan-review.md
// parses this line to emit SDD_FLEET_COST_PREVIEW in headless mode.)

export const meta = {
  name: "sdd-fleet-plan-review",
  description: "Product-tier PLAN_REVIEW: interrogate the product plan from each role's lens, consolidate findings (no survival vote), scribe appends the report",
  phases: [
    { title: "Interrogate", detail: "the roster interrogates vision/backlog/STACK in parallel (configurable; default architect, qa)" },
    { title: "Consolidate", detail: "group + count findings by severity — nothing is auto-killed" },
    { title: "Apply", detail: "scribe appends the interrogation report to _product/REVIEW.md and sets PHASE=PLAN_REVIEW" },
  ],
};

// ---------- args ----------
// { product: "<slug>", cycle: <int>, now: "<iso8601>", run_id: "<marker token>", roles?: string[] }
// `now` is supplied by the command because the script cannot call Date.
// `run_id` is the token the command wrote into .sdd/_product/.workflow-in-flight
// at dispatch; the scribe releases the marker (empties it) only when its content matches.
// `roles` (optional) overrides the interrogation roster — a >=2-element subset of
//   {architect, qa} (the lenses defined below). Default is all three.
//   There is NO cycle_budget here: plan-review never votes or escalates.

const A = typeof args === "string" ? JSON.parse(args) : (args || {});

const product = A.product;
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

const WORKSPACE = ".sdd/_product/";

// --- LAYER1-PURE-HELPERS START — configurable interrogation roster ---
// Extracted VERBATIM by scripts/workflow-plan-review-config.test.sh, so this MUST
// stay pure: no log()/agent()/args, deterministic, side-effect-free. plan-review has
// NO cycle budget (it never votes or escalates), so ONLY the roster is configurable.
// Allowed roles are exactly those with a LENS entry below — {architect,
// qa}; `coder` is not a product-plan lens. >= 2 distinct, so the plan is interrogated
// from more than one lens. Default reproduces the historical roster. The const sits
// ABOVE the first call site (arg validation) to avoid a temporal-dead-zone read.
const ALLOWED_INTERROGATION_ROLES = ["architect", "qa"];
const DEFAULT_INTERROGATION_ROLES = ["architect", "qa"];

// normalizeRoles(raw) → { roles: string[]|null, error: string|null }
function normalizeRoles(raw) {
  if (raw === undefined || raw === null) return { roles: DEFAULT_INTERROGATION_ROLES.slice(), error: null };
  if (!Array.isArray(raw) || raw.length === 0)
    return { roles: null, error: "roles: must be a non-empty array of interrogation roles" };
  const seen = [];
  for (const r of raw) {
    if (typeof r !== "string" || ALLOWED_INTERROGATION_ROLES.indexOf(r) === -1)
      return { roles: null, error: `roles: unknown interrogation role ${JSON.stringify(r)} (allowed: ${ALLOWED_INTERROGATION_ROLES.join(", ")})` };
    if (seen.indexOf(r) === -1) seen.push(r);
  }
  if (seen.length < 2)
    return { roles: null, error: "roles: need at least 2 distinct roles so the plan is interrogated from more than one lens" };
  return { roles: seen, error: null };
}
// --- LAYER1-PURE-HELPERS END ---

// Validation failures are NEVER a bare throw: a throw would strand the
// .workflow-in-flight marker the command dropped (this script has no filesystem
// access — only the scribe can release it). Dispatch a minimal scribe cleanup
// envelope, then return a structured invalid-args verdict for the orchestrator.
const rolesResult = normalizeRoles(A.roles);

const argErrors = [];
if (!product || typeof product !== "string") argErrors.push("product: required non-empty string");
if (typeof cycle !== "number" || Number.isNaN(cycle)) argErrors.push("cycle: required integer");
if (!now || typeof now !== "string") argErrors.push("now: required iso8601 string (the dispatching command supplies it — the script cannot call Date)");
if (rolesResult.error) argErrors.push(rolesResult.error);
if (argErrors.length > 0) {
  log(`Invalid args: ${argErrors.join("; ")}. No state advanced.`);
  if (product && typeof product === "string") {
    await applyScribe(cleanupEnvelope(product, typeof now === "string" ? now : null, runId));
  }
  return {
    verdict: "invalid-args",
    errors: argErrors,
    note: product && typeof product === "string"
      ? "Marker cleanup dispatched; PHASE/CYCLE unchanged. Fix the dispatch args and re-run /sdd-fleet:plan-review."
      : "product unknown — the dispatching command must delete .sdd/_product/.workflow-in-flight itself (only if its content matches the run_id it wrote).",
  };
}

// Effective roster (validated above) — drives the fan-out AND the schema role enum.
const ROLES = rolesResult.roles;
log(`Interrogation roster: [${ROLES.join(", ")}].`);

// ---------- schema (structured interrogation output) ----------
//
// One object per interrogating role. `findings` is a flat list across the three
// kinds (question | risk | gap) so the role can weight its lens freely; `kind`
// distinguishes them for the report. No refutation/verdict fields — there is no
// vote here.

const INTERROGATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["role", "findings"],
  properties: {
    // role enum tracks the configured interrogation roster (Layer 1) — not a fixed list.
    role: { type: "string", enum: ROLES },
    findings: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "kind", "severity", "text"],
        properties: {
          id: { type: "string" },
          kind: { type: "string", enum: ["question", "risk", "gap"] },
          severity: { type: "string", enum: ["blocker", "major", "minor"] },
          text: { type: "string" },
          artifact: { type: "string" }, // optional: vision.md | backlog.md | STACK.md | DECISIONS.md
        },
      },
    },
  },
};

// ---------- Phase 1: fan-out interrogation ----------

phase("Interrogate");

const interrogations = await parallel(
  ROLES.map((role) => () =>
    agent(interrogatePrompt(role, product, cycle), {
      label: `interrogate:${role}`,
      phase: "Interrogate",
      agentType: `sdd-fleet:${role}`,
      schema: INTERROGATION_SCHEMA,
    })
  )
);

// Post-condition: every role must return a usable structured payload. Unlike the
// feature review, a missing payload does NOT escalate (there is no auto-escalate
// in plan-review) — it halts the workflow with an error the command surfaces, so
// the human re-runs. We never write a partial interrogation report.
const reports = ROLES.map((role, i) => ({ role, payload: interrogations[i] }));
for (const r of reports) {
  if (!r.payload || !Array.isArray(r.payload.findings)) {
    log(`Interrogation incomplete: ${r.role} returned no usable findings payload. Cleaning up without advancing state.`);
    // Do NOT write the report and do NOT advance PHASE/CYCLE — but we still must
    // remove the .workflow-in-flight marker the command dropped, or it orphans
    // until the reaper. The scribe is the only thing that can delete it (the
    // script has no filesystem access). A cleanup envelope whose state_delta
    // carries ONLY `UPDATED` leaves PHASE + CYCLE untouched (the scribe replaces
    // in place, key by key) while still triggering marker removal. Mirrors how
    // review.js always reaches its scribe on the missing-payload path.
    const scribeResult = await applyScribe(cleanupEnvelope(product, now, runId));
    return {
      verdict: "incomplete",
      reason: "missing-interrogator-payload",
      role: r.role,
      product,
      cycle,
      scribe_apply: scribeResult.ok ? "applied" : "failed",
      scribe_error: scribeResult.error,
      note: "No interrogation report written; PHASE/CYCLE unchanged. Re-run /sdd-fleet:plan-review.",
    };
  }
}

// ---------- Phase 2: consolidate (pure JS — nothing is killed) ----------

phase("Consolidate");

const allFindings = mergeFindings(reports);
const counts = countBySeverity(allFindings);

log(
  `Plan cycle ${cycle}: ${allFindings.length} findings interrogated ` +
  `(${counts.blocker} blocker, ${counts.major} major, ${counts.minor} minor). ` +
  `No survival vote — all findings surfaced for human ratification.`
);

// ---------- Phase 3: apply via scribe ----------

phase("Apply");

const envelope = buildEnvelope({ product, cycle, now, reports, allFindings, counts });
const scribeResult = await applyScribe(envelope);

return {
  verdict: "interrogated",
  product,
  cycle,
  findings: allFindings.length,
  open_blockers: counts.blocker,
  scribe_apply: scribeResult.ok ? "applied" : "failed",
  scribe_error: scribeResult.error,
  next: scribeResult.ok ? envelope.next_legal_commands : [],
  note: !scribeResult.ok
    ? "SCRIBE APPLY FAILED after retry — the interrogation report/PROGRESS did NOT land and the .workflow-in-flight marker may remain. The dispatching command must report failure, not success."
    : counts.blocker > 0
    ? `${counts.blocker} blocker-severity finding(s) open. /sdd-fleet:plan-finalize will require 'ratify force' to override.`
    : "No blocker-severity findings. /sdd-fleet:plan-finalize ratify will pass.",
};

// ================= helpers =================

function interrogatePrompt(role, product, cycle) {
  const lens = LENS[role];
  return `You are the ${role}, INTERROGATING the product plan for "${product}". Plan-review cycle ${cycle}.

This is NOT a spec review and NOT a vote. You are surfacing what a strategic plan
must answer before a human commits to it. You cannot kill anyone's finding and no
finding kills the plan — everything you raise is recorded for the human to weigh.

**Do NOT write or edit any file** — even artifacts you normally own (vision/backlog).
This phase is read-only interrogation; you return findings only. The scribe is the
sole writer; the human revises the plan after reading your report.

Read these product artifacts yourself (you have Read/Grep/Glob):
- .sdd/_product/vision.md      (the product vision + goals; OUTCOME for standard/large)
- .sdd/_product/backlog.md     (phased feature backlog + dependencies + per-feature intent lines)
- .sdd/_product/STACK.md       (the binding stack-of-record; brownfield has a Baseline + maybe PROVISIONAL forward)
- .sdd/_product/DECISIONS.md   (product ADRs — the why behind the stack)
- .sdd/_product/REVIEW.md      (prior interrogation cycles; may not exist on cycle 1)

**Pressure-test the per-feature INTENT lines (v0.4 M3.3).** Each backlog row should
have an indented one-to-three-line intent — what the feature is + its scope boundary.
These intents are inherited by /sdd-fleet:jira-story to seed each spec, so a vague,
overlapping, or wrongly-bounded intent yields a wrong spec downstream. From your lens,
interrogate: is each intent clear enough to drive a spec, or too vague to constrain it?
Are the boundaries between sibling features clean (no two features claiming the same
scope; no scope falling in the gap between them)? Do the stated boundaries/deferrals
justify the depends-on edges? Is any feature under-scoped (a real concern hidden) or
over-scoped (should be split)? A missing intent line on a non-trivial feature is itself
a gap. **But do not demand spec-level detail in the intent** — acceptance criteria,
interfaces, and behavior belong in the feature's own spec.md, not the backlog.

Interrogate through YOUR lens:
${lens}

Honor the brownfield contract: a "## Forward direction (PROVISIONAL — unreviewed)"
section is strategy that does NOT yet bind. Interrogate whether the provisional
direction is justified — but do NOT treat the binding Baseline as a defect for
merely existing. Flag a stack concern as a finding to the human, never as a demand
to rewrite reality.

Return the structured object you are required to produce:
- role: "${role}"
- findings: array of { id, kind, severity, text, artifact? }
  - id: stable "${role}-1", "${role}-2", ...
  - kind: "question" (an unanswered decision the plan must resolve) |
          "risk" (a way this plan plausibly fails) |
          "gap" (something the plan should cover but omits)
  - severity: "blocker" (a human should not ratify until this is addressed) |
              "major" (should be resolved or consciously accepted) |
              "minor" (worth noting; not ratification-blocking)
  - artifact (optional): which file the finding is about.
  If the plan is sound from your lens, return an empty findings array — that is a
  legitimate signal (you found nothing ratification-relevant), not a failure.`;
}

const LENS = {
  "architect":
`- Is the stack-of-record sound for the stated goals and scale? Any load-bearing gap?
- Is each ADR justified, or are there silent/unexplained choices?
- Brownfield: is the Baseline captured accurately? Is any PROVISIONAL forward direction
  incremental (migrate/wrap) rather than a rewrite, and is its risk named?
- What failure modes (data integrity, blast radius, coupling) does the plan not address?
- INTENT: do the intents' stated boundaries/deferrals match the stack's module seams,
  and justify the depends-on edges? Is a load-bearing piece deferred into a feature
  whose intent does not actually claim it (a boundary gap)?`,
  "qa":
`- Is the OUTCOME / are the goals actually measurable and testable as written?
- Does each backlog phase have a discernible acceptance shape, or is "done" undefined?
- What observability / verification is the plan silent on?
- Are there cross-feature integration risks the phasing hides?
- INTENT: is each intent concrete enough that a tester could see *that* it's testable
  (not *what* the tests are), or so vague that "done" is undefinable? Flag intents too
  thin to anchor a spec — but never demand acceptance criteria here (that's the spec).`,
};

function mergeFindings(reports) {
  const out = [];
  for (const r of reports) {
    for (const f of r.payload.findings || []) {
      out.push({
        id: f.id,
        kind: f.kind,
        severity: f.severity,
        raised_by: r.role,
        text: f.text,
        artifact: f.artifact || null,
      });
    }
  }
  return out;
}

function countBySeverity(findings) {
  const c = { blocker: 0, major: 0, minor: 0 };
  for (const f of findings) {
    if (c[f.severity] !== undefined) c[f.severity] += 1;
  }
  return c;
}

function buildEnvelope({ product, cycle, now, reports, allFindings, counts }) {
  // One REVIEW.md block per role, grouped by kind. Append-only; the scribe writes
  // .sdd/_product/REVIEW.md (workspace_dir below routes it there).
  const KIND_ORDER = ["question", "risk", "gap"];
  const KIND_LABEL = { question: "Open questions", risk: "Risks", gap: "Gaps" };

  const reviewEntries = reports.map((r) => {
    const own = allFindings.filter((f) => f.raised_by === r.role);
    const lines = [`## Plan Cycle ${cycle} — ${r.role} interrogation — ${now}`];
    if (own.length === 0) {
      lines.push("- (no ratification-relevant findings from this lens)");
    } else {
      for (const kind of KIND_ORDER) {
        const group = own.filter((f) => f.kind === kind);
        if (group.length === 0) continue;
        lines.push(`### ${KIND_LABEL[kind]}`);
        for (const f of group) {
          const where = f.artifact ? ` (${f.artifact})` : "";
          lines.push(`- [${f.severity}] ${f.text}${where}`);
        }
      }
    }
    return lines.join("\n");
  });

  // A consolidated summary block, last, so the human sees totals at the tail.
  reviewEntries.push(
    [
      `## Plan Cycle ${cycle} — interrogation summary — ${now}`,
      `- findings: ${allFindings.length} (blocker: ${counts.blocker}, major: ${counts.major}, minor: ${counts.minor})`,
      counts.blocker > 0
        ? `- ratification: BLOCKED by ${counts.blocker} open blocker-severity finding(s) — /sdd-fleet:plan-finalize requires 'ratify force' to override.`
        : `- ratification: no blocker-severity findings — /sdd-fleet:plan-finalize ratify will pass.`,
    ].join("\n")
  );

  return {
    sdd_fleet_version: "0.2",
    feature: product, // scribe uses this for SCRIBE_OK + any ESCALATION title; carries the product slug
    run_id: runId,
    workspace_dir: WORKSPACE,
    phase: "PLAN_REVIEW",
    cycle,
    verdict: "interrogated", // informational — plan-review never votes
    surviving_concerns: [], // no survival vote in plan-review
    review_entries: reviewEntries,
    state_delta: {
      PHASE: "PLAN_REVIEW",
      CYCLE: cycle,
      UPDATED: now,
    },
    next_legal_commands: ["/sdd-fleet:plan-finalize", "/sdd-fleet:plan-review"],
    escalation_payload: null, // plan-review never auto-escalates — the human ratifies
  };
}

// Minimal envelope for the incomplete-interrogation/invalid-args paths: removes
// the workflow marker (ownership-checked against run_id) and refreshes UPDATED
// only. state_delta deliberately OMITS PHASE/CYCLE so the scribe leaves them at
// their pre-run values (it only replaces keys present).
function cleanupEnvelope(product, now, runId) {
  return {
    sdd_fleet_version: "0.2",
    feature: product,
    run_id: runId,
    workspace_dir: WORKSPACE,
    phase: "PLAN_REVIEW",
    cycle: 0,
    verdict: "incomplete",
    surviving_concerns: [],
    review_entries: [], // nothing appended to REVIEW.md
    state_delta: now ? { UPDATED: now } : {}, // PHASE + CYCLE intentionally preserved
    next_legal_commands: ["/sdd-fleet:plan-review"],
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
        `Apply this sdd-fleet workflow envelope to ${envelope.workspace_dir} exactly per your instructions in agents/scribe.md. Note the workspace_dir field — you write the PRODUCT workspace, not a feature dir.

Marker ownership: RELEASE ${envelope.workspace_dir}.workflow-in-flight by overwriting it with EMPTY content via the Write tool (you have no Bash; an empty marker counts as released and is reaped later) — ONLY if its current content matches the envelope's run_id${envelope.run_id ? ` ("${envelope.run_id}")` : " (null — legacy envelope: release unconditionally, best-effort)"}. If the content differs, leave the marker — it belongs to another run.

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
