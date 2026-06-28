#!/usr/bin/env bash
# Tests for hooks/scripts/validate-spec-status.sh (audit §3.8 — the priority
# uncovered gate). Feeds a PostToolUse JSON payload on stdin with
# CLAUDE_PROJECT_DIR anchoring the fixture repo, and asserts exit code (and
# stderr where the message is load-bearing).
# Run: bash hooks/scripts/validate-spec-status.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/validate-spec-status.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# A spec.md body with the given STATUS token and all 8 required headings.
body() {
  printf 'STATUS: %s\n\n# Spec: example\n\n## Overview\na\n\n## Goals\nb\n\n## Non-goals\nc\n\n## Behavior\nd\n\n## Interfaces / Contracts\ne\n\n## Constraints\nf\n\n## Risks\ng\n\n## Acceptance Criteria\nh\n' "$1"
}
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd/feat"; printf '%s' "$p"; }

# check <name> <proj> <file_path> <want_rc>
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-38s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-38s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}
# check_err <name> <proj> <file_path> <want_rc> <stderr_substring>
check_err() {
  local name="$1" proj="$2" fp="$3" want="$4" needle="$5" rc=0 err=""
  err=$( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
  if [ "$rc" -eq "$want" ] && printf '%s' "$err" | grep -qi "$needle"; then
    pass=$((pass+1)); printf 'ok   %-38s rc=%s\n' "$name" "$rc"
  else
    fail=$((fail+1)); printf 'FAIL %-38s want=%s+/%s/ got=%s (%s)\n' "$name" "$want" "$needle" "$rc" "$err"
  fi
}

# --- all four valid STATUS tokens accepted ---
p=$(new_proj v1)
for tok in DRAFT IN_REVIEW FINALIZED BLOCKED; do
  body "$tok" > "$p/.sdd/feat/spec.md"
  check "valid-$tok" "$p" ".sdd/feat/spec.md" 0
done

# --- missing STATUS line → block, message names the contract ---
p=$(new_proj m1)
body DRAFT | grep -v '^STATUS:' > "$p/.sdd/feat/spec.md"
check_err "missing-status-line" "$p" ".sdd/feat/spec.md" 2 "missing STATUS line"

# --- STATUS beyond the first 30 lines → treated as missing → block ---
p=$(new_proj m2)
{ for i in $(seq 1 30); do printf '# filler %s\n' "$i"; done; body DRAFT; } > "$p/.sdd/feat/spec.md"
check "status-beyond-line-30-blocks" "$p" ".sdd/feat/spec.md" 2
# ...but a STATUS line *within* the first 30 lines (line 30) is found
p=$(new_proj m3)
{ for i in $(seq 1 29); do printf '# filler %s\n' "$i"; done; body DRAFT; } > "$p/.sdd/feat/spec.md"
check "status-on-line-30-allows" "$p" ".sdd/feat/spec.md" 0

# --- invalid STATUS value → block, message names the offender ---
p=$(new_proj i1)
body SHIPPED > "$p/.sdd/feat/spec.md"
check_err "invalid-status-value" "$p" ".sdd/feat/spec.md" 2 "invalid"
# a bug-lane token is not a spec token
p=$(new_proj i2)
body CONFIRMED > "$p/.sdd/feat/spec.md"
check "bug-token-rejected-on-spec" "$p" ".sdd/feat/spec.md" 2

# --- missing required section heading → block ---
p=$(new_proj s1)
body DRAFT | grep -v '^## Risks' > "$p/.sdd/feat/spec.md"
check_err "missing-required-section" "$p" ".sdd/feat/spec.md" 2 "required section"

# --- scoping: non-spec files and out-of-tree specs are ignored ---
p=$(new_proj n1)
body BOGUS > "$p/.sdd/feat/notes.md"
check "non-spec-file-ignored" "$p" ".sdd/feat/notes.md" 0
p=$(new_proj n2)
mkdir -p "$p/docs"; body BOGUS > "$p/docs/spec.md"
check "spec-outside-sdd-ignored" "$p" "docs/spec.md" 0
p=$(new_proj n3)   # path under .sdd/ but the file is absent → cannot validate
check "absent-spec-file-allows" "$p" ".sdd/feat/spec.md" 0

# --- malformed input: no file_path (e.g. Bash tool payload) → allow ---
p=$(new_proj j0)
rc=0; ( cd "$p" && printf '{"tool_input":{}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-38s rc=0\n' "no-file_path-allows"
else fail=$((fail+1)); printf 'FAIL %-38s want=0 got=%s\n' "no-file_path-allows" "$rc"; fi

# --- T3 hardening: malformed JSON on stdin → ERR trap → fail CLOSED (exit 2) ---
p=$(new_proj j1)
rc=0; ( cd "$p" && printf 'not json at all' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-38s rc=2\n' "malformed-json-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-38s want=2 got=%s\n' "malformed-json-fails-closed" "$rc"; fi

# --- T3 hardening: jq missing + active feature → fail CLOSED (require_jq) ---
stub="$work/stubbin"; mkdir -p "$stub"
for b in dirname basename head tail tr cat grep sed find date stat; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$stub/$b"
done
p=$(new_proj q1); printf 'feat\n' > "$p/.sdd/ACTIVE"; body DRAFT > "$p/.sdd/feat/spec.md"
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":".sdd/feat/spec.md"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-38s rc=2\n' "no-jq-active-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-38s want=2+msg got=%s (%s)\n' "no-jq-active-fails-closed" "$rc" "$err"; fi

# --- T3 hardening: drifted cwd — CLAUDE_PROJECT_DIR anchors relative file_path ---
p=$(new_proj c1); mkdir -p "$p/sub"; body SHIPPED > "$p/.sdd/feat/spec.md"
rc=0; ( cd "$p/sub" && printf '{"tool_input":{"file_path":".sdd/feat/spec.md"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-38s rc=2\n' "drifted-cwd-still-validates"
else fail=$((fail+1)); printf 'FAIL %-38s want=2 got=%s\n' "drifted-cwd-still-validates" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
