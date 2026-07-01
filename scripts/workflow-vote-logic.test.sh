#!/usr/bin/env bash
# Tests the PURE vote/verdict helpers of workflows/review.js — the bounded,
# regression-guarded review loop (audit B4 + B5). blockerIdentity gives a
# deterministic "same blocker" comparison; computeVerdict escalates EARLY when the
# surviving-blocker count fails to strictly fall (not only on budget exhaustion).
# ADR-0002 additions pinned here too:
#   - the concern schema's optional `criterion` flows through mergeConcerns so
#     blockerIdentity's criterion branch is exercised through the REAL schema shape
#     (CONCERNS_SCHEMA is extracted from the source, and the sample payload is
#     asserted key-legal against it), not a hand-built object;
#   - the harness-side citation-existence check: a refutation citation must carry a
#     verbatim `quote`, and collectContested DISCARDS (before adjudication) any
#     refutation whose quote is not found — whitespace-normalized — in the artifact
#     text the workflow holds. Held-text absent → the existence check is inert.
# The helpers are EXTRACTED VERBATIM between the LAYER2-VOTE-HELPERS markers, so the
# REAL source runs, never a copy. Skips if node is absent (CI always has it).
# Run: bash scripts/workflow-vote-logic.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
REVIEW="$ROOT/workflows/review.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   workflow-vote-logic (SKIPPED: node not found; helpers enforced in CI)"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-vote.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk '/LAYER2-VOTE-HELPERS START/{f=1;next} /LAYER2-VOTE-HELPERS END/{f=0;next} f' "$REVIEW" > "$TMP/helpers.js"
if [ ! -s "$TMP/helpers.js" ]; then
  echo "FAIL could not extract LAYER2-VOTE-HELPERS region from $REVIEW"
  exit 1
fi

# Extract the REAL structured-output schemas so the criterion + quote paths are
# exercised through the actual schema shape, not a hand-built approximation. The
# schemas reference the runtime ROLES const, so a stub is prepended.
awk '/^const CONCERNS_SCHEMA = \{/{f=1} f{print} f&&/^\};/{exit}' "$REVIEW" > "$TMP/concerns-schema.js"
awk '/^const REFUTATION_SCHEMA = \{/{f=1} f{print} f&&/^\};/{exit}' "$REVIEW" > "$TMP/refutation-schema.js"
if [ ! -s "$TMP/concerns-schema.js" ] || [ ! -s "$TMP/refutation-schema.js" ]; then
  echo "FAIL could not extract CONCERNS_SCHEMA / REFUTATION_SCHEMA from $REVIEW"
  exit 1
fi
printf 'const ROLES = ["architect", "qa", "coder"];\n' > "$TMP/roles.js"

cat "$TMP/roles.js" "$TMP/concerns-schema.js" "$TMP/refutation-schema.js" "$TMP/helpers.js" - > "$TMP/run.js" <<'EOF'

let pass = 0, fail = 0;
function check(name, cond) {
  if (cond) { pass++; console.log("ok   " + name); }
  else { fail++; console.log("FAIL " + name); }
}

// ---- blockerIdentity: deterministic + normalizing ----
const a = blockerIdentity({ text: "Missing AC for the refund path" });
const b = blockerIdentity({ text: "missing   ac for the   REFUND path" });
const c = blockerIdentity({ text: "A completely different concern" });
check("identity-stable",        a === blockerIdentity({ text: "Missing AC for the refund path" }));
check("identity-normalizes",    a === b);           // case + whitespace insensitive
check("identity-distinguishes", a !== c);
check("identity-prefers-criterion", blockerIdentity({ criterion: "AC-3", text: "x" }) === blockerIdentity({ criterion: "AC-3", text: "y" }));

// ---- criterion flows through the REAL schema shape + mergeConcerns (ADR-0002) ----
const itemProps = CONCERNS_SCHEMA.properties.concerns.items.properties;
check("schema-criterion-optional-string",
  !!itemProps.criterion && itemProps.criterion.type === "string" &&
  CONCERNS_SCHEMA.properties.concerns.items.required.indexOf("criterion") === -1);
