#!/usr/bin/env bash
# scripts/blast-radius.sh <contract>@<major> [--catalog <file> | --root <dir>] [--threshold N]
# Transitive consumer closure over the catalog reverse edges → the blast set, with
# money_movement/pii flags and the human-gate decision ([D-b]). Emits one JSON line:
#   {contract,major,consumers:[…],count:N,money_movement:bool,pii:bool,human_gate_required:bool}
# human_gate_required = count >= threshold OR any reached service carries money_movement/pii.
# Threshold default 3 (override via --threshold / BLAST_RADIUS_THRESHOLD). Read-only.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target=""; catalog_file=""; root=""; threshold="${BLAST_RADIUS_THRESHOLD:-3}"
while [ $# -gt 0 ]; do
  case "$1" in
    --catalog)   catalog_file="${2:-}"; shift 2;;
    --root)      root="${2:-}"; shift 2;;
    --threshold) threshold="${2:-}"; shift 2;;
    --) shift;;
    -*) echo "blast-radius: unknown flag $1" >&2; exit 2;;
    *)  if [ -z "$target" ]; then target="$1"; shift; else echo "blast-radius: unexpected arg $1" >&2; exit 2; fi;;
  esac
done
[ -n "$target" ] || { echo "usage: blast-radius.sh <contract>@<major> [--catalog f|--root d] [--threshold N]" >&2; exit 2; }
case "$target" in *@*) ;; *) echo "blast-radius: target must be <contract>@<major>" >&2; exit 2;; esac
contract="${target%@*}"; major="${target##*@}"

if [ -n "$catalog_file" ]; then
  catalog="$(cat "$catalog_file")"
else
  catalog="$(bash "$DIR/catalog-derive.sh" "${root:-.}")" || { echo "blast-radius: catalog derivation failed" >&2; exit 1; }
fi

rev()  { printf '%s' "$catalog" | jq -r --arg t "$1" '.reverse[$t][]? // empty' 2>/dev/null; }
prod() { printf '%s' "$catalog" | jq -r --arg i "$1" '.services[]|select(.id==$i)|.produces[]? // empty' 2>/dev/null; }
dcls() { printf '%s' "$catalog" | jq -r --arg i "$1" '.services[]|select(.id==$i)|.data_classes[]? // empty' 2>/dev/null; }

# Queue-based BFS over reverse edges. visited bounds growth (each id expands once), so a
# cycle drains the queue rather than looping forever.
visited=""
queue="$(rev "$target")"
while : ; do
  s=""
  while IFS= read -r line; do [ -n "$line" ] && { s="$line"; break; }; done <<EOF
$queue
EOF
  [ -n "$s" ] || break
  queue="$(printf '%s\n' "$queue" | grep -vxF "$s" || true)"
  case " $visited " in *" $s "*) continue;; esac
  visited="$visited $s"
  for p in $(prod "$s"); do
    for c in $(rev "$p"); do queue="$queue
$c"; done
  done
done

consumers="$(printf '%s\n' $visited | grep -v '^$' | sort -u || true)"
count=0
[ -n "$consumers" ] && count=$(printf '%s\n' "$consumers" | grep -c .)

mm=false; pii=false
for s in $consumers; do
  for dc in $(dcls "$s"); do
    [ "$dc" = "money_movement" ] && mm=true
    [ "$dc" = "pii" ] && pii=true
  done
done

hg=false
if [ "$count" -ge "$threshold" ] || [ "$mm" = true ] || [ "$pii" = true ]; then hg=true; fi

cons_json="$(printf '%s\n' "$consumers" | grep -v '^$' | jq -R . | jq -s 'sort')"
[ -n "$cons_json" ] || cons_json='[]'

jq -n --arg c "$contract" --argjson maj "$major" --argjson cons "$cons_json" \
  --argjson cnt "$count" --argjson mm "$mm" --argjson pii "$pii" --argjson hg "$hg" \
  '{contract:$c,major:$maj,consumers:$cons,count:$cnt,money_movement:$mm,pii:$pii,human_gate_required:$hg}'
