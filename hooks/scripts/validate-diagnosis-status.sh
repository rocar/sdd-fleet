#!/usr/bin/env bash
# PostToolUse (Write|Edit): when a write touches a .sdd/<slug>/diagnosis.md, verify
# the STATUS line is present and valid (one of the five bug-lane tokens), and that
# the required section headings from the sdd-diagnosis-template skill are present.
#
# The bug-lane analog of validate-spec-status.sh. Keyed strictly on
# basename==diagnosis.md under .sdd/ — feature dirs have no diagnosis.md and bug
# dirs have no spec.md, so the two validators never cross-fire (v0.5 M0 / AC-10).
set -euo pipefail
# Fail CLOSED on any unexpected runtime error (audit §3.5); deliberate allows
# below are explicit exit 0.
trap 'echo "sdd-fleet: gate script errored unexpectedly — failing closed" >&2; exit 2' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
file_path=$(extract_file_path "$input")
[ -n "$file_path" ] || exit 0

base=$(basename "$file_path")
[ "$base" = "diagnosis.md" ] || exit 0

# Only validate diagnosis.md files that live under .sdd/.
case "$file_path" in
  *.sdd/*) ;;
  *) exit 0 ;;
esac

[ -f "$file_path" ] || exit 0

status_line=$(head -n30 "$file_path" | grep -m1 "^STATUS:" || true)
if [ -z "$status_line" ]; then
  echo "sdd-fleet: diagnosis.md missing STATUS line. The first non-blank section (within the first 30 lines) must contain 'STATUS: REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED'." >&2
  exit 2
fi

status_value=$(printf '%s' "$status_line" | sed -E 's/^STATUS:[[:space:]]*//' | tr -d '\r ')
case "$status_value" in
  REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED) ;;
  *)
    echo "sdd-fleet: diagnosis.md STATUS value '${status_value}' is invalid. Must be one of: REPORTED, REPRODUCING, DIAGNOSED, CONFIRMED, FIXED." >&2
    exit 2
    ;;
esac

required_sections=(
  "## Symptom + reproduction steps"
  "## Root-cause hypothesis"
  "## Blast radius"
  "## Fix strategy"
)
missing=()
for s in "${required_sections[@]}"; do
  if ! grep -Fq "$s" "$file_path"; then
    missing+=("$s")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "sdd-fleet: diagnosis.md is missing required section heading(s):" >&2
  for s in "${missing[@]}"; do
    echo "  - ${s}" >&2
  done
  echo "Reference: skill sdd-diagnosis-template." >&2
  exit 2
fi

exit 0
