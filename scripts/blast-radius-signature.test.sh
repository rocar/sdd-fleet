#!/usr/bin/env bash
# Tests for scripts/blast-radius-signature.sh (Slice 6b) — THE single home of the blast-radius
# VERDICT + SIGNATURE. The gate hook (verify) and handoff-approve-record.sh (record) both call
# it, so record/verify can never drift. Emits {required, signature, verdict}. The signature is a
# digest pinned to the verdict (consumer SET + classes); it MUST change when the radius widens.
# Uses inline --catalog fixtures (like blast-radius.test.sh) + a cwd service.json; no git needed.
# Run: bash scripts/blast-radius-signature.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIG="$DIR/blast-radius-signature.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# proj <name> <service-json> <catalog-json> -> echoes a cwd with service.json + cat.json
proj() {
  local name="$1" svc="$2" cat="$3"
  local p="$work/$name"
  mkdir -p "$p"
  printf '%s' "$svc" > "$p/service.json"
  printf '%s' "$cat" > "$p/cat.json"
  printf '%s' "$p"
}
run() { ( cd "$1" && bash "$SIG" --catalog cat.json 2>/dev/null ); }   # run <proj> -> JSON line
check() {  # check <name> <proj> <jq-filter>
  local name="$1" p="$2" filt="$3"
  if run "$p" | jq -e "$filt" >/dev/null 2>&1; then pass=$((pass+1)); printf 'ok   %-46s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %-46s got[%s]\n' "$name" "$(run "$p")"; fi
}

SVC_PROD='{"id":"app","team":"t","lifecycle":"production","data_classes":[],"produces":["ledger.post@1"],"consumes":[]}'
SVC_MM='{"id":"app","team":"t","lifecycle":"production","data_classes":["money_movement"],"produces":[],"consumes":[]}'

CAT2='{"services":[
  {"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcC","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB","svcC"]},"produced_by":{},"published":[]}'
CAT3='{"services":[
  {"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcC","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcD","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB","svcC","svcD"]},"produced_by":{},"published":[]}'
CAT4='{"services":[
  {"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcC","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcD","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcE","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB","svcC","svcD","svcE"]},"produced_by":{},"published":[]}'
# 3 consumers, one carrying money_movement (radius same size as CAT3, different risk)
CAT3MM='{"services":[
  {"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":["money_movement"]},
  {"id":"svcC","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcD","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB","svcC","svcD"]},"produced_by":{},"published":[]}'

# --- required true/false ---
pclean=$(proj clean "$SVC_PROD" "$CAT2")
check "below-threshold-not-required"   "$pclean" '.required==false and .signature==""'
p3=$(proj risky3 "$SVC_PROD" "$CAT3")
check "threshold-required"             "$p3" '.required==true and (.signature|length)>0 and (.verdict.contracts[0].consumers|length)==3'
pmm=$(proj prodmm "$SVC_MM" "$CAT2")
check "producer-class-required"        "$pmm" '.required==true and .verdict.producer_classes==["money_movement"] and (.verdict.contracts|length)==0'

# --- signature stable for the same verdict ---
s1=$(run "$p3" | jq -r '.signature'); s1b=$(run "$p3" | jq -r '.signature')
if [ -n "$s1" ] && [ "$s1" = "$s1b" ]; then pass=$((pass+1)); printf 'ok   %-46s\n' "signature-stable-same-verdict"
else fail=$((fail+1)); printf 'FAIL %-46s [%s vs %s]\n' "signature-stable-same-verdict" "$s1" "$s1b"; fi

# --- signature CHANGES when a consumer is added (3 -> 4: the staleness the gate relies on) ---
p4=$(proj risky4 "$SVC_PROD" "$CAT4")
s4=$(run "$p4" | jq -r '.signature')
if [ -n "$s4" ] && [ "$s4" != "$s1" ]; then pass=$((pass+1)); printf 'ok   %-46s\n' "signature-changes-on-consumer-add"
else fail=$((fail+1)); printf 'FAIL %-46s [3=%s 4=%s]\n' "signature-changes-on-consumer-add" "$s1" "$s4"; fi

# --- signature CHANGES when a reached consumer gains a sensitive class (same count) ---
p3mm=$(proj risky3mm "$SVC_PROD" "$CAT3MM")
s3mm=$(run "$p3mm" | jq -r '.signature')
if [ -n "$s3mm" ] && [ "$s3mm" != "$s1" ]; then pass=$((pass+1)); printf 'ok   %-46s\n' "signature-changes-on-class-appears"
else fail=$((fail+1)); printf 'FAIL %-46s [clean=%s mm=%s]\n' "signature-changes-on-class-appears" "$s1" "$s3mm"; fi

# --- INVERSE: the signature must IGNORE everything outside the verdict, else it over-binds and
#     wedges the gate on incidental churn. These FAIL against an over-binding digest. ---
# non-verdict descriptor fields (team / lifecycle / the producer's own consumes) do NOT move it
SVC_NV='{"id":"app","team":"OTHER","lifecycle":"deprecated","data_classes":[],"produces":["ledger.post@1"],"consumes":["x.y@1"]}'
snv=$(run "$(proj nonverdict "$SVC_NV" "$CAT3")" | jq -r '.signature')
if [ -n "$snv" ] && [ "$snv" = "$s1" ]; then pass=$((pass+1)); printf 'ok   %-46s\n' "signature-ignores-non-verdict-fields"
else fail=$((fail+1)); printf 'FAIL %-46s [base=%s nv=%s]\n' "signature-ignores-non-verdict-fields" "$s1" "$snv"; fi

# consumer declaration order in the catalog does NOT move it (canonical: consumers sorted)
CAT3_REORDER='{"services":[
  {"id":"svcD","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":[]},
  {"id":"svcC","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcD","svcB","svcC"]},"produced_by":{},"published":[]}'
sreo=$(run "$(proj reorder "$SVC_PROD" "$CAT3_REORDER")" | jq -r '.signature')
if [ -n "$sreo" ] && [ "$sreo" = "$s1" ]; then pass=$((pass+1)); printf 'ok   %-46s\n' "signature-order-stable-consumers"
else fail=$((fail+1)); printf 'FAIL %-46s [base=%s reordered=%s]\n' "signature-order-stable-consumers" "$s1" "$sreo"; fi

# data_classes declaration order does NOT move it (canonical: classes sorted): ["pii","money_movement"] == ["money_movement","pii"]
SVC_BOTH='{"id":"app","team":"t","lifecycle":"production","data_classes":["money_movement","pii"],"produces":[],"consumes":[]}'
SVC_BOTH_REV='{"id":"app","team":"t","lifecycle":"production","data_classes":["pii","money_movement"],"produces":[],"consumes":[]}'
sb=$(run "$(proj both "$SVC_BOTH" "$CAT2")" | jq -r '.signature')
sbr=$(run "$(proj bothrev "$SVC_BOTH_REV" "$CAT2")" | jq -r '.signature')
if [ -n "$sb" ] && [ "$sb" = "$sbr" ]; then pass=$((pass+1)); printf 'ok   %-46s\n' "signature-order-stable-classes"
else fail=$((fail+1)); printf 'FAIL %-46s [mm,pii=%s pii,mm=%s]\n' "signature-order-stable-classes" "$sb" "$sbr"; fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
