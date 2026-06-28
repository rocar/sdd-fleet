#!/usr/bin/env bash
# scripts/conductor-tick.sh — ONE tick of the modelless estate conductor.
#
# The level-triggered reconciler for a single epic: read the live Jira story set
# + the contract registry FRESH, compute the ready frontier as PURE SET LOGIC
# (ready-frontier.sh), and advance each ready story NOT_STARTED -> DISPATCHED via
# the Jira adapter, emitting one SDD_FLEET_DISPATCH signal per dispatch. It is the
# estate-wide generalization of next-feature.sh's resolve -> signal -> never-invoke
# pattern (it never invokes the per-repo machine, never creates a story, never
# reads plan.md/contracts.md). The "loop" is the harness re-invoking this tick.
#
# MODELLESS + CREATION-FREE (gated by conductor-modelless-lint.test.sh): no clock
# (the caller injects --now), no randomness, no model call; it only snapshots +
# transitions existing stories. DISPATCH-ONCE does NOT depend on the lease: the
# frontier is NOT_STARTED-only and the transition is idempotent, so a re-run sees
# an already-dispatched story as out-of-frontier. The lease is the one-conductor-
# per-epic coordination invariant only (same-owner re-entrant for crash recovery,
# no auto-expiry — staleness across owners is a human's call).
#
# Usage: conductor-tick.sh <epic-slug> --now <iso8601> [--owner <id>] [--registry <dir>]
# Reads:  .sdd/_epic/<slug>/JIRA_LINK.md (JIRA_EPIC: key only — never plan/contracts)
# Adapter (SDD_JIRA_ADAPTER, default $DIR/jira-adapter.sh), read + transition verbs:
#   <adapter> jira-snapshot   --epic-key <k> --now <iso>
#       -> {"epic":"<k>","stories":[{"id","key","status","consumes":["<c>@<m>"],"repo"}]}
#   <adapter> jira-transition --epic-key <k> --story <id> --to DISPATCHED --now <iso>
#       -> {"status":"transitioned"|"noop", ...}   (idempotent: noop if already DISPATCHED)
# stdout: SDD_FLEET_DISPATCH lines (one per dispatch) then one status JSON line.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/_lib.sh
. "$DIR/../hooks/scripts/_lib.sh"
FRONTIER="$DIR/ready-frontier.sh"

command -v jq >/dev/null 2>&1 || {
  echo "conductor-tick: jq is required — failing closed. Install jq (brew install jq / apt install jq)." >&2
  exit 2
}

slug="${1:-}"
case "$slug" in
  ""|--*) echo "conductor-tick: usage: conductor-tick.sh <epic-slug> --now <iso8601> [--owner <id>] [--registry <dir>]" >&2; exit 2 ;;
  */*|*..*) echo "conductor-tick: refusing slug with path separators / traversal: '$slug'" >&2; exit 2 ;;
esac
shift
now="" owner="" registry="registry"
while [ $# -gt 0 ]; do
  case "$1" in
    --now)      now="${2:-}";      shift 2 ;;
    --owner)    owner="${2:-}";    shift 2 ;;
    --registry) registry="${2:-}"; shift 2 ;;
    *) echo "conductor-tick: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$now" ] || { echo "conductor-tick: --now <iso8601> is required (the caller supplies it; the script reads no clock)." >&2; exit 2; }
[ -n "$owner" ] || owner="conductor:${slug}"

epicdir=".sdd/_epic/${slug}"
linkf="${epicdir}/JIRA_LINK.md"
# Resolve ONLY the external epic key from the materialisation receipt. The story
# set + edges come live from the adapter; the vault is touched for nothing else.
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

# Lease: one conductor per epic. Held by another owner -> defer (do NOT steal).
lock="${epicdir}/.conductor.lock"
if ! lease_acquire "$lock" "$owner" "$now"; then
  busy_owner="$(lease_field "$lock" OWNER)"
  printf '{"status":"busy","epic":"%s","owner":"%s"}\n' "$slug" "$busy_owner"
  exit 0
fi
# Release on every exit path from here on. lease_release is owner-checked, so it
# never removes a different owner's lock.
trap 'lease_release "$lock" "$owner" >/dev/null 2>&1 || true' EXIT

snap="$(bash "$ADAPTER" jira-snapshot --epic-key "$key" --now "$now" 2>/dev/null || true)"
# An adapter present but unconfigured (no creds) soft-defers like no adapter (the EXIT
# trap releases the lease). Keeps the default jira-adapter.sh inert until creds are set.
case "$snap" in
  *'"status":"unconfigured"'*) printf '{"status":"deferred","reason":"jira-adapter-unconfigured","epic":"%s"}\n' "$slug"; exit 0 ;;
esac
if [ -z "$snap" ] || ! printf '%s' "$snap" | jq -e '.stories' >/dev/null 2>&1; then
  printf '{"status":"snapshot-error","epic":"%s"}\n' "$slug"
  exit 1
fi

# Pure set logic: the frontier is exactly the NOT_STARTED stories whose consumes
# are all published now. The conductor never decides readiness itself.
frontier="$(printf '%s' "$snap" | bash "$FRONTIER" --registry "$registry" 2>/dev/null || true)"
if ! printf '%s' "$frontier" | jq -e 'type=="array"' >/dev/null 2>&1; then
  printf '{"status":"frontier-error","epic":"%s"}\n' "$slug"
  exit 1
fi

fn="$(printf '%s' "$frontier" | jq 'length')"
dispatched=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  repo="$(printf '%s' "$snap" | jq -r --arg id "$id" '.stories[] | select(.id==$id) | .repo // ""')"
  res="$(bash "$ADAPTER" jira-transition --epic-key "$key" --story "$id" --to DISPATCHED --now "$now" 2>/dev/null || true)"
  st="$(printf '%s' "$res" | jq -r '.status // "error"' 2>/dev/null || echo error)"
  if [ "$st" = "transitioned" ]; then
    dispatched=$((dispatched+1))
    printf 'SDD_FLEET_DISPATCH: %s\n' "$(jq -cn --arg epic "$slug" --arg story "$id" --arg repo "$repo" --arg jira_epic "$key" '{epic:$epic,story:$story,repo:$repo,jira_epic:$jira_epic}')"
  fi
done < <(printf '%s' "$frontier" | jq -r '.[]')

jq -cn --arg epic "$slug" --arg jira_epic "$key" --argjson frontier "${fn:-0}" --argjson dispatched "$dispatched" \
  '{status:"dispatched",epic:$epic,jira_epic:$jira_epic,frontier:$frontier,dispatched:$dispatched}'
