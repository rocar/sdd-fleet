#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — registry append-only / immutability gate (audit G1).
# A published contract version (registry/<contract>/<semver>.json) is IMMUTABLE: once it
# exists, no Write/Edit may overwrite it. Recovery is forward-only (design §03): a defective
# contract rolls forward to a NEW version; you never mutate a published one. Publishing a NEW
# version file is allowed here — block-publish-before-handoff.sh + cdc-gate.sh govern WHEN and
# WHETHER a publish may happen; this gate only forbids overwriting an existing version.
#
# INERT (exit 0): a non-registry write; an expectations write (registry/<c>/expectations/…); a
# NEW version file (does not yet exist); no file path. Fail closed (exit 2): a '..' path, jq
# missing, an unparseable payload, or any unexpected error.
set -euo pipefail
trap 'echo "sdd-fleet: registry-append-only errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

# jq is required UNCONDITIONALLY: registry immutability is not scoped to an active feature, so
# the feature-conditional require_jq would fail OPEN at the workspace/registry level. Fail closed
# on a missing tool instead (mirrors link-discipline.sh).
command -v jq >/dev/null 2>&1 || {
  echo "sdd-fleet: registry-append-only requires jq — failing closed. Install jq (brew install jq / apt install jq)." >&2
  exit 2
}

input=$(cat)
file=$(extract_file_path "$input")            # jq in $(): an unparseable payload → ERR → exit 2
[ -n "$file" ] || exit 0
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing registry path containing '..': $file" >&2; exit 2;; esac

# Normalize to a project-root-relative path (mirror block-publish-before-handoff.sh).
rel="$file"; rel="${rel#./}"
phys="$(pwd -P 2>/dev/null || pwd)"
case "$rel" in
  "$PWD"/*)  rel="${rel#"$PWD"/}";;
  "$phys"/*) rel="${rel#"$phys"/}";;
esac
case "$rel" in registry/*) ;; *) exit 0;; esac
inner="${rel#registry/}"            # "<contract>/<semver>.json" OR "<contract>/expectations/<x>.json"
case "$inner" in
  */*/*) exit 0;;                   # deeper than <contract>/<file> → expectations etc. → not a published version
  */*.json) ;;                      # a <contract>/<semver>.json publish
  *) exit 0;;
esac

# Immutable: a published version file may not be overwritten. A new version file (absent) passes.
if [ -e "$rel" ]; then
  echo "sdd-fleet: ${file} already exists — published contract versions are IMMUTABLE (append-only registry)." >&2
  echo "Recovery is forward-only: roll the defect forward to a NEW version (bump the semver); never overwrite a published version." >&2
  echo "Refused write: ${file}" >&2
  exit 2
fi
exit 0
