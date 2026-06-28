#!/usr/bin/env bash
# Tests for hooks/scripts/block-publish-before-handoff.sh (Slice 6, publish-ordering gate).
# PreToolUse Write|Edit: a write that PUBLISHES registry/<contract>/<semver>.json is allowed
# ONLY when the active feature's PHASE is HANDOFF — otherwise block (exit 2). This is the
# "publish is downstream of the human-approved HANDOFF" proof: a contract cannot reach the
# registry before the gate at the HANDOFF transition has had its say.
# Inert (exit 0): non-registry write; an expectations write (not a publish); no active item.
# Fail closed (exit 2): '..' path, unreadable .sdd/ACTIVE, missing jq while active.
# Run: bash hooks/scripts/block-publish-before-handoff.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/block-publish-before-handoff.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# fire <name> <proj> <file_path> <want-rc>  (content is irrelevant to ordering)
fire() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" '{tool_input:{file_path:$f}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# mk <name> <phase> -> a project working tree with ACTIVE=feat and PROGRESS PHASE:<phase>.
mk() {
  local name="$1" phase="$2"
  local p="$work/$name"
  mkdir -p "$p/.sdd/feat"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  printf 'PHASE: %s\n' "$phase" > "$p/.sdd/feat/PROGRESS.md"
  printf '%s' "$p"
}

# --- ordering proof: publish blocked until PHASE is HANDOFF ---
p=$(mk pub_build BUILD);          fire "publish-before-handoff-blocks"   "$p" "registry/ledger.post/1.0.0.json" 2
p=$(mk pub_cr CHANGE_REVIEW);     fire "publish-at-change-review-blocks" "$p" "registry/ledger.post/1.0.0.json" 2
p=$(mk pub_ho HANDOFF);           fire "publish-at-handoff-allows"       "$p" "registry/ledger.post/1.0.0.json" 0

# --- inert ---
p=$(mk exp BUILD);                fire "expectations-write-inert"        "$p" "registry/ledger.post/expectations/c1.json" 0
p=$(mk nonreg BUILD);             fire "non-registry-write-inert"        "$p" "src.py" 0
mkdir -p "$work/empty";           fire "no-active-feature-inert"         "$work/empty" "registry/ledger.post/1.0.0.json" 0

# --- fail closed ---
p=$(mk trav BUILD);               fire "traversal-rejected"              "$p" "registry/../x/1.0.0.json" 2

up=$(mk unread BUILD); chmod 000 "$up/.sdd/ACTIVE"
rc=0; ( cd "$up" && jq -nc '{tool_input:{file_path:"registry/ledger.post/1.0.0.json"}}' | CLAUDE_PROJECT_DIR="$up" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$up/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-44s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

jp=$(mk jqmiss BUILD)
stubnojq="$work/stubnojq"; mkdir -p "$stubnojq"
for b in bash head tr cat grep sed basename dirname find chmod mktemp pwd; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stubnojq/$b"; done
rc=0; err=$( cd "$jp" && jq -nc '{tool_input:{file_path:"registry/ledger.post/1.0.0.json"}}' | PATH="$stubnojq" CLAUDE_PROJECT_DIR="$jp" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-44s rc=2\n' "jq-missing-fails-closed-when-active"
else fail=$((fail+1)); printf 'FAIL %-44s want=2 got=%s err=[%s]\n' "jq-missing-fails-closed-when-active" "$rc" "$err"; fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
