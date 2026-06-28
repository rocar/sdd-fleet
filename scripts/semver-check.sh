#!/usr/bin/env bash
# scripts/semver-check.sh <contract> --old <semver> --new <semver> [--catalog f | --root d]
# DETERMINISTIC bump classification + pinned-consumer lookup. Emits model_call_required — the
# SEAM for the single isolated model call ("is this diff semantically breaking beyond its
# bump?"); this script NEVER calls a model. The decision is logged to stderr.
#   {contract,old,new,bump:"major|minor|patch|none",pinned_consumers:[…],pinned_count:N,model_call_required:bool}
# Downgrade or malformed semver → exit 1. Read-only.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

contract=""; old=""; new=""; catalog_file=""; root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --old) old="${2:-}"; shift 2;;
    --new) new="${2:-}"; shift 2;;
    --catalog) catalog_file="${2:-}"; shift 2;;
    --root) root="${2:-}"; shift 2;;
    --) shift;;
    -*) echo "semver-check: unknown flag $1" >&2; exit 2;;
    *)  if [ -z "$contract" ]; then contract="$1"; shift; else echo "semver-check: unexpected arg $1" >&2; exit 2; fi;;
  esac
done
[ -n "$contract" ] && [ -n "$old" ] && [ -n "$new" ] || { echo "usage: semver-check.sh <contract> --old <semver> --new <semver> [--catalog f|--root d]" >&2; exit 2; }

valid() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
valid "$old" || { echo "semver-check: bad semver: $old" >&2; exit 1; }
valid "$new" || { echo "semver-check: bad semver: $new" >&2; exit 1; }

oM="${old%%.*}"; oR="${old#*.}"; om="${oR%%.*}"; op="${oR#*.}"
nM="${new%%.*}"; nR="${new#*.}"; nm="${nR%%.*}"; np="${nR#*.}"

if   [ "$nM" -lt "$oM" ]; then down=1
elif [ "$nM" -eq "$oM" ] && [ "$nm" -lt "$om" ]; then down=1
elif [ "$nM" -eq "$oM" ] && [ "$nm" -eq "$om" ] && [ "$np" -lt "$op" ]; then down=1
else down=0; fi
[ "$down" -eq 0 ] || { echo "semver-check: downgrade $old -> $new is not allowed" >&2; exit 1; }

if   [ "$nM" -ne "$oM" ]; then bump=major
elif [ "$nm" -ne "$om" ]; then bump=minor
elif [ "$np" -ne "$op" ]; then bump=patch
else bump=none; fi

pinned='[]'
if [ -n "$catalog_file" ] || [ -n "$root" ]; then
  if [ -n "$catalog_file" ]; then catalog="$(cat "$catalog_file")"; else catalog="$(bash "$DIR/catalog-derive.sh" "${root:-.}" 2>/dev/null || true)"; fi
  pinned="$(printf '%s' "$catalog" | jq -c --arg t "${contract}@${oM}" '.reverse[$t] // []' 2>/dev/null || printf '[]')"
  [ -n "$pinned" ] || pinned='[]'
fi
pcount=$(printf '%s' "$pinned" | jq 'length' 2>/dev/null || printf 0)

model=false
if { [ "$bump" = minor ] || [ "$bump" = patch ]; } && [ "$pcount" -gt 0 ]; then model=true; fi

echo "semver-check: ${contract} ${old}->${new} bump=${bump} pinned=${pcount} model_call_required=${model}" >&2

jq -n --arg c "$contract" --arg o "$old" --arg nw "$new" --arg b "$bump" \
  --argjson pinned "$pinned" --argjson pc "$pcount" --argjson model "$model" \
  '{contract:$c,old:$o,new:$nw,bump:$b,pinned_consumers:$pinned,pinned_count:$pc,model_call_required:$model}'
