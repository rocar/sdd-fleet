#!/usr/bin/env bash
# Tests for hooks/scripts/guard-bash-writes.sh (audit §3.2 — the Bash escape hatch).
# While the active lane is source-locked, Bash commands matching write-to-source
# patterns are blocked; read-only commands and writes into .sdd//tests/ are not.
# Run: bash hooks/scripts/guard-bash-writes.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/guard-bash-writes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

dbody() {
  printf 'STATUS: %s\n\n# Bug: x\n\n## Symptom + reproduction steps\na\n\n## Root-cause hypothesis\nb\n\n## Blast radius\nc\n\n## Fix strategy\nd\n' "$1"
}
new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }

# check <name> <proj> <bash_command> <want_rc>  — payload mirrors the real
# PreToolUse(Bash) contract: {"tool_input":{"command":"..."}}.
check() {
  local name="$1" proj="$2" cmd="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# Locked fixture: forward feature, spec DRAFT.
L=$(new_proj locked); printf 'feat\n' > "$L/.sdd/ACTIVE"; mkdir -p "$L/.sdd/feat"; printf 'STATUS: DRAFT\n' > "$L/.sdd/feat/spec.md"

# --- write-to-source patterns blocked while locked ---
check "heredoc-to-src-blocked" "$L" 'cat > src/app.py <<EOF
print("hi")
EOF' 2
check "redirect-to-src-blocked" "$L" 'echo hi > src/app.py' 2
check "append-to-src-blocked" "$L" 'echo hi >> src/app.py' 2
check "quoted-redirect-target-blocked" "$L" 'cat > "src/app.py"' 2
check "tee-to-src-blocked" "$L" 'echo hi | tee src/app.py' 2
check "tee-append-to-src-blocked" "$L" 'echo hi | tee -a src/app.py' 2
check "sed-inplace-blocked" "$L" "sed -i '' 's/a/b/' src/app.py" 2
check "patch-blocked" "$L" 'patch -p1 < fix.patch' 2
check "cp-to-src-blocked" "$L" 'cp /tmp/x.py src/app.py' 2
check "mv-to-src-blocked" "$L" 'mv /tmp/x.py src/app.py' 2
check "install-to-src-blocked" "$L" 'install -m 755 /tmp/x src/x' 2
check "chained-write-blocked" "$L" 'make lint && echo done > src/out.txt' 2

# --- read-only / safe-target commands allowed while locked ---
check "ls-allowed" "$L" 'ls -la src/' 0
check "grep-allowed" "$L" 'grep -rn "foo" src/' 0
check "grep-gt-pattern-not-false-blocked" "$L" 'grep ">" notes.txt' 0
check "stderr-redirect-allowed" "$L" 'ls src 2>/dev/null' 0
check "fd-dup-allowed" "$L" 'echo warn >&2' 0
check "redirect-to-devnull-allowed" "$L" 'noisy_cmd > /dev/null 2>&1' 0
check "redirect-to-tmp-allowed" "$L" 'git diff > /tmp/diff.txt' 0
check "redirect-into-sdd-allowed" "$L" 'echo note >> .sdd/feat/IMPL_NOTES.md' 0
check "tee-into-sdd-allowed" "$L" 'echo note | tee .sdd/feat/notes.md' 0
check "cp-into-sdd-allowed" "$L" 'cp notes.md .sdd/feat/notes.md' 0
check "git-status-allowed" "$L" 'git status' 0
check "sed-readonly-allowed" "$L" "sed -n '1,10p' src/app.py" 0
# traversal inside an otherwise-safe target prefix is NOT safe
check "redirect-sdd-traversal-blocked" "$L" 'echo hi > .sdd/../src/app.py' 2

# --- unlocked: feature FINALIZED → guard inert ---
U=$(new_proj unlocked); printf 'feat\n' > "$U/.sdd/ACTIVE"; mkdir -p "$U/.sdd/feat"; printf 'STATUS: FINALIZED\n' > "$U/.sdd/feat/spec.md"
check "finalized-redirect-to-src-allowed" "$U" 'echo hi > src/app.py' 0
check "finalized-sed-inplace-allowed" "$U" "sed -i '' 's/a/b/' src/app.py" 0

# --- bug lane: locked until CONFIRMED + reproducing test (mirrors the gate pair) ---
B=$(new_proj bug1); printf 'bug\n' > "$B/.sdd/ACTIVE"; mkdir -p "$B/.sdd/bug"; dbody REPORTED > "$B/.sdd/bug/diagnosis.md"
check "bug-reported-redirect-src-blocked" "$B" 'echo fix > src/app.py' 2
check "bug-reported-redirect-tests-allowed" "$B" 'echo test > tests/test_repro.py' 0
B2=$(new_proj bug2); printf 'bug\n' > "$B2/.sdd/ACTIVE"; mkdir -p "$B2/.sdd/bug" "$B2/tests"; dbody CONFIRMED > "$B2/.sdd/bug/diagnosis.md"; touch "$B2/tests/repro_test.py"
check "bug-confirmed-with-test-src-allowed" "$B2" 'echo fix > src/app.py' 0
B3=$(new_proj bug3); printf 'bug\n' > "$B3/.sdd/ACTIVE"; mkdir -p "$B3/.sdd/bug"; dbody CONFIRMED > "$B3/.sdd/bug/diagnosis.md"
check "bug-confirmed-no-test-src-blocked" "$B3" 'echo fix > src/app.py' 2

# --- no active item / empty command → allow ---
N=$(new_proj none); : > "$N/.sdd/ACTIVE"
check "no-active-allowed" "$N" 'echo hi > src/app.py' 0
rc=0; ( cd "$L" && printf '{"tool_input":{}}' | CLAUDE_PROJECT_DIR="$L" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=0\n' "no-command-payload-allowed"
else fail=$((fail+1)); printf 'FAIL %-40s want=0 got=%s\n' "no-command-payload-allowed" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
