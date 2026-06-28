#!/usr/bin/env bash
# Tests for scripts/blast-radius.sh — transitive consumer closure over a catalog
# (Slice 5 Task 3). Uses inline catalog fixtures via --catalog so the closure logic is
# unit-tested independent of catalog-derive. human_gate_required per [D-b] (threshold N=3).
# Run: bash scripts/blast-radius.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR="$DIR/blast-radius.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# br <name> <catalog-json> <target> <jq-filter> [extra-args...]
br() {
  local name="$1" cat="$2" target="$3" filt="$4"; shift 4
  printf '%s' "$cat" > "$work/cat.json"
  if bash "$BR" "$target" --catalog "$work/cat.json" "$@" 2>/dev/null | jq -e "$filt" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   %-44s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-44s got[%s]\n' "$name" "$(bash "$BR" "$target" --catalog "$work/cat.json" "$@" 2>&1)"
  fi
}

# two direct consumers of ledger.post@1
CAT_DIRECT='{"services":[
  {"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcC","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB","svcC"]},"produced_by":{},"published":[]}'
br "direct-consumers-counted"   "$CAT_DIRECT" "ledger.post@1" '.count==2 and (.consumers|sort)==["svcB","svcC"]'
br "deterministic-consumer-order" "$CAT_DIRECT" "ledger.post@1" '.consumers==(.consumers|sort)'

# two-hop: svcB consumes X@1 and produces Y@1; svcD consumes Y@1
CAT_HOPS='{"services":[
  {"id":"svcB","produces":["acct.event@1"],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcD","produces":[],"consumes":["acct.event@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB"],"acct.event@1":["svcD"]},"produced_by":{},"published":[]}'
br "transitive-closure-two-hops" "$CAT_HOPS" "ledger.post@1" '.count==2 and (.consumers|sort)==["svcB","svcD"]'

# no consumers
CAT_EMPTY='{"services":[],"reverse":{},"produced_by":{},"published":[]}'
br "no-consumers-zero"          "$CAT_EMPTY" "ledger.post@1" '.count==0 and .human_gate_required==false'
br "unknown-contract-empty"     "$CAT_EMPTY" "nope@1"        '.count==0'

# money_movement on a reached consumer forces the gate even below threshold
CAT_MM='{"services":[{"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":["money_movement"]}],
  "reverse":{"ledger.post@1":["svcB"]},"produced_by":{},"published":[]}'
br "money-movement-forces-human-gate" "$CAT_MM" "ledger.post@1" '.count==1 and .money_movement==true and .human_gate_required==true' --threshold 99

# pii on a reached consumer forces the gate even below threshold
CAT_PII='{"services":[{"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":["pii"]}],
  "reverse":{"ledger.post@1":["svcB"]},"produced_by":{},"published":[]}'
br "pii-forces-human-gate"      "$CAT_PII" "ledger.post@1" '.pii==true and .human_gate_required==true' --threshold 99

# three plain consumers → count>=3 forces the gate at default threshold
CAT_THREE='{"services":[
  {"id":"a","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"b","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"c","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["a","b","c"]},"produced_by":{},"published":[]}'
br "threshold-forces-human-gate" "$CAT_THREE" "ledger.post@1" '.count==3 and .human_gate_required==true'

# two plain consumers, no flags → below default threshold, no gate
br "below-threshold-clean-no-gate" "$CAT_DIRECT" "ledger.post@1" '.count==2 and .human_gate_required==false'

# cycle: A produces Y consumed by B; B produces X consumed by A → must terminate
CAT_CYCLE='{"services":[
  {"id":"A","produces":["y@1"],"consumes":["x@1"],"data_classes":[]},
  {"id":"B","produces":["x@1"],"consumes":["y@1"],"data_classes":[]}],
  "reverse":{"x@1":["A"],"y@1":["B"]},"produced_by":{},"published":[]}'
br "cycle-safe-terminates"      "$CAT_CYCLE" "x@1" '.count==2 and (.consumers|sort)==["A","B"]'

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
