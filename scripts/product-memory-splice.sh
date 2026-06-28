#!/usr/bin/env bash
# scripts/product-memory-splice.sh — deterministic product-memory block splice
# (audit §3.29). Replaces the model-driven Edit splice in /sdd-fleet:product-memory
# and /sdd-fleet:plan-finalize step 7b with a tested, non-clobbering script.
#
# The target is the user-owned repo-root CLAUDE.md. Only the region between the
# sdd-fleet markers is ever rewritten; everything outside is preserved
# byte-for-byte. Markers (matching the sdd-protocol skill + product-memory.md):
#   BEGIN — any line starting with:  <!-- BEGIN sdd-fleet:product
#           (prefix match — the trailing prose may differ between versions)
#   END   — the exact line:          <!-- END sdd-fleet:product -->
#
# Usage: product-memory-splice.sh <target-CLAUDE.md-path>
#        stdin = the new block content, WITHOUT the markers.
#
# Behavior:
#   no file              → create it containing just the marked block
#   both markers present → replace the region (BEGIN..END inclusive) with the
#                          new marked block; everything outside untouched
#   no markers           → append the marked block at EOF (after a blank line)
#   BEGIN without END    → error, exit 1, NO write (corrupt region — a blind
#                          splice could eat user content)
#   END without BEGIN    → error, exit 1, NO write (same reasoning)
#
# Prints one status word on stdout: created | updated-in-place | appended
# (the values /sdd-fleet:product-memory's OK signal reports).
# Exit: 0 = spliced; 1 = bad usage or corrupt markers (no write). bash 3.2.
set -uo pipefail

BEGIN_MARK='<!-- BEGIN sdd-fleet:product -->'
BEGIN_PREFIX='<!-- BEGIN sdd-fleet:product'
END_MARK='<!-- END sdd-fleet:product -->'

target="${1:-}"
if [ -z "$target" ]; then
  echo "product-memory-splice.sh: usage: product-memory-splice.sh <target-CLAUDE.md> < block" >&2
  exit 1
fi

block="$(cat)"   # new block content, sans markers

emit_block() {
  printf '%s\n' "$BEGIN_MARK"
  printf '%s\n' "$block"
  printf '%s\n' "$END_MARK"
}

# --- no file: create it containing just the block ---
if [ ! -f "$target" ]; then
  tmp="${target}.tmp.$$"
  emit_block > "$tmp"
  mv "$tmp" "$target"
  echo "created"
  exit 0
fi

# --- locate the markers (first BEGIN-prefixed line; first exact END line) ---
begin_ln="$(grep -nF "$BEGIN_PREFIX" "$target" | head -1 | cut -d: -f1 || true)"
end_ln="$(grep -nxF "$END_MARK" "$target" | head -1 | cut -d: -f1 || true)"

if [ -n "$begin_ln" ] && [ -z "$end_ln" ]; then
  echo "product-memory-splice.sh: BEGIN marker without END in $target — refusing to write (fix the markers by hand)" >&2
  exit 1
fi
if [ -z "$begin_ln" ] && [ -n "$end_ln" ]; then
  echo "product-memory-splice.sh: END marker without BEGIN in $target — refusing to write (fix the markers by hand)" >&2
  exit 1
fi
if [ -n "$begin_ln" ] && [ -n "$end_ln" ] && [ "$end_ln" -lt "$begin_ln" ]; then
  echo "product-memory-splice.sh: END marker precedes BEGIN in $target — refusing to write (fix the markers by hand)" >&2
  exit 1
fi

tmp="${target}.tmp.$$"
if [ -n "$begin_ln" ]; then
  # --- both markers present: replace the region, preserve outside byte-for-byte ---
  {
    head -n "$((begin_ln - 1))" "$target"
    emit_block
    tail -n "+$((end_ln + 1))" "$target"
  } > "$tmp"
  mv "$tmp" "$target"
  echo "updated-in-place"
else
  # --- no markers: append at EOF, after a separating blank line ---
  {
    cat "$target"
    # ensure the existing content ends with a newline before we add ours
    if [ -s "$target" ] && [ "$(tail -c 1 "$target" | wc -l | tr -d ' ')" -eq 0 ]; then
      printf '\n'
    fi
    printf '\n'
    emit_block
  } > "$tmp"
  mv "$tmp" "$target"
  echo "appended"
fi
exit 0
