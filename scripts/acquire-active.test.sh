#!/usr/bin/env bash
# Tests for scripts/acquire-active.sh (atomic .sdd/ACTIVE acquisition, audit §3.32a).
# Self-contained: builds throwaway project dirs under mktemp, runs the script with
# cwd = that dir (the script resolves .sdd/ relative to cwd, like the hooks).
# Run: bash scripts/acquire-active.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/acquire-active.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %-38s %s\n' "$1" "${2:-}"; }
bad() { fail=$((fail+1)); printf 'FAIL %-38s %s\n' "$1" "${2:-}"; }

# run <fixture-dir> <args...>  — sets $rc, $out (stdout), $err (stderr)
run() {
  local p="$1"; shift
  out="$( (cd "$p" && bash "$SCRIPT" "$@") 2>"$work/.stderr" )"; rc=$?
  err="$(cat "$work/.stderr")"
}
# expect <name> <want-rc> <want-stdout-substring>
expect() {
  local name="$1" wrc="$2" wout="$3"
  if [ "$rc" -ne "$wrc" ]; then bad "$name" "want rc=$wrc got rc=$rc [$out][$err]"; return; fi
  if [ -n "$wout" ] && ! printf '%s' "$out" | grep -qF "$wout"; then
    bad "$name" "stdout missing [$wout] got [$out]"; return
  fi
  ok "$name" "$out"
}

# ---- acquire on a fresh repo ------------------------------------------------
p="$work/fresh"; mkdir -p "$p"
run "$p" acquire feat-a --owner "sdd-fleet:jira-story" --now "2026-06-11T10:00:00Z"
expect "acquire-fresh" 0 '"status":"acquired","slug":"feat-a"'
[ "$(cat "$p/.sdd/ACTIVE")" = "feat-a" ] \
  && ok "acquire-writes-ACTIVE" "feat-a" || bad "acquire-writes-ACTIVE" "$(cat "$p/.sdd/ACTIVE" 2>&1)"
grep -q '^OWNER: sdd-fleet:jira-story$' "$p/.sdd/ACTIVE.lock" \
  && grep -q '^SLUG: feat-a$' "$p/.sdd/ACTIVE.lock" \
  && grep -q '^ACQUIRED: 2026-06-11T10:00:00Z$' "$p/.sdd/ACTIVE.lock" \
  && ok "lock-metadata" || bad "lock-metadata" "$(cat "$p/.sdd/ACTIVE.lock" 2>&1)"

# ---- status: held -------------------------------------------------------------
run "$p" status
expect "status-held" 0 '"status":"held","slug":"feat-a","owner":"sdd-fleet:jira-story","held_since":"2026-06-11T10:00:00Z"'

# ---- double-acquire: second loses, first's metadata intact -------------------
run "$p" acquire feat-b --owner "sdd-fleet:jira-story" --now "2026-06-11T11:00:00Z"
expect "double-acquire-refused" 1 'SDD_FLEET_ACTIVE_CONFLICT: {"requested":"feat-b","active":"feat-a","owner":"sdd-fleet:jira-story","held_since":"2026-06-11T10:00:00Z"}'
printf '%s' "$err" | grep -q "sdd-fleet:jira-story" \
  && ok "conflict-stderr-names-owner" || bad "conflict-stderr-names-owner" "[$err]"
grep -q '^OWNER: sdd-fleet:jira-story$' "$p/.sdd/ACTIVE.lock" \
  && grep -q '^ACQUIRED: 2026-06-11T10:00:00Z$' "$p/.sdd/ACTIVE.lock" \
  && [ "$(cat "$p/.sdd/ACTIVE")" = "feat-a" ] \
  && ok "first-holder-intact" || bad "first-holder-intact" "$(cat "$p/.sdd/ACTIVE.lock" 2>&1)"

# ---- release of the wrong slug is refused ------------------------------------
run "$p" release feat-b
expect "release-wrong-slug-refused" 1 ""
printf '%s' "$err" | grep -q "feat-a" \
  && ok "wrong-release-stderr-names-holder" || bad "wrong-release-stderr-names-holder" "[$err]"
