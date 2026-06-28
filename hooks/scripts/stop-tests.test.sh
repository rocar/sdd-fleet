#!/usr/bin/env bash
# Tests for hooks/scripts/stop-tests.sh (audit §3.6 — bounded Stop gate).
# Loop guard (stop_hook_active), bounded retry counter with escalation at 3,
# operator override flag, green-run counter reset, independent stack detection.
# Run: bash hooks/scripts/stop-tests.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/stop-tests.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# new_proj <name> <make_test_exit_code> → fixture: active feature in BUILD with
# a Makefile test target exiting <code>. Counter/ESCALATION state starts clean.
new_proj() {
  local p="$work/$1" code="$2"
  mkdir -p "$p/.sdd/feat"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  printf 'PHASE: BUILD\n' > "$p/.sdd/feat/PROGRESS.md"
  printf 'test:\n\t@echo running; exit %s\n' "$code" > "$p/Makefile"
  printf '%s' "$p"
}
set_red()   { printf 'test:\n\t@echo running; exit 1\n' > "$1/Makefile"; }
set_green() { printf 'test:\n\t@echo running; exit 0\n' > "$1/Makefile"; }

# run <proj> [stdin_json] → sets rc
run() {
  local proj="$1" json="${2:-{\"stop_hook_active\":false\}}"
  rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
}
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then pass=$((pass+1)); printf 'ok   %-44s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %-44s (%s)\n' "$name" "$cond"; fi
}

# --- green suite → exit 0, no counter ---
p=$(new_proj green0 0)
run "$p"
assert "green-suite-allows-stop" "[ $rc -eq 0 ]"
assert "green-suite-no-counter" "[ ! -f '$p/.sdd/feat/.stop-test-retries' ]"

# --- loop guard: stop_hook_active=true → exit 0 even on a red suite ---
p=$(new_proj loop 1)
run "$p" '{"stop_hook_active":true}'
assert "loop-guard-respected" "[ $rc -eq 0 ]"
assert "loop-guard-no-counter" "[ ! -f '$p/.sdd/feat/.stop-test-retries' ]"

# --- operator override: .skip-stop-tests → exit 0 + warning, red suite ---
p=$(new_proj skip 1); touch "$p/.sdd/feat/.skip-stop-tests"
err=$( cd "$p" && printf '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
assert "override-flag-allows-stop" "[ $rc -eq 0 ]"
assert "override-flag-warns" "printf '%s' \"\$err\" | grep -q skip-stop-tests"

# --- red suite: blocks and counts 1, 2, then escalates on the 3rd ---
p=$(new_proj red3 1)
run "$p"
assert "red-1st-blocks" "[ $rc -eq 2 ]"
assert "red-1st-counter-is-1" "[ \"\$(cat '$p/.sdd/feat/.stop-test-retries')\" = 1 ]"
run "$p"
assert "red-2nd-blocks" "[ $rc -eq 2 ]"
assert "red-2nd-counter-is-2" "[ \"\$(cat '$p/.sdd/feat/.stop-test-retries')\" = 2 ]"
err=$( cd "$p" && printf '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
assert "red-3rd-escalates-allows-stop" "[ $rc -eq 0 ]"
assert "red-3rd-writes-escalation" "[ -f '$p/.sdd/feat/ESCALATION.md' ]"
assert "escalation-names-stop-tests" "grep -q 'stop-tests' '$p/.sdd/feat/ESCALATION.md'"
assert "escalation-scribe-format" "grep -q '^# Escalation — feat' '$p/.sdd/feat/ESCALATION.md'"
assert "red-3rd-clears-counter" "[ ! -f '$p/.sdd/feat/.stop-test-retries' ]"
assert "red-3rd-says-escalated" "printf '%s' \"\$err\" | grep -qi escalat"

# --- green run clears an existing counter ---
p=$(new_proj clear 1)
run "$p"
assert "clear-red-counts-1" "[ -f '$p/.sdd/feat/.stop-test-retries' ]"
set_green "$p"
run "$p"
assert "clear-green-allows" "[ $rc -eq 0 ]"
assert "clear-green-removes-counter" "[ ! -f '$p/.sdd/feat/.stop-test-retries' ]"

# --- §4 minor: stack detection is independent fall-throughs, not elif —
# a package.json WITHOUT scripts.test must not shadow a red Makefile ---
p=$(new_proj indep 1); printf '{"name":"x","version":"0.0.0"}\n' > "$p/package.json"
run "$p"
assert "pkgjson-does-not-shadow-makefile" "[ $rc -eq 2 ]"

# --- pre-BUILD phase: gate inert even on a red suite ---
p=$(new_proj prebuild 1); printf 'PHASE: SPEC\n' > "$p/.sdd/feat/PROGRESS.md"
run "$p"
assert "pre-build-phase-inert" "[ $rc -eq 0 ]"

# --- no active feature → exit 0 ---
p="$work/noactive"; mkdir -p "$p/.sdd"; : > "$p/.sdd/ACTIVE"
printf 'test:\n\t@exit 1\n' > "$p/Makefile"
run "$p"
assert "no-active-inert" "[ $rc -eq 0 ]"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
