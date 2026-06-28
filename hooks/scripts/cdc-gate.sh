#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — decision [D-c]. A write that PUBLISHES
# registry/<contract>/<semver>.json must satisfy EVERY registered consumer expectation, else
# block (exit 2). The satisfies check is scripts/cdc-check.sh; this hook resolves the publish
# chokepoint and runs it on the written content.
#
# INERT (exit 0): non-registry write; an expectations write (registry/<c>/expectations/…, not a
# publish); empty content. Fail closed (exit 2) on a '..' path, malformed published content, an
# unreadable expectation, or any unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: cdc-gate errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
file=$(extract_file_path "$input")
[ -n "$file" ] || exit 0
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing registry path containing '..': $file" >&2; exit 2;; esac

# Normalize to a project-root-relative path.
rel="$file"; rel="${rel#./}"
phys="$(pwd -P 2>/dev/null || pwd)"
case "$rel" in
  "$PWD"/*)  rel="${rel#"$PWD"/}";;
  "$phys"/*) rel="${rel#"$phys"/}";;
esac
case "$rel" in registry/*) ;; *) exit 0;; esac
inner="${rel#registry/}"            # "<contract>/<semver>.json" OR "<contract>/expectations/<x>.json"
case "$inner" in
  */*/*) exit 0;;                   # deeper than <contract>/<file> → expectations etc. → not a publish
  */*.json) contract="${inner%%/*}";;
  *) exit 0;;
esac

content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')
[ -n "$content" ] || exit 0
vf=$(mktemp); printf '%s' "$content" > "$vf"
if ! jq -e . "$vf" >/dev/null 2>&1; then
  rm -f "$vf"; echo "sdd-fleet: published contract content is not valid JSON — failing closed: $file" >&2; exit 2
fi
res=$(bash "$DIR/../../scripts/cdc-check.sh" --contract "$contract" --version-file "$vf" --registry registry 2>/dev/null) || {
  rm -f "$vf"; echo "sdd-fleet: consumer-driven contract check could not run — failing closed for $file" >&2; exit 2
}
rm -f "$vf"
status=$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null || printf '')
case "$status" in
  satisfies) exit 0;;
  violates)
    echo "sdd-fleet: publishing $file violates registered consumer expectations:" >&2
    printf '%s\n' "$res" | jq -r '.unsatisfied[]? | "  \(.consumer): \(.reason)"' >&2 2>/dev/null || true
    exit 2;;
  *)
    echo "sdd-fleet: cdc-check returned no verdict — failing closed for $file" >&2; exit 2;;
esac
