#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — the HANDOFF SUITE gate (ADR-0002: "no handoff on
# a failing or untraceable suite" enforced at the tool boundary). When a write transitions
# PROGRESS.md to PHASE: HANDOFF (the same ship chokepoint as dependency-gate /
# handoff-blast-radius-gate / counterfactual-gate), require BOTH for the active forward
# feature:
#
#  1) TRACEABILITY at flip time — when the acceptance source (acceptance.md, else the
#     spec's inline criteria) carries AC-<n> ids, TEST_PLAN.md must exist and mention
#     every id (mapped to a test row, or documented under ## Gaps). This is the
#     traceability-gate predicate re-verified at the ship flip: BUILD enforced it before
#     source was written; this leg refuses to SHIP a change whose plan lost an AC since.
#     No AC ids → this leg is inert (the finalize gate owns AC presence).
#
#  2) A RECORDED, signature-fresh GREEN run — .sdd/<slug>/SUITE_RUN.md, written by
#     scripts/suite-record.sh (which runs every detected stack — SDD_FLEET_TEST_CMD
#     override, else the stop-tests.sh multi-stack detection). RESULT must be green and
#     CHANGE_SIGNATURE must match the CURRENT change content (recomputed via
#     `counterfactual-record.sh signature`, THE single home, so record and verify can
#     never drift). red / skip (no recognized test command — set SDD_FLEET_TEST_CMD and
#     re-record) / stale / missing → block.
#
# INERT (exit 0): not a PROGRESS.md→HANDOFF write; no active item; bug lane (its suite
# discipline is the reproducing-test gate + stop-tests); git absent or not a work tree
# (the standalone fail-open boundary — no change signature is computable there). Fail
# closed (exit 2) on a '..' path, an unreadable .sdd/ACTIVE, missing jq while active, a
# signature-computation fault, or any unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: handoff-suite-gate errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
file=$(extract_file_path "$input")
[ -n "$file" ] || exit 0
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing path containing '..': $file" >&2; exit 2;; esac

# Only the PROGRESS.md → HANDOFF transition is the chokepoint.
[ "$(basename "$file")" = "PROGRESS.md" ] || exit 0
content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')
printf '%s' "$content" | grep -Eq 'PHASE:[[:space:]]*HANDOFF' || exit 0

slug=$(resolve_active)
[ -n "$slug" ] || exit 0
# Forward lane only (TEST_PLAN.md and the suite record are forward-feature artifacts).
[ "$(resolve_lane "$slug")" = "feature" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

block() {
  echo "sdd-fleet: HANDOFF blocked for '${slug}' — $1." >&2
  echo "No handoff on a failing or untraceable suite. Record a fresh green run: bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/suite-record.sh\" ${slug} --now <iso8601> (/sdd-fleet:pr-review runs it before the flip)." >&2
  echo "Refused write: ${file}" >&2
  exit 2
}

# --- Leg 1: AC → test traceability, re-verified at flip time (traceability-gate predicate).
accept_src=""
[ -f ".sdd/${slug}/acceptance.md" ] && accept_src="${accept_src}
$(cat ".sdd/${slug}/acceptance.md" 2>/dev/null || true)"
[ -f ".sdd/${slug}/spec.md" ] && accept_src="${accept_src}
$(cat ".sdd/${slug}/spec.md" 2>/dev/null || true)"
ac_ids=$(printf '%s' "$accept_src" | grep -oE 'AC-[0-9]+' | sort -u || true)

if [ -n "$ac_ids" ]; then
  plan=".sdd/${slug}/TEST_PLAN.md"
  [ -f "$plan" ] || block "the suite is UNTRACEABLE: no TEST_PLAN.md maps the acceptance criteria to tests"
  covered=$(grep -oE 'AC-[0-9]+' "$plan" | sort -u || true)
  missing=""
  for id in $ac_ids; do
    if ! printf '%s\n' "$covered" | grep -qx "$id"; then
      missing="${missing} ${id}"
    fi
  done
  [ -z "$missing" ] || block "the suite is UNTRACEABLE: acceptance criteria not mapped to a test in TEST_PLAN.md (or recorded under ## Gaps):${missing}"
fi

# --- Leg 2: a recorded, signature-fresh green run of the suite.
rec=".sdd/${slug}/SUITE_RUN.md"
[ -f "$rec" ] || block "no recorded suite run exists"

field() { { grep -m1 "^$1:" "$rec" 2>/dev/null || true; } | sed -E "s/^$1:[[:space:]]*//" | tr -d '\r' | sed -E 's/[[:space:]]+$//'; }
result=$(field RESULT)
reason=$(field REASON)
recorded=$(field CHANGE_SIGNATURE)

# Recompute the change signature (the single home). A hard fault exits non-zero → the ERR
# trap fails closed.
current=$(bash "$DIR/../../scripts/counterfactual-record.sh" signature)
[ -n "$current" ] || block "the current change signature could not be computed"
[ -n "$recorded" ] || block "the recorded suite run carries no CHANGE_SIGNATURE (re-record it)"
[ "$recorded" = "$current" ] || block "the recorded suite run is STALE: the change content shifted since it ran"

case "$result" in
  green)
    exit 0 ;;
  red)
    block "the recorded suite run is RED (${reason:-unspecified}) — fix the suite, then re-record" ;;
  skip)
    block "the recorded suite run is skip (${reason:-unspecified}) — no recognized test command ran; set SDD_FLEET_TEST_CMD (or add a test stack) and re-record" ;;
  *)
    block "the recorded suite RESULT is '${result:-missing}' — only a fresh 'green' opens the gate" ;;
esac
