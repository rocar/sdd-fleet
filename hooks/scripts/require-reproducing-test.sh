#!/usr/bin/env bash
# PreToolUse (Write|Edit): the inviolable reproducing-test gate for the bug lane (B7).
# When the active item is a BUG, a write to SOURCE (outside .sdd/ and outside tests/)
# is blocked (exit 2) unless BOTH:
#   (a) diagnosis.md STATUS == CONFIRMED, and
#   (b) at least one test exists under tests/.
# Writes under .sdd/ or tests/ are always allowed — the reproducing test must be
# writable before CONFIRMED. The gate is SEVERITY-INDEPENDENT: it holds even for sev0
# (severity may skip the diagnosis-confirmation workflow's rigor, never this gate).
# A forward feature (no diagnosis.md) is unaffected: resolve_lane==feature → exit 0.
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

# No active item → allow. Bootstrap-friendly.
[ -n "$slug" ] || exit 0

# Not a bug (forward feature) → this gate is inert; block-source-before-finalized
# handles the forward FINALIZED gate.
[ "$(resolve_lane "$slug")" = "bug" ] || exit 0

file_path=$(extract_file_path "$input")

# Tool call without a file/notebook path → allow (Bash has its own gate:
# guard-bash-writes.sh).
[ -n "$file_path" ] || exit 0

# Workspace (.sdd/) and test (tests/) writes are always permitted.
if path_in_sdd "$file_path" || path_in_tests "$file_path"; then
  exit 0
fi

# A source write on an active bug: require BOTH CONFIRMED and a reproducing test.
dstatus=$(read_diagnosis_status "$slug")
if [ "$dstatus" != "CONFIRMED" ]; then
  echo "sdd-fleet: active bug '${slug}' has diagnosis STATUS=${dstatus:-<none>}. No fix source may land until the root cause is CONFIRMED (run /sdd-fleet:feature-dev)." >&2
  echo "Refused write: ${file_path}" >&2
  exit 2
fi

if ! tests_exist; then
  echo "sdd-fleet: active bug '${slug}' is CONFIRMED but no reproducing test exists under tests/. A fix cannot land without a test that was red first (run /sdd-fleet:feature-dev)." >&2
  echo "Refused write: ${file_path}" >&2
  exit 2
fi

exit 0
