#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — decision [D-a]. The ship chokepoint: when a write
# transitions PROGRESS.md to PHASE: HANDOFF (set by /sdd-fleet:pr-review just before devops
# raises the PR), scan the feature git-diff for UNDECLARED cross-service edges and block
# (exit 2) if any. The scan logic is scripts/dependency-check.sh; this hook only resolves
# the chokepoint + the diff.
#
# INERT (exit 0): not a PROGRESS.md→HANDOFF write; no active item; no service.json at root;
# git unavailable / not a work tree / no base (the deliberate fail-open boundary for standalone
# repos). Fail closed (exit 2) on a '..' path, an unreadable .sdd/ACTIVE, or any unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: dependency-gate errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
file=$(extract_file_path "$input")
[ -n "$file" ] || exit 0
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing path containing '..': $file" >&2; exit 2;; esac

# Only the PROGRESS.md → HANDOFF transition is the chokepoint.
[ "$(basename "$file")" = "PROGRESS.md" ] || exit 0
content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')
printf '%s' "$content" | grep -Eq 'PHASE:[[:space:]]*HANDOFF' || exit 0

slug=$(resolve_active)
[ -n "$slug" ] || exit 0
[ -f service.json ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Resolve a base ref: merge-base with the default branch, else HEAD (→ empty diff → inert).
base=""
for b in main master; do
  if git rev-parse --verify "$b" >/dev/null 2>&1; then
    base=$(git merge-base HEAD "$b" 2>/dev/null || true); [ -n "$base" ] && break
  fi
done
[ -n "$base" ] || base=$(git rev-parse HEAD 2>/dev/null || true)
[ -n "$base" ] || exit 0
diff=$(git diff "$base" 2>/dev/null || true)
[ -n "$diff" ] || exit 0

dfile=$(mktemp); printf '%s' "$diff" > "$dfile"
res=$(bash "$DIR/../../scripts/dependency-check.sh" --service service.json --registry registry --diff "$dfile" 2>/dev/null || true)
rm -f "$dfile"
status=$(printf '%s' "$res" | jq -r '.status // "clean"' 2>/dev/null || printf clean)
if [ "$status" = "blocked" ]; then
  echo "sdd-fleet: HANDOFF blocked for '${slug}' — the diff introduces a cross-service edge not declared in service.json:" >&2
  printf '%s\n' "$res" | jq -r '(.undeclared[]? | "  undeclared client call to contract: \(.)"), (.dangling[]? | "  consumes[] edge with no published contract: \(.)")' >&2 2>/dev/null || true
  echo "Declare the edge in service.json consumes[] (and publish the contract) before raising the PR." >&2
  exit 2
fi
exit 0
