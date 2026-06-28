#!/usr/bin/env bash
# Tests for scripts/service-descriptor.sh — the single home of the service.json
# schema + token grammar (Slice 5 Task 1). Self-contained mktemp harness.
# Run: bash scripts/service-descriptor.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SD="$DIR/service-descriptor.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

mk() { local n="$1" body="$2" f; f="$work/$(printf '%s' "$n" | tr -c 'A-Za-z0-9' _).json"; printf '%s' "$body" > "$f"; printf '%s' "$f"; }

# v <name> <json> <want-rc> <want-substr>
v() {
  local name="$1" body="$2" wrc="$3" want="$4" f out rc
  f="$(mk "$name" "$body")"
  out="$(bash "$SD" validate "$f" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq "$wrc" ] && printf '%s' "$out" | grep -qF "$want"; then
    pass=$((pass+1)); printf 'ok   %-40s %s\n' "$name" "$out"
  else
    fail=$((fail+1)); printf 'FAIL %-40s want rc=%s/[%s] got rc=%s/[%s]\n' "$name" "$wrc" "$want" "$rc" "$out"
  fi
}
# r <name> <json> <field> <want-substr>
r() {
  local name="$1" body="$2" field="$3" want="$4" f out
  f="$(mk "$name" "$body")"
  out="$(bash "$SD" read "$f" "$field" 2>/dev/null)"
  if printf '%s' "$out" | grep -qF "$want"; then
    pass=$((pass+1)); printf 'ok   %-40s [%s]\n' "$name" "$out"
  else
    fail=$((fail+1)); printf 'FAIL %-40s field=%s want[%s] got[%s]\n' "$name" "$field" "$want" "$out"
  fi
}

VALID='{"id":"payments-api","team":"payments","lifecycle":"production","data_classes":["money_movement","pii"],"produces":["payments.charge@2"],"consumes":["ledger.post@1","fraud.score@1"]}'

v "valid-minimal-passes"               "$VALID" 0 '"status":"valid"'
v "missing-id-fails"                    '{"team":"x","lifecycle":"production","data_classes":[],"produces":[],"consumes":[]}' 1 'id'
v "missing-team-fails"                  '{"id":"x","lifecycle":"production","data_classes":[],"produces":[],"consumes":[]}' 1 'team'
v "bad-lifecycle-fails"                 '{"id":"x","team":"t","lifecycle":"prod","data_classes":[],"produces":[],"consumes":[]}' 1 'lifecycle'
v "consumes-token-without-major-fails"  '{"id":"x","team":"t","lifecycle":"production","data_classes":[],"produces":[],"consumes":["ledger.post"]}' 1 'consumes'
v "consumes-nonint-major-fails"         '{"id":"x","team":"t","lifecycle":"production","data_classes":[],"produces":[],"consumes":["ledger.post@x"]}' 1 'consumes'
v "produces-bad-token-fails"            '{"id":"x","team":"t","lifecycle":"production","data_classes":[],"produces":["Bad@1"],"consumes":[]}' 1 'produces'
v "data-classes-not-array-fails"        '{"id":"x","team":"t","lifecycle":"production","data_classes":"pii","produces":[],"consumes":[]}' 1 'data_classes'
v "not-json-fails-closed"               'this is not json' 1 '"status":"invalid"'
v "empty-file-fails"                    '' 1 '"status":"invalid"'
v "crlf-tolerant-valid"                "$(printf '{\r\n"id":"x",\r\n"team":"t",\r\n"lifecycle":"production",\r\n"data_classes":[],\r\n"produces":[],\r\n"consumes":[]\r\n}\r\n')" 0 '"status":"valid"'

r "read-id-returns-value"               "$VALID" id 'payments-api'
r "read-consumes-returns-tokens"        "$VALID" consumes 'fraud.score@1'

# read-missing-field-empty → empty output (grep '' matches anything; assert emptiness directly)
out="$(bash "$SD" read "$(mk read-missing "$VALID")" nonesuch 2>/dev/null)"
if [ -z "$out" ]; then pass=$((pass+1)); printf 'ok   %-40s [empty]\n' "read-missing-field-empty"
else fail=$((fail+1)); printf 'FAIL %-40s want[empty] got[%s]\n' "read-missing-field-empty" "$out"; fi

# read-consumes-one-per-line → exactly 2 non-empty lines
out="$(bash "$SD" read "$(mk read-lines "$VALID")" consumes 2>/dev/null)"
n=$(printf '%s\n' "$out" | grep -c .)
if [ "$n" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s [%s lines]\n' "read-consumes-one-per-line" "$n"
else fail=$((fail+1)); printf 'FAIL %-40s want 2 lines got %s [%s]\n' "read-consumes-one-per-line" "$n" "$out"; fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
