#!/usr/bin/env bash
# Tests for scripts/intent-block.sh (audit §3.26 — the shared intent-block grammar
# + quality-floor verdict consumed by /sdd-fleet:jira-story and
# /sdd-fleet:next-feature).
# Self-contained: pipes fixtures on stdin, asserts output substrings + exit codes.
# Run: bash scripts/intent-block.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/intent-block.sh"

pass=0; fail=0

# assert <name> <fixture> <want-substring> [<extra-args...>]
assert() {
  local name="$1" body="$2" want="$3"; shift 3
  local out
  out="$(printf '%s\n' "$body" | bash "$SCRIPT" "$@" 2>/dev/null)"
  if printf '%s' "$out" | grep -qF "$want"; then
    pass=$((pass+1)); printf 'ok   %-38s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-38s want[%s] got[%s]\n' "$name" "$want" "$out"
  fi
}

# assert_rc <name> <fixture> <want-rc> [<extra-args...>]
assert_rc() {
  local name="$1" body="$2" want="$3"; shift 3
  local rc=0
  printf '%s\n' "$body" | bash "$SCRIPT" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass+1)); printf 'ok   %-38s rc=%s\n' "$name" "$rc"
  else
    fail=$((fail+1)); printf 'FAIL %-38s want rc=%s got rc=%s\n' "$name" "$want" "$rc"
  fi
}

# --- usable intents ---

assert "multiline-intent-usable" '- [ ] solo   PENDING   depends-on: none
      Line one of the intent: what it is.
      Line two: the scope boundary.
      Line three: explicit non-goals.' 'INTENT_VERDICT: usable'

assert "one-line-emdash-usable" '- [ ] api-client   PENDING   depends-on: cli-skeleton
      The internal/yahoo typed HTTP wrapper — sole package that talks to Yahoo.' 'INTENT_VERDICT: usable'

assert "one-line-semicolon-usable" '- [ ] cli-skeleton   PENDING   depends-on: none
      Cobra root command + global --format flag; the app shell.' 'INTENT_VERDICT: usable'

assert "usable-emits-slug" '- [ ] api-client   PENDING   depends-on: none
      What it is — its boundary.' 'INTENT_SLUG: api-client'

assert "usable-emits-dedented-intent" '- [ ] api-client   PENDING   depends-on: none
      What it is — its boundary.' 'What it is — its boundary.'

# --- too-thin intents ---

assert "missing-intent-too-thin" '- [ ] bare-row   PENDING   depends-on: none' 'INTENT_VERDICT: too-thin'

assert "slug-restatement-too-thin" '- [ ] api-client   PENDING   depends-on: none
      The API client.' 'INTENT_VERDICT: too-thin'

assert "blank-line-ends-block-too-thin" '- [ ] solo   PENDING   depends-on: none

      This indented line is AFTER a blank line, so it is not intent.' 'INTENT_VERDICT: too-thin'

assert "next-row-ends-block" '- [ ] first   PENDING   depends-on: none
- [ ] second   PENDING   depends-on: none
      intent for second, not first' 'INTENT_VERDICT: too-thin'

# --- block termination + cap ---

assert "heading-ends-block" '- [ ] solo   PENDING   depends-on: none
      One clause only
## Phase 2: Next — STATUS: pending' 'INTENT_VERDICT: too-thin'

assert "done-row-parses" '- [x] shipped   DONE   depends-on: none   handoff:2026-06-01
      What it was — its boundary.' 'INTENT_STATE: DONE'

# --- malformed / empty input ---

assert_rc "malformed-row-errors" 'this is not a backlog row at all' 1
assert_rc "prose-checklist-not-a-row" '- [x] we decided to use postgres' 1
assert_rc "empty-input-errors" '' 1
assert_rc "usable-exits-zero" '- [ ] ok   PENDING   depends-on: none
      What — boundary.' 0

# --- --slug mode against a full backlog ---

BACKLOG='PRODUCT: x
STATUS: FINALIZED

## Phase 1: Foundations — STATUS: in-progress
- [x] cli-skeleton   DONE   depends-on: none   handoff:2026-06-03
      Cobra root command + global --format flag; the app shell.
- [ ] api-client   PENDING   depends-on: cli-skeleton
      The internal/yahoo typed HTTP wrapper — sole package that talks to Yahoo.
- [ ] thin-one   PENDING   depends-on: cli-skeleton
      The thin one.'

assert "slug-mode-finds-row" "$BACKLOG" 'INTENT_SLUG: api-client' --slug api-client
assert "slug-mode-usable" "$BACKLOG" 'INTENT_VERDICT: usable' --slug api-client
assert "slug-mode-too-thin" "$BACKLOG" 'INTENT_VERDICT: too-thin' --slug thin-one
assert_rc "slug-mode-missing-slug-errors" "$BACKLOG" 1 --slug no-such-slug

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
