#!/usr/bin/env bash
# Stop: while a sdd-fleet feature is active AND in a phase where its tests
# should exist, refuse to stop on a failing test suite. Silent no-op when no
# feature is active, the feature is pre-BUILD, or no recognized test stack is
# present, so unrelated sessions and bootstrap don't deadlock.
#
# Bounded (audit §3.6): honors the platform loop guard (stop_hook_active),
# keeps a consecutive-failure counter at .sdd/<slug>/.stop-test-retries, and
# on the 3rd consecutive red block appends an entry to ESCALATION.md and
# ALLOWS the stop (escalation is the outcome, a wedged session is not). A
# green run deletes the counter. Operator override: touch
# .sdd/<slug>/.skip-stop-tests to skip this gate entirely.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

# Loop guard: when a previous Stop block already re-engaged the session, the
# payload carries stop_hook_active=true — never block again in that state.
# Parsed without jq (this hook must not hard-require it): a literal match on
# the documented field is sufficient and fail-safe.
input=$(cat 2>/dev/null || true)
if printf '%s' "$input" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

slug=$(resolve_active)
[ -n "$slug" ] || exit 0

# Operator override: documented escape hatch for a knowingly-red suite.
if [ -f ".sdd/${slug}/.skip-stop-tests" ]; then
  echo "sdd-fleet: .sdd/${slug}/.skip-stop-tests present — stop-tests gate skipped (operator override)." >&2
  exit 0
fi

# Phase gate: tests are authored by qa during BUILD (tests-first). Before
# BUILD there are legitimately no tests, and the block-source-before-finalized
# gate makes it impossible for the session to create any. Running the suite in
# SPEC/REVIEW/FINALIZE therefore can only deadlock the stop. Only enforce the
# test gate once the feature has reached a phase where its tests should exist.
phase=$(read_progress_field "$slug" PHASE)
case "$phase" in
  BUILD|CHANGE_REVIEW|HANDOFF) ;;
  *) exit 0 ;;
esac

# Stack detection: independent fall-throughs, NOT an elif chain — a repo with
# package.json AND pytest AND a Makefile test target runs all of them (audit
# §4 hooks minor: package.json must not shadow the others).
test_cmds=""
if [ -f package.json ]; then
  if command -v jq >/dev/null 2>&1 && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    test_cmds="${test_cmds}npm test --silent
"
  fi
fi
if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ]; then
  if command -v pytest >/dev/null 2>&1; then
    test_cmds="${test_cmds}pytest -q
"
  fi
fi
if [ -f Makefile ]; then
  if grep -Eq '^test:' Makefile; then
    test_cmds="${test_cmds}make test
"
  fi
fi

[ -n "$test_cmds" ] || exit 0

failed_cmds=""
fail_tail=""
while IFS= read -r run_test_cmd; do
  [ -n "$run_test_cmd" ] || continue
  # Capture output and exit code without tripping `set -e`.
  out=$($run_test_cmd 2>&1) && rc=0 || rc=$?

  # pytest exit code 5 == "no tests collected". That is not a test failure; it
  # is a missing-suite signal. Treat it as a pass so an empty collection never
  # hard-blocks a stop — a genuinely missing suite is surfaced by the BUILD
  # orchestration and the CHANGE_REVIEW coverage gate, not by deadlocking Stop.
  if [ "$rc" -eq 5 ] && printf '%s' "$run_test_cmd" | grep -q '^pytest'; then
    rc=0
  fi

  if [ "$rc" -ne 0 ]; then
    failed_cmds="${failed_cmds}${failed_cmds:+, }${run_test_cmd}"
    fail_tail=$(printf '%s\n' "$out" | tail -n 40)
  fi
done <<< "$test_cmds"

counter=".sdd/${slug}/.stop-test-retries"

if [ -z "$failed_cmds" ]; then
  # Green: reset the consecutive-failure counter and allow the stop.
  rm -f "$counter"
  exit 0
fi

# Red: bump the consecutive-failure counter.
n=0
if [ -f "$counter" ]; then
  n=$(head -n1 "$counter" 2>/dev/null | tr -cd '0-9')
  [ -n "$n" ] || n=0
fi
n=$((n + 1))

if [ "$n" -ge 3 ]; then
  # 3rd consecutive red block: escalate to a human instead of wedging the
  # session (the plugin's bounded-at-3 contract). Append an entry in the
  # scribe's ESCALATION.md layout and ALLOW the stop.
  rm -f "$counter"
  esc=".sdd/${slug}/ESCALATION.md"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    [ -f "$esc" ] && printf '\n---\n\n'
    printf '# Escalation — %s\n\n' "$slug"
    printf '**Triggered**: %s\n' "$ts"
    printf '**Cycle at escalation**: %s\n' "$n"
    printf '**Reason**: stop-tests gate — test suite failed on %s consecutive stop attempts\n\n' "$n"
    printf '## Surviving blockers\n\n'
    printf -- '- blocker — stop-tests — failing: %s\n\n' "$failed_cmds"
    printf '```\n%s\n```\n\n' "$fail_tail"
    printf '## Recommended next step\n\n'
    printf 'Human review required. Fix the failing suite (or record why it must stay red), then resolve this escalation before resuming the feature.\n'
  } >> "$esc"
  echo "sdd-fleet: '${failed_cmds}' failed on ${n} consecutive stop attempts for feature '${slug}' — escalated to .sdd/${slug}/ESCALATION.md and allowing the stop." >&2
  exit 0
fi

printf '%s\n' "$n" > "$counter"
echo "sdd-fleet: '${failed_cmds}' failed for active feature '${slug}' (stop attempt ${n} of 3 before escalation). Tail:" >&2
echo "----" >&2
printf '%s\n' "$fail_tail" >&2
echo "----" >&2
exit 2
