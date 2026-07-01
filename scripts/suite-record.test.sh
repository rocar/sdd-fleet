#!/usr/bin/env bash
# Tests for scripts/suite-record.sh (ADR-0002: "no handoff on a failing or untraceable
# suite" as a hook). Runs the write-locked suite and records the outcome into
# .sdd/<slug>/SUITE_RUN.md, pinned to the CURRENT change content by CHANGE_SIGNATURE
# (counterfactual-record.sh `signature` — the single home, so this record and
# handoff-suite-gate.sh's re-verification can never drift). Test commands:
# SDD_FLEET_TEST_CMD overrides; else multi-stack detection mirroring stop-tests.sh
# (independent fall-throughs). No recognized command → RESULT: skip / no-test-command
# is RECORDED (the gate blocks on it — set SDD_FLEET_TEST_CMD and re-record).
# Run: bash scripts/suite-record.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/suite-record.sh"
SIGSCRIPT="$DIR/counterfactual-record.sh"

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "suite-record.test: git + jq required — skipping"; exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %-44s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %-44s %s\n' "$1" "$2"; }

mkrepo() {
  local p="$work/$1"
  mkdir -p "$p"
  printf 'a\n' > "$p/f.txt"
  ( cd "$p" && git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$p"
}
sig() { ( cd "$1" && bash "$SIGSCRIPT" signature 2>/dev/null ); }
field() { { grep -m1 "^$2:" "$1/.sdd/feat/SUITE_RUN.md" 2>/dev/null || true; } | sed -E "s/^$2:[[:space:]]*//" | tr -d '\r' | sed -E 's/[[:space:]]+$//'; }

# --- green run (explicit test command) --------------------------------------------
p=$(mkrepo green)
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="true" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 0 ] && [ "$(field "$p" RESULT)" = green ] \
   && [ -n "$(field "$p" CHANGE_SIGNATURE)" ] && [ "$(field "$p" CHANGE_SIGNATURE)" = "$(sig "$p")" ] \
   && printf '%s' "$(field "$p" TEST_COMMANDS)" | grep -q 'true' \
   && printf '%s' "$OUT" | grep -q 'SDD_FLEET_SUITE_RECORD:.*"result":"green"'; then
  ok "green-recorded-and-pinned"; else no "green-recorded-and-pinned" "rc=$RC out=$OUT result=$(field "$p" RESULT) art=$(field "$p" CHANGE_SIGNATURE) cur=$(sig "$p")"; fi

# --- red run ------------------------------------------------------------------------
p=$(mkrepo red)
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="false" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 1 ] && [ "$(field "$p" RESULT)" = red ] && printf '%s' "$(field "$p" REASON)" | grep -q 'failing'; then
  ok "red-recorded"; else no "red-recorded" "rc=$RC result=$(field "$p" RESULT) reason=$(field "$p" REASON)"; fi

# --- no recognized test command → skip is RECORDED (the gate blocks on it) -----------
p=$(mkrepo none)
OUT=$( cd "$p" && SDD_FLEET_TEST_CMD="" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 3 ] && [ "$(field "$p" RESULT)" = skip ] && [ "$(field "$p" REASON)" = no-test-command ] \
   && [ -n "$(field "$p" CHANGE_SIGNATURE)" ]; then
  ok "no-test-command-skip-recorded"; else no "no-test-command-skip-recorded" "rc=$RC result=$(field "$p" RESULT) reason=$(field "$p" REASON)"; fi

# --- stack detection: a Makefile test target (only when make is present) --------------
if command -v make >/dev/null 2>&1; then
  p=$(mkrepo makegreen)
  printf 'test:\n\t@true\n' > "$p/Makefile"
  ( cd "$p" && SDD_FLEET_TEST_CMD="" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z >/dev/null 2>&1 ); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(field "$p" RESULT)" = green ] && printf '%s' "$(field "$p" TEST_COMMANDS)" | grep -q 'make test'; then
    ok "makefile-detected-green"; else no "makefile-detected-green" "rc=$RC result=$(field "$p" RESULT) cmds=$(field "$p" TEST_COMMANDS)"; fi

  p=$(mkrepo makered)
  printf 'test:\n\t@false\n' > "$p/Makefile"
  ( cd "$p" && SDD_FLEET_TEST_CMD="" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z >/dev/null 2>&1 ); RC=$?
  if [ "$RC" -eq 1 ] && [ "$(field "$p" RESULT)" = red ]; then
    ok "makefile-detected-red"; else no "makefile-detected-red" "rc=$RC result=$(field "$p" RESULT)"; fi
fi

# --- usage guards / no repo (nothing recorded) ----------------------------------------
p=$(mkrepo usage)
( cd "$p" && bash "$SCRIPT" >/dev/null 2>&1 ); RC=$?
if [ "$RC" -eq 2 ] && [ ! -f "$p/.sdd/feat/SUITE_RUN.md" ]; then ok "usage-no-slug-refuses"; else no "usage-no-slug-refuses" "rc=$RC"; fi
( cd "$p" && bash "$SCRIPT" feat >/dev/null 2>&1 ); RC=$?
if [ "$RC" -eq 2 ] && [ ! -f "$p/.sdd/feat/SUITE_RUN.md" ]; then ok "usage-no-now-refuses"; else no "usage-no-now-refuses" "rc=$RC"; fi

q="$work/norepo"; mkdir -p "$q"
OUT=$( cd "$q" && SDD_FLEET_TEST_CMD="true" bash "$SCRIPT" feat --now 2026-07-01T00:00:00Z 2>/dev/null ); RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'signature-failed' && [ ! -f "$q/.sdd/feat/SUITE_RUN.md" ]; then
  ok "no-repo-signature-failed"; else no "no-repo-signature-failed" "rc=$RC out=$OUT"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