const qaPayload = {
  role: "qa",
  status: "concerns-raised",
  concerns: [
    { id: "qa-1", severity: "blocker", text: "refund path lacks an idempotency key", criterion: "AC-3" },
    { id: "qa-2", severity: "blocker", text: "no retention rule for exported PII" },
  ],
  ac_verdicts: [{ criterion: "AC-3", verdict: "fail" }],
};
// every key the sample uses is legal under the schema (additionalProperties:false),
// so the criterion path is exercised through the real schema shape.
check("payload-shape-legal",
  qaPayload.concerns.every((cc) => Object.keys(cc).every((k) => k in itemProps)));
const mergedQa = mergeConcerns([{ role: "qa", payload: qaPayload }]);
check("merge-carries-criterion",      mergedQa[0].criterion === "AC-3");
check("merge-nulls-absent-criterion", mergedQa[1].criterion === null);
// same mapped criterion, completely reworded text → SAME blocker identity
const reworded = mergeConcerns([{ role: "qa", payload: { role: "qa", status: "concerns-raised", ac_verdicts: [],
  concerns: [{ id: "qa-1", severity: "blocker", text: "idempotency key missing on the refund flow", criterion: "AC-3" }] } }]);
check("identity-criterion-across-cycles", blockerIdentity(mergedQa[0]) === blockerIdentity(reworded[0]));
// no criterion → falls back to normalized text
check("identity-text-fallback", blockerIdentity(mergedQa[1]) === blockerIdentity({ criterion: null, text: "no   Retention rule for exported PII" }));

// ---- computeVerdict: clean / revise / escalate(budget) / escalate(regression) ----
check("verdict-clean",        computeVerdict({ survivingBlockerCount: 0, cycle: 1, cycleBudget: 3, priorBlockerCount: null }) === "clean");
check("verdict-revise",       computeVerdict({ survivingBlockerCount: 2, cycle: 1, cycleBudget: 3, priorBlockerCount: null }) === "revise");
check("verdict-budget-esc",   computeVerdict({ survivingBlockerCount: 1, cycle: 3, cycleBudget: 3, priorBlockerCount: 5 }) === "escalate");
check("verdict-count-fell",   computeVerdict({ survivingBlockerCount: 2, cycle: 2, cycleBudget: 3, priorBlockerCount: 3 }) === "revise");
check("verdict-count-flat",   computeVerdict({ survivingBlockerCount: 2, cycle: 2, cycleBudget: 3, priorBlockerCount: 2 }) === "escalate");
check("verdict-count-rose",   computeVerdict({ survivingBlockerCount: 3, cycle: 2, cycleBudget: 3, priorBlockerCount: 1 }) === "escalate");
check("verdict-no-prior-ok",  computeVerdict({ survivingBlockerCount: 2, cycle: 2, cycleBudget: 3, priorBlockerCount: null }) === "revise");

// ---- validCitation: file + locator + verbatim quote (ADR-0002 decision 4) ----
check("schema-citation-requires-quote",
  REFUTATION_SCHEMA.properties.refutations.items.properties.citation.required.indexOf("quote") !== -1);
check("cite-valid",           validCitation({ file: "spec.md", locator: "§ X", quote: "Refunds must be idempotent." }) === true);
check("cite-missing-quote",   validCitation({ file: "spec.md", locator: "§ X" }) === false);
check("cite-empty-quote",     validCitation({ file: "spec.md", locator: "§ X", quote: "  " }) === false);
check("cite-missing-locator", validCitation({ file: "spec.md", locator: "", quote: "q" }) === false);
check("cite-null",            validCitation(null) === false);

