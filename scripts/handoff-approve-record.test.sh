#!/usr/bin/env bash
# Tests for scripts/handoff-approve-record.sh (Slice 6b) — records the human's approval of the
# CURRENT blast radius into .sdd/<slug>/HANDOFF_APPROVAL.md, pinned by BLAST_RADIUS_SIGNATURE
# (from blast-radius-signature.sh, the single home the gate re-verifies against).
# Producer-axis fixtures (local money_movement/pii) — no git superproject needed; the
# consumer-axis end-to-end is covered by handoff-blast-radius-gate.test.sh.
# Run: bash scripts/handoff-approve-record.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$DIR/handoff-approve-record.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %-44s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %-44s %s\n' "$1" "$2"; }

# mkfeat <name> <data_classes-json> -> a cwd with .sdd/ACTIVE=feat + a producer service.json.
mkfeat() {
  local name="$1" dc="$2"
  local p="$work/$name"
  mkdir -p "$p/.sdd/feat"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  printf '{"id":"app","team":"t","lifecycle":"production","data_classes":%s,"produces":[],"consumes":[]}' "$dc" > "$p/service.json"
  printf '%s' "$p"
}
REC_OUT=""; REC_RC=0
rec_run() { local p="$1"; shift; REC_OUT=$( ( cd "$p" && bash "$REC" "$@" 2>/dev/null ) ); REC_RC=$?; }
artsig() { { grep -m1 '^BLAST_RADIUS_SIGNATURE:' "$1/.sdd/feat/HANDOFF_APPROVAL.md" 2>/dev/null || true; } | sed -E 's/^BLAST_RADIUS_SIGNATURE:[[:space:]]*//' | tr -d '\r '; }
jqf() { printf '%s' "$REC_OUT" | jq -r "$1" 2>/dev/null; }

# 1. records + writes the signature field (artifact pins the same digest the output reports)
p=$(mkfeat rec '["money_movement"]')
rec_run "$p" feat --now 2026-06-28T00:00:00Z
if [ "$REC_RC" -eq 0 ] && [ "$(jqf '.status')" = recorded ] && [ -n "$(jqf '.signature')" ] && [ "$(artsig "$p")" = "$(jqf '.signature')" ]; then
  ok "records-and-pins-signature"; else no "records-and-pins-signature" "rc=$REC_RC out=$REC_OUT art=$(artsig "$p")"; fi

# 2. not-required → refuse, write nothing
p=$(mkfeat clean '[]')
rec_run "$p" feat --now 2026-06-28T00:00:00Z
if [ "$REC_RC" -eq 1 ] && [ "$(jqf '.status')" = not-required ] && [ ! -f "$p/.sdd/feat/HANDOFF_APPROVAL.md" ]; then
  ok "not-required-refuses-no-write"; else no "not-required-refuses-no-write" "rc=$REC_RC out=$REC_OUT"; fi

# 3. already-approved (matching signature) → idempotent refuse
p=$(mkfeat dup '["pii"]')
rec_run "$p" feat --now 2026-06-28T00:00:00Z          # first records
rec_run "$p" feat --now 2026-06-28T00:00:00Z          # second: same state
if [ "$REC_RC" -eq 1 ] && [ "$(jqf '.status')" = already-approved ]; then
  ok "already-approved-matching-refuses"; else no "already-approved-matching-refuses" "rc=$REC_RC out=$REC_OUT"; fi

# 4. stale existing approval → overwrite with the new signature
p=$(mkfeat stale '["money_movement"]')
rec_run "$p" feat --now 2026-06-28T00:00:00Z
sig1=$(artsig "$p")
printf '{"id":"app","team":"t","lifecycle":"production","data_classes":["money_movement","pii"],"produces":[],"consumes":[]}' > "$p/service.json"
rec_run "$p" feat --now 2026-06-28T00:00:00Z
sig2=$(artsig "$p")
if [ "$REC_RC" -eq 0 ] && [ "$(jqf '.status')" = recorded ] && [ -n "$sig2" ] && [ "$sig2" != "$sig1" ]; then
  ok "stale-existing-overwrites"; else no "stale-existing-overwrites" "rc=$REC_RC sig1=$sig1 sig2=$sig2"; fi

# 5. usage guards
p=$(mkfeat u1 '["pii"]')
rec_run "$p"                                            # no slug
[ "$REC_RC" -eq 1 ] && ok "usage-no-slug-refuses" || no "usage-no-slug-refuses" "rc=$REC_RC"
rec_run "$p" feat                                       # no --now
[ "$REC_RC" -eq 1 ] && ok "usage-no-now-refuses" || no "usage-no-now-refuses" "rc=$REC_RC"

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
