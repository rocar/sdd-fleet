#!/usr/bin/env bash
# Planted-bug smoke test for the troubleshoot-fix bug lane (v0.5).
#
# Drives a real planted bug (docs/v0.5/smoke/fixture/) through the lane's DETERMINISTIC
# backbone — the diagnosis.md validator and the two source-write gates — invoking the ACTUAL
# plugin hooks at every gate, plus the RED→GREEN transition and the VERIFY counterfactual.
# Runnable with NO plugin enabled; it exercises exactly the hooks a live run would fire.
# (The LLM-driven parts — the bug-mode classifier and diagnose.js confirmation — are NOT
# scriptable; WALKTHROUGH.md drives those with `claude --plugin-dir .`.)
#
# Run: bash docs/v0.5/smoke/smoke.sh        (exit 0 = every gate behaved correctly)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/../../.." && pwd)"
HOOKS="$PLUGIN/hooks/scripts"
FIX="$HERE/fixture"
SLUG="bug-pagination-drops-last-page"

command -v python3 >/dev/null 2>&1 || { echo "smoke: python3 required"; exit 2; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected[$3] got[$2]"; fi; }

# --- hook helpers (cwd is the temp project, so hook path-resolution matches a real run) ---
hook_rc(){ local h="$1" fp="$2" rc=0; printf '{"tool_input":{"file_path":"%s"}}' "$fp" | bash "$HOOKS/$h" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
# the source-write gate = BOTH PreToolUse hooks; BLOCKED if either exits 2.
gate(){ local fp="$1" b r; b=$(hook_rc block-source-before-finalized.sh "$fp"); r=$(hook_rc require-reproducing-test.sh "$fp"); if [ "$b" = 2 ] || [ "$r" = 2 ]; then printf 'BLOCKED'; else printf 'ALLOWED'; fi; }
validate_diag(){ hook_rc validate-diagnosis-status.sh "$work/.sdd/$SLUG/diagnosis.md"; }
red_green(){ if PYTHONPATH="$work" python3 tests/test_pagination.py >/dev/null 2>&1; then printf 'GREEN'; else printf 'RED'; fi; }

# diagnosis.md at a given STATUS (hypothesis/blast/fix filled once we reach DIAGNOSED+)
diag(){
  local status="$1" hyp="_(empty until DIAGNOSE)_"
  case "$status" in DIAGNOSED|CONFIRMED|FIXED) hyp="page_count uses floor division (total // per_page), truncating the final partial page.";; esac
  cat > ".sdd/$SLUG/diagnosis.md" <<EOF
STATUS: $status

# Bug: pagination drops the last partial page

## Symptom + reproduction steps
page_count(31, 10) returns 3, but 31 items at 10/page need 4 pages — the last item is unreachable.
Reproduced by tests/test_pagination.py::test_partial_last_page_is_counted.

## Root-cause hypothesis
$hyp

## Blast radius
Every caller of page_count(): page nav, "page N of M" displays. Off-by-one undercount; read-path only.

## Fix strategy
Ceiling division: (total_items + per_page - 1) // per_page. Minimal, local to page_count.
EOF
}
progress(){ cat > ".sdd/$SLUG/PROGRESS.md" <<EOF
FEATURE: $SLUG
PHASE: $1
LANE: bug
SEV: sev1
CYCLE: 0
FIX_CYCLE: 0
UPDATED: 2026-06-05T00:00:00Z
EOF
}

echo "Planted-bug smoke test — $SLUG"
echo "(plugin: $PLUGIN)"
echo

# ---------- REPORT (what /sdd-fleet:jira-story scaffolds) ----------
mkdir -p ".sdd/$SLUG" tests
cp "$FIX/pagination.py" pagination.py
printf '%s\n' "$SLUG" > .sdd/ACTIVE
diag REPORTED
progress REPORT
echo "[REPORT]"
check "validate-diagnosis accepts the REPORTED scaffold" "$(validate_diag)" 0
check "source write BLOCKED pre-CONFIRMED" "$(gate pagination.py)" BLOCKED

# ---------- REPRODUCE (qa writes the failing test) ----------
echo "[REPRODUCE]"
check "writing the reproduction under tests/ is ALLOWED" "$(gate tests/test_pagination.py)" ALLOWED
cp "$FIX/repro_check.py" tests/test_pagination.py
check "the reproduction is RED against the bug" "$(red_green)" RED
diag REPRODUCING
check "validate-diagnosis accepts REPRODUCING" "$(validate_diag)" 0
check "source still BLOCKED (test exists, not yet CONFIRMED)" "$(gate pagination.py)" BLOCKED

# ---------- DIAGNOSE (hypothesis recorded; diagnose.js confirms in a live run) ----------
echo "[DIAGNOSE]"
diag DIAGNOSED
progress DIAGNOSE
check "validate-diagnosis accepts DIAGNOSED" "$(validate_diag)" 0
check "source still BLOCKED at DIAGNOSED" "$(gate pagination.py)" BLOCKED

# ---------- FIX (the gate flips diagnosis→CONFIRMED, unlocking source) ----------
echo "[FIX]"
diag CONFIRMED
progress FIX
check "validate-diagnosis accepts CONFIRMED" "$(validate_diag)" 0
check "source write now ALLOWED (CONFIRMED + reproducing test)" "$(gate pagination.py)" ALLOWED
cp "$FIX/pagination.fixed.py" pagination.py
check "the fix turns the reproduction GREEN" "$(red_green)" GREEN

# ---------- VERIFY (the counterfactual — red if the fix is reverted) ----------
echo "[VERIFY]"
cp "$FIX/pagination.py" pagination.py
check "counterfactual holds: reverted fix → RED" "$(red_green)" RED
cp "$FIX/pagination.fixed.py" pagination.py
check "restored fix → GREEN" "$(red_green)" GREEN
diag FIXED
progress HANDOFF

# ---------- HANDOFF (/ship-fix clears the lock) ----------
echo "[HANDOFF]"
: > .sdd/ACTIVE
check ".sdd/ACTIVE is cleared on ship" "$(cat .sdd/ACTIVE)" ""
check "with no active item, source writes are ALLOWED again" "$(gate pagination.py)" ALLOWED

echo
echo "-----"
echo "passed=$pass failed=$fail"
if [ "$fail" -eq 0 ]; then echo "SMOKE PASS — the bug-lane deterministic backbone is sound."; else echo "SMOKE FAIL"; fi
[ "$fail" -eq 0 ]
