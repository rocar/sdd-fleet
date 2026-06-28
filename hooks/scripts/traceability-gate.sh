#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit): the TRACEABILITY gate, in code.
#
# The design (docs/sdd-fleet-design.html:743,858) requires every acceptance
# criterion to map to a test BEFORE implementation begins. Without this hook that
# ordering lived only in command/agent prose (audit A4): a coder could write
# source against an incomplete or absent test plan. This gate refuses a SOURCE
# write during a forward feature's BUILD until TEST_PLAN.md exists and every
# acceptance criterion (AC-<n>) appears in it — mapped to a test row, or recorded
# under ## Gaps (a documented, CHANGE_REVIEW-blocking non-coverage).
#
# Scope: forward lane, PHASE=BUILD, spec FINALIZED, and only SOURCE targets
# (outside .sdd/ and tests/). qa's .sdd/ + tests/ authoring writes pass through;
# the bug lane is gated on its own source side (require-reproducing-test). When
# the acceptance source carries no AC-<n> ids the gate is inert — the finalize
# gate is the authority on AC presence/decidability.
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

# No active feature → allow.
[ -n "$slug" ] || exit 0

# Forward lane only; the bug lane gates source via require-reproducing-test.
[ "$(resolve_lane "$slug")" = "feature" ] || exit 0

# Only during BUILD, and only once the spec is FINALIZED (pre-FINALIZE source is
# block-source-before-finalized's job).
[ "$(read_progress_field "$slug" PHASE)" = "BUILD" ] || exit 0
[ "$(read_spec_status "$slug")" = "FINALIZED" ] || exit 0

file_path=$(extract_file_path "$input")
[ -n "$file_path" ] || exit 0

# Only SOURCE writes are traced. `.sdd/` (TEST_PLAN.md, IMPL_NOTES.md, …) and
# tests/ writes are not source; `..` traversal is rejected inside the helpers.
path_in_sdd "$file_path" && exit 0
path_in_tests "$file_path" && exit 0

# Gather the acceptance criteria (acceptance.md preferred, else inline in spec.md).
accept_src=""
[ -f ".sdd/${slug}/acceptance.md" ] && accept_src="${accept_src}
$(cat ".sdd/${slug}/acceptance.md" 2>/dev/null || true)"
[ -f ".sdd/${slug}/spec.md" ] && accept_src="${accept_src}
$(cat ".sdd/${slug}/spec.md" 2>/dev/null || true)"

ac_ids=$(printf '%s' "$accept_src" | grep -oE 'AC-[0-9]+' | sort -u || true)

# No AC ids → inert (finalize owns AC presence; nothing to trace here).
[ -n "$ac_ids" ] || exit 0

block() {
  echo "sdd-fleet: source write to '${file_path}' refused — $1. Every acceptance criterion must map to a test in TEST_PLAN.md (or be recorded under ## Gaps) before implementation begins." >&2
  exit 2
}

plan=".sdd/${slug}/TEST_PLAN.md"
[ -f "$plan" ] || block "no TEST_PLAN.md exists yet (qa drafts the failing suite + coverage matrix first — tests-first)"

covered=$(grep -oE 'AC-[0-9]+' "$plan" | sort -u || true)

missing=""
for id in $ac_ids; do
  if ! printf '%s\n' "$covered" | grep -qx "$id"; then
    missing="${missing} ${id}"
  fi
done
[ -z "$missing" ] || block "acceptance criteria not yet mapped to a test in TEST_PLAN.md:${missing}"

# Every AC is traced → implementation may proceed.
exit 0
