#!/usr/bin/env bash
# scripts/intent-block.sh — canonical backlog intent-block extractor + quality floor.
#
# THE single implementation of the intent-block grammar that /sdd-fleet:jira-story
# (step 5) and /sdd-fleet:next-feature (step 3) previously duplicated in prose
# (audit §3.26). Both commands call this script so they always reach the same verdict.
# The row grammar mirrors scripts/next-feature.sh exactly:
#   row    = "- [ ] <slug>   <PENDING|DONE>   depends-on: ..." ("-"/"*" bullets,
#            "[x]"/"[X]"/"[ ]" marks; the state word must be the SECOND token)
#   intent = the run of INDENTED lines immediately under the row (not starting with
#            "- [" or "##" after the indent), up to the next feature row, the next
#            "## " heading, or a blank line — capped at 3 lines.
#
# Quality floor (the canonical prose definition lives in the sdd-protocol skill):
# an intent is USABLE only if it carries at least 2 of its 3 components —
# what the feature is / its scope boundary / its non-goals. Encoded
# deterministically: components = intent lines, plus extra clauses split on
# "—" (em-dash) or ";" within a line. < 2 components (including a missing or
# empty intent — a bare slug restatement has no boundary clause) = TOO-THIN.
#
# Usage:
#   intent-block.sh [file]                  # input begins AT the feature row
#   intent-block.sh --slug <slug> [file]    # find <slug>'s row in a full backlog
#   (reads stdin when no file is given)
#
# Output (stdout):
#   INTENT_SLUG: <slug>
#   INTENT_STATE: <PENDING|DONE>
#   <intent line(s), dedented — the canonical block; omitted when empty>
#   INTENT_VERDICT: usable|too-thin
# Exit: 0 = verdict emitted; 1 = malformed/empty input or slug not found
#       (error on stderr, NO verdict line). bash 3.2 compatible; read-only.
set -uo pipefail

slug_filter=""
if [ "${1:-}" = "--slug" ]; then
  slug_filter="${2:-}"
  if [ -z "$slug_filter" ]; then
    echo "intent-block.sh: --slug requires a value" >&2
    exit 1
  fi
  shift 2
fi

input="$(cat "${1:-/dev/stdin}")"
if [ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]; then
  echo "intent-block.sh: empty input — expected a backlog feature row" >&2
  exit 1
fi

printf '%s\n' "$input" | awk -v want="$slug_filter" '
  function is_row(l) { return l ~ /^[-*][ \t]+\[[ xX]\][ \t]+/ }
  BEGIN { found = 0; nint = 0 }
  { gsub(/\r/, "") }   # CRLF tolerance, same as next-feature.sh

  !found {
    if (!is_row($0)) {
      if (want == "") { bad = 1; exit }   # row-mode: input must START at a row
      next                                 # slug-mode: scan for the row
    }
    rest = $0
    sub(/^[-*][ \t]+\[[ xX]\][ \t]+/, "", rest)
    ntok = split(rest, tok, /[ \t]+/)
    state = (ntok >= 2) ? tolower(tok[2]) : ""
    if (state != "pending" && state != "done") {
      if (want == "") { bad = 1; exit }   # row-mode: malformed row
      next
    }
    if (want != "" && tok[1] != want) next
    found = 1
    slug = tok[1]
    statew = toupper(state)
    next
  }

  found {
    if ($0 ~ /^[ \t]*$/) exit              # blank line ends the block
    if (is_row($0)) exit                   # next feature row ends the block
    if ($0 ~ /^##/) exit                   # next heading ends the block
    if ($0 !~ /^[ \t]/) exit               # intent lines are indented
    if (nint >= 3) next                    # cap at 3 lines
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == "") next
    nint++
    intent[nint] = line
  }

  END {
    if (bad || !found) {
      print "intent-block.sh: input is not a backlog feature row" \
            (want != "" ? " (slug \"" want "\" not found)" : "") > "/dev/stderr"
      exit 1
    }
    printf "INTENT_SLUG: %s\n", slug
    printf "INTENT_STATE: %s\n", statew
    components = 0
    for (i = 1; i <= nint; i++) {
      print intent[i]
      components++                          # each line is one component...
      c = intent[i]
      components += gsub(/—/, "—", c)       # ...plus em-dash-separated clauses
      components += gsub(/;/, ";", c)       # ...plus semicolon-separated clauses
    }
    printf "INTENT_VERDICT: %s\n", (components >= 2) ? "usable" : "too-thin"
    exit 0
  }
'
