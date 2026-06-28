#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit): the WRITE-LOCK gate, in code.
#
# The design's "trustworthy oracle" rule (docs/sdd-fleet-design.html:858): the
# coder is rewarded for turning the suite green, and the cheapest route to green
# is weakening a test — so the test paths are write-locked for the rest of the
# run and the coder physically cannot edit them. Without this hook that guarantee
# lived only in coder.md prose (audit A2, CRITICAL): a coder could edit a failing
# test to make it pass, defeating the RED→GREEN contract.
#
# The lock is keyed on a deterministic fact: PROGRESS.md TESTS_LOCKED, written by
# the orchestrator/scribe AFTER qa signals SDD_FLEET_QA_TESTS_READY and the suite
# is verified, BEFORE coder is dispatched. So tests/ stays freely writable during
# qa's authoring window (lock absent) and freezes the moment the suite is locked.
# Forward lane + PHASE=BUILD only: the bug lane's reproducing test lives in tests/
# and must stay writable through FIX (gated on the source side instead).
set -euo pipefail
# Fail CLOSED on any unexpected runtime error: exit 1 is non-blocking per the
# hooks contract (audit §3.5). Every deliberate allow below is an explicit exit 0.
trap 'echo "sdd-fleet: gate script errored unexpectedly — failing closed" >&2; exit 2' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
slug=$(resolve_active)

# No active feature → allow. Bootstrap-friendly.
[ -n "$slug" ] || exit 0

# Forward lane only — the bug lane's reproducing test lives in tests/ and stays
# writable through FIX (block-source-before-finalized / require-reproducing-test
# gate the source side there instead).
[ "$(resolve_lane "$slug")" = "feature" ] || exit 0

# The lock is a BUILD-phase guarantee, and only after the suite is locked.
[ "$(read_progress_field "$slug" PHASE)" = "BUILD" ] || exit 0
[ -n "$(read_progress_field "$slug" TESTS_LOCKED)" ] || exit 0

file_path=$(extract_file_path "$input")
[ -n "$file_path" ] || exit 0

# .sdd/ writes (TEST_PLAN.md, IMPL_NOTES.md, …) are always permitted.
path_in_sdd "$file_path" && exit 0

# Freeze the suite: any write under tests/ is refused while the lock holds.
# `..` traversal is rejected inside path_in_tests (audit §3.1), so it cannot
# smuggle a tests/ prefix; a traversal to source falls through to the source
# gates below (allowed here).
if path_in_tests "$file_path"; then
  echo "sdd-fleet: feature '${slug}' has a write-locked test suite (TESTS_LOCKED). The qa-authored tests are frozen for the rest of BUILD — the coder cannot edit the suite it is judged against." >&2
  echo "If a test is genuinely wrong, record a 'gap:' in IMPL_NOTES.md and surface it to the orchestrator (a spec/coverage issue for CHANGE_REVIEW); do not edit the test. Refused: ${file_path}" >&2
  exit 2
fi

# Source / other writes are this gate's no-business — the source gates own them.
# Note: like every Write|Edit path gate, a raw Bash write (`> tests/x`, `sed -i`)
# is the documented harness-wide chokepoint-evasion limit — the coder is told to
# use Edit/Write, and the scribe has no Bash.
exit 0
