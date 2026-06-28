#!/usr/bin/env bash
# Tests for hooks/scripts/restrict-reviewer-writes.sh (audit §3.8).
# PreToolUse gate: during REVIEW/CHANGE_REVIEW all writes are restricted to the
# active feature's .sdd/<slug>/ workspace, except while the workflow-in-flight
# marker is present (workflow reviewers are tool-restricted at AgentDefinition
# level; the scribe must write .sdd/). Feeds the PreToolUse JSON payload on
# stdin with CLAUDE_PROJECT_DIR anchoring the fixture repo.
# Run: bash hooks/scripts/restrict-reviewer-writes.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/restrict-reviewer-writes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# new_proj <name> <phase>  → fixture repo with active feature 'feat' in <phase>
new_proj() {
  local p="$work/$1"
  mkdir -p "$p/.sdd/feat" "$p/src"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  # SDD_SCHEMA stamp included: _lib.sh's field readers grep named fields and
  # must ignore it (every case below doubles as the graceful-ignore check).
  printf 'SDD_SCHEMA: 1\nPHASE: %s\nCYCLE: 1\n' "$2" > "$p/.sdd/feat/PROGRESS.md"
  printf '%s' "$p"
}
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}
check_json() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# --- phase scoping: only REVIEW and CHANGE_REVIEW restrict ---
p=$(new_proj r1 REVIEW)
check "review-blocks-source-write" "$p" "src/app.py" 2
check "review-allows-active-sdd-write" "$p" ".sdd/feat/REVIEW.md" 0
p=$(new_proj r2 REVIEW)
check "review-blocks-other-feature-sdd" "$p" ".sdd/other/REVIEW.md" 2
p=$(new_proj cr1 CHANGE_REVIEW)
check "change-review-blocks-source-write" "$p" "src/app.py" 2
check "change-review-allows-active-sdd" "$p" ".sdd/feat/IMPL_NOTES.md" 0
p=$(new_proj b1 BUILD)
check "build-phase-not-restricted" "$p" "src/app.py" 0
p=$(new_proj s1 SPEC)
check "spec-phase-not-restricted" "$p" "src/app.py" 0

# --- no active feature → nothing to guard ---
p="$work/noactive"; mkdir -p "$p/.sdd"; : > "$p/.sdd/ACTIVE"
check "no-active-feature-allows" "$p" "src/app.py" 0

# --- the .workflow-in-flight marker-skip path: hook stands down entirely ---
# A LIVE marker carries the dispatching run's id (non-empty).
p=$(new_proj w1 REVIEW); printf 'review-feat-c1-2026' > "$p/.sdd/feat/.workflow-in-flight"
check "marker-skips-source-write" "$p" "src/app.py" 0
check "marker-skips-sdd-write" "$p" ".sdd/feat/REVIEW.md" 0
# marker on a DIFFERENT feature does not skip the active one's gate
p=$(new_proj w2 REVIEW); mkdir -p "$p/.sdd/other"; printf 'run-id' > "$p/.sdd/other/.workflow-in-flight"
check "other-features-marker-does-not-skip" "$p" "src/app.py" 2
# a RELEASED marker (empty — the scribe emptied it, having no Bash to rm) does
# NOT skip: the gate re-engages the moment the scribe releases it
p=$(new_proj w3 REVIEW); : > "$p/.sdd/feat/.workflow-in-flight"
check "released-empty-marker-does-not-skip" "$p" "src/app.py" 2

# --- T3 hardening: traversal must not satisfy the .sdd/<slug>/ prefix ---
p=$(new_proj t1 REVIEW)
check "traversal-active-sdd-dotdot-blocked" "$p" ".sdd/feat/../../src/app.py" 2
check "traversal-bare-dotdot-blocked" "$p" ".." 2

# --- NotebookEdit goes through the same gate ---
p=$(new_proj n1 REVIEW)
check_json "notebook-to-src-blocked" "$p" '{"tool_input":{"notebook_path":"src/x.ipynb"}}' 2
check_json "notebook-to-active-sdd-allowed" "$p" '{"tool_input":{"notebook_path":".sdd/feat/scratch.ipynb"}}' 0

# --- malformed input: no file_path (e.g. a non-write payload) → allow ---
p=$(new_proj j0 REVIEW)
check_json "no-file_path-allows" "$p" '{"tool_input":{}}' 0

# --- T3 hardening: malformed JSON → ERR trap → fail CLOSED (exit 2) ---
p=$(new_proj j1 REVIEW)
rc=0; ( cd "$p" && printf 'not json' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "malformed-json-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "malformed-json-fails-closed" "$rc"; fi

# --- T3 hardening: unreadable ACTIVE → resolve_active errors → fail CLOSED ---
p=$(new_proj e1 REVIEW); chmod 000 "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

# --- T3 hardening: drifted cwd — CLAUDE_PROJECT_DIR anchors .sdd/ resolution ---
p=$(new_proj c1 REVIEW); mkdir -p "$p/sub"
rc=0; ( cd "$p/sub" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "drifted-cwd-still-blocks"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "drifted-cwd-still-blocks" "$rc"; fi

# --- refusal message names the phase and the refused path ---
p=$(new_proj msg1 REVIEW)
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "REVIEW" && printf '%s' "$err" | grep -q "src/app.py"; then
  pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "refusal-message-names-phase+path"
else
  fail=$((fail+1)); printf 'FAIL %-40s want=2+msg got=%s (%s)\n' "refusal-message-names-phase+path" "$rc" "$err"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
