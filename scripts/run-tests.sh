#!/usr/bin/env bash
# sdd-fleet test entrypoint (audit §3.8). Runs every hook suite, every
# scripts/ suite, and the planted-bug smoke test; prints a suite summary and
# exits non-zero if any suite failed. bash 3.2 compatible.
# Run: bash scripts/run-tests.sh
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0; total=0
for t in "$root"/hooks/scripts/*.test.sh "$root"/scripts/*.test.sh; do
  [ -f "$t" ] || continue
  total=$((total+1))
  echo "── $t"
  bash "$t" || fail=$((fail+1))
done
# node --check every committed workflow — a broken workflow is caught by the suite, not
# only at pin-time / by hand (audit G3). Skips cleanly if node is absent.
if command -v node >/dev/null 2>&1; then
  echo "── node --check workflows"
  total=$((total+1)); ok=1
  for w in "$root"/workflows/*.js; do
    [ -f "$w" ] || continue
    node --check "$w" 2>&1 || { echo "FAIL node --check $w"; ok=0; }
  done
  [ "$ok" -eq 1 ] || fail=$((fail+1))
fi
echo "── smoke"
total=$((total+1)); bash "$root/docs/smoke/smoke.sh" || fail=$((fail+1))
echo "suites: $total, failed: $fail"
exit $((fail > 0))
