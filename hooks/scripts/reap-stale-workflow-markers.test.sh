#!/usr/bin/env bash
# Tests for hooks/scripts/reap-stale-workflow-markers.sh (audit §3.8).
# Stop hook: removes .sdd/<slug>/.workflow-in-flight markers older than the
# staleness threshold (900s); fresh markers and anything outside the
# .sdd/<slug>/ layer are left alone. The hook operates from cwd, so each case
# runs inside its own mktemp fixture repo.
# Run: bash hooks/scripts/reap-stale-workflow-markers.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/reap-stale-workflow-markers.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

ok()  { pass=$((pass+1)); printf 'ok   %-42s %s\n' "$1" "$2"; }
bad() { fail=$((fail+1)); printf 'FAIL %-42s %s\n' "$1" "$2"; }

new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }
# make_stale <file>: push mtime well past the 900s threshold (bash-3.2/BSD-safe)
make_stale() { touch -t 202601010000 "$1"; }
# run_hook <proj>: invoke from the fixture, like a real Stop hook firing there
run_hook() { ( cd "$1" && printf '{}' | bash "$HOOK" >/dev/null 2>&1 ); }

# --- fresh LIVE marker (non-empty: carries the run id) is kept ---
p=$(new_proj fresh); mkdir -p "$p/.sdd/feat"; printf 'review-feat-c1' > "$p/.sdd/feat/.workflow-in-flight"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$p/.sdd/feat/.workflow-in-flight" ]; then ok "fresh-marker-kept" "rc=$rc"
else bad "fresh-marker-kept" "rc=$rc marker_exists=$([ -f "$p/.sdd/feat/.workflow-in-flight" ] && echo y || echo n)"; fi

# --- stale LIVE marker (past the 900s threshold) is reaped, with a stderr notice ---
p=$(new_proj stale); mkdir -p "$p/.sdd/feat"; printf 'review-feat-c1' > "$p/.sdd/feat/.workflow-in-flight"
make_stale "$p/.sdd/feat/.workflow-in-flight"
err=$( cd "$p" && printf '{}' | bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$p/.sdd/feat/.workflow-in-flight" ] && printf '%s' "$err" | grep -q "reaping stale workflow marker.*'feat'"; then
  ok "stale-marker-reaped" "rc=$rc"
else bad "stale-marker-reaped" "rc=$rc err=$err"; fi

# --- RELEASED marker (empty — the scribe emptied it at envelope-apply time) is
#     reaped immediately, fresh or not, with the released notice ---
p=$(new_proj released); mkdir -p "$p/.sdd/feat"; : > "$p/.sdd/feat/.workflow-in-flight"
err=$( cd "$p" && printf '{}' | bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$p/.sdd/feat/.workflow-in-flight" ] && printf '%s' "$err" | grep -q "released (empty) workflow marker.*'feat'"; then
  ok "released-empty-marker-reaped-immediately" "rc=$rc"
else bad "released-empty-marker-reaped-immediately" "rc=$rc err=$err"; fi

# --- mixed: only the stale one of two live markers is removed ---
p=$(new_proj mixed); mkdir -p "$p/.sdd/old" "$p/.sdd/new"
printf 'old-run' > "$p/.sdd/old/.workflow-in-flight"; printf 'new-run' > "$p/.sdd/new/.workflow-in-flight"
make_stale "$p/.sdd/old/.workflow-in-flight"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$p/.sdd/old/.workflow-in-flight" ] && [ -f "$p/.sdd/new/.workflow-in-flight" ]; then
  ok "mixed-only-stale-reaped" "rc=$rc"
else bad "mixed-only-stale-reaped" "rc=$rc"; fi

# --- no marker anywhere → clean no-op ---
p=$(new_proj nomarker); mkdir -p "$p/.sdd/feat"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ]; then ok "no-marker-noop" "rc=$rc"; else bad "no-marker-noop" "rc=$rc"; fi

# --- no .sdd/ at all (non-sdd-fleet repo) → clean no-op ---
p="$work/nosdd"; mkdir -p "$p"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ]; then ok "no-sdd-dir-noop" "rc=$rc"; else bad "no-sdd-dir-noop" "rc=$rc"; fi

# --- depth scoping: markers outside the .sdd/<slug>/ layer are never touched ---
p=$(new_proj depth); mkdir -p "$p/.sdd/feat/nested"
printf 'x' > "$p/.sdd/.workflow-in-flight"; printf 'x' > "$p/.sdd/feat/nested/.workflow-in-flight"
make_stale "$p/.sdd/.workflow-in-flight"; make_stale "$p/.sdd/feat/nested/.workflow-in-flight"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$p/.sdd/.workflow-in-flight" ] && [ -f "$p/.sdd/feat/nested/.workflow-in-flight" ]; then
  ok "out-of-layer-markers-untouched" "rc=$rc"
else bad "out-of-layer-markers-untouched" "rc=$rc"; fi

# --- malformed marker: a DIRECTORY named .workflow-in-flight is not reaped ---
p=$(new_proj dirmarker); mkdir -p "$p/.sdd/feat/.workflow-in-flight"
make_stale "$p/.sdd/feat/.workflow-in-flight"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ] && [ -d "$p/.sdd/feat/.workflow-in-flight" ]; then
  ok "directory-marker-not-reaped" "rc=$rc"
else bad "directory-marker-not-reaped" "rc=$rc"; fi

# --- slug with a space: the while-read loop still reaps it ---
p=$(new_proj space); mkdir -p "$p/.sdd/my feat"; printf 'x' > "$p/.sdd/my feat/.workflow-in-flight"
make_stale "$p/.sdd/my feat/.workflow-in-flight"
run_hook "$p"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$p/.sdd/my feat/.workflow-in-flight" ]; then
  ok "slug-with-space-reaped" "rc=$rc"
else bad "slug-with-space-reaped" "rc=$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
