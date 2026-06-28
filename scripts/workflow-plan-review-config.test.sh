#!/usr/bin/env bash
# Tests the PURE config helper of workflows/plan-review.js — Layer 1 (configurable
# interrogation roster). normalizeRoles is EXTRACTED VERBATIM from plan-review.js
# between the LAYER1-PURE-HELPERS markers (real source, not a copy) and run under
# node. Allowed roster differs from review.js: only {architect, qa}
# have a LENS entry, so `coder` must be rejected here. Skips if node is absent.
# Run: bash scripts/workflow-plan-review-config.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WF="$ROOT/workflows/plan-review.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   workflow-plan-review-config (SKIPPED: node not found; enforced in CI)"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-plan-cfg.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk '/LAYER1-PURE-HELPERS START/{f=1;next} /LAYER1-PURE-HELPERS END/{f=0;next} f' "$WF" > "$TMP/helpers.js"
if [ ! -s "$TMP/helpers.js" ]; then
  echo "FAIL could not extract LAYER1-PURE-HELPERS region from $WF"
  exit 1
fi

cat "$TMP/helpers.js" - > "$TMP/run.js" <<'EOF'

let pass = 0, fail = 0;
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function check(name, cond) {
  if (cond) { pass++; console.log("ok   " + name); }
  else { fail++; console.log("FAIL " + name); }
}

let r;
r = normalizeRoles(undefined);
check("roles-default", r.error === null && eq(r.roles, ["architect","qa"]));
r = normalizeRoles(["qa","architect"]);
check("roles-two-ok", r.error === null && eq(r.roles, ["qa","architect"]));
r = normalizeRoles(["architect","architect","qa"]);
check("roles-dedup", r.error === null && eq(r.roles, ["architect","qa"]));
r = normalizeRoles(["architect"]);
check("roles-too-few", r.roles === null && /at least 2/.test(r.error || ""));
r = normalizeRoles(["coder","qa"]);
check("roles-coder-rejected", r.roles === null && /unknown/.test(r.error || ""));
r = normalizeRoles(["architect", 5]);
check("roles-nonstring", r.roles === null && r.error !== null);
r = normalizeRoles([]);
check("roles-empty", r.roles === null && r.error !== null);
r = normalizeRoles("architect,qa");
check("roles-not-array", r.roles === null && r.error !== null);

console.log("-----");
console.log("passed=" + pass + " failed=" + fail);
process.exit(fail > 0 ? 1 : 0);
EOF

node "$TMP/run.js"
