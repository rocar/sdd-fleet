#!/usr/bin/env bash
# scripts/ready-frontier.sh — the PURE set-logic core of the conductor.
#
# Reads a story set on stdin and emits the READY frontier as one sorted/unique
# JSON array of story ids on stdout. A story is ready iff:
#   - status == "NOT_STARTED"  (never re-dispatch an already-dispatched story), AND
#   - every token in consumes[] is published NOW (a registry/<c>/<semver>.json
#     exists whose major matches — the published_has predicate in _lib.sh, shared
#     verbatim with the dependency gate so the two never disagree).
#
# It is a pure function of (stdin, --registry): NO clock, NO randomness, NO
# creation, NO Jira call, NO vault read (plan.md/contracts.md). The conductor
# (conductor-tick.sh) does all I/O; this script only computes the set. Determinism
# and the modelless/creation-free guarantee are gated by
# scripts/conductor-modelless-lint.test.sh; the set logic by ready-frontier.test.sh.
#
# stdin:  {"stories":[{"id":"...","status":"...","consumes":["<c>@<major>", ...]}]}
# arg:    --registry <dir>   (default "registry", relative to cwd = workspace root)
# stdout: a JSON array, e.g. ["storyA","storyD"]   (empty frontier => [])
# Fails CLOSED (exit 2) on empty/invalid stdin or a missing jq — never a silent [].
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/_lib.sh
. "$DIR/../hooks/scripts/_lib.sh"

# jq is required UNCONDITIONALLY here (the frontier is not feature-scoped, so the
# feature-conditional require_jq would fail OPEN at workspace level): fail closed.
command -v jq >/dev/null 2>&1 || {
  echo "ready-frontier: jq is required — failing closed. Install jq (brew install jq / apt install jq)." >&2
  exit 2
}

registry="registry"
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) registry="${2:-}"; shift 2 ;;
    *) echo "ready-frontier: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

input="$(cat)"
[ -n "$input" ] || { echo "ready-frontier: empty stdin (expected {\"stories\":[...]})." >&2; exit 2; }
printf '%s' "$input" | jq -e . >/dev/null 2>&1 || { echo "ready-frontier: stdin is not valid JSON." >&2; exit 2; }

ready=""
# One line per story: id <TAB> status <TAB> consumes-as-compact-JSON. tojson keeps
# the array on one field (no tabs/newlines), so @tsv splitting is safe. Process
# substitution (not a heredoc) avoids nesting with the per-token read below.
while IFS=$'\t' read -r id status cons; do
  [ -n "$id" ] || continue
  [ "$status" = "NOT_STARTED" ] || continue
  all_pub=yes
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    published_has "$tok" "$registry" || { all_pub=no; break; }
  done < <(printf '%s' "${cons:-[]}" | jq -r '.[]?' 2>/dev/null)
  [ "$all_pub" = yes ] && ready="${ready}${id}
"
done < <(printf '%s' "$input" | jq -r '.stories[]? | [.id, .status, ((.consumes // []) | tojson)] | @tsv')

if [ -z "$ready" ]; then
  printf '[]\n'
else
  printf '%s' "$ready" | grep -v '^$' | jq -R . | jq -s 'sort | unique'
fi
