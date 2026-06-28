#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit): while a feature is active, block ALL
# writes outside .sdd/ — source, docs, config, anything — until the feature's
# spec.md STATUS is FINALIZED (or, for an active bug, block writes outside
# .sdd/ and tests/ until diagnosis.md is CONFIRMED).
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

# No active feature → allow. Bootstrap-friendly.
[ -n "$slug" ] || exit 0

file_path=$(extract_file_path "$input")

# Tool call without a file/notebook path → allow (Bash has its own gate:
# guard-bash-writes.sh).
[ -n "$file_path" ] || exit 0

# Anything inside .sdd/ is always permitted — that's the workspace.
if path_in_sdd "$file_path"; then
  exit 0
fi

# Bug lane (v0.5 M2 — second unlock, B8): when the active item is a bug, its source
# writes unlock on diagnosis.md STATUS==CONFIRMED, mirroring the spec FINALIZED unlock.
# A forward feature has no diagnosis.md (resolve_lane==feature), so it skips this branch
# and the FINALIZED logic below stays byte-identical. require-reproducing-test.sh layers
# the reproducing-test precondition on top, so a bug needs CONFIRMED *and* a test.
if [ "$(resolve_lane "$slug")" = "bug" ]; then
  # tests/ is always writable for a bug — the reproducing test must land at REPRODUCE,
  # BEFORE the diagnosis is CONFIRMED (and the reproducing test is itself the precondition
  # for ever reaching CONFIRMED). Mirrors require-reproducing-test.sh and AC-7; without it
  # the two PreToolUse gates AND to a deadlock at REPRODUCE.
  if path_in_tests "$file_path"; then
    exit 0
  fi
  dstatus=$(read_diagnosis_status "$slug")
  if [ "$dstatus" = "CONFIRMED" ]; then
    exit 0
  fi
  echo "sdd-fleet: active bug '${slug}' has diagnosis STATUS=${dstatus:-<none>}. Source writes are blocked until the root cause is CONFIRMED (run /sdd-fleet:feature-dev)." >&2
  echo "Refused write: ${file_path}" >&2
  exit 2
fi

status=$(read_spec_status "$slug")

if [ -z "$status" ]; then
  echo "sdd-fleet: spec.md missing or has no STATUS line for active feature '${slug}'. Source writes blocked until the spec is FINALIZED." >&2
  exit 2
fi

if [ "$status" != "FINALIZED" ]; then
  echo "sdd-fleet: active feature '${slug}' has spec STATUS=${status}. Source writes blocked until STATUS=FINALIZED. Use /sdd-fleet:feature-dev once the review gate passes." >&2
  echo "Refused write: ${file_path}" >&2
  exit 2
fi

exit 0
