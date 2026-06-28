#!/usr/bin/env bash
# Tests for scripts/counterfactual.sh.
# The counterfactual reverts ONLY the coder's source change (keeping the
# qa-authored tests), runs the suite, and DECIDES: load-bearing change (suite goes
# red → pass) vs decorative tests (suite stays green → fail). The verdict is
# computed by the script, not narrated by the model (audit A3).
# Run: bash scripts/counterfactual.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/counterfactual.sh"

if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "counterfactual.test: git + python3 required — skipping"; exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

git_init() {
  local p="$1"
  ( cd "$p" && git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false ) >/dev/null 2>&1
}
testfile() { printf 'import sys\nsys.path.insert(0, ".")\nimport app\nassert app.add(2, 2) == 4\nprint("ok")\n'; }

run() { # run() <proj> -> sets RC and OUT
  OUT=$( cd "$1" && SDD_FLEET_TEST_CMD="python3 tests/test_app.py" CLAUDE_PROJECT_DIR="$1" bash "$SCRIPT" 2>/dev/null ); RC=$?
}
expect() { # expect <name> <want_rc> <want_verdict_substr>
  if [ "$RC" -eq "$2" ] && printf '%s' "$OUT" | grep -q "$3"; then
    pass=$((pass+1)); printf 'ok   %-34s rc=%s\n' "$1" "$RC"
  else
    fail=$((fail+1)); printf 'FAIL %-34s want rc=%s/%s got rc=%s (%s)\n' "$1" "$2" "$3" "$RC" "$OUT"
  fi
}

# --- PASS: a load-bearing source change (revert → suite red) -------------------
p="$work/pass"; mkdir -p "$p/tests"; git_init "$p"
testfile > "$p/tests/test_app.py"
printf 'def add(a, b):\n    return 0\n' > "$p/app.py"            # stub: test fails at base
( cd "$p" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf 'def add(a, b):\n    return a + b\n' > "$p/app.py"        # coder's fix (uncommitted)
run "$p"; expect "load-bearing-change-passes" 0 '"verdict":"pass"'
# restoration: the fix is back in place and the suite is green again
( cd "$p" && SDD_FLEET_TEST_CMD=1 true ); if grep -q 'a + b' "$p/app.py" && ( cd "$p" && python3 tests/test_app.py >/dev/null 2>&1 ); then
  pass=$((pass+1)); printf 'ok   %-34s\n' "restores-working-tree"
else fail=$((fail+1)); printf 'FAIL %-34s app.py not restored\n' "restores-working-tree"; fi

# --- FAIL: a decorative change (revert → suite still green) --------------------
p="$work/fail"; mkdir -p "$p/tests"; git_init "$p"
testfile > "$p/tests/test_app.py"
printf 'def add(a, b):\n    return a + b\n' > "$p/app.py"        # already correct at base
( cd "$p" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf 'UNUSED = 1\n' > "$p/util.py"                            # untracked source the test never exercises
run "$p"; expect "decorative-change-fails" 1 '"verdict":"fail"'

# --- SKIP: no source change (only a tests/ edit) ------------------------------
p="$work/skip"; mkdir -p "$p/tests"; git_init "$p"
testfile > "$p/tests/test_app.py"
printf 'def add(a, b):\n    return a + b\n' > "$p/app.py"
( cd "$p" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf '# touched\n' >> "$p/tests/test_app.py"                  # only a tests/ change
run "$p"; expect "no-source-change-skips" 3 '"verdict":"skip"'

# --- SKIP: not a git repo -----------------------------------------------------
p="$work/nogit"; mkdir -p "$p"
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="true" CLAUDE_PROJECT_DIR="$p" bash "$SCRIPT" 2>/dev/null ); RC=$?
expect "not-a-repo-skips" 3 '"verdict":"skip"'

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
