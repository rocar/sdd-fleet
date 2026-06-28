#!/usr/bin/env bash
# scripts/cdc-check.sh --contract <name> --version-file <published.json> --registry <dir>
# The consumer-driven contract check (no model): the published version must satisfy EVERY
# registered consumer expectation (registry/<contract>/expectations/*.json) —
# same major + required_operations ⊆ operations + required_fields ⊆ fields. One JSON line:
#   {status:"satisfies"|"violates", contract, version, unsatisfied:[{consumer,reason}…]}
# Malformed version-file / expectation → exit 1 (fail closed). Read-only.
set -uo pipefail
contract=""; vfile=""; registry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --contract)     contract="${2:-}"; shift 2;;
    --version-file) vfile="${2:-}"; shift 2;;
    --registry)     registry="${2:-}"; shift 2;;
    --) shift;;
    *) echo "cdc-check: unexpected arg $1" >&2; exit 2;;
  esac
done
[ -n "$contract" ] && [ -n "$vfile" ] && [ -n "$registry" ] || { echo "usage: cdc-check.sh --contract <c> --version-file <f> --registry <dir>" >&2; exit 2; }
[ -f "$vfile" ] || { echo "cdc-check: no version file: $vfile" >&2; exit 1; }
jq -e . "$vfile" >/dev/null 2>&1 || { echo "cdc-check: version file is not valid JSON: $vfile" >&2; exit 1; }

ver=$(jq -r '.version // empty' "$vfile")
pub_major="${ver%%.*}"; [ -n "$pub_major" ] || pub_major=0

expdir="$registry/$contract/expectations"
unsat='[]'
if [ -d "$expdir" ]; then
  for ef in "$expdir"/*.json; do
    [ -f "$ef" ] || continue
    jq -e . "$ef" >/dev/null 2>&1 || { echo "cdc-check: malformed expectation: $ef" >&2; exit 1; }
    reason=$(jq -r --argjson pubmaj "$pub_major" --slurpfile pub "$vfile" '
      . as $e | ($pub[0]) as $p |
      if ($e.expects_major != $pubmaj) then "major-mismatch: expects \($e.expects_major) got \($pubmaj)"
      else
        ( (($e.required_operations // []) - ($p.operations // [])) ) as $mo |
        ( (($e.required_fields // [])     - ($p.fields // []))     ) as $mf |
        if   ($mo|length) > 0 then "missing-operation: \($mo|join(","))"
        elif ($mf|length) > 0 then "missing-field: \($mf|join(","))"
        else "" end
      end' "$ef" 2>/dev/null)
    if [ -n "$reason" ]; then
      consumer=$(jq -r '.consumer // "unknown"' "$ef")
      unsat=$(printf '%s' "$unsat" | jq -c --arg c "$consumer" --arg r "$reason" '. + [{consumer:$c,reason:$r}]')
    fi
  done
fi

if [ "$(printf '%s' "$unsat" | jq 'length')" = "0" ]; then status=satisfies; else status=violates; fi
jq -n --arg st "$status" --arg c "$contract" --arg v "$ver" --argjson un "$unsat" \
  '{status:$st,contract:$c,version:$v,unsatisfied:$un}'
