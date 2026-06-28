#!/usr/bin/env bash
# scripts/link-sweep.test.sh — the one-time legacy-link sweep. It drives the REAL
# link-discipline hook over an existing .sdd/ corpus, so the proof is: it finds what the
# gate would block (wikilinks at every tier; repo-escaping relative links at repo tier),
# skips what the gate skips (escaping links at the workspace/vault tier), and its verdict
# AGREES with a direct hook invocation (single-source). Skip-proof: a known-dirty fixture
# must report a non-zero count (positive control), and a missing script is a counted FAIL.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$DIR/link-sweep.sh"
HOOK="$DIR/../hooks/scripts/link-discipline.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-38s = %s\n' "$1" "$2";
       else fail=$((fail+1)); printf 'FAIL %-38s want[%s] got[%s]\n' "$1" "$3" "$2"; fi; }
ok() { pass=$((pass+1)); printf 'ok   %-38s %s\n' "$1" "${2:-}"; }
bad(){ fail=$((fail+1)); printf 'FAIL %-38s %s\n' "$1" "${2:-}"; }
run_sweep() { out="$(bash "$SWEEP" "$1" 2>&1)"; rc=$?; }
vcount() { printf '%s' "$1" | sed -n 's/.*violations=\([0-9]*\).*/\1/p' | tail -1; }
hook_rc() { # <root> <rel> <file>  -> sets $hrc to the hook's exit code for that file
  local pl; pl="$(jq -nc --arg fp "$2" --rawfile c "$3" '{tool_input:{file_path:$fp,content:$c}}')"
  printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" >/dev/null 2>&1; hrc=$?
}

if [ -f "$SWEEP" ]; then ok "script-present"; else bad "script-present" "$SWEEP missing"; fi

# ---- dirty repo-tier fixture (no .gitmodules → standalone → Rule 2 applies) ----
d="$work/dirty"; mkdir -p "$d/.sdd/feat"
printf 'see [[some-page]] for the details\n'           > "$d/.sdd/feat/wl.md"
printf 'ref [x](../../../../etc/passwd.md) escapes\n'  > "$d/.sdd/feat/esc.md"
printf 'clean link [a](./local.md)\n'                  > "$d/.sdd/feat/ok.md"
run_sweep "$d"
eq "dirty-exit1"            "$rc" "1"
eq "dirty-count2"          "$(vcount "$out")" "2"
printf '%s' "$out" | grep -q 'wl.md'  && ok "dirty-lists-wikilink"   || bad "dirty-lists-wikilink"   "$out"
printf '%s' "$out" | grep -q 'esc.md' && ok "dirty-lists-escape"     || bad "dirty-lists-escape"     "$out"
printf '%s' "$out" | grep -q 'ok.md'  && bad "clean-file-not-flagged" "ok.md flagged" || ok "clean-file-not-flagged"

# ---- clean fixture: exit 0 ----
c="$work/clean"; mkdir -p "$c/.sdd/feat"
printf 'clean [a](./local.md) and [b](sub/c.md)\n' > "$c/.sdd/feat/ok.md"
run_sweep "$c"
eq "clean-exit0"   "$rc" "0"
eq "clean-count0" "$(vcount "$out")" "0"

# ---- workspace/vault tier (.gitmodules at root): Rule 2 skipped, Rule 1 still enforced ----
w="$work/ws"; mkdir -p "$w/.sdd/_epic/x"; : > "$w/.gitmodules"
printf 'vault down-link [m](../../../../member/spec.md) — legal at vault tier\n' > "$w/.sdd/_epic/x/esc.md"
printf 'bad [[wikilink]] at any tier\n'                                          > "$w/.sdd/_epic/x/wl.md"
run_sweep "$w"
eq "ws-exit1"             "$rc" "1"
eq "ws-count1"           "$(vcount "$out")" "1"
printf '%s' "$out" | grep -q 'wl.md'  && ok "ws-wikilink-reported"  || bad "ws-wikilink-reported"  "$out"
printf '%s' "$out" | grep -q 'esc.md' && bad "ws-escape-skipped" "esc.md flagged at vault tier" || ok "ws-escape-skipped"

# ---- agreement (single-source): sweep verdict == direct hook verdict ----
hook_rc "$w" ".sdd/_epic/x/wl.md"  "$w/.sdd/_epic/x/wl.md";  eq "agree-hook-blocks-wikilink"  "$hrc" "2"
hook_rc "$w" ".sdd/_epic/x/esc.md" "$w/.sdd/_epic/x/esc.md"; eq "agree-hook-allows-ws-escape" "$hrc" "0"

# ---- no corpus: nothing to sweep, exit 0 ----
n="$work/nocorp"; mkdir -p "$n"
run_sweep "$n"
eq "nocorpus-exit0" "$rc" "0"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
