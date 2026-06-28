#!/usr/bin/env bash
# PreToolUse (Write|Edit|NotebookEdit) — link discipline for .sdd/ markdown (Slice 7).
# The chokepoint is a write to a .sdd/**/*.md file; any other write is inert (exit 0).
#
#   Rule 1 (ALL tiers): a [[wikilink]] anywhere in the proposed content → block. Standard
#           markdown links only; cross-tree refs use a stable ID (contract name, Jira key,
#           registry URL). [[wikilinks]] die on GitHub and to the gate parsers.
#   Rule 2 (REPO-LEVEL only — member submodule + standalone repo): a relative markdown link
#           that, resolved against the file's directory, climbs ABOVE the repo root → block.
#           An in-repo "../../x.md" is legal; a "../" chain that crosses the root 404s in the
#           repo's PR view. The WORKSPACE/superproject tier (a .gitmodules at the anchored
#           root, the repo not itself a submodule) SKIPS rule 2 — its single Obsidian vault
#           spans the submodules, so down-links into them are legal and must never be blocked.
#
# INERT (exit 0): no file path; a write outside .sdd/; a non-.md write; a workspace-tier
# write w.r.t. rule 2. Fail CLOSED (exit 2): a '..' write-target, jq missing, an unparseable
# payload, or any unexpected error (the ERR trap). Reads topology only; writes nothing.
#
# STATED LIMIT (harness-wide, by design — NOT a bug to fix here): a write that SKIPS this
# PreToolUse chokepoint evades this gate exactly as it evades every other .sdd path gate
# (dependency, blast-radius) — a Bash write into .sdd/, or a pre-existing link in a region this
# edit does not touch. The one-time scripts/link-sweep.sh cleans the pre-existing on-disk case;
# the live case is the accepted chokepoint boundary (fail-closed on what passes, fail-open on
# what does not). See skills/sdd-protocol/references/service-catalog.md (Stated limits).
set -euo pipefail
trap 'echo "sdd-fleet: link-discipline errored — failing closed" >&2; exit 2' ERR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

# jq is required UNCONDITIONALLY here: link discipline is not scoped to an active feature
# (workspace-tier .sdd/_epic/ writes have no .sdd/ACTIVE), so the active-feature-conditional
# require_jq would fail OPEN at workspace level. Fail closed on a missing tool instead.
command -v jq >/dev/null 2>&1 || {
  echo "sdd-fleet: link-discipline requires jq — failing closed. Install jq (brew install jq / apt install jq)." >&2
  exit 2
}

# Echo the superproject working-tree path if this repo is a git submodule, else empty.
# Verbatim from epic-ratified-before-fanout.sh (kept local — no shared-lib mutation). The
# `|| true` keeps a non-zero git exit (e.g. not a git repo) from tripping the ERR trap.
resolve_superproject() {
  command -v git >/dev/null 2>&1 || return 0
  local s
  s=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
  printf '%s' "$s"
}

# Return 0 if <target> (a markdown link target) escapes the repo root from <file>.
# Pure string arithmetic on path depth — no realpath, no disk read of the target.
# Usage: link_escapes <file_path> <raw_target>
link_escapes() {
  local file="$1" target="$2" rel dir seg before phys depth=0
  target="${target%%#*}"      # drop a #fragment
  target="${target%%\?*}"     # drop a ?query
  [ -n "$target" ] || return 1
  # URLs (incl. registry URLs), absolute paths, and pure anchors are not relative file links.
  case "$target" in *://*|/*|\#*) return 1 ;; esac
  # A scheme like mailto:/tel: — a ':' before the first '/'. (A ':' AFTER a '/' is a path char.)
  case "$target" in
    */*) before="${target%%/*}"; case "$before" in *:*) return 1 ;; esac ;;
    *:*) return 1 ;;
  esac
  # Normalise <file> to repo-root-relative so depth is measured from the repo root, not '/'.
  rel="$file"; rel="${rel#./}"
  phys="$(pwd -P 2>/dev/null)"
  rel="${rel#"$PWD"/}"; rel="${rel#"$phys"/}"
  dir="${rel%/*}"             # .sdd/ guarantees a slash, so this is the file's directory
  local IFS=/
  for seg in $dir;    do case "$seg" in ''|'.') : ;; *) depth=$((depth+1)) ;; esac; done
  for seg in $target; do
    case "$seg" in
      ''|'.') : ;;
      '..') depth=$((depth-1)); if [ "$depth" -lt 0 ]; then return 0; fi ;;
      *) depth=$((depth+1)) ;;
    esac
  done
  return 1
}

input=$(cat)
file=$(extract_file_path "$input")            # jq in $(): an unparseable payload → ERR → exit 2
[ -n "$file" ] || exit 0                       # no targeted path → inert
case "$file" in */../*|../*|*/..|..) echo "sdd-fleet: refusing path containing '..': $file" >&2; exit 2;; esac
path_in_sdd "$file" || exit 0                  # not under .sdd/ → inert
case "$file" in *.md) ;; *) exit 0;; esac      # not markdown → inert

content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')

# --- Rule 1: no wikilinks, at every tier. ---
# Portable ERE: '[[', then a char that is neither ']' nor whitespace (so bash '[[ -f x ]]'
# with its leading space is NOT matched), then any non-']', then ']]'. The ']' sits first
# inside each negated class so it is literal across BSD and GNU grep.
if printf '%s' "$content" | grep -Eq '\[\[[^][:space:]][^]]*\]\]'; then
  echo "sdd-fleet: link-discipline — [[wikilink]] is not allowed in .sdd/ markdown ($file)." >&2
  echo "Use a standard markdown link [text](path), or a stable ID (contract name, Jira key, registry URL) for a cross-tree reference." >&2
  exit 2
fi

# --- Rule 2: repo-level only — a relative link escaping the repo root. ---
# Workspace/superproject (.gitmodules at root, not itself a submodule) skips rule 2: its
# vault spans the submodules, so down-links into them are legal.
super=$(resolve_superproject)
if [ -z "$super" ] && [ -f .gitmodules ]; then
  exit 0
fi
# Member (super non-empty) or standalone (super empty, no .gitmodules): the .sdd/ doc is
# repo-level — its links must resolve inside this repo's own tree.
links=$(printf '%s' "$content" | grep -Eo '\]\([^)]*\)' || true)
escapes=""
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  t=${raw#\]\(}; t=${t%\)}; t=${t%% *}        # strip '](' … ')' and an optional "title"
  if link_escapes "$file" "$t"; then escapes="${escapes} ${t}"; fi
done <<EOF
$links
EOF
if [ -n "$escapes" ]; then
  echo "sdd-fleet: link-discipline — relative link escapes the repo root in $file:$escapes" >&2
  echo "A per-repo .sdd/ doc must reference a cross-tree target by stable ID (contract name, Jira key, registry URL), never a ../ path that 404s in this repo's PR view." >&2
  exit 2
fi
exit 0