[ -f "$p/.sdd/ACTIVE.lock" ] && [ "$(cat "$p/.sdd/ACTIVE")" = "feat-a" ] \
  && ok "wrong-release-left-state-intact" || bad "wrong-release-left-state-intact"

# ---- release then re-acquire ---------------------------------------------------
run "$p" release feat-a
expect "release-ok" 0 '"status":"released","slug":"feat-a"'
[ ! -f "$p/.sdd/ACTIVE.lock" ] && [ -f "$p/.sdd/ACTIVE" ] && [ -z "$(tr -d '[:space:]' < "$p/.sdd/ACTIVE")" ] \
  && ok "release-empties-not-deletes" || bad "release-empties-not-deletes"
run "$p" status
expect "status-free-after-release" 0 '{"status":"free"}'
run "$p" acquire feat-b --owner "sdd-fleet:jira-story" --now "2026-06-11T12:00:00Z"
expect "reacquire-after-release" 0 '"status":"acquired","slug":"feat-b"'
[ "$(cat "$p/.sdd/ACTIVE")" = "feat-b" ] \
  && ok "reacquire-writes-ACTIVE" || bad "reacquire-writes-ACTIVE"

# ---- usage errors ---------------------------------------------------------------
p="$work/usage"; mkdir -p "$p"
run "$p" acquire feat-x --owner "o1"
expect "missing--now-usage-error" 1 ""
printf '%s' "$err" | grep -q -- "--now" && ok "missing--now-stderr" || bad "missing--now-stderr" "[$err]"
[ ! -f "$p/.sdd/ACTIVE.lock" ] && ok "missing--now-no-lock" || bad "missing--now-no-lock"

run "$p" acquire feat-x --now "2026-06-11T10:00:00Z"
expect "missing--owner-usage-error" 1 ""
printf '%s' "$err" | grep -q -- "--owner" && ok "missing--owner-stderr" || bad "missing--owner-stderr" "[$err]"
[ ! -f "$p/.sdd/ACTIVE.lock" ] && ok "missing--owner-no-lock" || bad "missing--owner-no-lock"

run "$p" acquire --owner "o1" --now "2026-06-11T10:00:00Z"
expect "missing-slug-usage-error" 1 ""

run "$p" bogus-mode
expect "unknown-mode-usage-error" 1 ""

# ---- status: free on a bare repo ------------------------------------------------
p="$work/bare"; mkdir -p "$p"
run "$p" status
expect "status-free-bare" 0 '{"status":"free"}'

# ---- release when free is refused ------------------------------------------------
run "$p" release anything
expect "release-when-free-refused" 1 ""

# ---- pre-lock legacy state: ACTIVE non-empty, no lock file ----------------------
p="$work/legacy"; mkdir -p "$p/.sdd"
printf 'old-feat\n' > "$p/.sdd/ACTIVE"
run "$p" acquire feat-c --owner "o2" --now "2026-06-11T13:00:00Z"
expect "legacy-active-blocks-acquire" 1 'SDD_FLEET_ACTIVE_CONFLICT: {"requested":"feat-c","active":"old-feat","owner":"unknown"'
[ ! -f "$p/.sdd/ACTIVE.lock" ] \
  && ok "legacy-conflict-rolls-back-lock" || bad "legacy-conflict-rolls-back-lock"
run "$p" status
expect "legacy-status-held" 0 '"status":"held","slug":"old-feat","owner":"unknown"'
run "$p" release old-feat
expect "legacy-release-ok" 0 '"status":"released","slug":"old-feat"'
[ -z "$(tr -d '[:space:]' < "$p/.sdd/ACTIVE")" ] \
  && ok "legacy-release-empties-ACTIVE" || bad "legacy-release-empties-ACTIVE"

# ---- same-slug re-acquire over legacy ACTIVE (resume) succeeds ------------------
p="$work/resume"; mkdir -p "$p/.sdd"
printf 'parked-feat\n' > "$p/.sdd/ACTIVE"
run "$p" acquire parked-feat --owner "human:resume" --now "2026-06-11T14:00:00Z"
expect "legacy-same-slug-reacquire" 0 '"status":"acquired","slug":"parked-feat"'

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
