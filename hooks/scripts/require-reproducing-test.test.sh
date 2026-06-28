#!/usr/bin/env bash
# Tests for hooks/scripts/require-reproducing-test.sh (troubleshoot-fix v0.5 M2).
# The inviolable bug-lane gate: a SOURCE write needs CONFIRMED + a reproducing test.
# Run: bash hooks/scripts/require-reproducing-test.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-reproducing-test.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# diagnosis.md body with the given STATUS (all four required headings present).
dbody() {
  printf 'STATUS: %s\n\n# Bug: x\n\n## Symptom + reproduction steps\na\n\n## Root-cause hypothesis\nb\n\n## Blast radius\nc\n\n## Fix strategy\nd\n' "$1"
}

# new_proj <name> → echoes a fresh project dir path with an .sdd/ tree.
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }

# check <name> <proj> <file_path> <want_rc>  (hook runs with cwd=proj)
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-34s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-34s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# AC-14: bug not CONFIRMED → source write blocked
p=$(new_proj p1); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; dbody DIAGNOSED > "$p/.sdd/b1/diagnosis.md"
check "bug-not-confirmed-blocks" "$p" "src/app.py" 2

# regression (fail-open guard): a diagnosis.md that exists but has NO STATUS line must
# still BLOCK (exit 2), not fail open (exit 1) under bash 3.2's set -e + pipefail.
p=$(new_proj p1b); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; printf '# Bug: x\n## Symptom + reproduction steps\na\n## Root-cause hypothesis\nb\n## Blast radius\nc\n## Fix strategy\nd\n' > "$p/.sdd/b1/diagnosis.md"
check "statusless-diagnosis-blocks" "$p" "src/app.py" 2

# AC-15: bug CONFIRMED but no tests/ → source write blocked
p=$(new_proj p2); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; dbody CONFIRMED > "$p/.sdd/b1/diagnosis.md"
check "confirmed-no-test-blocks" "$p" "src/app.py" 2

# AC-16: bug CONFIRMED + a reproducing test → source write allowed
p=$(new_proj p3); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1" "$p/tests"; dbody CONFIRMED > "$p/.sdd/b1/diagnosis.md"; touch "$p/tests/repro_test.py"
check "confirmed-with-test-allows" "$p" "src/app.py" 0
# …and a write UNDER tests/ is allowed in the same state
check "confirmed-write-to-tests-ok" "$p" "tests/another_test.py" 0

# AC-7 / B3: pre-CONFIRMED, a write to tests/ is allowed (the repro test must land first)
p=$(new_proj p5); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; dbody REPORTED > "$p/.sdd/b1/diagnosis.md"
check "pre-confirmed-tests-write-ok" "$p" "tests/repro_test.py" 0
# …and a write under .sdd/ is always allowed
check "write-to-sdd-ok" "$p" ".sdd/b1/diagnosis.md" 0

# AC-16 sev0: the gate is severity-independent (the hook never reads SEV)
p=$(new_proj p6); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1" "$p/tests"; dbody CONFIRMED > "$p/.sdd/b1/diagnosis.md"; touch "$p/tests/t.py"; printf 'SEV: sev0\n' > "$p/.sdd/b1/PROGRESS.md"
check "sev0-confirmed-with-test-allows" "$p" "src/app.py" 0
p=$(new_proj p6b); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1" "$p/tests"; dbody DIAGNOSED > "$p/.sdd/b1/diagnosis.md"; touch "$p/tests/t.py"; printf 'SEV: sev0\n' > "$p/.sdd/b1/PROGRESS.md"
check "sev0-not-confirmed-still-blocks" "$p" "src/app.py" 2

# additivity: forward feature (no diagnosis.md) → gate inert, source write allowed by THIS hook
p=$(new_proj p7); printf 'feat1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat1"; printf 'STATUS: DRAFT\n' > "$p/.sdd/feat1/spec.md"
check "forward-feature-inert" "$p" "src/app.py" 0

# no active item → allowed
p=$(new_proj p8); : > "$p/.sdd/ACTIVE"
check "no-active-item" "$p" "src/app.py" 0

# no file_path in payload → allowed
p=$(new_proj p9); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; dbody DIAGNOSED > "$p/.sdd/b1/diagnosis.md"
rc=0; ( cd "$p" && printf '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-34s rc=0\n' "no-file_path"; else fail=$((fail+1)); printf 'FAIL %-34s got=%s\n' "no-file_path" "$rc"; fi

# --- §3.1: path traversal must never satisfy the .sdd/ or tests/ prefix match ---
p=$(new_proj t1); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; dbody REPORTED > "$p/.sdd/b1/diagnosis.md"
check "traversal-tests-dotdot-blocked" "$p" "tests/../src/app.py" 2
check "traversal-sdd-dotdot-blocked" "$p" ".sdd/../src/app.py" 2
check "traversal-bare-dotdot-blocked" "$p" ".." 2
check "traversal-sdd-trailing-dotdot" "$p" ".sdd/.." 2

# --- §3.5: unexpected runtime error → fail CLOSED (exit 2, not 1) ---
# Fault injection: an unreadable .sdd/ACTIVE makes resolve_active's pipeline fail.
p=$(new_proj e1); printf 'b1\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/b1"; dbody REPORTED > "$p/.sdd/b1/diagnosis.md"
chmod 000 "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-34s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-34s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
