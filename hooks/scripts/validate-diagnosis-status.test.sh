#!/usr/bin/env bash
# Tests for hooks/scripts/validate-diagnosis-status.sh (troubleshoot-fix v0.5 M0).
# Feeds a PostToolUse JSON payload on stdin and asserts the hook's exit code.
# Run: bash hooks/scripts/validate-diagnosis-status.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/validate-diagnosis-status.sh"
SPEC_HOOK="$DIR/validate-spec-status.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# A valid diagnosis.md body for the given STATUS token (all four required headings).
body() {
  printf 'STATUS: %s\n\n# Bug: example\n\n## Symptom + reproduction steps\nx\n\n## Root-cause hypothesis\ny\n\n## Blast radius\nz\n\n## Fix strategy\nw\n' "$1"
}

# check <name> <hook> <file_path> <want_rc>   (file must already exist or not, per case)
check() {
  local name="$1" hook="$2" fp="$3" want="$4" rc=0
  printf '{"tool_input":{"file_path":"%s"}}' "$fp" | bash "$hook" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass+1)); printf 'ok   %-30s rc=%s\n' "$name" "$rc"
  else
    fail=$((fail+1)); printf 'FAIL %-30s want_rc=%s got_rc=%s\n' "$name" "$want" "$rc"
  fi
}

SDD="$work/.sdd"
mkdir -p "$SDD/bug-ok" "$SDD/bug-nostatus" "$SDD/bug-badstatus" "$SDD/bug-missingsection" "$SDD/feat-x"

# all five STATUS tokens accepted (exit 0)
for tok in REPORTED REPRODUCING DIAGNOSED CONFIRMED FIXED; do
  body "$tok" > "$SDD/bug-ok/diagnosis.md"
  check "valid-$tok" "$HOOK" "$SDD/bug-ok/diagnosis.md" 0
done

# missing STATUS line → exit 2
printf '# Bug: x\n\n## Symptom + reproduction steps\na\n## Root-cause hypothesis\nb\n## Blast radius\nc\n## Fix strategy\nd\n' > "$SDD/bug-nostatus/diagnosis.md"
check "missing-status" "$HOOK" "$SDD/bug-nostatus/diagnosis.md" 2

# invalid STATUS token (FINALIZED is a spec token, not a bug token) → exit 2
body FINALIZED > "$SDD/bug-badstatus/diagnosis.md"
check "invalid-status-token" "$HOOK" "$SDD/bug-badstatus/diagnosis.md" 2

# missing a required heading (drop Fix strategy) → exit 2
printf 'STATUS: DIAGNOSED\n\n# Bug: x\n\n## Symptom + reproduction steps\na\n\n## Root-cause hypothesis\nb\n\n## Blast radius\nc\n' > "$SDD/bug-missingsection/diagnosis.md"
check "missing-required-heading" "$HOOK" "$SDD/bug-missingsection/diagnosis.md" 2

# AC-10 forward: this hook ignores a spec.md (basename keying) → exit 0
printf 'STATUS: DRAFT\n# whatever\n' > "$SDD/feat-x/spec.md"
check "diag-hook-ignores-spec.md" "$HOOK" "$SDD/feat-x/spec.md" 0

# AC-10 reverse: validate-spec-status ignores a diagnosis.md → exit 0 (no cross-fire)
body REPORTED > "$SDD/bug-ok/diagnosis.md"
check "spec-hook-ignores-diagnosis.md" "$SPEC_HOOK" "$SDD/bug-ok/diagnosis.md" 0

# diagnosis.md OUTSIDE .sdd/ → not ours → exit 0
body REPORTED > "$work/diagnosis.md"
check "diagnosis-outside-sdd" "$HOOK" "$work/diagnosis.md" 0

# path ends in diagnosis.md under .sdd/ but the file is absent → cannot validate → exit 0
check "absent-diagnosis-file" "$HOOK" "$SDD/bug-absent/diagnosis.md" 0

# no file_path in the payload (e.g. a Bash tool call) → exit 0
rc=0; printf '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-30s rc=0\n' "no-file_path"; else fail=$((fail+1)); printf 'FAIL %-30s got_rc=%s\n' "no-file_path" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
