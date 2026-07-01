#!/usr/bin/env bash
# scripts/suite-record.sh <feature-slug> --now <iso8601>
#
# Run the write-locked suite and record the outcome into .sdd/<slug>/SUITE_RUN.md, pinned
# to the CURRENT change content by CHANGE_SIGNATURE (computed by
# `counterfactual-record.sh signature` — THE single home of the change-signature
# algorithm, so this record and handoff-suite-gate.sh's re-verification can never drift).
# The suite gate at the PROGRESS.md → HANDOFF flip requires RESULT: green with a fresh
# signature (ADR-0002: "no handoff on a failing or untraceable suite"); a later
# source/tests edit stales the record and the gate re-blocks until it is re-recorded.
#
# Test commands: SDD_FLEET_TEST_CMD overrides (same escape hatch as counterfactual.sh);
# else multi-stack detection mirroring stop-tests.sh — independent fall-throughs, NOT an
# elif chain (package.json must not shadow the others):
#   npm test --silent   when package.json carries .scripts.test
#   pytest -q           when pyproject.toml | pytest.ini | setup.cfg | tests/ exists AND
#                       pytest is installed (tests/ is the qa-authored suite home —
#                       counterfactual.sh's trigger); pytest rc 5 "no tests collected"
#                       counts as pass, same as stop-tests
#   make test           when the Makefile has a test: target
# ALL detected stacks must be green. No recognized command → RESULT: skip /
# REASON: no-test-command is RECORDED — the gate treats that as a BLOCK (no handoff
# without a suite; set SDD_FLEET_TEST_CMD and re-record).
#
# Deterministic: --now is injected by the caller; the script reads no clock. cwd-relative.
# Exit: 0 green · 1 red · 3 skip (each with the record written) · 2 usage / missing jq /
# signature failure (nothing recorded).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: suite-record.sh <feature-slug> --now <iso8601>" >&2; exit 2; }

SLUG=""; NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now) NOW="${2:-}"; shift 2 || usage ;;
    --) shift ;;
    -*) echo "suite-record: unknown flag: $1" >&2; usage ;;
    *)  if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "suite-record: unexpected arg: $1" >&2; usage; fi ;;
  esac
done
[ -n "$SLUG" ] || usage
[ -n "$NOW" ]  || { echo "suite-record: --now <iso8601> is required (the caller supplies it; the script reads no clock)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "suite-record: jq is required" >&2; exit 2; }

# Detect the test commands (override first, then the stop-tests multi-stack fall-throughs).
test_cmds=""
if [ -n "${SDD_FLEET_TEST_CMD:-}" ]; then
  test_cmds="${SDD_FLEET_TEST_CMD}
"
else
  if [ -f package.json ] && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    test_cmds="${test_cmds}npm test --silent
"
  fi
  if { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ] || [ -d tests ]; } \
     && command -v pytest >/dev/null 2>&1; then
    test_cmds="${test_cmds}pytest -q
"
  fi
  if [ -f Makefile ] && grep -Eq '^test:' Makefile; then
    test_cmds="${test_cmds}make test
"
  fi
fi

# Run every detected stack; the suite is green only if ALL are.
failed=""; cmds_csv=""
if [ -n "$test_cmds" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cmds_csv="${cmds_csv}${cmds_csv:+, }${c}"
    rc=0; eval "$c" >/dev/null 2>&1 || rc=$?
    # pytest exit 5 == "no tests collected" — a missing-suite signal, not a failure
    # (stop-tests semantics; a genuinely missing suite is the traceability leg's job).
    if [ "$rc" -eq 5 ] && printf '%s' "$c" | grep -q '^pytest'; then rc=0; fi
    [ "$rc" -eq 0 ] || failed="${failed}${failed:+, }${c}"
  done <<EOF
$test_cmds
EOF
fi

# Pin the record to the content the suite just ran against (post-run, so any artifacts the
# run created are part of the pin — the gate recomputes over the same tree at flip time).
sig=$(bash "$DIR/counterfactual-record.sh" signature 2>/dev/null) \
  || { printf 'SDD_FLEET_SUITE_RECORD: {"status":"signature-failed","feature":"%s"}\n' "$SLUG"; exit 2; }

result="green"; reason=""; rc_out=0
if [ -z "$test_cmds" ]; then
  result="skip"; reason="no-test-command"; rc_out=3
elif [ -n "$failed" ]; then
  result="red"; reason="failing: ${failed}"; rc_out=1
fi

mkdir -p ".sdd/${SLUG}"
{
  printf '# Suite Run — %s\n\n' "$SLUG"
  printf 'RECORDED: %s\n' "$NOW"
  printf 'RESULT: %s\n' "$result"
  printf 'REASON: %s\n' "$reason"
  printf 'TEST_COMMANDS: %s\n' "${cmds_csv:--}"
  printf 'CHANGE_SIGNATURE: %s\n\n' "$sig"
  printf 'The handoff suite gate re-verifies this record at the PROGRESS.md -> HANDOFF flip:\n'
  printf 'only a signature-fresh RESULT: green opens the gate (red, skip, stale, or missing\n'
  printf 'blocks — "no handoff on a failing or untraceable suite"). Any source or tests edit\n'
  printf 'after this record stales the signature — re-run scripts/suite-record.sh to re-pin.\n'
} > ".sdd/${SLUG}/SUITE_RUN.md"

jq -nc --arg f "$SLUG" --arg r "$result" --arg why "$reason" --arg c "${cmds_csv:--}" --arg s "$sig" \
  '{status:"recorded",feature:$f,result:$r,reason:$why,commands:$c,signature:$s}' \
  | sed 's/^/SDD_FLEET_SUITE_RECORD: /'
exit "$rc_out"
