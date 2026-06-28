#!/usr/bin/env bash
# Tests for scripts/epic-ratify-record.sh.
# Writes .sdd/_epic/<slug>/RATIFICATION.md (the human ratification record + a digest of
# plan.md+contracts.md). Deterministic: --now injected, no clock. Refuses if already
# ratified, no epic dir, or the plan/contracts are missing.
# Run: bash scripts/epic-ratify-record.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/epic-ratify-record.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
NOW="2026-06-27T12:00:00Z"

pass=0; fail=0
out=""; rc=0
run() { local p="$1"; shift; out=$( cd "$p" && bash "$SCRIPT" "$@" 2>"$work/.err" ); rc=$?; }
ok() { pass=$((pass+1)); printf 'ok   %-40s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %-40s :: %s\n' "$1" "$2"; }
expect() { # expect <name> <want_rc> <stdout-substr>
  local n="$1" wrc="$2" sub="$3"
  if [ "$rc" -eq "$wrc" ] && printf '%s' "$out" | grep -qF "$sub"; then ok "$n"
  else no "$n" "want rc=$wrc/$sub got rc=$rc out=$out"; fi
}

# mkepic <name> [no-plan|no-contracts] -> echoes the workspace root
mkepic() {
  local p e; p="$work/$1"; e="$p/.sdd/_epic/ep"; mkdir -p "$e"
  [ "${2:-}" = no-plan ] || printf 'EPIC: ep\n\n## Stories\n- id: s1\n  repo: member-a\n  consumes: []\n' > "$e/plan.md"
  [ "${2:-}" = no-contracts ] || printf 'EPIC: ep\n\n## Contracts\n### thing\n- kind: openapi\n' > "$e/contracts.md"
  printf '%s' "$p"
}

# --- happy path: records RATIFICATION.md with a digest ---
p=$(mkepic happy)
run "$p" ep --now "$NOW"
expect "records-ok" 0 '"status":"recorded"'
[ -f "$p/.sdd/_epic/ep/RATIFICATION.md" ] && grep -q "^RATIFIED: $NOW" "$p/.sdd/_epic/ep/RATIFICATION.md" \
  && grep -Eq "^PLAN_DIGEST: .+" "$p/.sdd/_epic/ep/RATIFICATION.md" \
  && ok "ratification-file-written" || no "ratification-file-written" "missing file/RATIFIED/PLAN_DIGEST"

# --- already ratified: refuse, do NOT overwrite ---
run "$p" ep --now "2099-01-01T00:00:00Z"
expect "already-ratified-refused" 1 '"status":"already-ratified"'
grep -q "^RATIFIED: $NOW" "$p/.sdd/_epic/ep/RATIFICATION.md" && ok "already-ratified-not-clobbered" \
  || no "already-ratified-not-clobbered" "the original record was overwritten"

# --- no epic dir ---
p=$(printf '%s' "$work/noepic"); mkdir -p "$p/.sdd"
run "$p" ep --now "$NOW"
expect "no-epic-refused" 1 '"status":"no-epic"'

# --- epic dir but plan.md missing ---
p=$(mkepic noplan no-plan)
run "$p" ep --now "$NOW"
expect "not-planned-refused" 1 '"status":"not-planned"'

# --- usage: missing --now / missing slug ---
p=$(mkepic usage1)
run "$p" ep
if [ "$rc" -eq 1 ]; then ok "missing-now-usage-error"; else no "missing-now-usage-error" "rc=$rc"; fi
run "$p" --now "$NOW"
if [ "$rc" -eq 1 ]; then ok "missing-slug-usage-error"; else no "missing-slug-usage-error" "rc=$rc"; fi

# --- digest is content-derived: identical content => identical digest; different => different ---
a=$(mkepic dig-a); run "$a" ep --now "$NOW"; da=$(grep '^PLAN_DIGEST:' "$a/.sdd/_epic/ep/RATIFICATION.md")
b=$(mkepic dig-b); run "$b" ep --now "$NOW"; db=$(grep '^PLAN_DIGEST:' "$b/.sdd/_epic/ep/RATIFICATION.md")
[ "$da" = "$db" ] && [ -n "$da" ] && ok "digest-deterministic" || no "digest-deterministic" "a=$da b=$db"
c=$(mkepic dig-c); printf 'EPIC: ep\n\n## Stories\n- id: DIFFERENT\n  repo: x\n' > "$c/.sdd/_epic/ep/plan.md"
run "$c" ep --now "$NOW"; dc=$(grep '^PLAN_DIGEST:' "$c/.sdd/_epic/ep/RATIFICATION.md")
[ "$dc" != "$da" ] && ok "digest-content-sensitive" || no "digest-content-sensitive" "same digest for different plan"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
