#!/usr/bin/env bash
# Tests for scripts/coverage.sh.
# QA's coverage verdict must be grounded in REAL tool output, not the model's
# opinion (audit C3). This script runs the project's coverage tool, parses the total
# %, records it, and optionally gates a threshold. Hermetic: the coverage command is
# overridden via SDD_FLEET_COVERAGE_CMD so no real coverage tooling is needed.
# Run: bash scripts/coverage.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/coverage.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

run() { # run <coverage-cmd> [min] -> sets RC, OUT
  local cmd="$1" min="${2:-}"
  OUT=$( cd "$work" && SDD_FLEET_COVERAGE_CMD="$cmd" SDD_FLEET_COVERAGE_MIN="$min" CLAUDE_PROJECT_DIR="$work" bash "$SCRIPT" 2>/dev/null ); RC=$?
}
expect() { # expect <name> <want_rc> <want_substr>
  if [ "$RC" -eq "$2" ] && printf '%s' "$OUT" | grep -q "$3"; then
    pass=$((pass+1)); printf 'ok   %-34s rc=%s\n' "$1" "$RC"
  else
    fail=$((fail+1)); printf 'FAIL %-34s want rc=%s/%s got rc=%s (%s)\n' "$1" "$2" "$3" "$RC" "$OUT"
  fi
}

# A coverage report whose grand total is the LAST percentage token.
REPORT='printf "Name   Stmts   Miss  Cover\nfoo.py    10      1   90%%\nTOTAL     20      1   95%%\n"'

# report-only (no threshold) → captures the real %, exit 0
run "$REPORT" ""
expect "report-only-captures-pct" 0 '"verdict":"report"'
expect "report-only-pct-95"       0 '"pct":95'

# threshold met → ok, exit 0
run "$REPORT" "90"
expect "threshold-met-ok" 0 '"verdict":"ok"'

# threshold breached → below, exit 1
run "$REPORT" "98"
expect "threshold-breached-below" 1 '"verdict":"below"'

# decimal percentage compares correctly
run 'printf "TOTAL 87.5%%\n"' "90"
expect "decimal-below" 1 '"verdict":"below"'
run 'printf "TOTAL 87.5%%\n"' "80"
expect "decimal-ok" 0 '"verdict":"ok"'

# no percentage in output → skip, exit 3
run 'printf "tests passed, no coverage here\n"' "90"
expect "no-percent-skips" 3 '"verdict":"skip"'

# no coverage tool detected (empty cmd, bare temp dir) → skip, exit 3
OUT=$( cd "$work" && CLAUDE_PROJECT_DIR="$work" bash "$SCRIPT" 2>/dev/null ); RC=$?
expect "no-tool-skips" 3 '"verdict":"skip"'

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
