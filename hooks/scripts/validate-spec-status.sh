#!/usr/bin/env bash
# PostToolUse (Write|Edit): when a write touches a .sdd/<slug>/spec.md, verify
# the STATUS line is present and valid, and that the required section
# headings from the sdd-spec-template skill are present.
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
[ "$base" = "spec.md" ] || exit 0

# Only validate spec.md files that live under .sdd/.
case "$file_path" in
  *.sdd/*) ;;
  *) exit 0 ;;
esac

[ -f "$file_path" ] || exit 0

status_line=$(head -n30 "$file_path" | grep -m1 "^STATUS:" || true)
if [ -z "$status_line" ]; then
  echo "sdd-fleet: spec.md missing STATUS line. The first non-blank section (within the first 30 lines) must contain 'STATUS: DRAFT|IN_REVIEW|FINALIZED|BLOCKED'." >&2
  exit 2
fi

status_value=$(printf '%s' "$status_line" | sed -E 's/^STATUS:[[:space:]]*//' | tr -d '\r ')
case "$status_value" in
  DRAFT|IN_REVIEW|FINALIZED|BLOCKED) ;;
  *)
    echo "sdd-fleet: spec.md STATUS value '${status_value}' is invalid. Must be one of: DRAFT, IN_REVIEW, FINALIZED, BLOCKED." >&2
    exit 2
    ;;
esac

required_sections=(
  "## Overview"
  "## Goals"
  "## Non-goals"
  "## Behavior"
  "## Interfaces / Contracts"
  "## Constraints"
  "## Risks"
  "## Acceptance Criteria"
)
missing=()
for s in "${required_sections[@]}"; do
  if ! grep -Fq "$s" "$file_path"; then
    missing+=("$s")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "sdd-fleet: spec.md is missing required section heading(s):" >&2
  for s in "${missing[@]}"; do
    echo "  - ${s}" >&2
  done
  echo "Reference: skill sdd-spec-template." >&2
  exit 2
fi

exit 0
