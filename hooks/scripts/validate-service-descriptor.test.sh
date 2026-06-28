#!/usr/bin/env bash
# Tests for hooks/scripts/validate-service-descriptor.sh (Slice 5 Task 1).
# PostToolUse Write|Edit gate: a write to service.json that fails schema validation is
# blocked (exit 2). Non-service.json writes are ignored. jq-missing fails closed.
# Run: bash hooks/scripts/validate-service-descriptor.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/validate-service-descriptor.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

VALID='{"id":"payments-api","team":"payments","lifecycle":"production","data_classes":["pii"],"produces":[],"consumes":["ledger.post@1"]}'
INVALID='{"id":"payments-api","team":"payments","lifecycle":"nope","data_classes":[],"produces":[],"consumes":[]}'

# check <name> <proj> <file_path> <content|-> <want-rc>
check() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc
  mkdir -p "$proj"
  if [ "$content" != "-" ]; then
    mkdir -p "$proj/$(dirname "$fp")" 2>/dev/null || true
    printf '%s' "$content" > "$proj/$fp" 2>/dev/null || true
  fi
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-38s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-38s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

check "valid-service-json-allows"      "$work/p1" "service.json"      "$VALID"   0
check "invalid-service-json-blocks"    "$work/p2" "service.json"      "$INVALID" 2
check "non-service-json-write-ignored" "$work/p3" "src/app.py"        "x=1"      0
check "traversal-path-rejected"        "$work/p4" "../e/service.json" "-"        2

# jq-missing while writing a service.json → fail closed (exit 2)
stub="$work/stub"; mkdir -p "$stub"
for b in bash basename dirname cat grep sed tr head find; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stub/$b"; done
p5="$work/p5"; mkdir -p "$p5"; printf '%s' "$VALID" > "$p5/service.json"
rc=0; ( cd "$p5" && printf '{"tool_input":{"file_path":"service.json"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p5" /bin/bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-38s rc=2\n' "missing-jq-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-38s want=2 got=%s\n' "missing-jq-fails-closed" "$rc"; fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
