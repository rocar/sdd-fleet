#!/usr/bin/env bash
# Tests the PURE vote/verdict helpers of workflows/review.js — the bounded,
# regression-guarded review loop (audit B4 + B5). blockerIdentity gives a
# deterministic "same blocker" comparison; computeVerdict escalates EARLY when the
# surviving-blocker count fails to strictly fall (not only on budget exhaustion).
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

cat "$TMP/helpers.js" - > "$TMP/run.js" <<'EOF'

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

// ---- computeVerdict: clean / revise / escalate(budget) / escalate(regression) ----
check("verdict-clean",        computeVerdict({ survivingBlockerCount: 0, cycle: 1, cycleBudget: 3, priorBlockerCount: null }) === "clean");
check("verdict-revise",       computeVerdict({ survivingBlockerCount: 2, cycle: 1, cycleBudget: 3, priorBlockerCount: null }) === "revise");
check("verdict-budget-esc",   computeVerdict({ survivingBlockerCount: 1, cycle: 3, cycleBudget: 3, priorBlockerCount: 5 }) === "escalate");
check("verdict-count-fell",   computeVerdict({ survivingBlockerCount: 2, cycle: 2, cycleBudget: 3, priorBlockerCount: 3 }) === "revise");
check("verdict-count-flat",   computeVerdict({ survivingBlockerCount: 2, cycle: 2, cycleBudget: 3, priorBlockerCount: 2 }) === "escalate");
check("verdict-count-rose",   computeVerdict({ survivingBlockerCount: 3, cycle: 2, cycleBudget: 3, priorBlockerCount: 1 }) === "escalate");
check("verdict-no-prior-ok",  computeVerdict({ survivingBlockerCount: 2, cycle: 2, cycleBudget: 3, priorBlockerCount: null }) === "revise");

console.log("-----");
console.log("passed=" + pass + " failed=" + fail);
process.exit(fail > 0 ? 1 : 0);
EOF

node "$TMP/run.js"
