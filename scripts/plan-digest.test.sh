#!/usr/bin/env bash
# Tests for scripts/plan-digest.sh — the shared ratification digest helper.
# Single home of the digest algorithm used by epic-ratify-record.sh (records PLAN_DIGEST)
# and the epic-ratified-before-fanout hook (re-validates it).
# Run: bash scripts/plan-digest.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/plan-digest.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %-32s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %-32s :: %s\n' "$1" "$2"; }

printf 'alpha\n' > "$work/a"
printf 'beta\n'  > "$work/b"
printf 'alpha\n' > "$work/a2"     # identical content to a
printf 'beta\n'  > "$work/b2"     # identical content to b
printf 'GAMMA\n' > "$work/c"      # different content

da=$(bash "$SCRIPT" "$work/a" "$work/b" 2>/dev/null)
da2=$(bash "$SCRIPT" "$work/a2" "$work/b2" 2>/dev/null)
[ -n "$da" ] && ok digest-prints-line || no digest-prints-line "empty output"
[ "$da" = "$da2" ] && ok digest-deterministic || no digest-deterministic "$da vs $da2"

dc=$(bash "$SCRIPT" "$work/a" "$work/c" 2>/dev/null)
[ -n "$dc" ] && [ "$da" != "$dc" ] && ok digest-content-sensitive || no digest-content-sensitive "same digest for different content"

donly=$(bash "$SCRIPT" "$work/a" 2>/dev/null)
dba=$(bash "$SCRIPT" "$work/b" "$work/a" 2>/dev/null)
{ [ "$da" != "$donly" ] && [ "$da" != "$dba" ]; } && ok digest-multifile || no digest-multifile "concatenation/order not reflected"

e=$(bash "$SCRIPT" "$work/a" "$work/missing" 2>/dev/null); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$e" ]; } && ok digest-unreadable-errors || no digest-unreadable-errors "rc=$rc out=$e"

bash "$SCRIPT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok digest-usage-error || no digest-usage-error "no-args should exit 1, got $rc"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
