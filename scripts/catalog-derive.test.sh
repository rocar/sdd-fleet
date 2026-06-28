#!/usr/bin/env bash
# Tests for scripts/catalog-derive.sh — the DERIVED service catalog (Slice 5 Task 2).
# Builds a fixture workspace (member */service.json + registry/) and asserts the
# derived nodes / reverse edges / published set via jq. Fails closed on malformed input.
# Run: bash scripts/catalog-derive.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD="$DIR/catalog-derive.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

svc() { mkdir -p "$1/$2"; printf '%s' "$3" > "$1/$2/service.json"; }
pub() { mkdir -p "$1/registry/$2"; printf '{"contract":"%s","version":"%s","kind":"openapi"}' "$2" "$3" > "$1/registry/$2/$3.json"; }

# jqok <name> <root> <filter>  — derive catalog, assert jq filter is truthy
jqok() {
  local name="$1" root="$2" filt="$3"
  if bash "$CD" "$root" 2>/dev/null | jq -e "$filt" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   %-44s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-44s got[%s]\n' "$name" "$(bash "$CD" "$root" 2>&1)"
  fi
}
# rcne <name> <root>  — expect non-zero exit (fail closed)
rcne() {
  local name="$1" root="$2" rc=0
  bash "$CD" "$root" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want rc!=0 got 0\n' "$name"; fi
}

DC='{"id":"%s","team":"t","lifecycle":"production","data_classes":%s,"produces":%s,"consumes":%s}'

# two-services-one-edge: producer + consumer of ledger.post@1
r1="$work/r1"
svc "$r1" svcA "$(printf "$DC" svcA '[]' '["ledger.post@1"]' '[]')"
svc "$r1" svcB "$(printf "$DC" svcB '[]' '[]' '["ledger.post@1"]')"
jqok "two-services-one-edge"        "$r1" '.reverse["ledger.post@1"]==["svcB"]'
jqok "produced-by-recorded"          "$r1" '.produced_by["ledger.post@1"]==["svcA"]'

# reverse-edges-aggregated: two consumers of same contract
r2="$work/r2"
svc "$r2" svcB "$(printf "$DC" svcB '[]' '[]' '["ledger.post@1"]')"
svc "$r2" svcC "$(printf "$DC" svcC '[]' '[]' '["ledger.post@1"]')"
jqok "reverse-edges-aggregated"     "$r2" '(.reverse["ledger.post@1"]|sort)==["svcB","svcC"]'

# published-set-from-registry
r3="$work/r3"
svc "$r3" svcA "$(printf "$DC" svcA '[]' '["ledger.post@1"]' '[]')"
pub "$r3" ledger.post 1.2.0
jqok "published-set-from-registry"  "$r3" '.published|index("ledger.post@1")'

# consumed-but-unpublished not in published
r4="$work/r4"
svc "$r4" svcB "$(printf "$DC" svcB '[]' '[]' '["fraud.score@2"]')"
jqok "consumed-but-unpublished-not-in-published" "$r4" '(.published|index("fraud.score@2"))==null'

# empty workspace → empty catalog
r5="$work/r5"; mkdir -p "$r5"
jqok "empty-workspace-empty-catalog" "$r5" '.services==[] and .published==[]'

# data_classes carried through to the node
r6="$work/r6"
svc "$r6" svcM "$(printf "$DC" svcM '["money_movement"]' '[]' '[]')"
jqok "data-classes-carried"         "$r6" '.services[0].data_classes|index("money_movement")'

# deterministic output order: services sorted by id (write Z before A)
r7="$work/r7"
svc "$r7" zsvc "$(printf "$DC" zsvc '[]' '[]' '[]')"
svc "$r7" asvc "$(printf "$DC" asvc '[]' '[]' '[]')"
jqok "deterministic-output-order"   "$r7" '.services[0].id=="asvc"'

# CRLF service.json still parsed
r8="$work/r8"; mkdir -p "$r8/svcX"
printf '{\r\n"id":"svcX",\r\n"team":"t",\r\n"lifecycle":"production",\r\n"data_classes":[],\r\n"produces":[],\r\n"consumes":[]\r\n}\r\n' > "$r8/svcX/service.json"
jqok "crlf-service-json-parsed"     "$r8" '.services[0].id=="svcX"'

# malformed service.json → fail closed (non-zero)
r9="$work/r9"; mkdir -p "$r9/svcBad"; printf 'not json at all' > "$r9/svcBad/service.json"
rcne "malformed-service-json-fails-closed" "$r9"

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
