#!/usr/bin/env bash
# Tests for scripts/next-feature.sh (v0.4 M3.2 resolver).
# Self-contained: writes fixtures to a temp dir, asserts the JSON status/slug.
# Run: bash scripts/next-feature.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$DIR/next-feature.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
# assert <name> <fixture-content> <substring-expected-in-output>
assert() {
  local name="$1" body="$2" want="$3" f out
  f="$work/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' _).md"
  printf '%s' "$body" > "$f"
  out="$(bash "$RESOLVER" "$f")"
  if printf '%s' "$out" | grep -qF "$want"; then
    pass=$((pass+1)); printf 'ok   %-34s %s\n' "$name" "$out"
  else
    fail=$((fail+1)); printf 'FAIL %-34s want[%s] got[%s]\n' "$name" "$want" "$out"
  fi
}

H='PRODUCT: x
STATUS: FINALIZED
'

assert "all-pending-first-unblocked" "$H
## Phase 1: Foundations — STATUS: pending
- [ ] cli-skeleton   PENDING   depends-on: none
- [ ] api-client   PENDING   depends-on: none
- [ ] output-formatter   PENDING   depends-on: cli-skeleton" '"status":"next","slug":"cli-skeleton"'

assert "deps-gate-picks-unblocked" "$H
## Phase 1: P1 — STATUS: in-progress
- [x] cli-skeleton   DONE   depends-on: none   handoff:2026-06-03
- [x] api-client   DONE   depends-on: none   handoff:2026-06-03
- [ ] output-formatter   PENDING   depends-on: cli-skeleton" '"slug":"output-formatter"'

assert "phase-crossing-lowest-with-unblocked" "$H
## Phase 1: P1 — STATUS: in-progress
- [x] a   DONE   depends-on: none   handoff:2026-06-03
- [ ] blocked-in-p1   PENDING   depends-on: not-done-yet
## Phase 2: P2 — STATUS: pending
- [ ] free-in-p2   PENDING   depends-on: a" '"slug":"free-in-p2","phase":"Phase 2: P2"'

assert "forward-referenced-dep" "$H
## Phase 1: P1 — STATUS: in-progress
- [ ] needs-later   PENDING   depends-on: later
- [x] later   DONE   depends-on: none   handoff:2026-06-03" '"slug":"needs-later"'

assert "multi-dep-one-missing-skips" "$H
## Phase 1: P1 — STATUS: in-progress
- [x] a   DONE   depends-on: none   handoff:2026-06-03
- [ ] needs-both   PENDING   depends-on: a, b
- [ ] needs-a   PENDING   depends-on: a" '"slug":"needs-a"'

assert "all-done-complete" "$H
## Phase 1: P1 — STATUS: complete
- [x] a   DONE   depends-on: none   handoff:2026-06-03
- [x] b   DONE   depends-on: a   handoff:2026-06-03" '"status":"complete","done":2,"total":2'

assert "deadlock-unsatisfiable" "$H
## Phase 1: P1 — STATUS: in-progress
- [x] a   DONE   depends-on: none   handoff:2026-06-03
- [ ] z   PENDING   depends-on: missing" '"status":"deadlocked"'

assert "substring-dep-not-false-match" "$H
## Phase 1: P1 — STATUS: in-progress
- [x] auth   DONE   depends-on: none   handoff:2026-06-03
- [ ] x   PENDING   depends-on: auth-v2" '"status":"deadlocked"'

# --- regressions found in M3.2 audit ---

assert "empty-backlog-not-complete" "$H
## Phase 1: P1 — STATUS: pending" '"status":"empty"'

assert "crlf-dep-none-not-deadlock" "$(printf 'PRODUCT: x\r\nSTATUS: FINALIZED\r\n\r\n## Phase 1: P1 — STATUS: pending\r\n- [ ] only   PENDING   depends-on: none\r\n')" '"status":"next","slug":"only"'

assert "capital-X-done" "$H
## Phase 1: P1 — STATUS: in-progress
- [X] a   DONE   depends-on: none   handoff:2026-06-03
- [ ] b   PENDING   depends-on: a" '"slug":"b"'

assert "capital-None-dep" "$H
## Phase 1: P1 — STATUS: pending
- [ ] solo   PENDING   depends-on: None" '"status":"next","slug":"solo"'

# prose checklist / star-bullet notes in a phase body must NOT parse as feature rows
assert "star-bullet-prose-ignored" "$H
## Phase 1: P1 — STATUS: in-progress
* [x] we decided to use postgres
- [ ] real-feature   PENDING   depends-on: none" '"status":"next","slug":"real-feature"'

assert "dash-prose-not-counted" "$H
## Phase 1: P1 — STATUS: complete
- [x] a   DONE   depends-on: none   handoff:2026-06-03
- [ ] make sure the linter passes" '"status":"complete","done":1,"total":1'

assert "prose-cannot-satisfy-dep" "$H
## Phase 1: P1 — STATUS: in-progress
* [x] cleanup the build before merging
- [ ] needs-cleanup   PENDING   depends-on: cleanup" '"status":"deadlocked"'

# M3.3 intent lines (indented, under each row) must be invisible to the resolver
assert "intent-lines-ignored" "$H
## Phase 1: Foundations — STATUS: in-progress
- [x] cli-skeleton   DONE   depends-on: none   handoff:2026-06-03
      Cobra root command + global --format flag; the app shell.
- [ ] api-client   PENDING   depends-on: cli-skeleton
      The internal/yahoo typed HTTP wrapper — sole package that talks to Yahoo." '"status":"next","slug":"api-client","phase":"Phase 1: Foundations","done":1,"total":2'

# M3.3 allows 1-3 line intents — multi-line indented blocks must also be invisible
assert "multiline-intent-ignored" "$H
## Phase 1: P1 — STATUS: pending
- [ ] solo   PENDING   depends-on: none
      Line one of the intent: what it is.
      Line two: the scope boundary.
      Line three: explicit non-goals / deferrals to sibling features." '"slug":"solo","phase":"Phase 1: P1","done":0,"total":1'

out="$(bash "$RESOLVER" "$work/does-not-exist.md")"
if printf '%s' "$out" | grep -qF '"status":"no-backlog"'; then
  pass=$((pass+1)); printf 'ok   %-34s %s\n' "missing-file-no-backlog" "$out"
else
  fail=$((fail+1)); printf 'FAIL %-34s got[%s]\n' "missing-file-no-backlog" "$out"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
