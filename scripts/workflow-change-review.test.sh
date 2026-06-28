#!/usr/bin/env bash
# Drift guard + syntax check for workflows/change-review.js (audit B6).
# change-review.js is a self-contained fork of review.js (the sandbox forbids
# import, so every workflow duplicates the shell). Its LAYER1-PURE-HELPERS
# (roster/budget) and LAYER2-VOTE-HELPERS (adjudicator/identity/verdict) MUST stay
# byte-identical to review.js so the survival-vote logic cannot drift between REVIEW
# and CHANGE_REVIEW. review.js's pure logic is exercised by workflow-vote-logic.test.sh;
# byte-identical blocks ⇒ identical behavior here.
# Run: bash scripts/workflow-change-review.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
R="$ROOT/workflows/review.js"
C="$ROOT/workflows/change-review.js"

pass=0; fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-cr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# extract <file> <marker-base> — prints the START..END block inclusive.
extract() { awk -v s="$2 START" -v e="$2 END" 'index($0,s){f=1} f{print} index($0,e){f=0}' "$1"; }

parity() { # parity <marker-base> <label>
  extract "$R" "$1" > "$TMP/r.txt"; extract "$C" "$1" > "$TMP/c.txt"
  if [ ! -s "$TMP/r.txt" ] || [ ! -s "$TMP/c.txt" ]; then
    fail=$((fail+1)); printf 'FAIL %-32s (a block was empty)\n' "$2"; return
  fi
  if diff -q "$TMP/r.txt" "$TMP/c.txt" >/dev/null; then
    pass=$((pass+1)); printf 'ok   %-32s identical to review.js\n' "$2"
  else
    fail=$((fail+1)); printf 'FAIL %-32s drifted from review.js\n' "$2"; diff "$TMP/r.txt" "$TMP/c.txt" | head -20
  fi
}

parity "LAYER1-PURE-HELPERS" "layer1-roster-budget"
parity "LAYER2-VOTE-HELPERS" "layer2-vote-adjudicator"

# syntax check (node always present in CI; skip gracefully otherwise)
if command -v node >/dev/null 2>&1; then
  if node --check "$C" >/dev/null 2>&1; then pass=$((pass+1)); printf 'ok   %-32s\n' "node-check"
  else fail=$((fail+1)); printf 'FAIL %-32s node --check failed\n' "node-check"; fi
else
  printf 'ok   %-32s (SKIPPED: node not found)\n' "node-check"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
