#!/usr/bin/env bash
# scripts/next-story.sh — deterministic resolver for the DEVELOPER PULL entry at the
# workspace tier: "which story of this epic is ready to start NOW?" (ADR-0001
# anticipated it as sugar over the conductor's core; ADR-0002 ratified it.)
#
# It is the epic-tier analog of next-feature.sh (resolve -> signal -> let the
# dispatcher start the work) and reuses the conductor's EXACT machinery — the live
# Jira snapshot via the SDD_JIRA_ADAPTER seam and the pure set-logic frontier
# (ready-frontier.sh: NOT_STARTED + every consumed contract published in the
# registry) — so the pull entry and the autonomous conductor can NEVER disagree
# about readiness. Re-resolves from LIVE state on every call; no cache, no index.
#
# NOT a second conductor: READ-ONLY against Jira (jira-snapshot only — it never
# transitions a story, never creates one, never reads plan.md/contracts.md; the
# vault is touched only to resolve the Jira epic key from JIRA_LINK.md). The Jira
# status advance happens when the developer actually starts the story
# (/sdd-fleet:jira-story <key> syncs PHASE: SPEC). MODELLESS + no clock: the caller
# injects --now (the adapter contract requires it); no clock read, no randomness.
#
# Usage: next-story.sh <epic-slug> --now <iso8601> [--registry <dir>]
# Run from the WORKSPACE root (reads .sdd/_epic/<slug>/JIRA_LINK.md + registry/).
# Output: exactly one JSON line on stdout (status carries the outcome):
#   {"status":"next","epic","jira_epic","story","key","repo","ready":<n>,"done":<d>,"total":<t>}
#       the frontier's sorted-first story — no prioritization policy, ever
#   {"status":"waiting","not_started":<n>,"in_flight":<m>,"done":<d>,"total":<t>,...}
#       nothing ready now; blocked stories may be released by an in-flight handoff
#   {"status":"complete","done":<d>,"total":<t>,...}    every materialised story done
#   {"status":"empty",...}                              the epic has no stories in Jira
#   {"status":"not-materialised",...}                   no JIRA_LINK.md epic key (run epic-ratify)
#   {"status":"deferred","reason":"no-jira-adapter"|"jira-adapter-unconfigured",...}
# Exit 0 on every resolved status above; exit 1 on snapshot/frontier errors;
# exit 2 on bad arguments or missing jq (fail closed).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/_lib.sh
. "$DIR/../hooks/scripts/_lib.sh"
FRONTIER="$DIR/ready-frontier.sh"

command -v jq >/dev/null 2>&1 || {
  echo "next-story: jq is required — failing closed. Install jq (brew install jq / apt install jq)." >&2
  exit 2
}

slug="${1:-}"
case "$slug" in
  ""|--*) echo "next-story: usage: next-story.sh <epic-slug> --now <iso8601> [--registry <dir>]" >&2; exit 2 ;;
  */*|*..*) echo "next-story: refusing slug with path separators / traversal: '$slug'" >&2; exit 2 ;;
esac
shift
now="" registry="registry"
while [ $# -gt 0 ]; do
  case "$1" in
    --now)      now="${2:-}";      shift 2 ;;
    --registry) registry="${2:-}"; shift 2 ;;
    *) echo "next-story: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$now" ] || { echo "next-story: --now <iso8601> is required (the caller supplies it; the script reads no clock)." >&2; exit 2; }

epicdir=".sdd/_epic/${slug}"
linkf="${epicdir}/JIRA_LINK.md"
# Resolve ONLY the external epic key from the materialisation receipt (exactly as
# conductor-tick does). The story set + edges come live from the adapter.
key=""
if [ -f "$linkf" ]; then
  key="$( { grep -m1 '^JIRA_EPIC:' "$linkf" 2>/dev/null || true; } | sed -E 's/^JIRA_EPIC:[[:space:]]*//' | tr -d '\r' | sed -E 's/[[:space:]]+$//')"
fi
if [ -z "$key" ]; then
  printf '{"status":"not-materialised","epic":"%s"}\n' "$slug"
  exit 0
fi

ADAPTER="${SDD_JIRA_ADAPTER:-$DIR/jira-adapter.sh}"
if [ ! -f "$ADAPTER" ]; then
  printf '{"status":"deferred","reason":"no-jira-adapter","epic":"%s"}\n' "$slug"
  exit 0
fi

snap="$(bash "$ADAPTER" jira-snapshot --epic-key "$key" --now "$now" 2>/dev/null || true)"
case "$snap" in
  *'"status":"unconfigured"'*) printf '{"status":"deferred","reason":"jira-adapter-unconfigured","epic":"%s"}\n' "$slug"; exit 0 ;;
esac
if [ -z "$snap" ] || ! printf '%s' "$snap" | jq -e '.stories' >/dev/null 2>&1; then
  printf '{"status":"snapshot-error","epic":"%s"}\n' "$slug"
  exit 1
fi

total="$(printf '%s' "$snap" | jq '.stories | length')"
if [ "$total" -eq 0 ]; then
  jq -cn --arg epic "$slug" --arg jira_epic "$key" '{status:"empty",epic:$epic,jira_epic:$jira_epic}'
  exit 0
fi

# Pure set logic — the SAME frontier core the conductor uses; never re-derived here.
frontier="$(printf '%s' "$snap" | bash "$FRONTIER" --registry "$registry" 2>/dev/null || true)"
if ! printf '%s' "$frontier" | jq -e 'type=="array"' >/dev/null 2>&1; then
  printf '{"status":"frontier-error","epic":"%s"}\n' "$slug"
  exit 1
fi

ready_n="$(printf '%s' "$frontier" | jq 'length')"
done_n="$(printf '%s' "$snap" | jq '[.stories[] | select((.status | ascii_downcase) == "done")] | length')"
notstarted_n="$(printf '%s' "$snap" | jq '[.stories[] | select(.status == "NOT_STARTED")] | length')"

if [ "$ready_n" -gt 0 ]; then
  # The frontier is sorted/unique — the first id is the deterministic pick.
  first="$(printf '%s' "$frontier" | jq -r '.[0]')"
  printf '%s' "$snap" | jq -c --arg epic "$slug" --arg jira_epic "$key" --arg id "$first" \
    --argjson ready "$ready_n" --argjson done "$done_n" --argjson total "$total" '
    (.stories[] | select(.id == $id)) as $s |
    {status:"next", epic:$epic, jira_epic:$jira_epic,
     story:$id, key:($s.key // ""), repo:($s.repo // ""),
     ready:$ready, done:$done, total:$total}'
  exit 0
fi

if [ "$done_n" -eq "$total" ]; then
  jq -cn --arg epic "$slug" --arg jira_epic "$key" --argjson done "$done_n" --argjson total "$total" \
    '{status:"complete",epic:$epic,jira_epic:$jira_epic,done:$done,total:$total}'
  exit 0
fi

in_flight=$((total - done_n - notstarted_n))
jq -cn --arg epic "$slug" --arg jira_epic "$key" \
  --argjson ns "$notstarted_n" --argjson inf "$in_flight" --argjson done "$done_n" --argjson total "$total" \
  '{status:"waiting",epic:$epic,jira_epic:$jira_epic,not_started:$ns,in_flight:$inf,done:$done,total:$total}'
exit 0
