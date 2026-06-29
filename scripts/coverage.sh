#!/usr/bin/env bash
# Deterministic coverage capture (audit C3).
#
# The design's "floor under detection" requires QA to be grounded in REAL coverage
# output, not the model's opinion of it. Today nothing measures coverage — the qa
# verdict is the model's read of the test matrix. This script runs the project's
# coverage tool, parses the total %, and (optionally) gates a threshold. The COMMAND
# runs it (the workflow sandbox cannot exec) and records the result in IMPL_NOTES.md,
# so the qa reviewer reacts to the captured number rather than guessing.
#
# Coverage tooling varies by stack, so the command is overridable via
# SDD_FLEET_COVERAGE_CMD; the threshold via SDD_FLEET_COVERAGE_MIN (unset =
# report-only — capture the real %, never gate). The total % is taken as the LAST
# percentage token in the report (coverage tools print the grand total last).
#
# Exit: 0 ok (>= threshold, or report-only) · 1 below threshold · 3 skip (no tool /
# no % parsed) · 2 error. The SDD_FLEET_COVERAGE: stdout line is the machine contract.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || { printf 'SDD_FLEET_COVERAGE: {"verdict":"error","reason":"cwd"}\n'; exit 2; }

emit() { printf 'SDD_FLEET_COVERAGE: %s\n' "$1"; }

cmd="${SDD_FLEET_COVERAGE_CMD:-}"
if [ -z "$cmd" ]; then
  if { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ]; } && command -v pytest >/dev/null 2>&1; then
    cmd="pytest -q --cov --cov-report=term"
  elif [ -f package.json ] && command -v npx >/dev/null 2>&1; then
    cmd="npx --no-install nyc --reporter=text npm test --silent"
  elif [ -f Makefile ] && grep -Eq '^coverage:' Makefile; then
    cmd="make coverage"
  fi
fi
[ -n "$cmd" ] || { emit '{"verdict":"skip","reason":"no-coverage-tool"}'; exit 3; }

out=$(eval "$cmd" 2>&1) || true

# Total coverage % = the last percentage token in the report. Tool-agnostic;
# override SDD_FLEET_COVERAGE_CMD for an exotic stack whose total isn't last.
pct=$(printf '%s\n' "$out" | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -n1 | tr -d '%')
[ -n "$pct" ] || { emit '{"verdict":"skip","reason":"no-percent-parsed"}'; exit 3; }

min="${SDD_FLEET_COVERAGE_MIN:-}"
if [ -n "$min" ]; then
  # bash has no float compare; awk does the >= threshold check.
  below=$(awk -v p="$pct" -v m="$min" 'BEGIN { print (p + 0 < m + 0) ? 1 : 0 }')
  if [ "$below" = "1" ]; then
    emit "{\"verdict\":\"below\",\"pct\":${pct},\"min\":${min}}"
    exit 1
  fi
  emit "{\"verdict\":\"ok\",\"pct\":${pct},\"min\":${min}}"
  exit 0
fi

emit "{\"verdict\":\"report\",\"pct\":${pct}}"
exit 0
