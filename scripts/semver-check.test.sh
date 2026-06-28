#!/usr/bin/env bash
# Tests for scripts/semver-check.sh — deterministic bump classification + pinned-consumer
# lookup; emits model_call_required (the seam for the single isolated model call).
# (Slice 5 Task 5.) The script makes NO model call.
# Run: bash scripts/semver-check.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SV="$DIR/semver-check.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

CAT='{"services":[{"id":"svcB","produces":[],"consumes":["ledger.post@1"],"data_classes":[]}],
  "reverse":{"ledger.post@1":["svcB"]},"produced_by":{},"published":[]}'
printf '%s' "$CAT" > "$work/cat.json"

# ok <name> <old> <new> <jq-filter> [extra-args...]
ok() {
  local name="$1" old="$2" new="$3" filt="$4"; shift 4
  if bash "$SV" ledger.post --old "$old" --new "$new" "$@" 2>/dev/null | jq -e "$filt" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   %-44s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-44s got[%s]\n' "$name" "$(bash "$SV" ledger.post --old "$old" --new "$new" "$@" 2>&1)"
  fi
}
# rcne <name> <old> <new>  — expect non-zero exit
rcne() {
  local name="$1" old="$2" new="$3" rc=0
  bash "$SV" ledger.post --old "$old" --new "$new" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want rc!=0 got 0\n' "$name"; fi
}

ok "major-bump-classified"   1.2.0 2.0.0 '.bump=="major"'
ok "minor-bump-classified"   1.2.0 1.3.0 '.bump=="minor"'
ok "patch-bump-classified"   1.2.0 1.2.1 '.bump=="patch"'
ok "no-change-none"          1.2.0 1.2.0 '.bump=="none"'
rcne "downgrade-rejected"    2.0.0 1.0.0
rcne "bad-semver-rejected"   x     1.0.0

# pinned consumers resolved from the catalog (old major line = ledger.post@1)
ok "pinned-consumers-from-catalog"        1.2.0 1.3.0 '(.pinned_consumers|index("svcB")) and .pinned_count==1' --catalog "$work/cat.json"
ok "minor-with-pinned-requires-model-call" 1.2.0 1.3.0 '.model_call_required==true' --catalog "$work/cat.json"
ok "major-no-model-call"                   1.2.0 2.0.0 '.model_call_required==false' --catalog "$work/cat.json"
# minor bump but no catalog → no pinned consumers → no model call
ok "minor-without-pinned-no-model-call"    1.2.0 1.3.0 '.pinned_count==0 and .model_call_required==false'

# the decision is LOGGED to stderr (the "logged" requirement)
if bash "$SV" ledger.post --old 1.2.0 --new 1.3.0 --catalog "$work/cat.json" 2>&1 1>/dev/null | grep -qi 'semver'; then
  pass=$((pass+1)); printf 'ok   %-44s\n' "emits-stderr-log-line"
else
  fail=$((fail+1)); printf 'FAIL %-44s no stderr log\n' "emits-stderr-log-line"
fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
