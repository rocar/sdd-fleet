#!/usr/bin/env bash
# Tests for hooks/scripts/dependency-gate.sh (Slice 5 Task 4, decision [D-a]).
# PreToolUse Write|Edit: when a write transitions PROGRESS.md to PHASE: HANDOFF (the ship
# chokepoint), scan the feature git-diff for undeclared client edges; exit 2 if blocked.
# Inert: non-HANDOFF write, non-PROGRESS write, no service.json, git-missing, no active item.
# Run: bash hooks/scripts/dependency-gate.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/dependency-gate.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# fire <name> <proj> <file_path> <content> <want-rc>
fire() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" --arg c "$content" '{tool_input:{file_path:$f,content:$c}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# make_repo <name> <declared:yes|no> -> echoes the repo working tree (a feature branch with
# an added `ledgerClient.post(` call committed on top of a clean main).
SIG='{"contract":"ledger.post","version":"1.0.0","kind":"openapi","client_signature":"ledgerClient\\.post\\("}'
make_repo() {
  local name="$1" declared="$2" cons="[]"
  local repo="$work/$name"
  [ "$declared" = yes ] && cons='["ledger.post@1"]'
  mkdir -p "$repo"
  ( cd "$repo" && git init -q && git checkout -q -b main && git config user.email t@e && git config user.name t )
  printf '{"id":"app","team":"t","lifecycle":"production","data_classes":[],"produces":[],"consumes":%s}' "$cons" > "$repo/service.json"
  mkdir -p "$repo/registry/ledger.post"; printf '%s' "$SIG" > "$repo/registry/ledger.post/1.0.0.json"
  printf 'print("hello")\n' > "$repo/src.py"
  mkdir -p "$repo/.sdd/feat"; printf 'feat\n' > "$repo/.sdd/ACTIVE"; printf 'PHASE: CHANGE_REVIEW\n' > "$repo/.sdd/feat/PROGRESS.md"
  ( cd "$repo" && git add -A && git commit -qm base ) >/dev/null 2>&1
  ( cd "$repo" && git checkout -q -b feature )
  printf 'result = ledgerClient.post(payload)\n' >> "$repo/src.py"
  ( cd "$repo" && git add -A && git commit -qm change ) >/dev/null 2>&1
  printf '%s' "$repo"
}

# --- non-git inert cases (no repo needed) ---
np="$work/np"; mkdir -p "$np/.sdd/feat"; printf 'feat\n' > "$np/.sdd/ACTIVE"
fire "non-progress-write-allows"  "$np" "src.py"               "PHASE: HANDOFF" 0
mkdir -p "$work/empty"
fire "no-active-feature-allows"   "$work/empty" ".sdd/x/PROGRESS.md" "PHASE: HANDOFF" 0  # empty proj, no ACTIVE

# traversal in the path → reject (rc 2)
tp="$work/tp"; mkdir -p "$tp/.sdd/feat"; printf 'feat\n' > "$tp/.sdd/ACTIVE"
fire "traversal-rejected"         "$tp" "../e/.sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

# unreadable ACTIVE → fail closed (rc 2)
up="$work/up"; mkdir -p "$up/.sdd/feat"; printf 'feat\n' > "$up/.sdd/ACTIVE"; printf 'STATUS\n' > "$up/.sdd/feat/PROGRESS.md"
chmod 000 "$up/.sdd/ACTIVE"
rc=0; ( cd "$up" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | CLAUDE_PROJECT_DIR="$up" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$up/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=2\n' "unreadable-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-44s want=2 got=%s\n' "unreadable-fails-closed" "$rc"; fi

# --- git-dependent cases ---
git_ok=0
if command -v git >/dev/null 2>&1; then
  probe=$(make_repo probe no)
  [ -n "$(cd "$probe" && git rev-parse --verify main 2>/dev/null)" ] && git_ok=1
fi

if [ "$git_ok" -eq 1 ]; then
  m=$(make_repo undecl no);  fire "handoff-transition-undeclared-blocks" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
  m=$(make_repo decl yes);   fire "handoff-transition-clean-allows"      "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
  m=$(make_repo nobuild no); fire "non-handoff-progress-write-allows"    "$m" ".sdd/feat/PROGRESS.md" "PHASE: BUILD" 0
  # service.json removed → inert
  m=$(make_repo nosvc no); rm -f "$m/service.json"
  fire "no-service-json-inert" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
  # git missing → inert (stub PATH without git)
  stub="$work/stub"; mkdir -p "$stub"
  for b in bash basename dirname cat grep sed tr head find jq chmod; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stub/$b"; done
  m=$(make_repo gitmiss no)
  rc=0; ( cd "$m" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$m" /bin/bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-44s rc=0\n' "git-missing-inert"
  else fail=$((fail+1)); printf 'FAIL %-44s want=0 got=%s\n' "git-missing-inert" "$rc"; fi
else
  printf 'SKIP git fixtures (git unavailable)\n'
fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
