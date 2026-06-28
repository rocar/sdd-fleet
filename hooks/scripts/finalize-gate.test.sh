#!/usr/bin/env bash
# Tests for hooks/scripts/finalize-gate.sh.
# The finalize gate moves the FINALIZE consequence out of command prose into code:
# a write that flips the active feature's spec.md to STATUS: FINALIZED is blocked
# unless the review record approves it (or TIER=trivial waived REVIEW). This is
# what makes block-source-before-finalized a real boundary rather than a guard
# over a model-set predicate (audit finding A1, CRITICAL).
# Run: bash hooks/scripts/finalize-gate.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/finalize-gate.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

new_proj() { local p="$work/$1"; mkdir -p "$p/.sdd"; printf '%s' "$p"; }

# Approved cycle <N> for the default roster (architect qa coder).
approved_review() {
  local n="$1"
  printf '## Cycle %s — architect — 2026-06-28T00:00:00Z\nlooks good\nstatus: approved\n\n' "$n"
  printf '## Cycle %s — qa — 2026-06-28T00:00:00Z\ncoverage ok\nstatus: approved\n\n' "$n"
  printf '## Cycle %s — coder — 2026-06-28T00:00:00Z\nidiomatic\nstatus: approved\n' "$n"
}

# Decidable acceptance criteria — the testability floor a FINALIZED flip requires.
accept() { printf '# Acceptance\n\n- AC-1: returns 200 on a valid request\n- AC-2: returns 422 on a malformed body\n'; }

