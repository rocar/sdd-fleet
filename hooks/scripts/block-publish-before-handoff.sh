#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — publish-ordering gate. A write that PUBLISHES
# registry/<contract>/<semver>.json is permitted ONLY when the active feature's PHASE is
# HANDOFF; otherwise block (exit 2). This proves a contract cannot reach the registry before the
# HANDOFF transition (where the blast-radius human gate fires) — so the human gate cannot be
# bypassed by publishing early. It checks ONLY the phase ordering; the consumer-expectation check
# is cdc-gate.sh's job (which runs after this, on the same publish).
#
# INERT (exit 0): non-registry write; an expectations write (registry/<c>/expectations/…, not a
# publish); no active item (the feature-flow ordering does not apply). Fail closed (exit 2) on a
# '..' path, an unreadable .sdd/ACTIVE, missing jq while active, or any unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: block-publish-before-handoff errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
file=$(extract_file_path "$input")
[ -n "$file" ] || exit 0
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing registry path containing '..': $file" >&2; exit 2;; esac

# Normalize to a project-root-relative path (mirror cdc-gate.sh).
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
  */*.json) ;;                      # a publish
  *) exit 0;;
esac

slug=$(resolve_active)
[ -n "$slug" ] || exit 0            # no active feature → the feature-flow ordering does not apply

phase=$(read_progress_field "$slug" PHASE)
if [ "$phase" = "HANDOFF" ]; then
  exit 0
fi

echo "sdd-fleet: publishing ${file} blocked — feature '${slug}' is at PHASE '${phase:-<none>}', not HANDOFF." >&2
echo "Contract publish is downstream of the human-approved HANDOFF; it must not precede it." >&2
echo "Refused write: ${file}" >&2
exit 2
