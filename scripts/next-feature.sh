#!/usr/bin/env bash
# scripts/next-feature.sh — deterministic resolver for the v0.4 M3.2 DEVELOPING loop.
#
# Resolves the next unblocked feature from the product backlog:
#   "first PENDING row in the lowest phase whose depends-on are all DONE".
# Re-resolves from LIVE backlog state on every call — never a cached index — so a
# mid-flight re-prioritization is always honored. Shared by /sdd-fleet:pr-review,
# /sdd-fleet:status, and (M4) /sdd-fleet:next-feature so the resolution logic
# has exactly one source of truth instead of being re-derived in prose per command.
#
# Output: exactly one JSON line on stdout (status carries the outcome; exit is
# always 0 unless the backlog path is unreadable):
#   {"status":"next","slug":"<slug>","phase":"<phase name>","done":<n>,"total":<n>}
#   {"status":"complete","done":<n>,"total":<n>}       all rows [x] (total>0)
#   {"status":"deadlocked","pending":<k>,"done":<n>,"total":<n>}
#   {"status":"empty","done":0,"total":0}              no parseable feature rows
#   {"status":"no-backlog"}                            backlog file absent
# Read-only — never writes.
#
# Usage: next-feature.sh [path-to-backlog.md]   (default .sdd/_product/backlog.md)
set -euo pipefail

backlog="${1:-.sdd/_product/backlog.md}"

if [ ! -f "$backlog" ]; then
  printf '{"status":"no-backlog"}\n'
  exit 0
fi

awk '
  function trim(s){ gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }

  # Strip CR first so CRLF-edited backlogs parse identically (every other
  # sdd-fleet script strips \r; the resolver must too).
  { gsub(/\r/, "") }

  # Phase heading: "## Phase N: <name> — STATUS: <state>". Capture <name>.
  /^##[ \t]+Phase[ \t]+[0-9]+:/ {
    phase = $0
    sub(/^##[ \t]+/, "", phase)              # drop leading "## "
    sub(/[ \t]+STATUS:.*$/, "", phase)        # drop " STATUS: ..." tail
    sub(/[^A-Za-z0-9)]+$/, "", phase)         # drop trailing " —" / " -" (byte-safe)
    next
  }

  # Feature row: "- [x] <slug> DONE ..." or "- [ ] <slug> PENDING depends-on: ...".
  # Tolerate "-" or "*" bullets and "[x]"/"[X]"/"[ ]" marks (hand edits happen).
  /^[-*][ \t]+\[[ xX]\]/ {
    line = $0
    rest = line
    sub(/^[-*][ \t]+\[[ xX]\][ \t]+/, "", rest)   # strip the checkbox prefix
    # A real feature row is "<slug>  <PENDING|DONE>  depends-on: ...". Require the
    # state word as the SECOND token so prose checklists / star-bullet notes inside a
    # phase body are not mis-parsed as features — which would inflate the counts and
    # could falsely satisfy a depends-on edge via a prose-derived slug.
    ntok = split(rest, tok, /[ \t]+/)
    state = (ntok >= 2) ? tolower(tok[2]) : ""
    if (state != "pending" && state != "done") next
    slug = tok[1]
    mark = (tolower(line) ~ /\[x\]/) ? "x" : " "
    if (mark == "x") { done[slug] = 1; donecount++; total++; next }

    total++; pidx++
    pslug[pidx] = slug
    pphase[pidx] = phase
    deps = ""
    if (match(rest, /depends-on:[ \t]*/)) {
      deps = substr(rest, RSTART + RLENGTH)
      sub(/[ \t]+handoff:.*$/, "", deps)           # defensive: strip any trailing handoff:
      deps = trim(deps)
    }
    pdeps[pidx] = deps
    next
  }

  END {
    if (pidx == 0) {
      if (total == 0) { printf "{\"status\":\"empty\",\"done\":0,\"total\":0}\n"; exit 0 }
      printf "{\"status\":\"complete\",\"done\":%d,\"total\":%d}\n", donecount, total
      exit 0
    }
    # First PENDING (file order = lowest phase, top-to-bottom) with all deps DONE.
    for (i = 1; i <= pidx; i++) {
      ok = 1
      d = pdeps[i]
      if (d != "" && tolower(d) != "none") {
        n = split(d, arr, /[ ,]+/)
        for (j = 1; j <= n; j++) {
          t = arr[j]
          if (t == "" || tolower(t) == "none") continue
          if (!(t in done)) { ok = 0; break }
        }
      }
      if (ok) {
        printf "{\"status\":\"next\",\"slug\":\"%s\",\"phase\":\"%s\",\"done\":%d,\"total\":%d}\n", pslug[i], pphase[i], donecount, total
        exit 0
      }
    }
    printf "{\"status\":\"deadlocked\",\"pending\":%d,\"done\":%d,\"total\":%d}\n", pidx, donecount, total
    exit 0
  }
' "$backlog"
