#!/usr/bin/env bash
# Tests for hooks/scripts/block-source-before-finalized.sh.
# Locks in the forward FINALIZED gate (AC-17 — byte-identical pre-/post-M2) AND the
# v0.5 M2 bug-lane second unlock (AC-18).
# Run: bash hooks/scripts/block-source-before-finalized.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/block-source-before-finalized.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

dbody() {
  printf 'STATUS: %s\n\n# Bug: x\n\n## Symptom + reproduction steps\na\n\n## Root-cause hypothesis\nb\n\n## Blast radius\nc\n\n## Fix strategy\nd\n' "$1"
}
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-36s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-36s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# check_json <name> <proj> <raw_json_payload> <want_rc>
check_json() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-36s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-36s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# --- forward feature (AC-17): byte-identical to pre-M2 behavior ---
p=$(new_proj f1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
check "feature-draft-blocks-source" "$p" "src/app.py" 2
p=$(new_proj f2); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"
check "feature-finalized-allows-source" "$p" "src/app.py" 0
check "feature-sdd-write-always-ok" "$p" ".sdd/feat/spec.md" 0
p=$(new_proj f3); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"   # spec.md absent → no STATUS
check "feature-missing-spec-blocks" "$p" "src/app.py" 2
p=$(new_proj f4); : > "$p/.sdd/ACTIVE"
check "no-active-allows-source" "$p" "src/app.py" 0

# --- bug lane (AC-18): the second unlock ---
p=$(new_proj b1); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"; dbody CONFIRMED > "$p/.sdd/bug/diagnosis.md"
check "bug-confirmed-unlocks-source" "$p" "src/app.py" 0
p=$(new_proj b2); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"; dbody DIAGNOSED > "$p/.sdd/bug/diagnosis.md"
check "bug-not-confirmed-blocks-source" "$p" "src/app.py" 2
p=$(new_proj b3); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"; dbody REPORTED > "$p/.sdd/bug/diagnosis.md"
check "bug-reported-blocks-source" "$p" "src/app.py" 2
check "bug-sdd-write-always-ok" "$p" ".sdd/bug/diagnosis.md" 0
# AC-7: a bug's tests/ write is allowed BEFORE CONFIRMED (the reproducing test lands at
# REPRODUCE; blocking it would deadlock the lane against require-reproducing-test).
check "bug-tests-write-allowed-pre-confirmed" "$p" "tests/test_x.py" 0

# --- regression (fail-open guard): a status-less diagnosis.md / spec.md must BLOCK ---
# (exit 2), not fail open (exit 1) under bash 3.2's set -e + pipefail.
p=$(new_proj b4); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"; printf '# Bug: no status line\n## Symptom + reproduction steps\na\n## Root-cause hypothesis\nb\n## Blast radius\nc\n## Fix strategy\nd\n' > "$p/.sdd/bug/diagnosis.md"
check "bug-statusless-diagnosis-blocks" "$p" "src/app.py" 2
p=$(new_proj f5); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf '# spec without status\n' > "$p/.sdd/feat/spec.md"
check "feature-statusless-spec-blocks" "$p" "src/app.py" 2

# --- §3.1: path traversal must never satisfy the .sdd/ or tests/ prefix match ---
p=$(new_proj t1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
check "traversal-sdd-dotdot-blocked" "$p" ".sdd/../src/app.py" 2
check "traversal-bare-dotdot-blocked" "$p" ".." 2
check "traversal-sdd-trailing-dotdot" "$p" ".sdd/.." 2
p=$(new_proj t2); printf 'bug\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/bug"; dbody REPORTED > "$p/.sdd/bug/diagnosis.md"
check "traversal-tests-dotdot-blocked" "$p" "tests/../src/app.py" 2

# --- §3.5 / NotebookEdit: notebook_path goes through the same gate ---
p=$(new_proj n1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
check_json "notebook-to-src-blocked" "$p" '{"tool_input":{"notebook_path":"src/analysis.ipynb"}}' 2
check_json "notebook-to-sdd-allowed" "$p" '{"tool_input":{"notebook_path":".sdd/feat/scratch.ipynb"}}' 0

# --- §3.3: drifted cwd — CLAUDE_PROJECT_DIR anchors .sdd/ resolution ---
p=$(new_proj c1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat" "$p/sub"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
rc=0; ( cd "$p/sub" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-36s rc=2\n' "drifted-cwd-still-blocks"
else fail=$((fail+1)); printf 'FAIL %-36s want=2 got=%s\n' "drifted-cwd-still-blocks" "$rc"; fi

# --- §3.4: jq missing + active feature → fail CLOSED (exit 2, install message) ---
stub="$work/stubbin"; mkdir -p "$stub"
for b in dirname basename head tail tr cat grep sed find date stat; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$stub/$b"
done
p=$(new_proj j1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-36s rc=2\n' "no-jq-active-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-36s want=2+msg got=%s (%s)\n' "no-jq-active-fails-closed" "$rc" "$err"; fi
# ...but with NO active feature, missing jq stays exit 0 (bootstrap-friendly)
p=$(new_proj j2); : > "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-36s rc=0\n' "no-jq-no-active-allows"
else fail=$((fail+1)); printf 'FAIL %-36s want=0 got=%s\n' "no-jq-no-active-allows" "$rc"; fi

# --- §3.5: unexpected runtime error → fail CLOSED (exit 2, not 1) ---
# Fault injection: an unreadable .sdd/ACTIVE makes resolve_active's pipeline fail.
p=$(new_proj e1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
chmod 000 "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-36s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-36s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
