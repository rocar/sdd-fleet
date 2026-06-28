#!/usr/bin/env bash
# Tests for scripts/pin-workflow.sh — the deterministic pin keystone of Layer 2
# (generate-then-pin). Pinning a generated candidate from quarantine
# (.sdd/_generated/<name>.js) into the target project's .claude/workflows/<name>.js
# is GATED by the determinism lint (fail-closed) and validates <name> (no traversal,
# no slashes). Hermetic mktemp projects; asserts signal lines + exit codes + the
# pinned file. Run: bash scripts/pin-workflow.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/pin-workflow.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %-34s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %-34s %s\n' "$1" "${2:-}"; }

CLEAN='export const meta = { name: "x", description: "y", phases: [] };
const A = typeof args === "string" ? JSON.parse(args) : (args || {});
const now = A.now;
phase("Go");
const r = await agent("do it", { schema: { type: "object" } });
return { ok: true, now };'

BAD='export const meta = { name: "x", description: "y" };
const t = Date.now();'

# new_project [<name> <content>] -> echoes a fresh project dir, with an optional candidate
new_project() {
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/pin-test.XXXXXX")"
  mkdir -p "$d/.sdd/_generated"
  if [ -n "${1:-}" ]; then printf '%s\n' "$2" > "$d/.sdd/_generated/$1.js"; fi
  printf '%s' "$d"
}

# --- clean candidate pins ---
d="$(new_project clean-wf "$CLEAN")"
out="$(CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" clean-wf 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'SDD_FLEET_WORKFLOW_PINNED'; } \
  && ok "clean-pins" || bad "clean-pins" "rc=$rc out=$out"
[ -f "$d/.claude/workflows/clean-wf.js" ] && ok "clean-dest-exists" || bad "clean-dest-exists" "no dest"
diff -q "$d/.sdd/_generated/clean-wf.js" "$d/.claude/workflows/clean-wf.js" >/dev/null 2>&1 \
  && ok "content-matches" || bad "content-matches" "differs"
rm -rf "$d"

# --- non-deterministic candidate refused (lint gate), dest NOT created ---
d="$(new_project bad-wf "$BAD")"
out="$(CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" bad-wf 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'SDD_FLEET_WORKFLOW_PIN_REFUSED'; } \
  && ok "bad-refused" || bad "bad-refused" "rc=$rc out=$out"
[ ! -e "$d/.claude/workflows/bad-wf.js" ] && ok "bad-not-pinned" || bad "bad-not-pinned" "dest created!"
rm -rf "$d"

# --- missing candidate refused ---
d="$(new_project)"
rc=0; CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" nope >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "missing-refused" || bad "missing-refused" "rc=$rc"
rm -rf "$d"

# --- name traversal / slash / empty refused ---
d="$(new_project ok-wf "$CLEAN")"
rc=0; CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" "../etc/x" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "traversal-refused" || bad "traversal-refused" "rc=$rc"
rc=0; CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" "a/b" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "slash-refused" || bad "slash-refused" "rc=$rc"
rc=0; CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" "" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "empty-refused" || bad "empty-refused" "rc=$rc"
rm -rf "$d"

# --- creates .claude/workflows/ when absent ---
d="$(new_project mk-wf "$CLEAN")"
[ -d "$d/.claude/workflows" ] && bad "precondition" "dir already exists"
CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" mk-wf >/dev/null 2>&1
[ -d "$d/.claude/workflows" ] && ok "creates-dest-dir" || bad "creates-dest-dir" "not created"
rm -rf "$d"

# --- re-pin overwrites (re-ratify after revision) ---
d="$(new_project re-wf "$CLEAN")"
CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" re-wf >/dev/null 2>&1
printf '%s\n// revised\n' "$CLEAN" > "$d/.sdd/_generated/re-wf.js"
rc=0; CLAUDE_PROJECT_DIR="$d" bash "$SCRIPT" re-wf >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 0 ] && grep -qF '// revised' "$d/.claude/workflows/re-wf.js"; } \
  && ok "re-pin-overwrites" || bad "re-pin-overwrites" "rc=$rc"
rm -rf "$d"

# --- robust to RELATIVE invocation: DIR must resolve before the cd to the project ---
d="$(new_project rel-wf "$CLEAN")"
ROOT="$(cd "$DIR/.." && pwd)"
rc=0; out="$( cd "$ROOT" && CLAUDE_PROJECT_DIR="$d" bash scripts/pin-workflow.sh rel-wf 2>/dev/null )" || rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$d/.claude/workflows/rel-wf.js" ]; } \
  && ok "relative-invocation" || bad "relative-invocation" "rc=$rc out=$out"
rm -rf "$d"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
