#!/usr/bin/env bash
# epic-materialise.sh <epic-slug> --now <iso8601>
#
# STEP 3 of the epic spine, post-ratification: read the ratified plan and create the Jira
# epic + one story per plan node, recording the created keys in JIRA_LINK.md (the vault↔Jira
# link — external IDs that can't be re-derived). It does NOT copy the structured plan into
# Jira: the vault owns the plan, Jira owns intent + status. materialise passes the adapter
# only identifiers (epic key, story id, target repo) — the adapter attaches any high-level
# context / vault pointer. (Projecting each story's consume edges onto its Jira issue is a
# later, conductor-facing concern — not wired here yet.)
#
# Creating Jira issues is a CONSEQUENCE, so this is deterministic code (not command prose).
# --now is injected by the caller; the script reads no clock.
#
# THE JIRA ADAPTER SEAM. All Jira I/O goes through an adapter resolved from $SDD_JIRA_ADAPTER
# (default: scripts/jira-adapter.sh, not shipped in this slice — the real MCP/CLI backend
# slots in behind the seam later). The adapter CLI contract:
#   <adapter> create-epic  --slug <epic-slug> --now <iso>                         -> stdout: "JIRA_KEY: <key>"
#   <adapter> create-story --epic-key <key> --story <slug> --repo <repo> --now <iso> -> stdout: "JIRA_KEY: <key>"
# Exit 0 + a JIRA_KEY line on success; non-zero on failure. With no configured adapter the
# step SOFT-DEFERS (exit 0, status "deferred") — ratification already succeeded; Jira can be
# materialised later. A failed/partial Jira write never un-ratifies the epic.
#
# Emits one JSON status line on stdout. Exit 0 on materialised | deferred; exit 1 on refusal
# (not-ratified | already-materialised | not-planned) or adapter-error or usage.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: epic-materialise.sh <epic-slug> --now <iso8601>" >&2; exit 1; }

SLUG=""; NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now) NOW="${2:-}"; shift 2 || usage ;;
    --) shift ;;
    -*) echo "epic-materialise: unknown flag: $1" >&2; usage ;;
    *)  if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "epic-materialise: unexpected arg: $1" >&2; usage; fi ;;
  esac
done
[ -n "$SLUG" ] || usage
[ -n "$NOW" ]  || { echo "epic-materialise: --now <iso8601> is required (the caller supplies it)" >&2; exit 1; }

EPICDIR=".sdd/_epic/${SLUG}"
PLAN="${EPICDIR}/plan.md"
RAT="${EPICDIR}/RATIFICATION.md"
JIRA_LINK="${EPICDIR}/JIRA_LINK.md"

# Only ratified epics may materialise — RATIFICATION.md's existence is the ratified signal.
[ -f "$RAT" ]  || { printf '{"status":"not-ratified","epic":"%s"}\n' "$SLUG"; exit 1; }
[ -f "$PLAN" ] || { printf '{"status":"not-planned","epic":"%s"}\n' "$SLUG"; exit 1; }
# Idempotency: a materialised epic carries JIRA_LINK.md.
[ -f "$JIRA_LINK" ] && { printf '{"status":"already-materialised","epic":"%s"}\n' "$SLUG"; exit 1; }

# Resolve the adapter; no usable adapter → soft-defer (ratification already stands).
ADAPTER="${SDD_JIRA_ADAPTER:-$DIR/jira-adapter.sh}"
[ -f "$ADAPTER" ] || { printf '{"status":"deferred","reason":"no-jira-adapter","epic":"%s"}\n' "$SLUG"; exit 0; }

# Extract one "id<TAB>repo" line per story node from plan.md (CRLF-tolerant). The story's
# consume edges are projected onto the Jira story by the adapter, not parsed here.
read_key() { sed -n 's/^JIRA_KEY:[[:space:]]*//p' | head -n1; }

epic_key=$(bash "$ADAPTER" create-epic --slug "$SLUG" --now "$NOW" 2>/dev/null | read_key)
[ -n "$epic_key" ] || { printf '{"status":"adapter-error","epic":"%s","reason":"create-epic-failed"}\n' "$SLUG"; exit 1; }

stories=$(awk '
  { gsub(/\r/,"") }
  /^[[:space:]]*-?[[:space:]]*id:[[:space:]]*/ {
    line=$0; sub(/^[[:space:]]*-?[[:space:]]*id:[[:space:]]*/,"",line); sub(/[[:space:]].*$/,"",line); id=line; repo=""
  }
  /^[[:space:]]*repo:[[:space:]]*/ {
    line=$0; sub(/^[[:space:]]*repo:[[:space:]]*/,"",line); sub(/[[:space:]].*$/,"",line); repo=line
    if (id != "") { print id "\t" repo; id="" }
  }
' "$PLAN")

n=0
story_lines=""
while IFS="$(printf '\t')" read -r sid srepo; do
  [ -n "$sid" ] || continue
  skey=$(bash "$ADAPTER" create-story --epic-key "$epic_key" --story "$sid" --repo "$srepo" --now "$NOW" 2>/dev/null | read_key)
  [ -n "$skey" ] || { printf '{"status":"adapter-error","epic":"%s","story":"%s","reason":"create-story-failed"}\n' "$SLUG" "$sid"; exit 1; }
  story_lines="${story_lines}- ${sid} → ${skey} (repo: ${srepo})
"
  n=$((n+1))
done <<EOF
$stories
EOF

{
  printf '# Jira materialisation — %s\n\n' "$SLUG"
  printf 'MATERIALISED: %s\n' "$NOW"
  printf 'JIRA_EPIC: %s\n\n' "$epic_key"
  printf 'The vault owns the plan; Jira owns intent + status. This is the materialisation\n'
  printf 'receipt (created keys), not the conductor story list — the conductor reads stories\n'
  printf 'live from Jira (ground truth), using JIRA_EPIC only to resolve the external key.\n\n'
  printf '## Stories\n'
  printf '%s' "$story_lines"
} > "$JIRA_LINK"

printf '{"status":"materialised","epic":"%s","jira_epic":"%s","stories":%d}\n' "$SLUG" "$epic_key" "$n"
exit 0
