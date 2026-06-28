#!/usr/bin/env bash
# scripts/catalog-derive.sh [root] — emit the DERIVED service catalog as one JSON object:
#   {
#     "services":    [ {id,team,lifecycle,data_classes,produces,consumes} … ] (sorted by id),
#     "reverse":     { "<contract>@<major>": [consumer-id …] },
#     "produced_by": { "<contract>@<major>": [producer-id …] },
#     "published":   [ "<contract>@<major>" … ]
#   }
# Derived from every service.json (root + root/*/) and every registry/<contract>/<semver>.json.
# Pure function of the inputs; never hand-kept. Fails closed (non-zero) on a malformed
# service.json. Read-only — writes nothing; `catalog.json` is `catalog-derive.sh > catalog.json`.
set -uo pipefail
root="${1:-.}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
: > "$tmp"

err=0
for f in "$root"/service.json "$root"/*/service.json; do
  [ -f "$f" ] || continue
  if obj=$(jq -c '{id,team,lifecycle,data_classes:(.data_classes//[]),produces:(.produces//[]),consumes:(.consumes//[])}' "$f" 2>/dev/null); then
    printf '%s\n' "$obj" >> "$tmp"
  else
    echo "catalog-derive: malformed service.json: $f" >&2; err=1
  fi
done
[ "$err" -eq 0 ] || exit 1

pub=""
if [ -d "$root/registry" ]; then
  for d in "$root"/registry/*/; do
    [ -d "$d" ] || continue
    c="$(basename "$d")"
    [ "$c" = "expectations" ] && continue
    for vf in "$d"*.json; do
      [ -f "$vf" ] || continue
      ver="$(basename "$vf" .json)"
      pub="${pub}${c}@${ver%%.*}
"
    done
  done
fi

jq -n --slurpfile s "$tmp" --arg pub "$pub" '
  ($s) as $svcs |
  {
    services:    ($svcs | sort_by(.id)),
    reverse:     (reduce $svcs[] as $x ({}; reduce ($x.consumes[]) as $c (.; .[$c] += [$x.id]))),
    produced_by: (reduce $svcs[] as $x ({}; reduce ($x.produces[]) as $c (.; .[$c] += [$x.id]))),
    published:   ($pub | split("\n") | map(select(length>0)) | unique)
  }
  | .reverse     |= with_entries(.value |= unique)
  | .produced_by |= with_entries(.value |= unique)
'
