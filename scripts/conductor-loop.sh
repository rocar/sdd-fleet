#!/usr/bin/env bash
# scripts/conductor-loop.sh — one reconcile sweep: fire conductor-tick.sh once per
# epic. The set of epics IS the set of .sdd/_epic/*/ dirs (ground truth — no index
# that could drift), minus the reserved `lessons/` dir. The "loop" proper is the
# harness re-invoking this sweep; nothing here decides anything (the tick does),
# so it is not proof-bearing beyond being modelless. Modelless: --now injected, no
# clock, no randomness, no creation. Usage:
#   conductor-loop.sh --now <iso8601> [--owner <id>] [--registry <dir>]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/_lib.sh
. "$DIR/../hooks/scripts/_lib.sh"
TICK="$DIR/conductor-tick.sh"

now=""
passthru=()
while [ $# -gt 0 ]; do
  case "$1" in
    --now)      now="${2:-}"; passthru+=(--now "${2:-}");      shift 2 ;;
    --owner)    passthru+=(--owner "${2:-}");                  shift 2 ;;
    --registry) passthru+=(--registry "${2:-}");              shift 2 ;;
    *) echo "conductor-loop: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$now" ] || { echo "conductor-loop: --now <iso8601> is required (the caller supplies it; the script reads no clock)." >&2; exit 2; }

[ -d .sdd/_epic ] || { printf '{"status":"no-epics","epics":0}\n'; exit 0; }

swept=0
for d in .sdd/_epic/*/; do
  [ -d "$d" ] || continue
  slug="$(basename "$d")"
  case "$slug" in lessons) continue ;; esac   # reserved cross-service-lessons dir, not an epic
  # --now is always in passthru (required above), so the array is never empty
  # (avoids the bash 3.2 set -u empty-array expansion trap).
  bash "$TICK" "$slug" "${passthru[@]}" || true
  swept=$((swept+1))
done
printf '{"status":"swept","epics":%d}\n' "$swept"
