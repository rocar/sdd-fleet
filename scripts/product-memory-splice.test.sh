#!/usr/bin/env bash
# Tests for scripts/product-memory-splice.sh (audit §3.29 — the "never clobber"
# guarantee on the user-owned root CLAUDE.md, now deterministic + tested).
# Covers the five plan cases: no-file / block-present / block-absent /
# missing-END (error, no write) / duplicate-final-line.
# Run: bash scripts/product-memory-splice.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/product-memory-splice.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %-40s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %-40s %s\n' "$1" "${2:-}"; }

BEGIN='<!-- BEGIN sdd-fleet:product -->'
END='<!-- END sdd-fleet:product -->'

# --- case 1: no file → created with just the marked block ---
t="$work/no-file.md"
out="$(printf '## Product: demo\nvision line\n' | bash "$SCRIPT" "$t")"
expected="$(printf '%s\n## Product: demo\nvision line\n%s\n' "$BEGIN" "$END")"
if [ "$out" = "created" ] && [ "$(cat "$t")" = "$expected" ]; then
  ok "no-file-creates-marked-block"
else
  bad "no-file-creates-marked-block" "out=$out"
fi

# --- case 2: markers present → region replaced, outside preserved byte-for-byte ---
t="$work/present.md"
printf '# My own notes\nprecious user line\n\n%s\nOLD generated content\n%s\n\ntrailing user content\n' "$BEGIN" "$END" > "$t"
out="$(printf 'NEW content\n' | bash "$SCRIPT" "$t")"
expected="$(printf '# My own notes\nprecious user line\n\n%s\nNEW content\n%s\n\ntrailing user content\n' "$BEGIN" "$END")"
if [ "$out" = "updated-in-place" ] && [ "$(cat "$t")" = "$expected" ]; then
  ok "markers-present-replaces-region-only"
else
  bad "markers-present-replaces-region-only" "out=$out"
fi

# variant: BEGIN line carries trailing prose (prefix-detection, per the skill)
t="$work/present-prose.md"
printf 'user top\n<!-- BEGIN sdd-fleet:product — generated, edits overwritten -->\nOLD\n%s\nuser bottom\n' "$END" > "$t"
out="$(printf 'NEW\n' | bash "$SCRIPT" "$t")"
if [ "$out" = "updated-in-place" ] && grep -q '^user top$' "$t" && grep -q '^user bottom$' "$t" \
   && grep -q '^NEW$' "$t" && ! grep -q '^OLD$' "$t"; then
  ok "begin-prefix-with-trailing-prose-matches"
else
  bad "begin-prefix-with-trailing-prose-matches" "out=$out"
fi

# --- case 3: no markers → appended at EOF with markers; prior content intact ---
t="$work/absent.md"
printf '# Hand-authored CLAUDE.md\nrule one\nrule two\n' > "$t"
out="$(printf 'gen content\n' | bash "$SCRIPT" "$t")"
expected="$(printf '# Hand-authored CLAUDE.md\nrule one\nrule two\n\n%s\ngen content\n%s\n' "$BEGIN" "$END")"
if [ "$out" = "appended" ] && [ "$(cat "$t")" = "$expected" ]; then
  ok "no-markers-appends-at-eof"
else
  bad "no-markers-appends-at-eof" "out=$out"
fi

# --- case 4: BEGIN without END → error exit 1, file untouched ---
t="$work/missing-end.md"
printf 'user line\n%s\norphaned generated content\nmore content\n' "$BEGIN" > "$t"
before="$(cat "$t")"
rc=0; printf 'NEW\n' | bash "$SCRIPT" "$t" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ "$(cat "$t")" = "$before" ]; then
  ok "missing-end-errors-no-write"
else
  bad "missing-end-errors-no-write" "rc=$rc"
fi

# defensive twin: END without BEGIN → error exit 1, file untouched
t="$work/missing-begin.md"
printf 'user line\n%s\n' "$END" > "$t"
before="$(cat "$t")"
rc=0; printf 'NEW\n' | bash "$SCRIPT" "$t" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ "$(cat "$t")" = "$before" ]; then
  ok "missing-begin-errors-no-write"
else
  bad "missing-begin-errors-no-write" "rc=$rc"
fi

# --- case 5: duplicate final line (the model-driven-Edit failure mode) ---
# A file whose last line also appears earlier: append must land exactly once,
# at EOF, with every original line still present in order.
t="$work/dup-final.md"
printf 'shared line\nmiddle line\nshared line\n' > "$t"
out="$(printf 'gen\n' | bash "$SCRIPT" "$t")"
expected="$(printf 'shared line\nmiddle line\nshared line\n\n%s\ngen\n%s\n' "$BEGIN" "$END")"
if [ "$out" = "appended" ] && [ "$(cat "$t")" = "$expected" ]; then
  ok "duplicate-final-line-appends-once-at-eof"
else
  bad "duplicate-final-line-appends-once-at-eof" "out=$out got=[$(cat "$t")]"
fi

# --- robustness extras ---

# idempotency: splicing the same content twice leaves one block
t="$work/idem.md"
printf 'user\n' > "$t"
printf 'same\n' | bash "$SCRIPT" "$t" >/dev/null
printf 'same\n' | bash "$SCRIPT" "$t" >/dev/null
n="$(grep -c 'BEGIN sdd-fleet:product' "$t")"
if [ "$n" -eq 1 ]; then ok "idempotent-single-block"; else bad "idempotent-single-block" "blocks=$n"; fi

# no trailing newline on the existing file: append still produces a sane file
t="$work/no-trailing-nl.md"
printf 'last line without newline' > "$t"
out="$(printf 'gen\n' | bash "$SCRIPT" "$t")"
if [ "$out" = "appended" ] && grep -q '^last line without newline$' "$t" && grep -qF "$BEGIN" "$t"; then
  ok "no-trailing-newline-append-sane"
else
  bad "no-trailing-newline-append-sane" "out=$out"
fi

# missing target arg → usage error
rc=0; printf 'x\n' | bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then ok "missing-arg-usage-error"; else bad "missing-arg-usage-error" "rc=$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
