#!/usr/bin/env bash
# PreToolUse (Bash): close the Bash escape hatch around the write gates
# (audit §3.2). While the active item is SOURCE-LOCKED — a feature whose spec
# is not FINALIZED, or a bug whose diagnosis is not CONFIRMED / that has no
# reproducing test (i.e. the combined condition of block-source-before-
# finalized.sh + require-reproducing-test.sh) — block Bash commands that match
# common write-to-source patterns:
#   - `>` / `>>` redirections (incl. heredoc-fed `cat > file <<EOF`)
#   - `tee [-a] <file>`
#   - `sed -i` (in-place edit)
#   - `patch` (targets come from the diff body — undeterminable, always a write)
#   - `cp` / `mv` / `install` destinations
# …whenever the resolved target is outside .sdd/ and tests/ (scratch space
# /dev/*, /tmp/*, $TMPDIR stays usable).
#
# This is deliberately CONSERVATIVE pattern matching, not a shell parser:
#   - false-ALLOW is acceptable: exotic quoting, eval, $(...) indirection, or
#     interpreter one-liners (python -c "open(...,'w')") can slip through.
#     The Write/Edit gates remain the contract; this hook closes the common,
#     cheap bypass paths.
#   - false-BLOCK of read-only commands is NOT acceptable: quoted strings are
#     handled so e.g. `grep ">" file` is never blocked.
# The block message points the agent at Write/Edit so the real gates adjudicate.
set -euo pipefail
set -f  # no globbing: we word-split untrusted command text below
# Fail CLOSED on any unexpected runtime error: exit 1 is non-blocking per the
# hooks contract (audit §3.5). Every deliberate allow below is an explicit exit 0.
trap 'echo "sdd-fleet: gate script errored unexpectedly — failing closed" >&2; exit 2' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
slug=$(resolve_active)

# No active item → nothing is locked. Bootstrap-friendly.
[ -n "$slug" ] || exit 0

# Determine whether source is locked — mirrors the Write/Edit gate pair so the
# two surfaces always agree.
lane=$(resolve_lane "$slug")
locked=0
if [ "$lane" = "bug" ]; then
  # Bug lane: source unlocks on CONFIRMED *and* an existing reproducing test
  # (block-source-before-finalized AND require-reproducing-test combined).
  dstatus=$(read_diagnosis_status "$slug")
  if [ "$dstatus" != "CONFIRMED" ]; then locked=1
  elif ! tests_exist; then locked=1; fi
else
  status=$(read_spec_status "$slug")
  [ "$status" = "FINALIZED" ] || locked=1
fi
[ "$locked" -eq 1 ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Block with feedback the model can act on. $1 = the offending target.
block() {
  echo "sdd-fleet: Bash write to '${1}' blocked — the active ${lane} '${slug}' is source-locked. Use the Write/Edit tools instead so the SDD gates can adjudicate (.sdd/ and tests/ remain writable)." >&2
  echo "Refused command: ${cmd}" >&2
  exit 2
}

# Return 0 when a write target is harmless while locked: fd duplications and
# process substitution (not file paths), /dev//tmp/$TMPDIR scratch, and the
# always-writable .sdd/ + tests/ workspaces. `..` traversal is rejected inside
# path_in_sdd/path_in_tests (audit §3.1), so it cannot smuggle a safe prefix.
target_is_safe() {
  local t="$1"
  case "$t" in
    ""|"&"*|"("*) return 0 ;;
    /dev/*|/tmp/*|/private/tmp/*) return 0 ;;
  esac
  if [ -n "${TMPDIR:-}" ]; then
    case "$t" in "${TMPDIR%/}/"*) return 0 ;; esac
  fi
  if path_in_sdd "$t"; then return 0; fi
  if path_in_tests "$t"; then return 0; fi
  return 1
}

# ---- Pass 1: redirections with QUOTED targets (before quotes are stripped) ----
# e.g. cat > "src/app.py"   /   cat > 'src/app.py'
qt=$( { printf '%s' "$cmd" | grep -oE '>>?[[:space:]]*("[^"]+"|'"'"'[^'"'"']+'"'"')' || true; } \
       | sed -E 's/^>>?[[:space:]]*//' | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' )
if [ -n "$qt" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    target_is_safe "$t" || block "$t"
  done <<< "$qt"
fi

# ---- Pass 2: unquoted redirection targets ----
# Strip quoted strings first so a ">" inside a pattern/argument (e.g.
# `grep ">" file`, `awk '$1 > 2'`) can never look like a redirection.
stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
ut=$( { printf '%s' "$stripped" | grep -oE '[0-9]*>>?[[:space:]]*[^[:space:];|&<>)]+' || true; } \
       | sed -E 's/^[0-9]*>>?[[:space:]]*//' )
if [ -n "$ut" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    target_is_safe "$t" || block "$t"
  done <<< "$ut"
fi

# ---- Pass 3: write-y commands (tee, sed -i, patch, cp/mv/install) ----
# Analyzed per simple-command segment. Quote CHARACTERS are removed (content
# kept) so quoted targets stay visible as tokens; segments are split on
# ; | & and newlines. Wrapper words (env assignments, sudo, command, …) are
# skipped so `sudo cp x /etc/y` is still seen as cp.
check_segment() {
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;                                  # FOO=bar prefix
      sudo|command|env|exec|nohup|time|nice) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  local cmd0 a
  cmd0=$(basename "$1"); shift
  case "$cmd0" in
    tee)
      # every non-flag argument is a write target
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        target_is_safe "$a" || block "$a"
      done
      ;;
    cp|mv|install)
      # destination = last non-flag argument (conservative: misses -t form →
      # false-allow, never false-block)
      local dest=""
      for a in "$@"; do
        case "$a" in -*) ;; *) dest="$a" ;; esac
      done
      if [ -n "$dest" ]; then
        target_is_safe "$dest" || block "$dest"
      fi
      ;;
    sed)
      # only in-place sed is a write; the first non-flag arg is the sed
      # expression, the rest are the files edited in place
      local inplace=0 first_seen=0
      for a in "$@"; do
        case "$a" in -i*|--in-place*) inplace=1 ;; esac
      done
      [ "$inplace" -eq 1 ] || return 0
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        if [ "$first_seen" -eq 0 ]; then first_seen=1; continue; fi
        target_is_safe "$a" || block "$a"
      done
      ;;
    patch)
      block "(patch target — taken from the diff body)"
      ;;
  esac
  return 0
}

segments=$(printf '%s' "$cmd" | tr -d "\"'" | tr ';|&' '\n\n\n')
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # shellcheck disable=SC2086  # intentional word-split (set -f is on)
  check_segment $seg
done <<< "$segments"

exit 0
