#!/usr/bin/env bash
# epic-ratify-record.sh <epic-slug> --now <iso8601> [--by <who>]
#
# Writes .sdd/_epic/<slug>/RATIFICATION.md — the human ratification record (the ONE fact
# that can't be re-derived) plus a content digest of plan.md + contracts.md, so a
# post-ratification edit to the plan is detectable rather than silently "still ratified".
# Its existence IS the ratified signal (see references/workspace-tier.md, "Derived status").
#
# Deterministic: --now is injected by the caller (the script reads no clock), so runs are
# reproducible and testable. Operates cwd-relative — the caller runs it at the workspace
# (superproject) root, the same convention as acquire-active.sh / next-feature.sh.
#
# Emits one JSON status line on stdout. Exit 0 on record; exit 1 on any refusal or usage
# error (recorded | already-ratified | no-epic | not-planned).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: epic-ratify-record.sh <epic-slug> --now <iso8601> [--by <who>]" >&2; exit 1; }

SLUG=""; NOW=""; BY="human"
while [ $# -gt 0 ]; do
  case "$1" in
    --now) NOW="${2:-}"; shift 2 || usage ;;
    --by)  BY="${2:-}";  shift 2 || usage ;;
    --) shift ;;
    -*) echo "epic-ratify-record: unknown flag: $1" >&2; usage ;;
    *)  if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "epic-ratify-record: unexpected arg: $1" >&2; usage; fi ;;
  esac
done
[ -n "$SLUG" ] || usage
[ -n "$NOW" ]  || { echo "epic-ratify-record: --now <iso8601> is required (the caller supplies it; the script reads no clock)" >&2; exit 1; }

EPICDIR=".sdd/_epic/${SLUG}"
PLAN="${EPICDIR}/plan.md"
CONTRACTS="${EPICDIR}/contracts.md"
RAT="${EPICDIR}/RATIFICATION.md"

[ -d "$EPICDIR" ] || { printf '{"status":"no-epic","epic":"%s"}\n' "$SLUG"; exit 1; }
{ [ -f "$PLAN" ] && [ -f "$CONTRACTS" ]; } || { printf '{"status":"not-planned","epic":"%s"}\n' "$SLUG"; exit 1; }
[ -f "$RAT" ] && { printf '{"status":"already-ratified","epic":"%s"}\n' "$SLUG"; exit 1; }

# Content digest of the ratified plan + contract design, via the shared helper — the SAME
# algorithm the epic-ratified-before-fanout hook re-validates against (single digest home).
digest=$(bash "$DIR/plan-digest.sh" "$PLAN" "$CONTRACTS")
[ -n "$digest" ] || { printf '{"status":"digest-failed","epic":"%s"}\n' "$SLUG"; exit 1; }

{
  printf '# Epic Ratification — %s\n\n' "$SLUG"
  printf 'RATIFIED: %s\n' "$NOW"
  printf 'RATIFIED_BY: %s\n' "$BY"
  printf 'PLAN_DIGEST: %s\n\n' "$digest"
  printf 'The dependency DAG (plan.md) and contract design (contracts.md) were ratified as written.\n'
  printf 'The presence of this file marks the epic RATIFIED: the conductor may dispatch its\n'
  printf 'stories and the epic-ratified-before-fanout gate permits their specs to be authored.\n'
  printf 'Materialisation into Jira: see JIRA_LINK.md.\n'
} > "$RAT"

printf '{"status":"recorded","epic":"%s","digest":"%s"}\n' "$SLUG" "$digest"
exit 0
