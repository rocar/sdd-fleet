#!/usr/bin/env bash
# scripts/link-sweep.sh — ONE-TIME, NON-GATE legacy-link sweep over an existing .sdd/ corpus.
#
# The PreToolUse link-discipline gate (hooks/scripts/link-discipline.sh) only governs a
# .sdd/**/*.md file as it is WRITTEN; a [[wikilink]] or repo-escaping relative link already on
# disk is invisible to it until its region is next written. This sweep feeds every existing
# .sdd/**/*.md through the REAL hook as a synthetic write and reports the files the gate would
# block. It is SINGLE-SOURCE with the gate — it re-implements no rules; its verdict IS the
# gate's verdict, so the two can never drift.
#
# Report-only: detection is deterministic (the gate), but FIXING is per-link judgment — a
# [[wikilink]] needs a real target and an escaping ../ needs the canonical stable ID (contract
# name / Jira key / registry URL). Clean what it reports, then re-run until clean.
#
# Scope: single-repo, anchored at <root> (arg, else $CLAUDE_PROJECT_DIR, else cwd). Tier
# (workspace / member / standalone) is a per-repo property the hook resolves itself; sweep an
# estate by running this once PER REPO. Not a hook — not registered in hooks.json.
#
# Usage: link-sweep.sh [root]
# Exit: 0 = clean (or no .sdd/ corpus), 1 = violations found, 2 = setup error (fail closed).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SELF_DIR/../hooks/scripts/link-discipline.sh"

command -v jq >/dev/null 2>&1 || { echo "link-sweep: jq is required — failing closed." >&2; exit 2; }
[ -f "$HOOK" ] || { echo "link-sweep: link-discipline hook not found at $HOOK — cannot sweep." >&2; exit 2; }

root="${1:-${CLAUDE_PROJECT_DIR:-.}}"
[ -d "$root" ] || { echo "link-sweep: root '$root' is not a directory." >&2; exit 2; }
root="$(cd "$root" && pwd)"
sdd="$root/.sdd"

if [ ! -d "$sdd" ]; then
  echo "link-sweep: no .sdd/ corpus under $root — nothing to sweep." >&2
  printf -- '----- link-sweep: scanned=0 violations=0 (root: %s)\n' "$root"
  exit 0
fi

scanned=0
violations=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  scanned=$((scanned+1))
  rel="${f#"$root"/}"   # the .sdd/...-relative path the hook expects
  payload="$(jq -nc --arg fp "$rel" --rawfile c "$f" '{tool_input:{file_path:$fp,content:$c}}')"
  # Drive the real gate. Capture its stderr (the rule + why); discard stdout (it emits none).
  reason="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$root" bash "$HOOK" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    violations=$((violations+1))
    printf 'VIOLATION  %s\n' "$rel"
    [ -n "$reason" ] && printf '%s\n' "$reason" | sed 's/^/    /'
  fi
done < <(find "$sdd" -type f -name '*.md' | sort)

printf -- '----- link-sweep: scanned=%d violations=%d (root: %s)\n' "$scanned" "$violations" "$root"
if [ "$violations" -gt 0 ]; then
  echo "link-sweep: legacy link-discipline violations found — fix them (wikilink → standard markdown link; escaping ../ → a stable ID) and re-run until clean." >&2
  exit 1
fi
echo "link-sweep: clean — no legacy link-discipline violations under $sdd."
exit 0
