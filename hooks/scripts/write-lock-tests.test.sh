#!/usr/bin/env bash
# Tests for hooks/scripts/write-lock-tests.sh.
# Once the qa-authored failing suite is locked (PROGRESS.md TESTS_LOCKED, set after
# SDD_FLEET_QA_TESTS_READY is verified and before coder is dispatched), the coder
# physically cannot edit the test paths it is judged against (audit A2, CRITICAL).
# The lock is forward-lane + PHASE=BUILD only; tests/ stays writable during qa
# authoring (before the lock) and throughout the bug lane.
# Run: bash hooks/scripts/write-lock-tests.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/write-lock-tests.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }

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

locked_build()  { printf 'PHASE: BUILD\nLANE: feature\nTESTS_LOCKED: %s\n' "${1:-7}"; }

# --- locked forward BUILD: tests/ is frozen, source + .sdd still writable -------
p=$(new_proj a1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; locked_build 7 > "$p/.sdd/feat/PROGRESS.md"
check "locked-test-edit-blocks"        "$p" "tests/test_app.py" 2
check "locked-nested-test-edit-blocks" "$p" "tests/integration/test_x.py" 2
check "locked-source-write-allows"     "$p" "src/app.py" 0
check "locked-sdd-write-allows"        "$p" ".sdd/feat/IMPL_NOTES.md" 0

# --- before the lock (qa authoring window): tests/ is writable ------------------
p=$(new_proj a2); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; printf 'PHASE: BUILD\nLANE: feature\n' > "$p/.sdd/feat/PROGRESS.md"
check "unlocked-test-write-allows" "$p" "tests/test_app.py" 0

# --- lock only bites during BUILD ----------------------------------------------
p=$(new_proj a3); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; printf 'PHASE: SPEC\nLANE: feature\nTESTS_LOCKED: 7\n' > "$p/.sdd/feat/PROGRESS.md"
check "spec-phase-test-write-allows" "$p" "tests/test_app.py" 0
p=$(new_proj a3b); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; printf 'PHASE: CHANGE_REVIEW\nLANE: feature\nTESTS_LOCKED: 7\n' > "$p/.sdd/feat/PROGRESS.md"
check "change-review-test-write-allows" "$p" "tests/test_app.py" 0

# --- bug lane: tests/ stays writable (the reproducing test lives there) ---------
p=$(new_proj b1); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"
printf 'STATUS: CONFIRMED\n' > "$p/.sdd/bug/diagnosis.md"; printf 'PHASE: FIX\nLANE: bug\nTESTS_LOCKED: 3\n' > "$p/.sdd/bug/PROGRESS.md"
check "bug-lane-test-write-allows" "$p" "tests/test_repro.py" 0

# --- NotebookEdit under tests/ while locked → blocked --------------------------
p=$(new_proj n1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; locked_build 7 > "$p/.sdd/feat/PROGRESS.md"
check_json "locked-notebook-test-blocks" "$p" '{"tool_input":{"notebook_path":"tests/explore.ipynb"}}' 2

# --- §3.1 traversal cannot satisfy the tests/ prefix (other gates own source) ---
p=$(new_proj t1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; locked_build 7 > "$p/.sdd/feat/PROGRESS.md"
check "traversal-tests-dotdot-not-locked" "$p" "tests/../src/app.py" 0

# --- no active feature → allow --------------------------------------------------
p=$(new_proj z1); : > "$p/.sdd/ACTIVE"
check "no-active-allows" "$p" "tests/test_app.py" 0

# --- §3.4 jq missing + active feature → fail CLOSED (exit 2) --------------------
stub="$work/stubbin"; mkdir -p "$stub"
for b in dirname basename head tail tr cat grep sed find date stat awk wc; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$stub/$b"
done
p=$(new_proj j1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; locked_build 7 > "$p/.sdd/feat/PROGRESS.md"
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":"tests/test_app.py"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "no-jq-active-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2+msg got=%s (%s)\n' "no-jq-active-fails-closed" "$rc" "$err"; fi

# --- §3.5 unexpected runtime error → fail CLOSED (exit 2) -----------------------
p=$(new_proj e1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; locked_build 7 > "$p/.sdd/feat/PROGRESS.md"
chmod 000 "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":"tests/test_app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
