#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — the COUNTERFACTUAL gate (ADR-0002). When a write
# transitions PROGRESS.md to PHASE: HANDOFF (the ship chokepoint dependency-gate and the
# blast-radius gate also fire on), require a RECORDED counterfactual verdict for the active
# forward feature: .sdd/<slug>/COUNTERFACTUAL.md, written by scripts/counterfactual-record.sh
# after running the deterministic engine (scripts/counterfactual.sh — "the fully fail-closed
# hook form" its header anticipated; this hook is that form).
#
# FRESHNESS: the record carries CHANGE_SIGNATURE — a content digest of every non-.sdd
# tracked + untracked file, computed by `counterfactual-record.sh signature` (THE single
# home, so the recorded digest and the digest recomputed here can never drift — the
# blast-radius-signature.sh record-and-verify pattern). Any source or tests edit after the
# record yields a new signature ⇒ the record is STALE ⇒ block (re-record). A commit of
# identical content does NOT stale it (content-based, not diff-based), and .sdd/ writes
# (the records themselves, this very PROGRESS.md flip) never do.
#
# VERDICTS: pass + fresh → explicit allow. skip is gate-opening ONLY for
# REASON: no-source-change — nothing revertable, the counterfactual is vacuous by the
# engine's own semantics. Every other skip (no-test-command, baseline-red, …) means the
# engine COULD NOT decide → block, fail-closed (fix the cause — e.g. set
# SDD_FLEET_TEST_CMD, make the baseline green — and re-record). fail (the suite stays
# green on revert: decorative tests) / error / missing verdict → block.
#
# INERT (exit 0): not a PROGRESS.md→HANDOFF write; no active item; bug lane (its VERIFY
# counterfactual is the gated qa snapshot procedure — references/bug-lane.md); git absent
# or not a work tree (the standalone fail-open boundary, same as dependency-gate — no
# change signature is computable there). Fail closed (exit 2) on a '..' path, an
# unreadable .sdd/ACTIVE, missing jq while active, a signature-computation fault, or any
# unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: counterfactual-gate errored — failing closed" >&2; exit 2' ERR
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
# Forward lane only: the bug lane's VERIFY counterfactual is the mandatory qa snapshot
# procedure (references/bug-lane.md), not this record.
[ "$(resolve_lane "$slug")" = "feature" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

block() {
  echo "sdd-fleet: HANDOFF blocked for '${slug}' — $1." >&2
  echo "Record a fresh verdict first: bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/counterfactual-record.sh\" ${slug} --now <iso8601> (/sdd-fleet:pr-review runs it before the flip)." >&2
  echo "Refused write: ${file}" >&2
  exit 2
}

rec=".sdd/${slug}/COUNTERFACTUAL.md"
[ -f "$rec" ] || block "no recorded counterfactual verdict exists (the change must prove its tests go red on revert before it ships)"

field() { { grep -m1 "^$1:" "$rec" 2>/dev/null || true; } | sed -E "s/^$1:[[:space:]]*//" | tr -d '\r' | sed -E 's/[[:space:]]+$//'; }
verdict=$(field VERDICT)
reason=$(field REASON)
recorded=$(field CHANGE_SIGNATURE)

# Recompute the change signature (the single home). A hard fault exits non-zero → the ERR
# trap fails closed.
current=$(bash "$DIR/../../scripts/counterfactual-record.sh" signature)
[ -n "$current" ] || block "the current change signature could not be computed"
[ -n "$recorded" ] || block "the recorded counterfactual carries no CHANGE_SIGNATURE (re-record it)"
[ "$recorded" = "$current" ] || block "the recorded counterfactual verdict is STALE: the change content shifted since it was recorded"

case "$verdict" in
  pass)
    exit 0 ;;
  skip)
    # Deliberate allow: nothing revertable — the counterfactual is vacuous.
    [ "$reason" = "no-source-change" ] && exit 0
    block "the recorded counterfactual is skip (${reason:-unspecified}) — the engine could not decide; fix the cause (e.g. set SDD_FLEET_TEST_CMD, make the baseline green) and re-record" ;;
  fail)
    block "the recorded counterfactual verdict is FAIL — the suite stays green when the source change is reverted (decorative tests); fix the tests to actually exercise the change, then re-record" ;;
  *)
    block "the recorded counterfactual verdict is '${verdict:-missing}' — only a fresh 'pass' (or skip with reason no-source-change) opens the gate" ;;
esac
