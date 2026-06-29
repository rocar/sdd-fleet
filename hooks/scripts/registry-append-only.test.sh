#!/usr/bin/env bash
# Tests for hooks/scripts/registry-append-only.sh.
# A published contract version (registry/<contract>/<semver>.json) is IMMUTABLE: once it
# exists, no Write/Edit may overwrite it (forward-only recovery — bump the version). A NEW
# version file is allowed; expectations and non-registry writes are inert (audit G1).
# Run: bash hooks/scripts/registry-append-only.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/registry-append-only.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

new_proj() { local p="$work/$1"; mkdir -p "$p"; printf '%s' "$p"; }
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}
check_json() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-44s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-44s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# --- an existing published version is immutable ---
p=$(new_proj a1); mkdir -p "$p/registry/pay.authorise"; printf '{}' > "$p/registry/pay.authorise/3.3.0.json"
check "overwrite-published-version-blocks" "$p" "registry/pay.authorise/3.3.0.json" 2
check_json "edit-published-version-blocks"  "$p" '{"tool_input":{"file_path":"registry/pay.authorise/3.3.0.json","old_string":"{}","new_string":"{\"x\":1}"}}' 2

# --- a NEW version is allowed (append-only: publish forward) ---
check "new-version-allows" "$p" "registry/pay.authorise/3.4.0.json" 0

# --- expectations are not a version publish → inert even if they exist ---
mkdir -p "$p/registry/pay.authorise/expectations"; printf '{}' > "$p/registry/pay.authorise/expectations/checkout.json"
check "expectations-write-inert" "$p" "registry/pay.authorise/expectations/checkout.json" 0

# --- non-registry writes are inert ---
p=$(new_proj b1); mkdir -p "$p/registry/x"; printf '{}' > "$p/registry/x/1.0.0.json"
check "non-registry-write-inert" "$p" "src/app.py" 0
check "sdd-write-inert"          "$p" ".sdd/feat/spec.md" 0

# --- a new contract's first version (dir absent) is allowed ---
check "first-version-of-new-contract-allows" "$p" "registry/brand.new/1.0.0.json" 0

# --- traversal / no path ---
check "traversal-blocks"  "$p" "registry/x/../../escape.json" 2
check_json "no-path-inert" "$p" '{"tool_input":{}}' 0

# --- absolute path to an existing version blocks too ---
p=$(new_proj c1); mkdir -p "$p/registry/led.post"; printf '{}' > "$p/registry/led.post/2.0.0.json"
check "absolute-existing-version-blocks" "$p" "$p/registry/led.post/2.0.0.json" 2

# --- jq missing → fail CLOSED ---
stub="$work/stub"; mkdir -p "$stub"
for b in bash basename dirname cat grep sed tr head pwd; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stub/$b"; done
p=$(new_proj j1); mkdir -p "$p/registry/x"; printf '{}' > "$p/registry/x/1.0.0.json"
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":"registry/x/1.0.0.json"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "jq"; then pass=$((pass+1)); printf 'ok   %-44s rc=2\n' "no-jq-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-44s want=2+jq got=%s (%s)\n' "no-jq-fails-closed" "$rc" "$err"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
