#!/usr/bin/env bash
# Tests for hooks/scripts/counterfactual-gate.sh (ADR-0002: the counterfactual is a
# fail-closed gate at the HANDOFF flip — "the fully fail-closed hook form" the engine's
# header anticipated). PreToolUse Write|Edit: when a write transitions PROGRESS.md to
# PHASE: HANDOFF (the same ship chokepoint as dependency-gate / blast-radius-gate),
# require a recorded counterfactual verdict (.sdd/<slug>/COUNTERFACTUAL.md, written by
# scripts/counterfactual-record.sh) that is
#   (a) FRESH — its CHANGE_SIGNATURE matches the current change content (content-based:
#       a source/tests edit stales it; a commit of identical content does not), and
#   (b) gate-opening — VERDICT: pass, or the ONE deliberate skip (REASON: no-source-change,
#       nothing revertable so the counterfactual is vacuous by the engine's own semantics).
# Missing / stale / fail / error / any other skip → block (exit 2). Inert: non-chokepoint
# writes, no active item, bug lane (its VERIFY counterfactual is the gated qa snapshot
# procedure), no git / not a work tree (the standalone fail-open boundary, mirroring
# dependency-gate — no signature is computable there). Fail closed on '..', unreadable
# ACTIVE, missing jq.
# Run: bash hooks/scripts/counterfactual-gate.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/counterfactual-gate.sh"
REC="$DIR/../../scripts/counterfactual-record.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

command -v git >/dev/null 2>&1 || { echo "FAIL counterfactual-gate fixtures need git — refusing to pass with the suite un-run"; exit 1; }

# fire <name> <proj> <file_path> <content> <want-rc>
fire() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" --arg c "$content" '{tool_input:{file_path:$f,content:$c}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-46s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-46s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# mkfeat <name> -> a git-repo working tree with an active forward feature in CHANGE_REVIEW.
mkfeat() {
  local p="$work/$1"
  mkdir -p "$p/.sdd/feat"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  printf 'PHASE: CHANGE_REVIEW\n' > "$p/.sdd/feat/PROGRESS.md"
  printf 'x = 1\n' > "$p/app.py"
  ( cd "$p" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$p"
}
cursig() { ( cd "$1" && bash "$REC" signature 2>/dev/null ); }
# wrec <proj> <verdict> <reason> <sig>
wrec() {
  printf '# Counterfactual — feat\n\nRECORDED: 2026-07-01T00:00:00Z\nVERDICT: %s\nREASON: %s\nCHANGE_SIGNATURE: %s\n' \
    "$2" "$3" "$4" > "$1/.sdd/feat/COUNTERFACTUAL.md"
}

# --- the fail-closed core: no record / bad verdicts -----------------------------------
p=$(mkfeat miss);   fire "missing-record-blocks"            "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat vfail);  wrec "$p" fail suite-green-after-revert "$(cursig "$p")"
fire "verdict-fail-blocks"                                  "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat verr);   wrec "$p" error stash-failed "$(cursig "$p")"
fire "verdict-error-blocks"                                 "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat nosig);  wrec "$p" pass "" ""
fire "record-without-signature-blocks"                      "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

# --- pass + freshness (the tamper cycle) -----------------------------------------------
p=$(mkfeat pfresh); wrec "$p" pass "" "$(cursig "$p")"
fire "pass-fresh-allows"                                    "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# a source edit AFTER the record → stale → block (THE TAMPER TEST)
printf 'x = 2\n' > "$p/app.py"
fire "pass-stale-after-source-edit-blocks"                  "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
# re-record at the new content → allow again
wrec "$p" pass "" "$(cursig "$p")"
fire "re-record-after-edit-allows"                          "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# a tests/ edit AFTER the record → stale → block (tests are verdict inputs too)
p=$(mkfeat tstale); wrec "$p" pass "" "$(cursig "$p")"
mkdir -p "$p/tests"; printf 'assert True\n' > "$p/tests/test_x.py"
fire "pass-stale-after-tests-edit-blocks"                   "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
# a commit of IDENTICAL content must NOT stale (content-based, not diff-based)
p=$(mkfeat pcommit); printf 'x = 3\n' > "$p/app.py"
wrec "$p" pass "" "$(cursig "$p")"
( cd "$p" && git add -A && git commit -qm change ) >/dev/null 2>&1
fire "commit-does-not-stale-allows"                         "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# an .sdd/ write must NOT stale (the records/PROGRESS live there)
p=$(mkfeat sddw); wrec "$p" pass "" "$(cursig "$p")"
printf 'notes\n' > "$p/.sdd/feat/IMPL_NOTES.md"
fire "sdd-write-does-not-stale-allows"                      "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

# --- skip handling: ONLY no-source-change is gate-opening -------------------------------
p=$(mkfeat sok);  wrec "$p" skip no-source-change "$(cursig "$p")"
fire "skip-no-source-change-allows"                         "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
p=$(mkfeat sntc); wrec "$p" skip no-test-command "$(cursig "$p")"
fire "skip-no-test-command-blocks"                          "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat sred); wrec "$p" skip baseline-red "$(cursig "$p")"
fire "skip-baseline-red-blocks"                             "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat sbare); wrec "$p" skip "" "$(cursig "$p")"
fire "bare-skip-blocks"                                     "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

# --- chokepoint / inert ------------------------------------------------------------------
p=$(mkfeat nprog);  fire "non-progress-write-allows"        "$p" "src.py"                "PHASE: HANDOFF" 0
p=$(mkfeat nhand);  fire "non-handoff-progress-allows"      "$p" ".sdd/feat/PROGRESS.md" "PHASE: BUILD"   0
mkdir -p "$work/empty"
fire "no-active-feature-allows" "$work/empty" ".sdd/x/PROGRESS.md" "PHASE: HANDOFF" 0
# bug lane → inert (its VERIFY counterfactual is the gated qa snapshot procedure)
p=$(mkfeat bug); printf 'STATUS: FIXED\n' > "$p/.sdd/feat/diagnosis.md"
fire "bug-lane-inert"                                       "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# not a git work tree → inert (standalone boundary; no signature computable)
p="$work/norepo"; mkdir -p "$p/.sdd/feat"
printf 'feat\n' > "$p/.sdd/ACTIVE"; printf 'PHASE: CHANGE_REVIEW\n' > "$p/.sdd/feat/PROGRESS.md"
fire "not-a-repo-inert"                                     "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

# --- fail closed --------------------------------------------------------------------------
p=$(mkfeat trav)
fire "traversal-rejected" "$p" ".sdd/../e/.sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

up=$(mkfeat unread); chmod 000 "$up/.sdd/ACTIVE"
rc=0; ( cd "$up" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | CLAUDE_PROJECT_DIR="$up" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$up/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-46s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-46s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

jp=$(mkfeat jqmiss)
stubnojq="$work/stubnojq"; mkdir -p "$stubnojq"
for b in bash head tr cat grep sed basename dirname find chmod mktemp pwd; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stubnojq/$b"; done
rc=0; err=$( cd "$jp" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | PATH="$stubnojq" CLAUDE_PROJECT_DIR="$jp" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-46s rc=2\n' "jq-missing-fails-closed-when-active"
else fail=$((fail+1)); printf 'FAIL %-46s want=2 got=%s err=[%s]\n' "jq-missing-fails-closed-when-active" "$rc" "$err"; fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
