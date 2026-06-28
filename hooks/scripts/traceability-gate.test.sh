#!/usr/bin/env bash
# Tests for hooks/scripts/traceability-gate.sh.
# During a forward feature's BUILD (spec FINALIZED), a SOURCE write is refused
# until TEST_PLAN.md exists and maps every acceptance criterion (AC-<n>) to a test
# row — or records it under ## Gaps. Encodes "every AC maps to a test before
# implementation begins" in code (audit A4). qa's .sdd/ + tests/ writes pass
# through; only coder source writes are gated.
# Run: bash hooks/scripts/traceability-gate.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/traceability-gate.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }

check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-42s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-42s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}
check_json() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-42s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-42s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# build a forward feature at FINALIZED/BUILD with given acceptance + TEST_PLAN
mk() {
  local p; p=$(new_proj "$1"); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
  printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"
  printf 'PHASE: BUILD\nLANE: feature\n' > "$p/.sdd/feat/PROGRESS.md"
  printf '%s' "$p"
}
accept2() { printf '# Acceptance\n\n- AC-1: returns 200\n- AC-2: returns 422 on bad body\n'; }
plan_both() { printf '# Test Plan\n\n## Coverage matrix\n\n| Criterion | Test | Type | Location |\n|--|--|--|--|\n| AC-1 | test_ok | unit | tests/t.py::test_ok |\n| AC-2 | test_bad | unit | tests/t.py::test_bad |\n'; }
plan_one()  { printf '# Test Plan\n\n## Coverage matrix\n\n| AC-1 | test_ok | unit | tests/t.py::test_ok |\n'; }
plan_one_gap() { printf '# Test Plan\n\n## Coverage matrix\n\n| AC-1 | test_ok | unit | tests/t.py::test_ok |\n\n## Gaps\n\n- AC-2: untestable as written — recommend spec revision.\n'; }

# --- full coverage → source write allowed ---------------------------------------
p=$(mk a1); accept2 > "$p/.sdd/feat/acceptance.md"; plan_both > "$p/.sdd/feat/TEST_PLAN.md"
check "full-coverage-source-allows" "$p" "src/app.py" 0

# --- partial coverage → source write blocked ------------------------------------
p=$(mk a2); accept2 > "$p/.sdd/feat/acceptance.md"; plan_one > "$p/.sdd/feat/TEST_PLAN.md"
check "uncovered-ac-source-blocks" "$p" "src/app.py" 2

# --- no TEST_PLAN.md → source write blocked (tests-first ordering) ---------------
p=$(mk a3); accept2 > "$p/.sdd/feat/acceptance.md"
check "no-test-plan-source-blocks" "$p" "src/app.py" 2

# --- an AC recorded under ## Gaps counts as addressed → allow -------------------
p=$(mk a4); accept2 > "$p/.sdd/feat/acceptance.md"; plan_one_gap > "$p/.sdd/feat/TEST_PLAN.md"
check "gap-recorded-ac-allows" "$p" "src/app.py" 0

# --- inline ACs in spec.md (no acceptance.md), covered → allow ------------------
p=$(mk a5); printf 'STATUS: FINALIZED\n\n## Acceptance Criteria\n- AC-1: returns 200\n' > "$p/.sdd/feat/spec.md"
plan_one > "$p/.sdd/feat/TEST_PLAN.md"
check "inline-ac-covered-allows" "$p" "src/app.py" 0

# --- non-source writes pass through (qa's lane) ---------------------------------
p=$(mk b1); accept2 > "$p/.sdd/feat/acceptance.md"; plan_one > "$p/.sdd/feat/TEST_PLAN.md"
check "sdd-write-allows"   "$p" ".sdd/feat/IMPL_NOTES.md" 0
check "tests-write-allows" "$p" "tests/new_test.py" 0

# --- inert outside BUILD (block-source owns pre-FINALIZE) -----------------------
p=$(new_proj c1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; printf 'PHASE: SPEC\nLANE: feature\n' > "$p/.sdd/feat/PROGRESS.md"
check "spec-phase-source-inert" "$p" "src/app.py" 0

# --- bug lane source write inert (forward-only) --------------------------------
p=$(new_proj d1); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"
printf 'STATUS: CONFIRMED\n' > "$p/.sdd/bug/diagnosis.md"; printf 'PHASE: FIX\nLANE: bug\n' > "$p/.sdd/bug/PROGRESS.md"
check "bug-lane-source-inert" "$p" "src/app.py" 0

# --- no AC ids found → inert (finalize owns AC presence) -----------------------
p=$(mk e1); printf '# Acceptance\n\n- the thing works\n' > "$p/.sdd/feat/acceptance.md"; plan_both > "$p/.sdd/feat/TEST_PLAN.md"
check "no-ac-ids-inert" "$p" "src/app.py" 0

# --- NotebookEdit source while uncovered → blocked -----------------------------
p=$(mk n1); accept2 > "$p/.sdd/feat/acceptance.md"; plan_one > "$p/.sdd/feat/TEST_PLAN.md"
check_json "notebook-source-uncovered-blocks" "$p" '{"tool_input":{"notebook_path":"src/analysis.ipynb"}}' 2

# --- no active feature → allow --------------------------------------------------
p=$(new_proj z1); : > "$p/.sdd/ACTIVE"
check "no-active-allows" "$p" "src/app.py" 0

# --- §3.4 jq missing + active feature → fail CLOSED (exit 2) --------------------
stub="$work/stubbin"; mkdir -p "$stub"
for b in dirname basename head tail tr cat grep sed find date stat awk wc sort; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$stub/$b"
done
p=$(mk j1); accept2 > "$p/.sdd/feat/acceptance.md"; plan_one > "$p/.sdd/feat/TEST_PLAN.md"
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-42s rc=2\n' "no-jq-active-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-42s want=2+msg got=%s (%s)\n' "no-jq-active-fails-closed" "$rc" "$err"; fi

# --- §3.5 unexpected runtime error → fail CLOSED (exit 2) -----------------------
p=$(mk e2); accept2 > "$p/.sdd/feat/acceptance.md"; plan_one > "$p/.sdd/feat/TEST_PLAN.md"
chmod 000 "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-42s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-42s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
