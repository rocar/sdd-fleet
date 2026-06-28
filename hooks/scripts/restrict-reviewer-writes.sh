#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit): during REVIEW and CHANGE_REVIEW phases,
# restrict all writes to the active feature's .sdd/<slug>/ workspace. Implements
# the phase-based interpretation of "reviewers may not write outside .sdd/" —
# see the build plan's Resolved Decision 1 for rationale.
set -euo pipefail
# Fail CLOSED on any unexpected runtime error: exit 1 is non-blocking per the
# hooks contract (audit §3.5). Every deliberate allow below is an explicit exit 0.
trap 'echo "sdd-fleet: gate script errored unexpectedly — failing closed" >&2; exit 2' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

input=$(cat)
slug=$(resolve_active)
[ -n "$slug" ] || exit 0

# Workflow reviewer subagents declare tools=[Read,Grep,Glob] (no Write/Edit)
# at AgentDefinition level, so writes are physically impossible. While the
# workflow-in-flight marker is LIVE (present AND non-empty — it carries the
# dispatching run's id), this hook skips to avoid duplicate enforcement against
# the scribe (which DOES need Write/Edit inside .sdd/). The scribe releases the
# marker by emptying it (it has no Bash to rm), so an empty marker means
# "released" and the hook re-engages; the Stop-hook reaper deletes it.
if [ -s ".sdd/${slug}/.workflow-in-flight" ]; then
  exit 0
fi

phase=$(read_progress_field "$slug" PHASE)
case "$phase" in
  REVIEW|CHANGE_REVIEW) ;;
  *) exit 0 ;;
esac

file_path=$(extract_file_path "$input")
[ -n "$file_path" ] || exit 0

if path_in_active_sdd "$file_path" "$slug"; then
  exit 0
fi

echo "sdd-fleet: phase is ${phase} for feature '${slug}'. Writes are restricted to .sdd/${slug}/ during review. Refused: ${file_path}" >&2
exit 2
