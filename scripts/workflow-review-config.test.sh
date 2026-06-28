#!/usr/bin/env bash
# Tests the PURE config helpers of workflows/review.js — Layer 1 parameterization
# (configurable reviewer roster + cycle budget). The helpers (normalizeRoles,
# normalizeCycleBudget) are EXTRACTED VERBATIM from review.js between the
# LAYER1-PURE-HELPERS markers — so the REAL source is exercised, never a copy —
# and run under node (workflows are JS; CI already validates them via node).
# Skips gracefully if node is absent (CI always has it). bash 3.2 compatible.
# Run: bash scripts/workflow-review-config.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
REVIEW="$ROOT/workflows/review.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   workflow-review-config (SKIPPED: node not found; helpers enforced in CI)"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-review-cfg.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Pull the marked region (the pure consts + helpers) out of the real workflow.
awk '/LAYER1-PURE-HELPERS START/{f=1;next} /LAYER1-PURE-HELPERS END/{f=0;next} f' "$REVIEW" > "$TMP/helpers.js"
if [ ! -s "$TMP/helpers.js" ]; then
  echo "FAIL could not extract LAYER1-PURE-HELPERS region from $REVIEW"
  exit 1
fi

# helpers (from review.js) + driver (assertions) -> one node script.
cat "$TMP/helpers.js" - > "$TMP/run.js" <<'EOF'

let pass = 0, fail = 0;
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function check(name, cond) {
  if (cond) { pass++; console.log("ok   " + name); }
  else { fail++; console.log("FAIL " + name); }
}

// ---- normalizeRoles ----
let r;
r = normalizeRoles(undefined);
check("roles-default-undefined", r.error === null && eq(r.roles, ["architect","qa","coder"]));
r = normalizeRoles(null);
check("roles-default-null", r.error === null && eq(r.roles, ["architect","qa","coder"]));
r = normalizeRoles(["architect","qa"]);
check("roles-two-ok", r.error === null && eq(r.roles, ["architect","qa"]));
r = normalizeRoles(["architect","qa","coder"]);
check("roles-three-all-ok", r.error === null && eq(r.roles, ["architect","qa","coder"]));
r = normalizeRoles(["architect","architect","qa"]);
check("roles-dedup", r.error === null && eq(r.roles, ["architect","qa"]));
r = normalizeRoles(["architect"]);
check("roles-too-few", r.roles === null && /at least 2/.test(r.error || ""));
r = normalizeRoles(["architect","devops"]);
check("roles-unknown", r.roles === null && /unknown reviewer role/.test(r.error || ""));
r = normalizeRoles(["architect", 5]);
check("roles-nonstring", r.roles === null && r.error !== null);
r = normalizeRoles([]);
check("roles-empty", r.roles === null && r.error !== null);
r = normalizeRoles("architect,qa");
check("roles-not-array", r.roles === null && r.error !== null);

// ---- normalizeCycleBudget ----
let b;
b = normalizeCycleBudget(undefined);
check("budget-default", b.error === null && b.budget === 3 && b.clamped === false);
b = normalizeCycleBudget(3);
check("budget-3", b.error === null && b.budget === 3);
b = normalizeCycleBudget(2);
check("budget-2", b.error === null && b.budget === 2);
b = normalizeCycleBudget(1);
check("budget-1", b.error === null && b.budget === 1);
b = normalizeCycleBudget(5);
check("budget-clamp", b.error === null && b.budget === 3 && b.clamped === true);
b = normalizeCycleBudget(0);
check("budget-zero-rejected", b.budget === null && b.error !== null);
b = normalizeCycleBudget("2");
check("budget-string-parsed", b.error === null && b.budget === 2);
b = normalizeCycleBudget(2.5);
check("budget-noninteger-rejected", b.budget === null && b.error !== null);
b = normalizeCycleBudget("abc");
check("budget-nan-rejected", b.budget === null && b.error !== null);

console.log("-----");
console.log("passed=" + pass + " failed=" + fail);
process.exit(fail > 0 ? 1 : 0);
EOF

node "$TMP/run.js"
