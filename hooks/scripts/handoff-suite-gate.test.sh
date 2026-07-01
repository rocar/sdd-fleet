#!/usr/bin/env bash
# Tests for hooks/scripts/handoff-suite-gate.sh (ADR-0002: "no handoff on a failing or
# untraceable suite" enforced at the tool boundary). PreToolUse Write|Edit: when a write
# transitions PROGRESS.md to PHASE: HANDOFF (the same ship chokepoint as dependency-gate /
# blast-radius-gate / counterfactual-gate), require BOTH:
#   1) TRACEABILITY at flip time — when the acceptance source carries AC-<n> ids,
#      TEST_PLAN.md must exist and mention every id (mapped to a test row or documented
#      under ## Gaps) — the traceability-gate predicate re-verified at the ship flip;
#   2) a RECORDED, signature-fresh GREEN suite run — .sdd/<slug>/SUITE_RUN.md (written by
#      scripts/suite-record.sh) with RESULT: green and CHANGE_SIGNATURE matching the
#      current change content (counterfactual-record.sh `signature`, the single home).
# red / skip (no recognized test command) / stale / missing → block (exit 2). Inert:
# non-chokepoint writes, no active item, bug lane, no git / not a work tree (the
# standalone fail-open boundary). Fail closed on '..', unreadable ACTIVE, missing jq.
# Run: bash hooks/scripts/handoff-suite-gate.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/handoff-suite-gate.sh"
REC="$DIR/../../scripts/counterfactual-record.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

command -v git >/dev/null 2>&1 || { echo "FAIL handoff-suite-gate fixtures need git — refusing to pass with the suite un-run"; exit 1; }

# fire <name> <proj> <file_path> <content> <want-rc>
fire() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" --arg c "$content" '{tool_input:{file_path:$f,content:$c}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-46s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-46s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

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
# wrun <proj> <result> <reason> <sig>
wrun() {
  printf '# Suite Run — feat\n\nRECORDED: 2026-07-01T00:00:00Z\nRESULT: %s\nREASON: %s\nTEST_COMMANDS: true\nCHANGE_SIGNATURE: %s\n' \
    "$2" "$3" "$4" > "$1/.sdd/feat/SUITE_RUN.md"
}

# --- the record core: missing / red / skip / stale ---------------------------------------
p=$(mkfeat miss);  fire "missing-record-blocks"             "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat green); wrun "$p" green "" "$(cursig "$p")"
fire "green-fresh-allows"                                   "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
p=$(mkfeat red);   wrun "$p" red "failing: pytest -q" "$(cursig "$p")"
fire "red-blocks"                                           "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat skip);  wrun "$p" skip no-test-command "$(cursig "$p")"
fire "skip-no-test-command-blocks"                          "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mkfeat nosig); wrun "$p" green "" ""
fire "record-without-signature-blocks"                      "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
# a source edit AFTER the green record → stale → block (THE TAMPER TEST)
p=$(mkfeat stale); wrun "$p" green "" "$(cursig "$p")"
printf 'x = 2\n' > "$p/app.py"
fire "green-stale-after-source-edit-blocks"                 "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
# re-record at the new content → allow again
wrun "$p" green "" "$(cursig "$p")"
fire "re-record-after-edit-allows"                          "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# a commit of IDENTICAL content must NOT stale (content-based, not diff-based)
p=$(mkfeat commit); printf 'x = 3\n' > "$p/app.py"
wrun "$p" green "" "$(cursig "$p")"
( cd "$p" && git add -A && git commit -qm change ) >/dev/null 2>&1
fire "commit-does-not-stale-allows"                         "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

# --- traceability at flip time (the AC->test predicate, re-verified at the ship flip) ----
# ACs exist, green fresh record, but NO TEST_PLAN.md → untraceable → block
p=$(mkfeat tnone); wrun "$p" green "" "$(cursig "$p")"
printf 'AC-1: adds two numbers\n' > "$p/.sdd/feat/acceptance.md"
fire "ac-without-testplan-blocks"                           "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
# every AC mapped → allow
printf '| AC-1 | tests/test_app.py::test_add |\n' > "$p/.sdd/feat/TEST_PLAN.md"
fire "ac-mapped-allows"                                     "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# an unmapped AC → block
p=$(mkfeat tmiss); wrun "$p" green "" "$(cursig "$p")"
printf 'AC-1: adds\nAC-2: subtracts\n' > "$p/.sdd/feat/acceptance.md"
printf '| AC-1 | tests/test_app.py::test_add |\n' > "$p/.sdd/feat/TEST_PLAN.md"
fire "ac-unmapped-blocks"                                   "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
# an AC recorded under ## Gaps counts as traced (a documented non-coverage)
printf '| AC-1 | tests/test_app.py::test_add |\n\n## Gaps\n- AC-2: deferred, ADR-7\n' > "$p/.sdd/feat/TEST_PLAN.md"
fire "ac-gap-documented-allows"                             "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
# no AC ids anywhere → the traceability leg is inert (finalize owns AC presence); record still rules
p=$(mkfeat tinert); wrun "$p" green "" "$(cursig "$p")"
printf 'ship it\n' > "$p/.sdd/feat/acceptance.md"
fire "no-ac-ids-traceability-inert"                         "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

# --- chokepoint / inert --------------------------------------------------------------------
p=$(mkfeat nprog); fire "non-progress-write-allows"         "$p" "src.py"                "PHASE: HANDOFF" 0
p=$(mkfeat nhand); fire "non-handoff-progress-allows"       "$p" ".sdd/feat/PROGRESS.md" "PHASE: BUILD"   0
mkdir -p "$work/empty"
fire "no-active-feature-allows" "$work/empty" ".sdd/x/PROGRESS.md" "PHASE: HANDOFF" 0
p=$(mkfeat bug); printf 'STATUS: FIXED\n' > "$p/.sdd/feat/diagnosis.md"
fire "bug-lane-inert"                                       "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
p="$work/norepo"; mkdir -p "$p/.sdd/feat"
printf 'feat\n' > "$p/.sdd/ACTIVE"; printf 'PHASE: CHANGE_REVIEW\n' > "$p/.sdd/feat/PROGRESS.md"
fire "not-a-repo-inert"                                     "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

# --- fail closed -----------------------------------------------------------------------------
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
