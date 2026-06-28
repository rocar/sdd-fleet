#!/usr/bin/env bash
# Tests for hooks/scripts/cdc-gate.sh (Slice 5 Task 6, decision [D-c]).
# PreToolUse Write|Edit: a write that PUBLISHES registry/<contract>/<semver>.json must
# satisfy every registered consumer expectation, else exit 2. Inert for non-registry writes.
# Run: bash hooks/scripts/cdc-gate.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/cdc-gate.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

EXP='{"consumer":"fraud-api","contract":"ledger.post","expects_major":1,"required_operations":["post","reverse"],"required_fields":["amount"]}'
PUB_OK='{"contract":"ledger.post","version":"1.1.0","kind":"openapi","operations":["post","reverse"],"fields":["amount","currency"]}'
PUB_BAD='{"contract":"ledger.post","version":"1.1.0","kind":"openapi","operations":["post"],"fields":["amount"]}'

# proj <name> <with-expectation:yes|no> -> echoes proj root
proj() {
  local p="$work/$1"; mkdir -p "$p/registry/ledger.post"
  if [ "$2" = yes ]; then mkdir -p "$p/registry/ledger.post/expectations"; printf '%s' "$EXP" > "$p/registry/ledger.post/expectations/fraud-api.json"; fi
  printf '%s' "$p"
}

# fire <name> <proj> <file_path> <content> <want-rc>
fire() {
  local name="$1" pr="$2" fp="$3" content="$4" want="$5" rc=0
  ( cd "$pr" && jq -nc --arg f "$fp" --arg c "$content" '{tool_input:{file_path:$f,content:$c}}' \
      | CLAUDE_PROJECT_DIR="$pr" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

p1=$(proj p1 yes); fire "publish-satisfying-allows"  "$p1" "registry/ledger.post/1.1.0.json" "$PUB_OK"  0
p2=$(proj p2 yes); fire "publish-violating-blocks"   "$p2" "registry/ledger.post/1.1.0.json" "$PUB_BAD" 2
p3=$(proj p3 yes); fire "non-registry-write-inert"   "$p3" "src.py"                           "$PUB_BAD" 0
p4=$(proj p4 no);  fire "no-expectations-allows"     "$p4" "registry/ledger.post/1.1.0.json" "$PUB_BAD" 0
p5=$(proj p5 yes); fire "malformed-publish-fails-closed" "$p5" "registry/ledger.post/1.1.0.json" "not json" 2
p6=$(proj p6 yes); fire "traversal-rejected"         "$p6" "registry/../x/ledger.post/1.1.0.json" "$PUB_OK" 2

# expectations write itself is NOT a publish → inert
p7=$(proj p7 yes); fire "expectations-write-inert"   "$p7" "registry/ledger.post/expectations/x.json" "$EXP" 0

# unreadable expectation while publishing → fail closed
p8=$(proj p8 yes); chmod 000 "$p8/registry/ledger.post/expectations/fraud-api.json"
rc=0; ( cd "$p8" && jq -nc --arg c "$PUB_OK" '{tool_input:{file_path:"registry/ledger.post/1.1.0.json",content:$c}}' | CLAUDE_PROJECT_DIR="$p8" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p8/registry/ledger.post/expectations/fraud-api.json" 2>/dev/null || true
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=2\n' "unreadable-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-44s want=2 got=%s\n' "unreadable-fails-closed" "$rc"; fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
