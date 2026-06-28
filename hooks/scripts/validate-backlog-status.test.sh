#!/usr/bin/env bash
# Tests for hooks/scripts/validate-backlog-status.sh (audit §3.8).
# PostToolUse gate: a write to .sdd/_product/backlog.md must leave the
# structure the product PLAN machine parses intact — PRODUCT: header, a valid
# STATUS line within the first 10 lines, and at least one '## Phase <N>:'
# heading. Feeds the PostToolUse JSON payload on stdin with CLAUDE_PROJECT_DIR
# anchoring the fixture repo.
# Run: bash hooks/scripts/validate-backlog-status.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/validate-backlog-status.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# A structurally valid backlog body for the given STATUS token.
body() {
  printf 'PRODUCT: demo-product\nSTATUS: %s\n\n# Backlog\n\n## Phase 1: foundations — STATUS: PENDING\n- [ ] B-1 first item\n' "$1"
}
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd/_product"; printf '%s' "$p"; }
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}
check_err() {
  local name="$1" proj="$2" fp="$3" want="$4" needle="$5" rc=0 err=""
  err=$( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
  if [ "$rc" -eq "$want" ] && printf '%s' "$err" | grep -qi "$needle"; then
    pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else
    fail=$((fail+1)); printf 'FAIL %-40s want=%s+/%s/ got=%s (%s)\n' "$name" "$want" "$needle" "$rc" "$err"
  fi
}

# --- all four valid STATUS tokens accepted on a well-formed backlog ---
p=$(new_proj v1)
for tok in DRAFT IN_REVIEW FINALIZED BLOCKED; do
  body "$tok" > "$p/.sdd/_product/backlog.md"
  check "valid-$tok" "$p" ".sdd/_product/backlog.md" 0
done

# --- missing PRODUCT: header → block ---
p=$(new_proj h1)
body DRAFT | grep -v '^PRODUCT:' > "$p/.sdd/_product/backlog.md"
check_err "missing-product-header" "$p" ".sdd/_product/backlog.md" 2 "PRODUCT"

# --- missing STATUS line → block ---
p=$(new_proj h2)
body DRAFT | grep -v '^STATUS:' > "$p/.sdd/_product/backlog.md"
check_err "missing-status-line" "$p" ".sdd/_product/backlog.md" 2 "missing STATUS line"

# --- STATUS beyond the first 10 lines → treated as missing → block ---
p=$(new_proj h3)
{ printf 'PRODUCT: demo-product\n'; for i in $(seq 1 10); do printf '# filler %s\n' "$i"; done; printf 'STATUS: DRAFT\n\n## Phase 1: x\n'; } > "$p/.sdd/_product/backlog.md"
check "status-beyond-line-10-blocks" "$p" ".sdd/_product/backlog.md" 2

# --- invalid STATUS value → block ---
p=$(new_proj h4)
body SHIPPED > "$p/.sdd/_product/backlog.md"
check_err "invalid-status-value" "$p" ".sdd/_product/backlog.md" 2 "invalid"

# --- no '## Phase <N>:' heading → block ---
p=$(new_proj h5)
printf 'PRODUCT: demo-product\nSTATUS: DRAFT\n\n# Backlog\n- [ ] B-1 orphan row\n' > "$p/.sdd/_product/backlog.md"
check_err "missing-phase-heading" "$p" ".sdd/_product/backlog.md" 2 "phase heading"

# --- a half-edited ROW does not block (structural gate, not row grammar) ---
p=$(new_proj r1)
{ body DRAFT; printf '%s\n' '- [ B-2 mangled row missing bracket'; } > "$p/.sdd/_product/backlog.md"
check "mangled-row-still-allowed" "$p" ".sdd/_product/backlog.md" 0

# --- scoping: only .sdd/_product/backlog.md is ours ---
p=$(new_proj s1); mkdir -p "$p/docs"
printf 'random\n' > "$p/docs/backlog.md"
check "backlog-outside-product-ignored" "$p" "docs/backlog.md" 0
p=$(new_proj s2)
printf 'random\n' > "$p/.sdd/_product/notes.md"
check "non-backlog-file-ignored" "$p" ".sdd/_product/notes.md" 0
p=$(new_proj s3)   # path matches but file absent → cannot validate
check "absent-backlog-file-allows" "$p" ".sdd/_product/backlog.md" 0

# --- malformed input: no file_path → allow ---
p=$(new_proj j0)
rc=0; ( cd "$p" && printf '{"tool_input":{}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=0\n' "no-file_path-allows"
else fail=$((fail+1)); printf 'FAIL %-40s want=0 got=%s\n' "no-file_path-allows" "$rc"; fi

# --- T3 hardening: malformed JSON → ERR trap → fail CLOSED (exit 2) ---
p=$(new_proj j1)
rc=0; ( cd "$p" && printf 'not json' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "malformed-json-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "malformed-json-fails-closed" "$rc"; fi

# --- T3 hardening: drifted cwd — CLAUDE_PROJECT_DIR anchors the relative path ---
p=$(new_proj c1); mkdir -p "$p/sub"
body SHIPPED > "$p/.sdd/_product/backlog.md"
rc=0; ( cd "$p/sub" && printf '{"tool_input":{"file_path":".sdd/_product/backlog.md"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "drifted-cwd-still-validates"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "drifted-cwd-still-validates" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
