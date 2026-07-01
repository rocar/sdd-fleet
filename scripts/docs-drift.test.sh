#!/usr/bin/env bash
# Docs-site drift test. Two invariants tie the GitHub Pages site to the
# protocol source of truth:
#   1. Every page that displays the full phase spine shows the tokens in the
#      exact order defined by skills/sdd-protocol/SKILL.md (the state-machine
#      line). Diagrams may render "CHANGE REVIEW" / "CHANGE&nbsp;REVIEW";
#      both normalize to CHANGE_REVIEW before comparison.
#   2. The canonical boundary sentence in docs/_includes/boundary-strip.html
#      appears verbatim (case-insensitive, tags stripped) in docs/boundary.html.
# While the site pages are not yet built, the test SKIPS cleanly (exit 0) so
# scripts/run-tests.sh stays green mid-build. bash 3.2 + BSD/GNU compatible.
# Run: bash scripts/docs-drift.test.sh   (exit 0 = no drift, or skipped)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docs="$root/docs"

# ---- skip guard: the site is built in stages -------------------------------
missing=""
for p in index.html boundary.html provenance.html architecture/index.html; do
  [ -f "$docs/$p" ] || missing="$missing $p"
done
if [ -n "$missing" ]; then
  echo "SKIP docs-drift: site pages not yet built (missing:$missing)"
  echo "-----"
  echo "passed=0 failed=0 skipped=1"
  exit 0
fi

pass=0; fail=0

# ---- check 1: phase-spine token order ---------------------------------------
# Canonical: the state-machine line in the sdd-protocol skill, e.g.
#   SPEC ──► REVIEW ──► FINALIZE ──► BUILD ──► CHANGE_REVIEW ──► HANDOFF
skill="$root/skills/sdd-protocol/SKILL.md"

# Extract the six spine tokens, first occurrence each, in document order.
# CHANGE_REVIEW is listed first in the alternation and POSIX leftmost-longest
# keeps REVIEW from matching inside it; FINALIZED matching FINALIZE is
# harmless (it only occurs after a full in-order spine).
extract_spine() {
  sed 's/&nbsp;/ /g; s/CHANGE REVIEW/CHANGE_REVIEW/g' "$1" \
    | grep -oE 'CHANGE_REVIEW|SPEC|REVIEW|FINALIZE|BUILD|HANDOFF' \
    | awk '!seen[$0]++' \
    | tr '\n' ' ' \
    | sed 's/ $//'
}

spine_line_file="${TMPDIR:-/tmp}/docs-drift-spine.$$"
awk '/^SPEC /{print; exit}' "$skill" > "$spine_line_file"
canon="$(extract_spine "$spine_line_file")"
rm -f "$spine_line_file"

canon_count=$(printf '%s\n' "$canon" | wc -w | tr -d ' ')
if [ -z "$canon" ] || [ "$canon_count" -ne 6 ]; then
  printf 'FAIL %-44s no ^SPEC state-machine line with 6 tokens in %s\n' \
    "anchor-present-in-skill" "$skill"
  fail=$((fail+1))
else
  printf 'ok   %-44s\n' "anchor-present-in-skill"
  pass=$((pass+1))
fi

# Targets: every published page + includes. Redirect stubs carry no tokens and
# skip naturally; the temporary _src-* monolith copies are not site pages.
qualifying=0
for f in "$docs"/*.html "$docs"/architecture/*.html "$docs"/_includes/*.html; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in _src-*) continue ;; esac
  rel="${f#$docs/}"
  got="$(extract_spine "$f")"
  got_count=$(printf '%s\n' "$got" | wc -w | tr -d ' ')
  # a file qualifies only if it contains all six tokens
  [ "$got_count" -eq 6 ] || continue
  qualifying=$((qualifying+1))
  if [ -n "$canon" ] && [ "$got" = "$canon" ]; then
    printf 'ok   %-44s\n' "spine-order-$rel"
    pass=$((pass+1))
  else
    printf 'FAIL %-44s expected [%s] got [%s]\n' "spine-order-$rel" "$canon" "$got"
    fail=$((fail+1))
  fi
done

# At least 2 pages must display the full spine (index trace, architecture
# end-to-end, feature-machine spine, provenance flow strip) — fewer means the
# extraction went stale.
if [ "$qualifying" -ge 2 ]; then
  printf 'ok   %-44s\n' "spine-appears-in-site"
  pass=$((pass+1))
else
  printf 'FAIL %-44s only %s page(s) carry the full spine\n' \
    "spine-appears-in-site" "$qualifying"
  fail=$((fail+1))
fi

# ---- check 2: canonical boundary sentence -----------------------------------
# Normalize: strip tags, join lines, collapse whitespace, lowercase — the
# include capitalises "Every", boundary.html carries it mid-sentence in <b>.
normalize() {
  sed 's/<[^>]*>//g' | tr '\n' ' ' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

strip_file="$docs/_includes/boundary-strip.html"
sentence=""
if [ -f "$strip_file" ]; then
  sentence=$(sed -n 's/.*<span class="bs-sentence">\(.*\)<\/span>.*/\1/p' "$strip_file")
fi
if [ -z "$sentence" ]; then
  printf 'FAIL %-44s no single-line <span class="bs-sentence"> in %s\n' \
    "strip-sentence-present" "$strip_file"
  fail=$((fail+1))
else
  printf 'ok   %-44s\n' "strip-sentence-present"
  pass=$((pass+1))
fi

norm_sentence=$(printf '%s' "$sentence" | normalize)
norm_page=$(normalize < "$docs/boundary.html")
if [ -n "$norm_sentence" ] && printf '%s' "$norm_page" | grep -Fq "$norm_sentence"; then
  printf 'ok   %-44s\n' "sentence-in-boundary-page"
  pass=$((pass+1))
else
  printf 'FAIL %-44s boundary.html does not contain the strip sentence verbatim\n' \
    "sentence-in-boundary-page"
  fail=$((fail+1))
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
