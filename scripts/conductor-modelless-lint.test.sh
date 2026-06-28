#!/usr/bin/env bash
# scripts/conductor-modelless-lint.test.sh — the conductor's modelless +
# creation-free guarantee, GATED (not asserted in prose). A test-only lint that
# RE-DERIVES from the source bytes of conductor-tick.sh + ready-frontier.sh
# (mirrors rubric-drift.test.sh: trust the artifact, not a "I am modelless"
# comment). It strips full-line comments first (so the header documenting the
# banned tokens never false-trips), then scans the CODE for:
#   modelless    : no `date`/`gdate` command, no $RANDOM, no /dev/u?random;
#                  AND conductor-tick.sh DOES carry a --now handler (proof it is
#                  in the clock-injection camp, not merely clock-absent).
#   creation-free: no `jira-story` invocation, no create-story/create-epic verb,
#                  no read of plan.md/contracts.md.
# Two-sided: a TAMPER copy (banned tokens injected as CODE) must be caught; the
# INVERSE (same tokens inside a comment) must be ignored — with TEETH: a naive
# comment-blind scanner is shown to over-bind on that same file. Fails LOUDLY
# (counted FAIL) if a source is missing/empty or stripping nukes the code.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK="$DIR/conductor-tick.sh"
FRONTIER="$DIR/ready-frontier.sh"
LOOP="$DIR/conductor-loop.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %-44s %s\n' "$1" "${2:-}"; }
bad() { fail=$((fail+1)); printf 'FAIL %-44s %s\n' "$1" "${2:-}"; }

# Strip full-line comments (incl. the shebang) — the conservative strip; banned
# tokens that must survive scanning live in CODE, documentation lives in #-lines.
strip_comments() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }
# Banned non-determinism in CODE. `date`/`gdate` are word-bounded so update/
# validate/candidate/ACQUIRED never false-trip.
modelless_hits() { strip_comments "$1" | grep -nE '(^|[^A-Za-z0-9_])(date|gdate)([^A-Za-z0-9_]|$)|\$RANDOM|/dev/u?random'; }
# Banned creation / vault-read in CODE.
creation_hits()  { strip_comments "$1" | grep -nE 'jira-story|create-story|create-epic|plan\.md|contracts\.md'; }
# The over-binding ALTERNATIVE: no comment strip. Used only to give the inverse teeth.
naive_hits()     { grep -nE '(^|[^A-Za-z0-9_])date([^A-Za-z0-9_]|$)|create-story' "$1" 2>/dev/null; }

# ---- loud anchor: all conductor sources present + non-empty ----------------
for f in "$TICK" "$FRONTIER" "$LOOP"; do
  b="$(basename "$f")"
  if [ -s "$f" ]; then ok "source-readable:$b"; else bad "source-readable:$b" "missing/empty"; fi
done
# ---- loud extractor guard: stripping must leave real code behind -----------
for f in "$TICK" "$FRONTIER" "$LOOP"; do
  b="$(basename "$f")"
  if [ -s "$f" ] && strip_comments "$f" | grep -q 'set -'; then ok "extractor-nonempty:$b"; else bad "extractor-nonempty:$b" "strip left no code"; fi
done

# ---- the real sources must be clean (the property) ------------------------
if [ -s "$TICK" ] && [ -s "$FRONTIER" ] && [ -s "$LOOP" ]; then
  m="$(modelless_hits "$TICK"; modelless_hits "$FRONTIER"; modelless_hits "$LOOP")"
  if [ -z "$m" ]; then ok "modelless-clean"; else bad "modelless-clean" "[$m]"; fi
  c="$(creation_hits "$TICK"; creation_hits "$FRONTIER"; creation_hits "$LOOP")"
  if [ -z "$c" ]; then ok "creationfree-clean"; else bad "creationfree-clean" "[$c]"; fi
  if grep -q -- '--now' "$TICK"; then ok "tick-has-now-handler"; else bad "tick-has-now-handler" "conductor-tick.sh lacks --now (not in injection camp)"; fi

  # ---- tamper (RED): banned tokens as CODE must be caught -----------------
  t="$work/tamper.sh"; cp "$TICK" "$t"
  printf 'now=$(date -u +%%FT%%TZ)\n'         >> "$t"
  printf 'bash "$ADAPTER" create-story --story x\n' >> "$t"
  printf 'cat "$epicdir/plan.md"\n'           >> "$t"
  [ -n "$(modelless_hits "$t")" ] && ok "tamper-date-caught"      || bad "tamper-date-caught"
  [ -n "$(creation_hits  "$t")" ] && ok "tamper-creation-caught" || bad "tamper-creation-caught"

  # ---- inverse (GREEN): same tokens inside a comment are ignored ----------
  i="$work/inverse.sh"; cp "$TICK" "$i"
  printf '# never call date/gdate; never create-story or create-epic; never read plan.md/contracts.md\n' >> "$i"
  if [ -z "$(modelless_hits "$i")$(creation_hits "$i")" ]; then ok "inverse-comment-ignored"; else bad "inverse-comment-ignored" "comment false-tripped"; fi
  # teeth: the over-binding naive (strip-less) scanner DOES flag that comment
  if [ -n "$(naive_hits "$i")" ]; then ok "inverse-has-teeth(naive-overbinds)"; else bad "inverse-has-teeth" "naive scanner should have over-bound"; fi
else
  bad "sources-present-for-scan" "conductor-tick.sh and/or ready-frontier.sh missing — cannot run the lint"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
