#!/usr/bin/env bash
# Tests the PURE cycle-budget helper of the workflows that carry one — deep-build.js
# and diagnose.js — Layer 1 (configurable, downward-only escalation budget).
# normalizeCycleBudget is EXTRACTED VERBATIM from EACH file between the
# LAYER1-PURE-HELPERS markers (real source, per-file copy → catches per-file drift)
# and run under node. Skips if node is absent. Run: bash scripts/workflow-cycle-budget.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   workflow-cycle-budget (SKIPPED: node not found; enforced in CI)"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail=0
for wf in deep-build diagnose; do
  f="$ROOT/workflows/$wf.js"
  awk '/LAYER1-PURE-HELPERS START/{f=1;next} /LAYER1-PURE-HELPERS END/{f=0;next} f' "$f" > "$TMP/$wf.js"
  echo "== $wf.js =="
  if [ ! -s "$TMP/$wf.js" ]; then
    echo "FAIL could not extract LAYER1-PURE-HELPERS region from $f"
    fail=1; continue
  fi
  cat "$TMP/$wf.js" - > "$TMP/$wf-run.js" <<'EOF'

let pass = 0, fail = 0;
function check(name, cond) {
  if (cond) { pass++; console.log("ok   " + name); }
  else { fail++; console.log("FAIL " + name); }
}
let b;
b = normalizeCycleBudget(undefined); check("budget-default", b.error === null && b.budget === 3 && b.clamped === false);
b = normalizeCycleBudget(3);         check("budget-3", b.error === null && b.budget === 3);
b = normalizeCycleBudget(2);         check("budget-2", b.error === null && b.budget === 2);
b = normalizeCycleBudget(1);         check("budget-1", b.error === null && b.budget === 1);
b = normalizeCycleBudget(5);         check("budget-clamp", b.error === null && b.budget === 3 && b.clamped === true);
b = normalizeCycleBudget(0);         check("budget-zero-rejected", b.budget === null && b.error !== null);
b = normalizeCycleBudget("2");       check("budget-string-parsed", b.error === null && b.budget === 2);
b = normalizeCycleBudget(2.5);       check("budget-noninteger-rejected", b.budget === null && b.error !== null);
b = normalizeCycleBudget("abc");     check("budget-nan-rejected", b.budget === null && b.error !== null);
console.log("passed=" + pass + " failed=" + fail);
process.exit(fail > 0 ? 1 : 0);
EOF
  node "$TMP/$wf-run.js" || fail=1
done

echo "-----"
[ "$fail" -eq 0 ] && echo "all cycle-budget helpers pass" || echo "cycle-budget helper FAILED"
exit "$fail"