// ---- quoteFoundInArtifacts: the deterministic citation-existence check ----
const specText = "## Constraints\nRefunds must be idempotent\nacross client retries.\nAll amounts use minor units.";
const held = [specText];
check("quote-found",           quoteFoundInArtifacts("Refunds must be idempotent across client retries.", held) === true);
check("quote-wrap-normalized", quoteFoundInArtifacts("Refunds must be\n   idempotent across client retries.", held) === true);
check("quote-not-found",       quoteFoundInArtifacts("Refunds may be replayed twice", held) === false);
check("quote-case-verbatim",   quoteFoundInArtifacts("refunds MUST be idempotent across client retries.", held) === false); // verbatim: case preserved
check("quote-inert-no-texts",  quoteFoundInArtifacts("anything at all", []) === true); // no held text → check is inert (command passed none)

// ---- collectContested: different-role + citation present + quote found; NO char-count ----
const concerns = [
  { id: "architect-1", raised_by: "architect", severity: "blocker", text: "t1", refuted: false },
  { id: "qa-1",        raised_by: "qa",        severity: "major",   text: "t2", refuted: false },
];
const refMap = {
  "architect-1": [
    { role: "architect", verdict: "refute", reason: "self refutation", citation: { file: "spec.md", locator: "x", quote: "All amounts use minor units." } }, // self → excluded
    { role: "coder",     verdict: "refute", reason: "nope",            citation: { file: "spec.md", locator: "§Y", quote: "All amounts use minor units." } }, // different role + citation + quote found → eligible
  ],
  "qa-1": [
    { role: "architect", verdict: "refute", reason: "missing citation", citation: null },  // no citation → excluded
    { role: "coder",     verdict: "affirm", reason: "agree" },                              // affirm → excluded
  ],
};
const contested = collectContested(concerns, refMap, held);
check("contested-picks-eligible",       contested.length === 1 && contested[0].id === "architect-1");
check("contested-self-excluded",        contested[0].candidates.length === 1 && contested[0].candidates[0].role === "coder");
check("contested-shortreason-eligible", contested[0].candidates[0].reason === "nope"); // a 4-char reason is eligible — the char-count proxy is GONE

// quote-found → reaches the adjudicator; quote-not-found → DISCARDED by code before
// adjudication (same consequence as a missing citation); absent held text → inert.
const goodRef = { "architect-1": [{ role: "qa", verdict: "refute", reason: "spec covers it", citation: { file: "spec.md", locator: "§ Constraints", quote: "Refunds must be   idempotent\nacross client retries." } }] };
const badRef  = { "architect-1": [{ role: "qa", verdict: "refute", reason: "spec covers it", citation: { file: "spec.md", locator: "§ Constraints", quote: "Refunds may be replayed twice" } }] };
check("contested-quote-found-reaches-adjudicator", collectContested(concerns, goodRef, held).length === 1);
check("contested-quote-not-found-discarded",       collectContested(concerns, badRef,  held).length === 0);
check("contested-no-held-text-inert",              collectContested(concerns, goodRef, []).length === 1);
check("contested-missing-quote-discarded",         collectContested(concerns, { "architect-1": [{ role: "qa", verdict: "refute", reason: "r", citation: { file: "spec.md", locator: "§ C" } }] }, []).length === 0);

// the quote rides the citation through mergeRefutations (the real pipeline)
const rm = mergeRefutations(["architect", "qa"], [null, { role: "qa", refutations: [
  { concern_id: "architect-1", verdict: "refute", reason: "r", citation: { file: "spec.md", locator: "L", quote: "All amounts use minor units." } },
] }]);
check("merge-refutations-carries-quote", rm["architect-1"][0].citation.quote === "All amounts use minor units.");
check("merge-refutations-quoted-contested", collectContested(concerns, rm, held).length === 1);

