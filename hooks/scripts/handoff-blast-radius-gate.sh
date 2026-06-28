#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — the blast-radius human gate [D-b]. When a write
# transitions PROGRESS.md to PHASE: HANDOFF (the ship chokepoint), force a human gate when the
# change's blast radius is risky, UNLESS a human has approved *this* blast radius.
#
# The verdict + signature are computed by scripts/blast-radius-signature.sh — THE single home,
# also called by handoff-approve-record.sh, so the recorded approval digest and the digest the
# gate recomputes here can never drift (the plan-digest.sh single-home pattern, one layer up).
# "Risky" = the script's `required` (producer self-check OR a produced contract reaching ≥ N
# transitive consumers / money_movement / pii). Computed from the catalog, never a hardcoded name.
#
# ALLOW-WHEN-APPROVED: a risky change is permitted iff .sdd/<slug>/HANDOFF_APPROVAL.md records a
# BLAST_RADIUS_SIGNATURE equal to the CURRENT signature. A widened/changed blast radius yields a
# new signature ⇒ the recorded approval is STALE ⇒ block (re-approve). The approval is written by
# the human-only /sdd-fleet:handoff-approve command (disable-model-invocation).
#
# INERT (exit 0): not a PROGRESS.md→HANDOFF write; no active item; no service.json; not risky; or
# risky with a matching approval. Fail closed (exit 2) on a '..' path, an unreadable .sdd/ACTIVE,
# missing jq while active, a signature-computation fault, or any unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: handoff-blast-radius-gate errored — failing closed" >&2; exit 2' ERR
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
[ -f service.json ] || exit 0

# Compute the blast-radius verdict + signature (the single home). A hard fault exits non-zero →
# the ERR trap fails closed.
sig_json=$(bash "$DIR/../../scripts/blast-radius-signature.sh")
[ "$(printf '%s' "$sig_json" | jq -r '.required // false')" = "true" ] || exit 0
current=$(printf '%s' "$sig_json" | jq -r '.signature // empty')

# Allow-when-approved: a recorded approval whose signature matches the CURRENT blast radius.
approval=".sdd/${slug}/HANDOFF_APPROVAL.md"
if [ -f "$approval" ]; then
  recorded=$({ grep -m1 '^BLAST_RADIUS_SIGNATURE:' "$approval" 2>/dev/null || true; } \
    | sed -E 's/^BLAST_RADIUS_SIGNATURE:[[:space:]]*//' | tr -d '\r ')
  if [ -n "$current" ] && [ "$recorded" = "$current" ]; then
    exit 0
  fi
  echo "sdd-fleet: HANDOFF blocked for '${slug}' — the recorded approval is STALE: the blast radius changed since approval." >&2
  printf '%s' "$sig_json" | jq -r '.verdict.contracts[]? | "  contract \(.token): \(.consumers|length) transitive consumers (money_movement=\(.money_movement), pii=\(.pii))"' >&2 2>/dev/null || true
  printf '%s' "$sig_json" | jq -r '.verdict.producer_classes[]? | "  changed service carries sensitive data_class: \(.)"' >&2 2>/dev/null || true
  echo "Re-approve with /sdd-fleet:handoff-approve (it re-pins to the current blast radius)." >&2
  echo "Refused write: ${file}" >&2
  exit 2
fi

echo "sdd-fleet: HANDOFF blocked for '${slug}' — blast radius forces a human gate:" >&2
printf '%s' "$sig_json" | jq -r '.verdict.contracts[]? | "  contract \(.token): \(.consumers|length) transitive consumers (money_movement=\(.money_movement), pii=\(.pii))"' >&2 2>/dev/null || true
printf '%s' "$sig_json" | jq -r '.verdict.producer_classes[]? | "  changed service carries sensitive data_class: \(.)"' >&2 2>/dev/null || true
echo "A human must approve this handoff: run /sdd-fleet:handoff-approve (bare = preview, then 'approve')." >&2
echo "Refused write: ${file}" >&2
exit 2
