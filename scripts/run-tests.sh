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
echo "── smoke"
total=$((total+1)); bash "$root/docs/smoke/smoke.sh" || fail=$((fail+1))
echo "suites: $total, failed: $fail"
exit $((fail > 0))
