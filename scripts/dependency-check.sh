#!/usr/bin/env bash
# scripts/dependency-check.sh --service <service.json> --registry <dir> [--diff <file>]
# DETERMINISTIC source-scan (no model): a diff added-line (^+, not +++) matching a registry
# contract's client_signature whose contract is NOT in consumes[] is an UNDECLARED edge; a
# consumes[] token with no published registry version of its major is a DANGLING edge; a
# registry contract with no client_signature is UNSCANNED (logged coverage gap). One JSON line:
#   {status:"clean"|"blocked", undeclared:[…], dangling:[…], unscanned_contracts:[…]}
# Read-only.
set -uo pipefail
service=""; registry=""; diff_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --service)  service="${2:-}"; shift 2;;
    --registry) registry="${2:-}"; shift 2;;
    --diff)     diff_file="${2:-}"; shift 2;;
    --) shift;;
    *) echo "dependency-check: unexpected arg $1" >&2; exit 2;;
  esac
done
[ -n "$service" ] && [ -n "$registry" ] || { echo "usage: dependency-check.sh --service <f> --registry <dir> [--diff <f>]" >&2; exit 2; }
[ -f "$service" ] || { echo "dependency-check: no service.json: $service" >&2; exit 1; }

consumed_names="$(jq -r '.consumes[]? // empty' "$service" 2>/dev/null | sed -E 's/@.*$//' | sort -u)"
consumed_tokens="$(jq -r '.consumes[]? // empty' "$service" 2>/dev/null | sort -u)"

added=""
if [ -n "$diff_file" ] && [ -f "$diff_file" ]; then
  added="$(tr -d '\r' < "$diff_file" | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
fi

undeclared=""; unscanned=""
if [ -d "$registry" ]; then
  for d in "$registry"/*/; do
    [ -d "$d" ] || continue
    c="$(basename "$d")"
    [ "$c" = "expectations" ] && continue
    sig=""
    for vf in "$d"*.json; do
      [ -f "$vf" ] || continue
      s="$(jq -r '.client_signature // empty' "$vf" 2>/dev/null || true)"
      [ -n "$s" ] && { sig="$s"; break; }
    done
    if [ -z "$sig" ]; then unscanned="${unscanned}${c}
"; continue; fi
    printf '%s\n' "$consumed_names" | grep -Fxq "$c" && continue   # declared → fine
    if [ -n "$added" ] && printf '%s\n' "$added" | grep -Eq -- "$sig"; then
      undeclared="${undeclared}${c}
"
    fi
  done
fi

dangling=""
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  cn="${tok%@*}"; mj="${tok##*@}"
  found=no
  if [ -d "$registry/$cn" ]; then
    for vf in "$registry/$cn"/*.json; do
      [ -f "$vf" ] || continue
      ver="$(basename "$vf" .json)"
      [ "${ver%%.*}" = "$mj" ] && { found=yes; break; }
    done
  fi
  [ "$found" = no ] && dangling="${dangling}${tok}
"
done <<EOF
$consumed_tokens
EOF

arr() { printf '%s\n' "$1" | grep -v '^$' | jq -R . | jq -s 'sort'; }
u_json="$(arr "$undeclared")"; [ -n "$u_json" ] || u_json='[]'
d_json="$(arr "$dangling")";   [ -n "$d_json" ] || d_json='[]'
s_json="$(arr "$unscanned")";  [ -n "$s_json" ] || s_json='[]'

status=clean
{ [ "$u_json" != '[]' ] || [ "$d_json" != '[]' ]; } && status=blocked

jq -n --arg st "$status" --argjson u "$u_json" --argjson d "$d_json" --argjson s "$s_json" \
  '{status:$st,undeclared:$u,dangling:$d,unscanned_contracts:$s}'
