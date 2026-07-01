#!/usr/bin/env bash
# scripts/counterfactual-record.sh <feature-slug> --now <iso8601>
# scripts/counterfactual-record.sh signature
#
# RECORD mode: run the deterministic counterfactual engine (scripts/counterfactual.sh —
# "the fully fail-closed hook form rides the CHANGE_REVIEW workflow port; this is the
# deterministic engine that port will call") and record its verdict into
# .sdd/<slug>/COUNTERFACTUAL.md, pinned to the CURRENT change content by CHANGE_SIGNATURE.
# The counterfactual gate (hooks/scripts/counterfactual-gate.sh) re-verifies that record at
# the PROGRESS.md → HANDOFF flip — the handoff-approve-record.sh / blast-radius-signature.sh
# record-and-verify pattern: a later source/tests edit yields a new signature, the record
# goes STALE, and the gate re-blocks until it is re-recorded.
#
# SIGNATURE mode: print the change signature — THE single home of the algorithm; both
# HANDOFF-flip gates (counterfactual, suite) and suite-record.sh call this mode, so the
# recorded digest and the digest a gate recomputes can never drift. CONTENT-based, not
# diff-based: the plan-digest.sh cascade over "<blob-hash>\t<path>" lines for every
# tracked + untracked (non-ignored) regular file OUTSIDE .sdd/, LC_ALL=C-sorted. A commit
# of identical content does not change it; any source or tests edit does; .sdd/ writes
# (the records themselves, PROGRESS.md) never do.
#
# Deterministic: --now is injected by the caller; the script reads no clock. cwd-relative
# (the member repo root, like handoff-approve-record.sh).
#
# Exit (record): the ENGINE's code with the record written — 0 pass · 1 fail · 3 skip;
# 2 on usage / missing jq / no engine output / signature failure (nothing recorded).
# Exit (signature): 0 + the digest on stdout; 1 when git / work tree / digest unavailable
# (no output, so a caller that fails closed on empty does so).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print the content-based change signature, or return 1 (no output) when it cannot be
# computed. GNU/BSD-portable: git + paste + the plan-digest.sh shasum→sha256sum→cksum
# cascade only.
change_signature() {
  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local raw plist hlist mat s
  raw=$(mktemp); plist=$(mktemp); hlist=$(mktemp); mat=$(mktemp)
  # Every tracked path + every untracked non-ignored path (core.quotepath=false so
  # non-ASCII paths come out raw, one per line).
  git -c core.quotepath=false ls-files --cached --others --exclude-standard 2>/dev/null \
    | LC_ALL=C sort -u > "$raw" || true
  : > "$plist"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # .sdd/ is the record plane, never part of the pinned change (the records themselves,
    # PROGRESS.md, and the HANDOFF flip all live there and must not stale a fresh record).
    case "$f" in .sdd/*|*/.sdd/*) continue ;; esac
    [ -f "$f" ] || continue   # deleted-but-tracked paths drop out (their absence IS a change)
    printf '%s\n' "$f" >> "$plist"
  done < "$raw"
  if [ -s "$plist" ]; then
    git hash-object --stdin-paths < "$plist" > "$hlist" 2>/dev/null \
      || { rm -f "$raw" "$plist" "$hlist" "$mat"; return 1; }
  else
    : > "$hlist"
  fi
  paste "$hlist" "$plist" > "$mat"
  s=$(bash "$DIR/plan-digest.sh" "$mat" 2>/dev/null) || s=""
  rm -f "$raw" "$plist" "$hlist" "$mat"
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

usage() {
  echo "usage: counterfactual-record.sh <feature-slug> --now <iso8601>" >&2
  echo "       counterfactual-record.sh signature" >&2
  exit 2
}

[ $# -ge 1 ] || usage
if [ "$1" = "signature" ]; then
  change_signature || exit 1
  exit 0
fi

SLUG=""; NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now) NOW="${2:-}"; shift 2 || usage ;;
    --) shift ;;
    -*) echo "counterfactual-record: unknown flag: $1" >&2; usage ;;
    *)  if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "counterfactual-record: unexpected arg: $1" >&2; usage; fi ;;
  esac
done
[ -n "$SLUG" ] || usage
[ -n "$NOW" ]  || { echo "counterfactual-record: --now <iso8601> is required (the caller supplies it; the script reads no clock)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "counterfactual-record: jq is required" >&2; exit 2; }

# Run the engine in THIS cwd (it anchors at CLAUDE_PROJECT_DIR; pin it so the record and
# the signature below describe the same tree). The engine restores the worktree before
# returning, so the post-run signature equals what the gate will recompute at flip time.
out=$(CLAUDE_PROJECT_DIR="$(pwd)" bash "$DIR/counterfactual.sh" 2>/dev/null); rc=$?
json=$(printf '%s\n' "$out" | sed -n 's/^SDD_FLEET_COUNTERFACTUAL: //p' | head -n1)
[ -n "$json" ] || { printf 'SDD_FLEET_COUNTERFACTUAL_RECORD: {"status":"engine-no-output","feature":"%s"}\n' "$SLUG"; exit 2; }
verdict=$(printf '%s' "$json" | jq -r '.verdict // empty')
reason=$(printf '%s' "$json" | jq -r '.reason // empty')

sig=$(change_signature) || { printf 'SDD_FLEET_COUNTERFACTUAL_RECORD: {"status":"signature-failed","feature":"%s"}\n' "$SLUG"; exit 2; }

mkdir -p ".sdd/${SLUG}"
{
  printf '# Counterfactual — %s\n\n' "$SLUG"
  printf 'RECORDED: %s\n' "$NOW"
  printf 'VERDICT: %s\n' "$verdict"
  printf 'REASON: %s\n' "$reason"
  printf 'CHANGE_SIGNATURE: %s\n\n' "$sig"
  printf 'The counterfactual gate re-verifies this record at the PROGRESS.md -> HANDOFF flip:\n'
  printf 'only a signature-fresh VERDICT: pass (or skip with REASON: no-source-change — nothing\n'
  printf 'revertable, the counterfactual is vacuous) opens the gate. Any source or tests edit\n'
  printf 'after this record stales the signature — re-run scripts/counterfactual-record.sh to\n'
  printf 're-pin.\n\n'
  printf 'Engine output (verbatim):\n\n'
  printf '    SDD_FLEET_COUNTERFACTUAL: %s\n' "$json"
} > ".sdd/${SLUG}/COUNTERFACTUAL.md"

jq -nc --arg f "$SLUG" --arg v "$verdict" --arg r "$reason" --arg s "$sig" \
  '{status:"recorded",feature:$f,verdict:$v,reason:$r,signature:$s}' \
  | sed 's/^/SDD_FLEET_COUNTERFACTUAL_RECORD: /'
exit "$rc"
