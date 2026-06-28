#!/usr/bin/env bash
# scripts/jira-payload-leak-check.test.sh — the single-source body-leak guard:
# exit 0 iff every --require token is present AND no --forbid token is present.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="$DIR/jira-payload-leak-check.sh"
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-34s = %s\n' "$1" "$2";
       else fail=$((fail+1)); printf 'FAIL %-34s want[%s] got[%s]\n' "$1" "$3" "$2"; fi; }
run() { out="$(printf '%s' "$1" | bash "$CHK" "${@:2}" 2>/dev/null)"; rc=$?; }

if [ -f "$CHK" ]; then pass=$((pass+1)); printf 'ok   script-present\n'; else fail=$((fail+1)); printf 'FAIL script-present\n'; fi

# clean: required present, forbidden absent
run 'story storyA — see vault .sdd/_epic' --require storyA --require .sdd/_epic --forbid SENTINEL
eq "clean-passes" "$rc" "0"
# forbidden present → leak → fail
run 'story storyA SENTINEL_must_not_reach' --require storyA --forbid SENTINEL_must_not_reach
eq "forbidden-present-fails" "$rc" "1"
# required absent → positive control missing → fail (teeth: an empty payload can't pass)
run 'nothing useful here' --require storyA --forbid SENTINEL
eq "required-absent-fails" "$rc" "1"
# both wrong → fail
run 'SENTINEL only' --require storyA --forbid SENTINEL
eq "both-wrong-fails" "$rc" "1"
# no constraints → trivially passes (but the callers always pass a positive control)
run 'anything'
eq "no-constraints-passes" "$rc" "0"
# substring forbidden matches inside a larger blob
run '{"fields":{"description":"DAGBODY_SENTINEL_must_not_reach_jira"}}' --require fields --forbid DAGBODY_SENTINEL
eq "substring-leak-caught" "$rc" "1"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
