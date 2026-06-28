#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit): the FINALIZE gate, in code.
#
# The design draws FINALIZE as a Layer-1 code gate (▣): the spec freezes —
# unlocking source writes (block-source-before-finalized) — only once REVIEW has
# passed. Without this hook the FINALIZED flip lived in command prose
# (feature-dev.md "FINALIZE gate" step 4): a model could write
# `STATUS: FINALIZED` into spec.md directly, skipping or fabricating REVIEW, and
# block-source would then trust that model-set string and unlock all source
# (audit finding A1, CRITICAL). This gate moves the consequence into code: a
# write that flips the active feature's spec.md to FINALIZED is refused unless
# the review record approves it (or the classifier waived REVIEW via
# TIER=trivial). It mirrors the criteria in feature-dev.md:196-220 — the command
# may now defer to this gate as the authority.
#
# Scope: this gate enforces the load-bearing core — a flip needs an approved,
# blocker-free current-cycle review (or trivial waiver, and no live escalation),
# AND decidable acceptance criteria (the testability floor: at least one AC-<n>,
# no placeholder values). The [major]-needs-an-ADR refinement stays in the
# command's refusal prose; it is a quality nuance, not the source-unlock
# consequence this gate protects.
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
[ -n "$file_path" ] || exit 0

# Only a write to THIS feature's spec.md can be a finalize flip. `..` traversal is
# rejected inside path_in_active_sdd (audit §3.1); a basename check rejects
# look-alikes (myspec.md). Anything else is inert here.
[ "$(basename "$file_path")" = "spec.md" ] || exit 0
path_in_active_sdd "$file_path" "$slug" || exit 0

# Already FINALIZED on disk → not a flip; later spec edits are not this gate's
# concern (keeps re-finalize / post-finalize .sdd edits idempotent).
current=$(read_spec_status "$slug")
[ "$current" = "FINALIZED" ] && exit 0

# Does the incoming write SET STATUS: FINALIZED? Covers a full Write (content) and
# an Edit (new_string): a full status line, or a word-only value replacement
# (old_string "DRAFT" → new_string "FINALIZED"). Prose merely mentioning the word
# does not match (the line form, or the whole replacement equalling FINALIZED).
new_content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // .tool_input.new_source // empty')
sets_finalized=0
if printf '%s' "$new_content" | grep -Eq '^[[:space:]]*STATUS:[[:space:]]*FINALIZED[[:space:]]*$'; then
  sets_finalized=1
elif [ "$(printf '%s' "$new_content" | tr -d '[:space:]')" = "FINALIZED" ]; then
  sets_finalized=1
fi
[ "$sets_finalized" -eq 1 ] || exit 0

# From here, this write would freeze the spec. It must earn it.

# Trivial features skip REVIEW by design — the classifier already decided REVIEW
# was unnecessary at /sdd-fleet:jira-story time.
tier=$(read_progress_field "$slug" TIER)
[ "$tier" = "trivial" ] && exit 0

# A live escalation halts the feature; only a human may unblock it.
if [ -f ".sdd/${slug}/ESCALATION.md" ]; then
  echo "sdd-fleet: feature '${slug}' has an open ESCALATION.md — the spec cannot be FINALIZED until a human resolves it (/sdd-fleet:resolve-escalation)." >&2
  exit 2
fi

# Resolve the reviewer roster (durable PROGRESS.md default; falls back to the
# canonical architect/qa/coder). A flag override is per-run and not persisted, so
# the durable field is the only thing a gate can key on.
roles_raw=$(read_progress_field "$slug" REVIEW_ROLES)
if [ -n "$roles_raw" ]; then
  roles=$(printf '%s' "$roles_raw" | tr ',' ' ')
else
  roles="architect qa coder"
fi

cycle=$(read_progress_field "$slug" CYCLE)
case "$cycle" in ''|*[!0-9]*) cycle="" ;; esac

refuse() {
  echo "sdd-fleet: refusing to FINALIZE '${slug}' — $1. REVIEW must pass first (run /sdd-fleet:feature-dev); the spec STATUS=FINALIZED flip is what unlocks source writes." >&2
  echo "Refused write: ${file_path}" >&2
  exit 2
}

[ -n "$cycle" ] || refuse "PROGRESS.md has no valid CYCLE to validate a review against"

review_file=".sdd/${slug}/REVIEW.md"
[ -f "$review_file" ] || refuse "no REVIEW.md review record exists"

# Extract only the current cycle's blocks: every line from a `## Cycle <cycle> —`
# heading until the next `## Cycle ` heading of a different number.
section=$(awk -v c="$cycle" '
  /^##[[:space:]]+Cycle[[:space:]]+/ { inblk = ($3 == c) ? 1 : 0 }
  inblk == 1 { print }
' "$review_file")
[ -n "$section" ] || refuse "REVIEW.md has no blocks for the current cycle ${cycle}"

# An open [blocker] anywhere in the current cycle → not approved.
if printf '%s' "$section" | grep -q '\[blocker\]'; then
  refuse "the current review cycle ${cycle} still has open [blocker] items"
fi

# Any reviewer that raised concerns (did not approve) → not approved.
if printf '%s' "$section" | grep -Eqi 'status:[[:space:]]*concerns-raised'; then
  refuse "a reviewer in cycle ${cycle} ended in status: concerns-raised"
fi

# Every roster role must have a current-cycle block.
for r in $roles; do
  if ! printf '%s' "$section" | grep -Eq "^##[[:space:]]+Cycle[[:space:]]+${cycle}[[:space:]]+[—–-][[:space:]]+${r}[[:space:]]+[—–-]"; then
    refuse "reviewer '${r}' has no block in cycle ${cycle}"
  fi
done

# And there must be at least one approval per roster role.
approved_count=$(printf '%s' "$section" | grep -Eci 'status:[[:space:]]*approved' || true)
nroles=$(printf '%s' "$roles" | wc -w | tr -d ' ')
[ "${approved_count:-0}" -ge "$nroles" ] || refuse "cycle ${cycle} has ${approved_count:-0} approvals for ${nroles} roster roles"

# Testability floor (the design's SPEC-phase ▣): a spec cannot freeze without
# decidable acceptance criteria. They live in acceptance.md (preferred) or inline
# in spec.md's `## Acceptance Criteria` — gather both on disk plus the incoming
# content, and require at least one AC-<n> with no placeholder value.
accept_src="${new_content}"
[ -f ".sdd/${slug}/acceptance.md" ] && accept_src="${accept_src}
$(cat ".sdd/${slug}/acceptance.md" 2>/dev/null || true)"
[ -f ".sdd/${slug}/spec.md" ] && accept_src="${accept_src}
$(cat ".sdd/${slug}/spec.md" 2>/dev/null || true)"

if ! printf '%s' "$accept_src" | grep -Eq 'AC-[0-9]'; then
  refuse "no decidable acceptance criteria (expected AC-1, AC-2, … in acceptance.md or spec.md)"
fi
if printf '%s' "$accept_src" | grep -Eqi 'acceptance criteria:?[[:space:]]*tbd|AC-[0-9]+[^[:alnum:]]+(tbd|n/?a|tba|\?\?\?)([^[:alnum:]]|$)'; then
  refuse "acceptance criteria contain placeholders (TBD / n-a) — each criterion must be decidable before FINALIZE"
fi

# Review passed and the criteria are decidable → the flip is earned.
exit 0
