#!/usr/bin/env bash
# Tests for scripts/cdc-check.sh — the consumer-driven contract check (Slice 5 Task 6).
# A published contract version must satisfy EVERY registered consumer expectation:
# same major + required_operations ⊆ operations + required_fields ⊆ fields. No model call.
# Run: bash scripts/cdc-check.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$DIR/cdc-check.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# expect <dir> <consumer> <json>
expect() { mkdir -p "$1/registry/ledger.post/expectations"; printf '%s' "$3" > "$1/registry/ledger.post/expectations/$2.json"; }
# published version file
verfile() { printf '%s' "$2" > "$work/$1.json"; printf '%s' "$work/$1.json"; }

# cc <name> <dir> <version-file> <jq-filter>
cc() {
  local name="$1" d="$2" vf="$3" filt="$4" out
  out="$(bash "$CC" --contract ledger.post --version-file "$vf" --registry "$d/registry" 2>/dev/null)"
  if printf '%s' "$out" | jq -e "$filt" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   %-44s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-44s got[%s]\n' "$name" "$out"
  fi
}
# rcne <name> <dir> <version-file>
rcne() {
  local name="$1" d="$2" vf="$3" rc=0
  bash "$CC" --contract ledger.post --version-file "$vf" --registry "$d/registry" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want rc!=0 got 0\n' "$name"; fi
}

PUB_OK='{"contract":"ledger.post","version":"1.2.0","kind":"openapi","operations":["post","reverse"],"fields":["amount","currency","account"]}'
PUB_NOOP='{"contract":"ledger.post","version":"1.2.0","kind":"openapi","operations":["post"],"fields":["amount","currency","account"]}'
PUB_NOFIELD='{"contract":"ledger.post","version":"1.2.0","kind":"openapi","operations":["post","reverse"],"fields":["amount"]}'
PUB_MAJ2='{"contract":"ledger.post","version":"2.0.0","kind":"openapi","operations":["post","reverse"],"fields":["amount","currency","account"]}'

EXP_PR='{"consumer":"fraud-api","contract":"ledger.post","expects_major":1,"required_operations":["post","reverse"],"required_fields":["amount","currency"]}'

a="$work/a"; expect "$a" fraud-api "$EXP_PR"
cc "satisfies-all"            "$a" "$(verfile ok "$PUB_OK")"      '.status=="satisfies"'
cc "missing-operation-violates" "$a" "$(verfile noop "$PUB_NOOP")" '.status=="violates" and (.unsatisfied[0].consumer=="fraud-api")'
cc "missing-field-violates"   "$a" "$(verfile nof "$PUB_NOFIELD")" '.status=="violates"'
cc "major-mismatch-violates"  "$a" "$(verfile m2 "$PUB_MAJ2")"   '.status=="violates"'

# no expectations registered → vacuously satisfies
b="$work/b"; mkdir -p "$b/registry/ledger.post"
cc "no-expectations-satisfies-vacuously" "$b" "$(verfile okb "$PUB_OK")" '.status=="satisfies"'

# two consumers, one violates
c="$work/c"; expect "$c" fraud-api "$EXP_PR"
expect "$c" risk-api '{"consumer":"risk-api","contract":"ledger.post","expects_major":1,"required_operations":["post"],"required_fields":["amount"]}'
cc "multiple-consumers-one-violates" "$c" "$(verfile noop2 "$PUB_NOOP")" '.status=="violates" and (.unsatisfied|length==1)'

# CRLF expectation file still parsed
e="$work/e"; mkdir -p "$e/registry/ledger.post/expectations"
printf '{\r\n"consumer":"fraud-api",\r\n"contract":"ledger.post",\r\n"expects_major":1,\r\n"required_operations":["reverse"],\r\n"required_fields":[]\r\n}\r\n' > "$e/registry/ledger.post/expectations/fraud-api.json"
cc "crlf-tolerant"           "$e" "$(verfile okc "$PUB_NOOP")"   '.status=="violates"'

# malformed expectation → fail closed
m="$work/m"; mkdir -p "$m/registry/ledger.post/expectations"; printf 'garbage' > "$m/registry/ledger.post/expectations/bad.json"
rcne "malformed-expectation-fails-closed" "$m" "$(verfile okm "$PUB_OK")"

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
