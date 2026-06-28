#!/usr/bin/env bash
# Tests for hooks/scripts/check-review-written.sh (audit §3.8 — checks in the
# coverage T3 verified by hand). SubagentStop gate: during REVIEW/CHANGE_REVIEW
# a reviewer subagent must have appended its "## Cycle <N> — <role> — <iso>"
# block to REVIEW.md before stopping. Feeds the SubagentStop JSON payload on
# stdin with CLAUDE_PROJECT_DIR anchoring the fixture repo.
# Run: bash hooks/scripts/check-review-written.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-review-written.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# new_proj <name> <phase> <cycle>  → fixture with active feature 'feat'
new_proj() {
  local p="$work/$1" cyc_field="CYCLE"
  [ "$2" = "CHANGE_REVIEW" ] && cyc_field="CHANGE_CYCLE"
  mkdir -p "$p/.sdd/feat"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  printf 'PHASE: %s\n%s: %s\n' "$2" "$cyc_field" "$3" > "$p/.sdd/feat/PROGRESS.md"
  printf '%s' "$p"
}
# review_block <proj> <cycle> <role>  → append a canonical REVIEW.md block
review_block() {
  printf '## Cycle %s — %s — 2026-06-10T00:00:00Z\n- [minor] nit\nstatus: approved\n' "$2" "$3" >> "$1/.sdd/feat/REVIEW.md"
}
# check <name> <proj> <json_payload> <want_rc>
check() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-42s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-42s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# --- REVIEW phase: reviewer wrote its block → allow; didn't → block ---
p=$(new_proj a1 REVIEW 1); review_block "$p" 1 architect
check "review-architect-wrote-block" "$p" '{"agent_type":"architect"}' 0
p=$(new_proj a2 REVIEW 1)   # no REVIEW.md at all
check "review-no-REVIEW.md-blocks" "$p" '{"agent_type":"architect"}' 2
p=$(new_proj a3 REVIEW 2); review_block "$p" 1 architect   # wrong cycle only
check "review-stale-cycle-block-blocks" "$p" '{"agent_type":"architect"}' 2
p=$(new_proj a4 REVIEW 1); review_block "$p" 1 qa          # someone else's block
check "review-other-roles-block-blocks" "$p" '{"agent_type":"architect"}' 2

# --- agent_type is the documented field; subagent_type is the legacy fallback ---
p=$(new_proj l1 REVIEW 1)
check "legacy-subagent_type-enforced" "$p" '{"subagent_type":"qa"}' 2
p=$(new_proj l2 REVIEW 1); review_block "$p" 1 qa
check "legacy-subagent_type-satisfied" "$p" '{"subagent_type":"qa"}' 0
# namespaced form is stripped (sdd-fleet:architect → architect)
p=$(new_proj l3 REVIEW 1); review_block "$p" 1 architect
check "namespaced-agent_type-stripped" "$p" '{"agent_type":"sdd-fleet:architect"}' 0

# --- non-reviewer / unidentifiable agents are not this hook's business ---
p=$(new_proj n1 REVIEW 1)
check "non-reviewer-agent-ignored" "$p" '{"agent_type":"devops"}' 0
check "no-agent-field-allows" "$p" '{}' 0
# the former authoring role is gone — non-reviewers are ignored (see the devops case above)

# --- CHANGE_REVIEW: reads CHANGE_CYCLE; architect + qa are the reviewers ---
p=$(new_proj c1 CHANGE_REVIEW 2); review_block "$p" 2 qa
check "change-review-qa-wrote-block" "$p" '{"agent_type":"qa"}' 0
p=$(new_proj c2 CHANGE_REVIEW 2); review_block "$p" 1 architect
check "change-review-wrong-change-cycle" "$p" '{"agent_type":"architect"}' 2
p=$(new_proj c2b CHANGE_REVIEW 2)
check "change-review-architect-no-block-blocks" "$p" '{"agent_type":"architect"}' 2
# coder reviews in REVIEW, not CHANGE_REVIEW
p=$(new_proj c3 CHANGE_REVIEW 2)
check "coder-not-a-CHANGE_REVIEW-reviewer" "$p" '{"agent_type":"coder"}' 0

# --- phase scoping: outside REVIEW/CHANGE_REVIEW the hook stands down ---
p=$(new_proj b1 BUILD 1)
check "build-phase-allows" "$p" '{"agent_type":"architect"}' 0
p=$(new_proj b2 SPEC 1)
check "spec-phase-allows" "$p" '{"agent_type":"architect"}' 0

# --- no active feature → allow ---
p="$work/noactive"; mkdir -p "$p/.sdd"; : > "$p/.sdd/ACTIVE"
check "no-active-feature-allows" "$p" '{"agent_type":"architect"}' 0

# --- the .workflow-in-flight marker-skip path (a LIVE marker is non-empty) ---
p=$(new_proj w1 REVIEW 1); printf 'review-feat-c1-2026' > "$p/.sdd/feat/.workflow-in-flight"
check "marker-skips-enforcement" "$p" '{"agent_type":"architect"}' 0
# a RELEASED marker (emptied by the scribe) does NOT skip enforcement
p=$(new_proj w2 REVIEW 1); : > "$p/.sdd/feat/.workflow-in-flight"
check "released-empty-marker-does-not-skip" "$p" '{"agent_type":"architect"}' 2

# --- non-integer cycle counter: warn + allow (never wedge the subagent) ---
p=$(new_proj g1 REVIEW "two")
rc=0; err=$( cd "$p" && printf '{"agent_type":"architect"}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -qi "not an integer"; then
  pass=$((pass+1)); printf 'ok   %-42s rc=0\n' "non-integer-cycle-warns-and-allows"
else
  fail=$((fail+1)); printf 'FAIL %-42s want=0+warn got=%s (%s)\n' "non-integer-cycle-warns-and-allows" "$rc" "$err"
fi
# empty cycle counter is the same degenerate case
p=$(new_proj g2 REVIEW "")
check "empty-cycle-warns-and-allows" "$p" '{"agent_type":"architect"}' 0

# --- en-dash / hyphen tolerance in the REVIEW.md heading ---
p=$(new_proj d1 REVIEW 1)
printf '## Cycle 1 - architect - 2026-06-10T00:00:00Z\nstatus: approved\n' >> "$p/.sdd/feat/REVIEW.md"
check "hyphen-heading-accepted" "$p" '{"agent_type":"architect"}' 0

# --- blocking message names the role and cycle ---
p=$(new_proj m1 REVIEW 3)
rc=0; err=$( cd "$p" && printf '{"agent_type":"qa"}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "qa" && printf '%s' "$err" | grep -q "cycle 3"; then
  pass=$((pass+1)); printf 'ok   %-42s rc=2\n' "block-message-names-role+cycle"
else
  fail=$((fail+1)); printf 'FAIL %-42s want=2+msg got=%s (%s)\n' "block-message-names-role+cycle" "$rc" "$err"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
