#!/usr/bin/env bash
# PostToolUse (Write|Edit|NotebookEdit): a write to service.json that fails schema validation
# is blocked (exit 2). Non-service.json writes pass (exit 0). jq-missing while a service.json
# write is in flight fails closed. The schema lives in scripts/service-descriptor.sh (one home).
set -euo pipefail
trap 'echo "sdd-fleet: validate-service-descriptor errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

input=$(cat)

# Without jq we cannot parse the tool payload; if it looks like a service.json write, fail closed.
if ! command -v jq >/dev/null 2>&1; then
  case "$input" in
    *service.json*) echo "sdd-fleet: jq is required to validate a service.json write — failing closed. Install jq (brew install jq / apt install jq)." >&2; exit 2;;
    *) exit 0;;
  esac
fi

file=$(extract_file_path "$input")
[ -n "$file" ] || exit 0
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing service.json path containing '..': $file" >&2; exit 2;; esac
[ "$(basename "$file")" = "service.json" ] || exit 0
[ -f "$file" ] || exit 0   # PostToolUse, but nothing on disk to validate (e.g. a delete) → allow

res=$(bash "$DIR/../../scripts/service-descriptor.sh" validate "$file" 2>/dev/null) || {
  echo "sdd-fleet: service.json failed schema validation — $res" >&2
  echo "Refused write: $file" >&2
  exit 2
}
exit 0
