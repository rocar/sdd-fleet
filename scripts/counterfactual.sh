#!/usr/bin/env bash
# Deterministic counterfactual check for CHANGE_REVIEW (audit A3).
#
# The design draws the counterfactual as a Layer-1 code gate (▣): "would each test
# FAIL if the change is reverted?" — a test that stays green on revert proves
# nothing. Today qa (the model) performs the git stash AND judges the red/green
# delta. This script moves the VERDICT into code: it reverts ONLY the coder's
# source change (keeping the qa-authored tests), runs the suite, and decides —
# the model narrates, this script decides. pr-review drives it.
#
# Suite-level (not per-test): if the suite was green and goes red on revert, the
# change is load-bearing (PASS); if it stays green, the tests are decorative
# (FAIL). The fully fail-closed hook form rides the CHANGE_REVIEW workflow port
# (Phase 2); this is the deterministic engine that port will call.
#
# Exit: 0 pass · 1 fail (decorative) · 2 error · 3 skip (cannot run). The
# SDD_FLEET_COUNTERFACTUAL: stdout line is the machine contract.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || { printf 'SDD_FLEET_COUNTERFACTUAL: {"verdict":"error","reason":"cwd"}\n'; exit 2; }

emit() { printf 'SDD_FLEET_COUNTERFACTUAL: %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { emit '{"verdict":"skip","reason":"no-git"}'; exit 3; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { emit '{"verdict":"skip","reason":"not-a-repo"}'; exit 3; }

# Test command: explicit override wins; else detect by stack (mirrors stop-tests).
test_cmd="${SDD_FLEET_TEST_CMD:-}"
if [ -z "$test_cmd" ]; then
  if [ -f package.json ]; then test_cmd="npm test --silent"
  elif [ -f pytest.ini ] || [ -f pyproject.toml ] || [ -d tests ]; then test_cmd="pytest -q"
  elif [ -f Makefile ]; then test_cmd="make test"
  else emit '{"verdict":"skip","reason":"no-test-command"}'; exit 3; fi
fi

# Changed SOURCE files = tracked modifications + untracked, minus tests/ and .sdd/.
changed=$( { git diff --name-only HEAD 2>/dev/null || true; git ls-files --others --exclude-standard 2>/dev/null || true; } | sort -u )
src=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in tests/*|*/tests/*|.sdd/*|*/.sdd/*) continue ;; esac
  src+=( "$f" )
done <<EOF
$changed
EOF

[ "${#src[@]}" -gt 0 ] || { emit '{"verdict":"skip","reason":"no-source-change"}'; exit 3; }

# Recovery snapshot of the full working tree (audit trail + manual recovery ref).
snapshot=$(git stash create 2>/dev/null || true)

# Baseline: post-implementation, the suite must currently be green for the
# counterfactual to mean anything.
if ! eval "$test_cmd" >/dev/null 2>&1; then
  emit "{\"verdict\":\"skip\",\"reason\":\"baseline-red\",\"snapshot\":\"${snapshot}\"}"
  exit 3
fi

# Revert ONLY the source change (recoverable), keeping the tests in place.
if ! git stash push --include-untracked --quiet -- "${src[@]}" 2>/dev/null; then
  emit "{\"verdict\":\"error\",\"reason\":\"stash-failed\",\"snapshot\":\"${snapshot}\"}"
  exit 2
fi

rc=0; eval "$test_cmd" >/dev/null 2>&1 || rc=$?

# Restore the source change. If pop fails, surface the manual recovery ref.
if ! git stash pop --quiet 2>/dev/null; then
  emit "{\"verdict\":\"error\",\"reason\":\"restore-failed — recover with: git stash list / git stash apply ${snapshot}\",\"snapshot\":\"${snapshot}\"}"
  exit 2
fi

if [ "$rc" -ne 0 ]; then
  emit "{\"verdict\":\"pass\",\"reverted_files\":${#src[@]},\"snapshot\":\"${snapshot}\"}"
  exit 0
fi
emit "{\"verdict\":\"fail\",\"reason\":\"suite-green-after-revert\",\"reverted_files\":${#src[@]},\"snapshot\":\"${snapshot}\"}"
exit 1
