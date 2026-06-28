#!/usr/bin/env bash
# Severity-rubric drift test (audit §4, agents minor). The blocker/major/minor
# table is defined in skills/review-rubric/SKILL.md and duplicated verbatim in
# agents/architect.md and agents/qa.md as belt-and-suspenders for non-workflow
# paths. This test extracts the table from all three and fails if they drift.
# Whitespace is normalized before diffing (column padding may differ; words and
# pipes may not). bash 3.2 compatible.
# Run: bash scripts/rubric-drift.test.sh   (exit 0 = all three agree)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=(
  "$root/skills/review-rubric/SKILL.md"
  "$root/agents/architect.md"
  "$root/agents/qa.md"
)

pass=0; fail=0

# Extract the severity table: from the '| Severity | Definition | Gate effect |'
# header row through the last contiguous '|' row, then normalize whitespace
# (collapse runs, trim edges) so column padding differences don't count as drift.
extract_rubric() {
  awk '
    /^\|[[:space:]]*Severity[[:space:]]*\|/ { grab = 1 }
    grab && /^\|/ { print; next }
    grab { exit }
  ' "$1" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

ref_file="${files[0]}"
ref=$(extract_rubric "$ref_file")

# The anchor itself must exist in the canonical source, and the table must
# carry all three severities — otherwise the extraction silently went stale.
if [ -z "$ref" ]; then
  printf 'FAIL %-44s no severity table found in %s\n' "anchor-present-in-skill" "$ref_file"
  fail=$((fail+1))
else
  printf 'ok   %-44s\n' "anchor-present-in-skill"
  pass=$((pass+1))
fi
for sev in blocker major minor; do
  if printf '%s\n' "$ref" | grep -q "\`$sev\`"; then
    printf 'ok   %-44s\n' "skill-table-defines-$sev"
    pass=$((pass+1))
  else
    printf 'FAIL %-44s severity row missing from %s\n' "skill-table-defines-$sev" "$ref_file"
    fail=$((fail+1))
  fi
done

# Each duplicate must match the skill's table after normalization.
for f in "${files[@]}"; do
  [ "$f" = "$ref_file" ] && continue
  name="rubric-matches-$(basename "$(dirname "$f")")/$(basename "$f")"
  got=$(extract_rubric "$f")
  if [ -z "$got" ]; then
    printf 'FAIL %-44s no severity table found in %s\n' "$name" "$f"
    fail=$((fail+1))
  elif [ "$got" = "$ref" ]; then
    printf 'ok   %-44s\n' "$name"
    pass=$((pass+1))
  else
    printf 'FAIL %-44s drifted from %s\n' "$name" "$ref_file"
    echo "--- expected (review-rubric SKILL.md, normalized)"
    printf '%s\n' "$ref"
    echo "--- got ($f, normalized)"
    printf '%s\n' "$got"
    fail=$((fail+1))
  fi
done

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
