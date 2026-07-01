#!/usr/bin/env bash
# Tests for scripts/counterfactual-record.sh (ADR-0002: the counterfactual becomes a
# fail-closed gate at the HANDOFF flip). Two modes:
#   record   — run the deterministic engine (scripts/counterfactual.sh) and record its
#              verdict into .sdd/<slug>/COUNTERFACTUAL.md, pinned to the CURRENT change
#              content by CHANGE_SIGNATURE (what counterfactual-gate.sh re-verifies).
#   signature — print the change signature. THE single home of the algorithm (the
#              blast-radius-signature.sh record-and-verify pattern): both HANDOFF-flip
#              gates and suite-record.sh call this mode, so record and verify never drift.
# The signature is CONTENT-based (blob hashes of every non-.sdd tracked+untracked file):
# a source or tests edit stales it; a commit of identical content does not; .sdd/ writes
# (the records themselves, PROGRESS.md) never do.
# Run: bash scripts/counterfactual-record.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/counterfactual-record.sh"

if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "counterfactual-record.test: git + python3 + jq required — skipping"; exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %-44s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %-44s %s\n' "$1" "$2"; }

git_init() {
  local p="$1"
  ( cd "$p" && git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false ) >/dev/null 2>&1
}
testfile() { printf 'import sys\nsys.path.insert(0, ".")\nimport app\nassert app.add(2, 2) == 4\nprint("ok")\n'; }
sig() { ( cd "$1" && bash "$SCRIPT" signature 2>/dev/null ); }
field() { { grep -m1 "^$2:" "$1/.sdd/feat/COUNTERFACTUAL.md" 2>/dev/null || true; } | sed -E "s/^$2:[[:space:]]*//" | tr -d '\r' | sed -E 's/[[:space:]]+$//'; }

# --- signature mode -------------------------------------------------------------
p="$work/sig"; mkdir -p "$p"; git_init "$p"
printf 'a\n' > "$p/f.txt"
( cd "$p" && git add -A && git commit -qm init ) >/dev/null 2>&1
s1=$(sig "$p"); s2=$(sig "$p")
if [ -n "$s1" ] && [ "$s1" = "$s2" ]; then ok "signature-stable"; else no "signature-stable" "s1=$s1 s2=$s2"; fi

printf 'b\n' >> "$p/f.txt"; s3=$(sig "$p")
if [ -n "$s3" ] && [ "$s3" != "$s1" ]; then ok "signature-changes-on-source-edit"; else no "signature-changes-on-source-edit" "s1=$s1 s3=$s3"; fi

mkdir -p "$p/tests"; printf 'assert True\n' > "$p/tests/test_x.py"; s4=$(sig "$p")
if [ -n "$s4" ] && [ "$s4" != "$s3" ]; then ok "signature-changes-on-tests-edit"; else no "signature-changes-on-tests-edit" "s3=$s3 s4=$s4"; fi

mkdir -p "$p/.sdd/feat"; printf 'PHASE: CHANGE_REVIEW\n' > "$p/.sdd/feat/PROGRESS.md"; s5=$(sig "$p")
if [ -n "$s5" ] && [ "$s5" = "$s4" ]; then ok "sdd-write-does-not-change-signature"; else no "sdd-write-does-not-change-signature" "s4=$s4 s5=$s5"; fi

( cd "$p" && git add -A && git commit -qm c2 ) >/dev/null 2>&1; s6=$(sig "$p")
if [ -n "$s6" ] && [ "$s6" = "$s5" ]; then ok "commit-does-not-change-signature"; else no "commit-does-not-change-signature" "s5=$s5 s6=$s6"; fi

q="$work/norepo"; mkdir -p "$q"
out=$( cd "$q" && bash "$SCRIPT" signature 2>/dev/null ); rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then ok "signature-outside-repo-fails"; else no "signature-outside-repo-fails" "rc=$rc out=$out"; fi

# --- record: pass (load-bearing change) ------------------------------------------
p="$work/rpass"; mkdir -p "$p/tests"; git_init "$p"
testfile > "$p/tests/test_app.py"
printf 'def add(a, b):\n    return 0\n' > "$p/app.py"
( cd "$p" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf 'def add(a, b):\n    return a + b\n' > "$p/app.py"
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="python3 tests/test_app.py" CLAUDE_PROJECT_DIR="$p" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 0 ] && [ "$(field "$p" VERDICT)" = pass ] \
   && [ -n "$(field "$p" CHANGE_SIGNATURE)" ] && [ "$(field "$p" CHANGE_SIGNATURE)" = "$(sig "$p")" ] \
   && printf '%s' "$OUT" | grep -q 'SDD_FLEET_COUNTERFACTUAL_RECORD:.*"verdict":"pass"'; then
  ok "pass-recorded-and-pinned"; else no "pass-recorded-and-pinned" "rc=$RC out=$OUT art=$(field "$p" VERDICT)/$(field "$p" CHANGE_SIGNATURE) cur=$(sig "$p")"; fi

# --- record: fail (decorative change) ---------------------------------------------
p="$work/rfail"; mkdir -p "$p/tests"; git_init "$p"
testfile > "$p/tests/test_app.py"
printf 'def add(a, b):\n    return a + b\n' > "$p/app.py"
( cd "$p" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf 'UNUSED = 1\n' > "$p/util.py"
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="python3 tests/test_app.py" CLAUDE_PROJECT_DIR="$p" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 1 ] && [ "$(field "$p" VERDICT)" = fail ]; then
  ok "fail-recorded"; else no "fail-recorded" "rc=$RC verdict=$(field "$p" VERDICT)"; fi

# --- record: skip (tests-only change → no-source-change) ---------------------------
p="$work/rskip"; mkdir -p "$p/tests"; git_init "$p"
testfile > "$p/tests/test_app.py"
printf 'def add(a, b):\n    return a + b\n' > "$p/app.py"
( cd "$p" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf '# touched\n' >> "$p/tests/test_app.py"
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="python3 tests/test_app.py" CLAUDE_PROJECT_DIR="$p" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 3 ] && [ "$(field "$p" VERDICT)" = skip ] && [ "$(field "$p" REASON)" = no-source-change ]; then
  ok "skip-no-source-change-recorded"; else no "skip-no-source-change-recorded" "rc=$RC verdict=$(field "$p" VERDICT) reason=$(field "$p" REASON)"; fi

# --- usage guards (nothing recorded) -----------------------------------------------
p="$work/usage"; mkdir -p "$p"; git_init "$p"
printf 'a\n' > "$p/f.txt"; ( cd "$p" && git add -A && git commit -qm init ) >/dev/null 2>&1
( cd "$p" && bash "$SCRIPT" >/dev/null 2>&1 ); RC=$?
if [ "$RC" -eq 2 ] && [ ! -f "$p/.sdd/feat/COUNTERFACTUAL.md" ]; then ok "usage-no-slug-refuses"; else no "usage-no-slug-refuses" "rc=$RC"; fi
( cd "$p" && bash "$SCRIPT" feat >/dev/null 2>&1 ); RC=$?
if [ "$RC" -eq 2 ] && [ ! -f "$p/.sdd/feat/COUNTERFACTUAL.md" ]; then ok "usage-no-now-refuses"; else no "usage-no-now-refuses" "rc=$RC"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
