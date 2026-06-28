#!/usr/bin/env bash
# scripts/service-descriptor.sh — THE single home of the service.json schema + token grammar
# (Slice 5). The descriptor is JSON (jq-native); there is no YAML in this harness.
#
#   service-descriptor.sh validate <file>    -> {"status":"valid"} (exit 0)
#                                               {"status":"invalid","errors":[…]} (exit 1)
#   service-descriptor.sh read <file> <field> -> scalar value, or array fields one-per-line
#                                               (missing field / bad file → empty, exit 0)
#
# Read-only. Reused by catalog-derive / dependency-check / semver-check / cdc gates so the
# schema lives in exactly one place.
set -uo pipefail

ID_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
TOKEN_RE='^[a-z0-9]([a-z0-9._-]*[a-z0-9])?@[1-9][0-9]*$'
LIFECYCLES='experimental production deprecated'

cmd="${1:-}"; file="${2:-}"

case "$cmd" in
  validate)
    [ -n "$file" ] || { printf '{"status":"invalid","errors":["no file given"]}\n'; exit 1; }
    if ! jq -e . "$file" >/dev/null 2>&1; then
      printf '{"status":"invalid","errors":["not valid JSON"]}\n'; exit 1
    fi
    errs=$(jq -c --arg idre "$ID_RE" --arg tok "$TOKEN_RE" --arg lifes "$LIFECYCLES" '
      [
        (if (.id|type)=="string" and (.id|test($idre)) then empty else "id: missing or invalid" end),
        (if (.team|type)=="string" and (.team|length>0) then empty else "team: missing or empty" end),
        (if (.lifecycle|type)=="string" and (.lifecycle as $lc | ($lifes|split(" "))|index($lc)) then empty
         else "lifecycle: must be one of experimental|production|deprecated" end),
        (if (.data_classes|type)=="array" then empty else "data_classes: must be an array" end),
        (if (.produces|type)=="array" then empty else "produces: must be an array" end),
        (if (.consumes|type)=="array" then empty else "consumes: must be an array" end),
        (if (.produces|type)=="array"
         then (.produces[] | select((type!="string") or (test($tok)|not)) | "produces: bad token \(.|tostring)")
         else empty end),
        (if (.consumes|type)=="array"
         then (.consumes[] | select((type!="string") or (test($tok)|not)) | "consumes: bad token \(.|tostring)")
         else empty end)
      ] | unique' "$file" 2>/dev/null)
    if [ -z "$errs" ]; then
      printf '{"status":"invalid","errors":["validation failed"]}\n'; exit 1
    fi
    n=$(printf '%s' "$errs" | jq 'length' 2>/dev/null || printf 1)
    if [ "$n" = "0" ]; then printf '{"status":"valid"}\n'; exit 0; fi
    printf '{"status":"invalid","errors":%s}\n' "$errs"; exit 1
    ;;
  read)
    field="${3:-}"
    [ -n "$file" ] && [ -n "$field" ] || exit 0
    jq -e . "$file" >/dev/null 2>&1 || exit 0
    jq -r --arg f "$field" '
      .[$f] as $v |
      if $v == null then empty
      elif ($v|type)=="array" then $v[]
      else $v end' "$file" 2>/dev/null
    exit 0
    ;;
  *)
    echo "usage: service-descriptor.sh validate <file> | read <file> <field>" >&2
    exit 2
    ;;
esac
