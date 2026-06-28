#!/usr/bin/env bash
# scripts/ready-frontier.test.sh — proof that the conductor's ready frontier is
# PURE SET LOGIC, two-sided, and re-derived from the live published-contract set:
#   - subset (upper bound): every emitted id is an input id AND is NOT_STARTED
#     (never invents an id; never re-emits an already-dispatched one — the exact
#     double-dispatch bug a status-ignoring frontier would cause = the teeth);
#   - completeness (lower bound): every NOT_STARTED story whose consumes[] are all
#     published IS emitted (catches silent under-dispatch);
#   - re-derive: publishing / unpublishing a dep flips readiness live (no cache);
#   - ignore: unrelated published contracts, DONE stories, and input reordering
#     do not change the frontier.
# Fails LOUDLY (counted FAIL / non-zero exit) if the script is missing or emits
# nothing on a known-ready input — never a silent skip.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTIER="$DIR/ready-frontier.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

eq()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-40s = %s\n' "$1" "$2";
        else fail=$((fail+1)); printf 'FAIL %-40s want[%s] got[%s]\n' "$1" "$3" "$2"; fi; }
ok()  { pass=$((pass+1)); printf 'ok   %-40s %s\n' "$1" "${2:-}"; }
bad() { fail=$((fail+1)); printf 'FAIL %-40s %s\n' "$1" "${2:-}"; }
q()   { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# pub <root> <contract> <semver>  — publish a registry version file
pub() { mkdir -p "$1/registry/$2"; printf '{"contract":"%s","version":"%s","kind":"openapi"}\n' "$2" "$3" > "$1/registry/$2/$3.json"; }
# run_frontier <root> <stories-json> -> sets $out, $rc
run_frontier() { out="$( (cd "$1" && printf '%s' "$2" | bash "$FRONTIER" --registry registry) 2>"$work/.err" )"; rc=$?; }

# Loud anchor: the script must exist + be executable as a file (else the whole
# proof is vacuous — counted FAIL, not a skip).
if [ -f "$FRONTIER" ]; then ok "script-present"; else bad "script-present" "$FRONTIER missing"; fi

STORIES='{"stories":[
 {"id":"ready1","status":"NOT_STARTED","consumes":["c@1"]},
 {"id":"ready2","status":"NOT_STARTED","consumes":[]},
 {"id":"blocked","status":"NOT_STARTED","consumes":["c@2"]},
 {"id":"done1","status":"DONE","consumes":["c@1"]},
 {"id":"dispatched1","status":"DISPATCHED","consumes":["c@1"]}
]}'

# ---- baseline: c@1 published, c@2 not -------------------------------------
p="$work/base"; mkdir -p "$p"; pub "$p" c 1.0.0
run_frontier "$p" "$STORIES"
eq  "baseline-rc"          "$rc" "0"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "baseline-valid-json"; else bad "baseline-valid-json" "[$out]"; fi
# positive control: a known-ready input must yield a NON-EMPTY frontier
n="$(q "$out" 'length')"; if [ "${n:-0}" -gt 0 ] 2>/dev/null; then ok "frontier-nonempty" "n=$n"; else bad "frontier-nonempty" "got [$out]"; fi
# completeness (lower bound): both eligible stories emitted
eq  "contains-ready1"      "$(q "$out" 'any(.[]; .=="ready1")')" "true"
eq  "contains-ready2-nodeps" "$(q "$out" 'any(.[]; .=="ready2")')" "true"
eq  "frontier-count-2"     "$(q "$out" 'length')" "2"
# subset (upper bound): blocked dep, DONE, and the teeth (DISPATCHED) excluded
eq  "excludes-blocked"     "$(q "$out" 'any(.[]; .=="blocked")')" "false"
eq  "excludes-done"        "$(q "$out" 'any(.[]; .=="done1")')" "false"
eq  "excludes-dispatched-TEETH" "$(q "$out" 'any(.[]; .=="dispatched1")')" "false"
# every emitted id is one of the input ids (no invention)
eq  "subset-of-input"      "$(q "$out" 'all(.[]; . as $x | ["ready1","ready2","blocked","done1","dispatched1"] | any(.==$x))')" "true"
# sorted + unique
eq  "sorted-unique"        "$(q "$out" '. == (.|sort|unique)')" "true"

# ---- re-derive (tamper): publish c@2 -> blocked becomes ready -------------
pub "$p" c 2.0.0
run_frontier "$p" "$STORIES"
eq  "rederive-blocked-ready"   "$(q "$out" 'any(.[]; .=="blocked")')" "true"
eq  "rederive-count-3"         "$(q "$out" 'length')" "3"
# unpublish c@2 -> blocked excluded again (live, never cached)
rm -f "$p/registry/c/2.0.0.json"
run_frontier "$p" "$STORIES"
eq  "rederive-blocked-excluded-again" "$(q "$out" 'any(.[]; .=="blocked")')" "false"
eq  "rederive-count-2-again"          "$(q "$out" 'length')" "2"

# ---- inverse (ignore): unrelated published contract changes nothing -------
pub "$p" z 1.0.0
run_frontier "$p" "$STORIES"
eq  "ignore-unrelated-count"   "$(q "$out" 'length')" "2"
eq  "ignore-unrelated-ready1"  "$(q "$out" 'any(.[]; .=="ready1")')" "true"

# ---- inverse (ignore): input reordering yields identical frontier ---------
REORDERED='{"stories":[
 {"id":"dispatched1","status":"DISPATCHED","consumes":["c@1"]},
 {"id":"blocked","status":"NOT_STARTED","consumes":["c@2"]},
 {"id":"ready2","status":"NOT_STARTED","consumes":[]},
 {"id":"done1","status":"DONE","consumes":["c@1"]},
 {"id":"ready1","status":"NOT_STARTED","consumes":["c@1"]}
]}'
run_frontier "$p" "$REORDERED"
eq  "order-stable"             "$(q "$out" '.')" "$(printf '%s' '["ready1","ready2"]' | jq -r '.')"

# ---- multi-token: ready only when ALL consumed contracts are published ----
p2="$work/multi"; mkdir -p "$p2"; pub "$p2" a 1.0.0   # b@1 not published
MULTI='{"stories":[{"id":"m","status":"NOT_STARTED","consumes":["a@1","b@1"]}]}'
run_frontier "$p2" "$MULTI"
eq  "multi-partial-excluded"   "$(q "$out" 'length')" "0"
pub "$p2" b 1.0.0
run_frontier "$p2" "$MULTI"
eq  "multi-all-published-ready" "$(q "$out" 'any(.[]; .=="m")')" "true"

# ---- loud-fail: empty / unparseable stdin must be non-zero, never []  -----
out="$( (cd "$p" && printf '' | bash "$FRONTIER" --registry registry) 2>/dev/null )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "empty-stdin-nonzero" "rc=$rc"; else bad "empty-stdin-nonzero" "rc=0 out=[$out]"; fi
out="$( (cd "$p" && printf 'not json' | bash "$FRONTIER" --registry registry) 2>/dev/null )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "garbage-stdin-nonzero" "rc=$rc"; else bad "garbage-stdin-nonzero" "rc=0 out=[$out]"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
