#!/usr/bin/env bash
# Tests for scripts/dependency-check.sh — deterministic source-scan for undeclared client
# edges + dangling consumes (Slice 5 Task 4). Scans a unified diff against the registry's
# per-contract client_signature; reconciles against service.json consumes[]. No model call.
# Run: bash scripts/dependency-check.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DC="$DIR/dependency-check.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# setup <dir> <consumes-json> — service.json + a registry (ledger.post has a signature,
# fraud.score has none → unscanned).
setup() {
  local d="$1" cons="$2"
  mkdir -p "$d/registry/ledger.post" "$d/registry/fraud.score"
  printf '{"id":"app","team":"t","lifecycle":"production","data_classes":[],"produces":[],"consumes":%s}' "$cons" > "$d/service.json"
  printf '%s' '{"contract":"ledger.post","version":"1.0.0","kind":"openapi","client_signature":"ledgerClient\\.post\\("}' > "$d/registry/ledger.post/1.0.0.json"
  printf '%s' '{"contract":"fraud.score","version":"2.0.0","kind":"openapi"}' > "$d/registry/fraud.score/2.0.0.json"
}

# dc <name> <dir> <diff-file|-> <jq-filter>
dc() {
  local name="$1" d="$2" diff="$3" filt="$4" out
  if [ "$diff" = "-" ]; then
    out="$(bash "$DC" --service "$d/service.json" --registry "$d/registry" 2>/dev/null)"
  else
    out="$(bash "$DC" --service "$d/service.json" --registry "$d/registry" --diff "$diff" 2>/dev/null)"
  fi
  if printf '%s' "$out" | jq -e "$filt" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   %-44s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-44s got[%s]\n' "$name" "$out"
  fi
}

mkdiff() { printf '%s' "$2" > "$work/$1.diff"; printf '%s' "$work/$1.diff"; }

ADD='+++ b/src.py
@@ -1 +1,2 @@
 print("x")
+result = ledgerClient.post(payload)
'
DEL='+++ b/src.py
@@ -1,2 +1 @@
 print("x")
-result = ledgerClient.post(payload)
'
NEARMISS='+++ b/src.py
@@ -1 +1,2 @@
 print("x")
+result = ledgerClientXpost(payload)
'

d1="$work/d1"; setup "$d1" '["ledger.post@1"]'
dc "declared-edge-clean"          "$d1" "$(mkdiff add1 "$ADD")"   '.status=="clean"'

d2="$work/d2"; setup "$d2" '[]'
dc "undeclared-edge-blocked"      "$d2" "$(mkdiff add2 "$ADD")"   '.status=="blocked" and (.undeclared|index("ledger.post"))'

d3="$work/d3"; setup "$d3" '[]'
dc "removed-line-ignored"         "$d3" "$(mkdiff del3 "$DEL")"   '.status=="clean"'

d4="$work/d4"; setup "$d4" '["fraud.score@3"]'
dc "dangling-consume-blocked"     "$d4" "-"                       '.status=="blocked" and (.dangling|index("fraud.score@3"))'

d5="$work/d5"; setup "$d5" '["fraud.score@2"]'
dc "no-signature-listed-unscanned" "$d5" "-"                      '.unscanned_contracts|index("fraud.score")'

d6="$work/d6"; setup "$d6" '[]'
dc "signature-anchored-no-substring-match" "$d6" "$(mkdiff nm6 "$NEARMISS")" '.status=="clean"'

d7="$work/d7"; setup "$d7" '["ledger.post@1"]'
dc "clean-when-no-diff"           "$d7" "-"                       '.status=="clean"'

d8="$work/d8"; setup "$d8" '[]'
CRLF="$(printf '+++ b/src.py\r\n@@ -1 +1,2 @@\r\n print("x")\r\n+result = ledgerClient.post(payload)\r\n')"
dc "crlf-diff-parsed"             "$d8" "$(mkdiff crlf8 "$CRLF")" '.status=="blocked" and (.undeclared|index("ledger.post"))'

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