// ---- applyAdjudications: a concern dies ONLY on an adjudicated-SOUND refutation --
// (citation EXISTENCE was already verified by code in collectContested — the
// adjudicator's single verdict is soundness/support, ADR-0002 decision 4.)
let applied;
applied = applyAdjudications(concerns, contested, [{ concern_id: "architect-1", sound: true }]);
check("adj-sound-dies",          applied.find((cc) => cc.id === "architect-1").refuted === true);
applied = applyAdjudications(concerns, contested, [{ concern_id: "architect-1", sound: false }]);
check("adj-unsound-survives",    applied.find((cc) => cc.id === "architect-1").refuted === false);
applied = applyAdjudications(concerns, contested, [{ concern_id: "architect-1", sound: "yes" }]);
check("adj-garbled-survives",    applied.find((cc) => cc.id === "architect-1").refuted === false);
applied = applyAdjudications(concerns, contested, []);
check("adj-empty-fail-safe",     applied.find((cc) => cc.id === "architect-1").refuted === false);

// ---- uncoveredCriteria: every acceptance criterion needs a verdict (silence impossible) ----
const full = { ac_verdicts: [{ criterion: "AC-1", verdict: "pass" }, { criterion: "AC-2", verdict: "fail" }] };
check("ac-all-covered",           uncoveredCriteria(full, ["AC-1", "AC-2"]).length === 0);
const partial = { ac_verdicts: [{ criterion: "AC-1", verdict: "pass" }] };
check("ac-missing-reported",      JSON.stringify(uncoveredCriteria(partial, ["AC-1", "AC-2"])) === JSON.stringify(["AC-2"]));
check("ac-empty-payload-missing", uncoveredCriteria({}, ["AC-1"]).length === 1);
check("ac-no-criteria-inert",     uncoveredCriteria({}, []).length === 0);
check("ac-null-payload-missing",  uncoveredCriteria(null, ["AC-1"]).length === 1);

// ---- adversarialConcerns: security/money/pii hunted separately, non-clear → vote ----
const adv = {
  security:       { verdict: "blocker", findings: ["SQL injection in login query"] },
  money_movement: { verdict: "clear",   findings: [] },
  pii:            { verdict: "concern", findings: ["email logged in plaintext"] },
};
const ac = adversarialConcerns(adv);
check("adv-blocker-axis-blocker", ac.some((cc) => cc.severity === "blocker" && cc.text.indexOf("[security]") === 0));
check("adv-clear-axis-skipped",   !ac.some((cc) => cc.text.indexOf("money_movement") !== -1));
check("adv-concern-axis-major",   ac.some((cc) => cc.severity === "major" && cc.text.indexOf("[pii]") === 0));
check("adv-raised-by-adversary",  ac.every((cc) => cc.raised_by === "adversary"));
check("adv-criterion-null",       ac.every((cc) => cc.criterion === null)); // no AC maps to a risk-axis finding
check("adv-null-empty",           adversarialConcerns(null).length === 0);

// ---- crossServiceConcerns: semver cross-service impact → concern (the one model call) ----
const xsMajor = { contract: "pay.authorise", old: "3.2.0", new: "4.0.0", bump: "major", pinned_consumers: ["checkout", "ledger"], pinned_count: 2, model_call_required: false };
const cm = crossServiceConcerns(xsMajor, false);
check("xs-major-pinned-blocker", cm.length === 1 && cm[0].severity === "blocker" && cm[0].raised_by === "cross-service");
check("xs-criterion-null",       cm[0].criterion === null); // no AC maps to a contract-bump concern
const xsMinor = { contract: "pay.authorise", old: "3.2.0", new: "3.3.0", bump: "minor", pinned_consumers: ["checkout"], pinned_count: 1, model_call_required: true };
check("xs-minor-breaking-blocker", crossServiceConcerns(xsMinor, true).length === 1);
check("xs-minor-honest-clear",     crossServiceConcerns(xsMinor, false).length === 0);
const xsNoPinned = { contract: "x", old: "1.0.0", new: "2.0.0", bump: "major", pinned_consumers: [], pinned_count: 0, model_call_required: false };
check("xs-no-pinned-clear",        crossServiceConcerns(xsNoPinned, false).length === 0);
check("xs-null-clear",             crossServiceConcerns(null, false).length === 0);

console.log("-----");
console.log("passed=" + pass + " failed=" + fail);
process.exit(fail > 0 ? 1 : 0);
EOF

node "$TMP/run.js"
