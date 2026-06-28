#!/usr/bin/env bash
# scripts/blast-radius-signature.sh [--catalog <file> | --root <dir>]
# THE single home of the blast-radius VERDICT + SIGNATURE for the service in the cwd (Slice 6b).
# Both the gate hook (verify) and handoff-approve-record.sh (record) call this, so the recorded
# approval digest and the gate's recomputed digest can never drift — the plan-digest.sh
# single-home pattern, one layer up.
#
# Emits one JSON line:
#   {"required":<bool>,"signature":"<digest|>","verdict":{"service":"<id>",
#     "producer_classes":[...],"contracts":[{"token","consumers":[...],"money_movement","pii"}...]}}
# required = producer_classes non-empty OR contracts non-empty.
# signature = digest of the CANONICAL verdict (jq -S → mktemp → plan-digest.sh; the SAME
#   shasum→sha256sum→cksum cascade), pinned to the consumer SET + classes. Empty when not required.
#
# Catalog: --catalog <file> (unit tests) | --root <dir> | else derive from the SUPERPROJECT
# (reverse edges live in sibling repos). The consumer axis is fail-OPEN when the estate cannot be
# resolved (no superproject / git / catalog) — the producer self-check (local service.json) still
# fires. Read-only. Exit 0 normally (incl. not-required); exit 1 only on a hard digest fault, so a
# caller that fails closed (the gate hook) does so.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

catalog_file=""; root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --catalog) catalog_file="${2:-}"; shift 2;;
    --root)    root="${2:-}"; shift 2;;
    --) shift;;
    -*) echo "blast-radius-signature: unknown flag $1" >&2; exit 2;;
    *)  echo "blast-radius-signature: unexpected arg $1" >&2; exit 2;;
  esac
done

emit() {  # emit <required-bool> <signature> <verdict-json>
  jq -nc --argjson req "$1" --arg sig "$2" --argjson v "$3" '{required:$req,signature:$sig,verdict:$v}'
}

# No descriptor → nothing to gate.
if [ ! -f service.json ]; then
  emit false "" '{"service":"","producer_classes":[],"contracts":[]}'; exit 0
fi

svc=$(bash "$DIR/service-descriptor.sh" read service.json id 2>/dev/null | head -n1 || true)

# Producer self-check (LOCAL): the changed service's own sensitive data_classes.
pc_acc=""
while IFS= read -r dc; do
  case "$dc" in money_movement|pii) pc_acc="${pc_acc}${dc}
";; esac
done <<EOF
$(bash "$DIR/service-descriptor.sh" read service.json data_classes 2>/dev/null || true)
EOF
pc_json=$(printf '%s' "$pc_acc" | grep -v '^$' | jq -R . | jq -s 'unique' 2>/dev/null || true)
[ -n "$pc_json" ] || pc_json='[]'

# Resolve the catalog (the consumer axis). Fail-open: empty → consumer axis skipped.
resolve_superproject() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --show-superproject-working-tree 2>/dev/null || true
}
catalog=""
if [ -n "$catalog_file" ]; then
  catalog=$(cat "$catalog_file" 2>/dev/null || true)
elif [ -n "$root" ]; then
  catalog=$(bash "$DIR/catalog-derive.sh" "$root" 2>/dev/null || true)
else
  super=$(resolve_superproject)
  [ -n "$super" ] && catalog=$(bash "$DIR/catalog-derive.sh" "$super" 2>/dev/null || true)
fi

# Consumer axis: per produced token, keep those that trip human_gate_required.
contracts_json='[]'
if [ -n "$catalog" ]; then
  catfile=$(mktemp); printf '%s' "$catalog" > "$catfile"
  c_acc=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    res=$(bash "$DIR/blast-radius.sh" "$tok" --catalog "$catfile" 2>/dev/null || true)
    [ -n "$res" ] || continue
    [ "$(printf '%s' "$res" | jq -r '.human_gate_required // false' 2>/dev/null || printf false)" = "true" ] || continue
    obj=$(printf '%s' "$res" | jq -c --arg t "$tok" '{token:$t,consumers:(.consumers|sort),money_movement:.money_movement,pii:.pii}' 2>/dev/null || true)
    [ -n "$obj" ] && c_acc="${c_acc}${obj}
"
  done <<EOF
$(bash "$DIR/service-descriptor.sh" read service.json produces 2>/dev/null || true)
EOF
  rm -f "$catfile"
  if [ -n "$(printf '%s' "$c_acc" | grep -v '^$' || true)" ]; then
    contracts_json=$(printf '%s' "$c_acc" | grep -v '^$' | jq -s 'sort_by(.token)')
  fi
fi

# Canonical verdict — jq -S sorts object keys recursively; arrays are pre-sorted above.
verdict=$(jq -nc -S --arg svc "$svc" --argjson pc "$pc_json" --argjson cs "$contracts_json" \
  '{service:$svc,producer_classes:$pc,contracts:$cs}')

required=false
[ "$(printf '%s' "$verdict" | jq -r '((.producer_classes|length)>0) or ((.contracts|length)>0)')" = "true" ] && required=true

signature=""
if [ "$required" = "true" ]; then
  tmp=$(mktemp); printf '%s' "$verdict" > "$tmp"
  signature=$(bash "$DIR/plan-digest.sh" "$tmp" 2>/dev/null || true)
  rm -f "$tmp"
  [ -n "$signature" ] || { echo "blast-radius-signature: digest failed" >&2; exit 1; }
fi

emit "$required" "$signature" "$verdict"