# check_write <name> <proj> <file_path> <content> <want_rc>
check_write() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc=0 payload
  payload=$(jq -nc --arg fp "$fp" --arg c "$content" '{tool_input:{file_path:$fp,content:$c}}')
  ( cd "$proj" && printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# check_edit <name> <proj> <file_path> <new_string> <want_rc>
check_edit() {
  local name="$1" proj="$2" fp="$3" ns="$4" want="$5" rc=0 payload
  payload=$(jq -nc --arg fp "$fp" --arg ns "$ns" '{tool_input:{file_path:$fp,old_string:"x",new_string:$ns}}')
  ( cd "$proj" && printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

std_progress() { printf 'PHASE: REVIEW\nCYCLE: %s\nTIER: standard\n' "$1"; }

# --- happy path: approved review allows the FINALIZED flip -------------------
p=$(new_proj a1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
approved_review 1 > "$p/.sdd/feat/REVIEW.md"; accept > "$p/.sdd/feat/acceptance.md"
check_write "approved-write-finalize-allows" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 0
check_edit  "approved-edit-statusline-allows" "$p" ".sdd/feat/spec.md" "STATUS: FINALIZED" 0
check_edit  "approved-edit-wordonly-allows"   "$p" ".sdd/feat/spec.md" "FINALIZED" 0

# --- no review record at all → block ----------------------------------------
p=$(new_proj a2); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
check_write "no-review-blocks-finalize" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2
check_edit  "no-review-wordonly-blocks"  "$p" ".sdd/feat/spec.md" "FINALIZED" 2

# --- open [blocker] in current cycle → block --------------------------------
p=$(new_proj a3); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
{ printf '## Cycle 1 — architect — t\n[blocker] missing AC for refund path\nstatus: concerns-raised\n\n'
  printf '## Cycle 1 — qa — t\nstatus: approved\n\n'
  printf '## Cycle 1 — coder — t\nstatus: approved\n'; } > "$p/.sdd/feat/REVIEW.md"
check_write "open-blocker-blocks-finalize" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2

# --- a reviewer role missing its current-cycle block → block ----------------
p=$(new_proj a4); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
{ printf '## Cycle 1 — architect — t\nstatus: approved\n\n'
  printf '## Cycle 1 — coder — t\nstatus: approved\n'; } > "$p/.sdd/feat/REVIEW.md"
check_write "missing-qa-block-blocks" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2

# --- a current-cycle block ends in concerns-raised → block ------------------
p=$(new_proj a5); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
{ printf '## Cycle 1 — architect — t\nstatus: approved\n\n'
  printf '## Cycle 1 — qa — t\nstatus: concerns-raised\n\n'
  printf '## Cycle 1 — coder — t\nstatus: approved\n'; } > "$p/.sdd/feat/REVIEW.md"
check_write "concerns-raised-blocks" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2

# --- only the CURRENT cycle counts: cycle 2 approved, cycle 1 had a blocker --
p=$(new_proj a6); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 2 > "$p/.sdd/feat/PROGRESS.md"
{ printf '## Cycle 1 — architect — t\n[blocker] old issue\nstatus: concerns-raised\n\n'
  approved_review 2; } > "$p/.sdd/feat/REVIEW.md"; accept > "$p/.sdd/feat/acceptance.md"
check_write "current-cycle-approved-allows" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 0

# --- TIER=trivial waives REVIEW (classifier skipped it) → allow -------------
p=$(new_proj a7); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
printf 'PHASE: SPEC\nCYCLE: 0\nTIER: trivial\n' > "$p/.sdd/feat/PROGRESS.md"
check_write "trivial-no-review-allows" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 0

# --- ESCALATION.md present halts the flip even with an approved review -------
p=$(new_proj a8); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
approved_review 1 > "$p/.sdd/feat/REVIEW.md"; printf 'escalated\n' > "$p/.sdd/feat/ESCALATION.md"
check_write "escalation-blocks-finalize" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2

# --- roster override REVIEW_ROLES: architect,qa (coder not required) ---------
p=$(new_proj a9); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"
printf 'PHASE: REVIEW\nCYCLE: 1\nTIER: standard\nREVIEW_ROLES: architect,qa\n' > "$p/.sdd/feat/PROGRESS.md"
{ printf '## Cycle 1 — architect — t\nstatus: approved\n\n'
  printf '## Cycle 1 — qa — t\nstatus: approved\n'; } > "$p/.sdd/feat/REVIEW.md"; accept > "$p/.sdd/feat/acceptance.md"
check_write "roster-override-allows" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 0

# --- testability: a FINALIZED flip needs decidable acceptance criteria ---------
p=$(new_proj c1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
approved_review 1 > "$p/.sdd/feat/REVIEW.md"   # review approved, but NO acceptance criteria anywhere
check_write "no-acceptance-criteria-blocks" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2

p=$(new_proj c2); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
approved_review 1 > "$p/.sdd/feat/REVIEW.md"; printf '# Acceptance\n\n- AC-1: TBD\n' > "$p/.sdd/feat/acceptance.md"
check_write "tbd-acceptance-blocks" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 2

p=$(new_proj c3); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n\n## Acceptance Criteria\n- AC-1: returns 200 on success\n' > "$p/.sdd/feat/spec.md"
std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
approved_review 1 > "$p/.sdd/feat/REVIEW.md"   # inline ACs in spec.md, no acceptance.md
check_edit "inline-acceptance-allows" "$p" ".sdd/feat/spec.md" "STATUS: FINALIZED" 0

# --- non-finalizing spec writes are not our concern → allow -----------------
p=$(new_proj b1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
check_write "draft-spec-write-allows"  "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: DRAFT\n\n# spec\n')" 0
check_edit  "spec-prose-edit-allows"   "$p" ".sdd/feat/spec.md" "some prose mentioning FINALIZED state machine" 0

# --- already FINALIZED on disk → not re-gated (idempotent) → allow ----------
p=$(new_proj b2); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: FINALIZED\n' > "$p/.sdd/feat/spec.md"; printf 'PHASE: BUILD\nCYCLE: 1\nTIER: standard\n' > "$p/.sdd/feat/PROGRESS.md"
check_edit "already-finalized-allows" "$p" ".sdd/feat/spec.md" "STATUS: FINALIZED" 0

# --- writes to non-spec files are inert here → allow ------------------------
p=$(new_proj b3); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
check_write "non-spec-write-inert" "$p" "src/app.py" "$(printf 'STATUS: FINALIZED\n')" 0
check_write "lookalike-myspec-inert" "$p" ".sdd/feat/myspec.md" "$(printf 'STATUS: FINALIZED\n')" 0

# --- no active feature → allow ----------------------------------------------
p=$(new_proj b4); : > "$p/.sdd/ACTIVE"
check_write "no-active-allows" "$p" ".sdd/feat/spec.md" "$(printf 'STATUS: FINALIZED\n')" 0

# --- §3.1 traversal targeting spec.md must not satisfy the active-sdd match --
p=$(new_proj t1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
check_write "traversal-spec-inert" "$p" ".sdd/feat/../spec.md" "$(printf 'STATUS: FINALIZED\n')" 0

# --- §3.4 jq missing + active feature → fail CLOSED (exit 2) -----------------
stub="$work/stubbin"; mkdir -p "$stub"
for b in dirname basename head tail tr cat grep sed find date stat awk wc; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$stub/$b"
done
p=$(new_proj j1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
rc=0; err=$( cd "$p" && printf '{"tool_input":{"file_path":".sdd/feat/spec.md","content":"STATUS: FINALIZED"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$p" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "no-jq-active-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2+msg got=%s (%s)\n' "no-jq-active-fails-closed" "$rc" "$err"; fi

# --- §3.5 unexpected runtime error → fail CLOSED (exit 2) --------------------
p=$(new_proj e1); printf 'feat\n' > "$p/.sdd/ACTIVE"; mkdir -p "$p/.sdd/feat"
printf 'STATUS: DRAFT\n' > "$p/.sdd/feat/spec.md"; std_progress 1 > "$p/.sdd/feat/PROGRESS.md"
chmod 000 "$p/.sdd/ACTIVE"
rc=0; ( cd "$p" && printf '{"tool_input":{"file_path":".sdd/feat/spec.md","content":"STATUS: FINALIZED"}}' | CLAUDE_PROJECT_DIR="$p" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$p/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
