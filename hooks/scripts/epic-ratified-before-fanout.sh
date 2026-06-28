#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit): the estate fan-out gate. While a story
# GOVERNED BY AN UNRATIFIED EPIC is active, block writes into its .sdd/<slug>/ spec
# dir — a story must not be specced before a human ratifies its epic.
#
# Cross-level: this hook runs inside a MEMBER repo (a git submodule), but the
# ratification fact lives in the SUPERPROJECT vault. It resolves the superproject via
# `git rev-parse --show-superproject-working-tree`, finds which epic (if any) lists the
# active story as a node in `_epic/*/plan.md`, and checks that epic's RATIFICATION.md
# (whose existence IS the ratified signal — see references/workspace-tier.md).
#
# INERT (allow) when: no active story; the write is outside .sdd/<active>/; no
# resolvable superproject (a standalone repo, or git unavailable — the deliberate
# fail-open boundary); or the story is not listed in any epic plan (a standalone
# story). Block (exit 2) ONLY when an epic governs the story and RATIFICATION.md is
# absent. The conductor is the PRIMARY 'ratified before fanout' enforcement (it never
# dispatches an unratified epic); this hook is the belt-and-suspenders backstop against
# an out-of-band manual spec.
set -euo pipefail
# Fail CLOSED on any unexpected runtime error: exit 1 is non-blocking per the hooks
# contract (audit §3.5). Every deliberate allow below is an explicit exit 0.
trap 'echo "sdd-fleet: gate script errored unexpectedly — failing closed" >&2; exit 2' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

require_jq

# Echo the superproject working-tree path if this repo is a git submodule, else empty.
# git-missing or not-a-submodule → empty (the gate is then inert). The `|| true` keeps a
# non-zero git exit (e.g. not a git repo) from tripping the ERR trap.
resolve_superproject() {
  command -v git >/dev/null 2>&1 || return 0
  local s
  s=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
  printf '%s' "$s"
}

# Echo the name of the epic whose plan.md lists <slug> as a story node, else empty.
# A node is a line `- id: <slug>` (or `id: <slug>`); the trailing boundary keeps `story`
# from matching `storyA`. CRLF-tolerant (\r is [[:space:]]).
# Usage: epic_governing_story <superproject> <slug>
epic_governing_story() {
  local super="$1" slug="$2" d
  [ -d "$super/.sdd/_epic" ] || return 0
  for d in "$super"/.sdd/_epic/*/; do
    [ -f "${d}plan.md" ] || continue
    if grep -Eq "^[[:space:]]*-?[[:space:]]*id:[[:space:]]*${slug}([[:space:]]|\$)" "${d}plan.md" 2>/dev/null; then
      basename "$d"
      return 0
    fi
  done
  return 0
}

input=$(cat)
slug=$(resolve_active)

# No active story → allow. Bootstrap-friendly; also avoids the git call entirely.
[ -n "$slug" ] || exit 0

file_path=$(extract_file_path "$input")
# Tool call without a file/notebook path → allow.
[ -n "$file_path" ] || exit 0

# Only the active story's own .sdd/<slug>/ dir is gated here — that's the spec
# scaffolding. Source writes are block-source-before-finalized's concern; other .sdd
# paths are not part of spec'ing this story.
path_in_active_sdd "$file_path" "$slug" || exit 0

# Estate context: resolve the parent superproject. None (standalone repo / no git) → inert.
super=$(resolve_superproject)
[ -n "$super" ] || exit 0

# Which epic, if any, governs this story? Not in any plan → standalone story → allow.
epic=$(epic_governing_story "$super" "$slug")
[ -n "$epic" ] || exit 0

# The epic governs the story. Ratified iff RATIFICATION.md exists AND its recorded
# PLAN_DIGEST still matches plan.md+contracts.md NOW — a plan edited after sign-off (tamper)
# is caught and fails closed. Existence alone is not enough.
rat="$super/.sdd/_epic/${epic}/RATIFICATION.md"
if [ -f "$rat" ]; then
  # `|| true` keeps grep-no-match (exit 1) off pipefail/the ERR trap (mirrors _lib.sh read_spec_status).
  recorded=$({ grep -m1 '^PLAN_DIGEST:' "$rat" 2>/dev/null || true; } | sed -E 's/^PLAN_DIGEST:[[:space:]]*//' | tr -d '\r ')
  if [ -z "$recorded" ]; then
    echo "sdd-fleet: epic '${epic}' RATIFICATION.md has no PLAN_DIGEST — cannot verify the plan is unchanged; failing closed. Re-ratify with /sdd-fleet:epic-ratify ${epic} ratify." >&2
    echo "Refused write: ${file_path}" >&2
    exit 2
  fi
  # Recompute via the SAME shared helper epic-ratify-record.sh used (single digest algorithm).
  current=$(bash "$DIR/../../scripts/plan-digest.sh" "$super/.sdd/_epic/${epic}/plan.md" "$super/.sdd/_epic/${epic}/contracts.md" 2>/dev/null || true)
  if [ -z "$current" ]; then
    echo "sdd-fleet: cannot recompute the plan digest for epic '${epic}' (plan.md/contracts.md missing or unreadable) — failing closed." >&2
    echo "Refused write: ${file_path}" >&2
    exit 2
  fi
  if [ "$current" = "$recorded" ]; then
    exit 0
  fi
  echo "sdd-fleet: epic '${epic}' plan was edited after ratification (digest mismatch) — spec'ing '${slug}' is blocked. Re-ratify with /sdd-fleet:epic-ratify ${epic} ratify, or restore the ratified plan." >&2
  echo "Refused write: ${file_path}" >&2
  exit 2
fi

echo "sdd-fleet: story '${slug}' is governed by epic '${epic}', which is not ratified. Spec'ing it is blocked until a human runs /sdd-fleet:epic-ratify ${epic} (the epic plan + contract design must be ratified before fan-out)." >&2
echo "Refused write: ${file_path}" >&2
exit 2
