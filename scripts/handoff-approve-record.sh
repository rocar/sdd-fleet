#!/usr/bin/env bash
# scripts/handoff-approve-record.sh <feature-slug> --now <iso8601> [--by <who>]
#
# Writes .sdd/<slug>/HANDOFF_APPROVAL.md — the human's approval of the CURRENT blast radius,
# pinned by BLAST_RADIUS_SIGNATURE (computed by blast-radius-signature.sh, THE single home the
# blast-radius gate re-verifies against; record and verify therefore cannot drift). Its presence
# + a matching signature is what lets a risky change pass the gate at the HANDOFF transition; a
# widened blast radius yields a new signature, so the recorded approval goes stale and the gate
# re-blocks.
#
# cwd-relative (the member repo root, like epic-ratify-record.sh). Deterministic: --now is
# injected by the caller (the human-only /sdd-fleet:handoff-approve command); the script reads no
# clock. Emits one JSON status line; exit 0 on record, exit 1 on any refusal/usage error
# (not-required | already-approved | signature-failed).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: handoff-approve-record.sh <feature-slug> --now <iso8601> [--by <who>]" >&2; exit 1; }

SLUG=""; NOW=""; BY="human"
while [ $# -gt 0 ]; do
  case "$1" in
    --now) NOW="${2:-}"; shift 2 || usage ;;
    --by)  BY="${2:-}";  shift 2 || usage ;;
    --) shift ;;
    -*) echo "handoff-approve-record: unknown flag: $1" >&2; usage ;;
    *)  if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "handoff-approve-record: unexpected arg: $1" >&2; usage; fi ;;
  esac
done
[ -n "$SLUG" ] || usage
[ -n "$NOW" ]  || { echo "handoff-approve-record: --now <iso8601> is required (the caller supplies it; the script reads no clock)" >&2; exit 1; }

# Current blast-radius verdict + signature (the single home).
sig_json=$(bash "$DIR/blast-radius-signature.sh") || { printf '{"status":"signature-failed","feature":"%s"}\n' "$SLUG"; exit 1; }
[ "$(printf '%s' "$sig_json" | jq -r '.required // false')" = "true" ] || { printf '{"status":"not-required","feature":"%s"}\n' "$SLUG"; exit 1; }
signature=$(printf '%s' "$sig_json" | jq -r '.signature // empty')
[ -n "$signature" ] || { printf '{"status":"signature-failed","feature":"%s"}\n' "$SLUG"; exit 1; }

APPROVAL=".sdd/${SLUG}/HANDOFF_APPROVAL.md"
# An existing approval whose signature still MATCHES the current radius → idempotent no-op.
# A stale one (signature differs) is overwritten below — the human is re-approving the new radius.
if [ -f "$APPROVAL" ]; then
  recorded=$({ grep -m1 '^BLAST_RADIUS_SIGNATURE:' "$APPROVAL" 2>/dev/null || true; } \
    | sed -E 's/^BLAST_RADIUS_SIGNATURE:[[:space:]]*//' | tr -d '\r ')
  [ "$recorded" = "$signature" ] && { printf '{"status":"already-approved","feature":"%s","signature":"%s"}\n' "$SLUG" "$signature"; exit 1; }
fi

mkdir -p ".sdd/${SLUG}"
{
  printf '# Handoff Approval — %s\n\n' "$SLUG"
  printf 'APPROVED: %s\n' "$NOW"
  printf 'APPROVED_BY: %s\n' "$BY"
  printf 'BLAST_RADIUS_SIGNATURE: %s\n\n' "$signature"
  printf 'The human approved the blast radius below. The blast-radius gate re-verifies this\n'
  printf 'signature at the HANDOFF transition and re-blocks if the radius changes (the approval\n'
  printf 'goes stale) — re-run /sdd-fleet:handoff-approve to re-pin.\n\n'
  printf 'Approved blast radius:\n'
  printf '%s' "$sig_json" | jq -r '.verdict | (.producer_classes[]? | "  changed service carries: \(.)"), (.contracts[]? | "  contract \(.token): consumers=\(.consumers|join(",")) money_movement=\(.money_movement) pii=\(.pii)")' 2>/dev/null || true
} > "$APPROVAL"

printf '{"status":"recorded","feature":"%s","signature":"%s"}\n' "$SLUG" "$signature"
exit 0
