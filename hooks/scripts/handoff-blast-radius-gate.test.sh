#!/usr/bin/env bash
# Tests for hooks/scripts/handoff-blast-radius-gate.sh (Slice 6, wires blast-radius [D-b]).
# PreToolUse Write|Edit: when a write transitions PROGRESS.md to PHASE: HANDOFF, FORCE a
# human gate (exit 2) when the change's blast radius is risky —
#   count >= 3 transitive consumers, OR money_movement/pii on a REACHED consumer,
#   OR money_movement/pii on the CHANGED service's OWN descriptor (the producer self-check).
# This slice has NO approved-transition branch (slice 6b adds it): a risky change ALWAYS
# blocks here. Inert otherwise; fail closed (exit 2) on '..', unreadable ACTIVE, missing jq.
# Consumer axis needs the estate catalog → resolved from the superproject (like
# epic-ratified-before-fanout.sh); standalone/git-missing skips it (producer axis still fires).
# Run: bash hooks/scripts/handoff-blast-radius-gate.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/handoff-blast-radius-gate.sh"
SIGSCRIPT="$DIR/../../scripts/blast-radius-signature.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# fire <name> <proj> <file_path> <content> <want-rc>
fire() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" --arg c "$content" '{tool_input:{file_path:$f,content:$c}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-46s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-46s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# mk_std <name> <data_classes-json> -> a standalone (non-submodule) project working tree.
# A plain mktemp dir is not a git submodule, so resolve_superproject is empty → the consumer
# axis is skipped and only the producer self-check runs.
mk_std() {
  local name="$1" dc="$2"
  local p="$work/$name"
  mkdir -p "$p/.sdd/feat"
  printf 'feat\n' > "$p/.sdd/ACTIVE"
  printf 'PHASE: CHANGE_REVIEW\n' > "$p/.sdd/feat/PROGRESS.md"
  printf '{"id":"app","team":"t","lifecycle":"production","data_classes":%s,"produces":[],"consumes":[]}' "$dc" > "$p/service.json"
  printf '%s' "$p"
}

# --- Producer self-check axis (no superproject; data_classes on the CHANGED service) ---
p=$(mk_std pmm '["money_movement"]');  fire "producer-money-movement-blocks"   "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mk_std ppii '["pii"]');            fire "producer-pii-blocks"              "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
p=$(mk_std pclean '[]');               fire "producer-clean-standalone-allows" "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

# --- Chokepoint / inert ---
p=$(mk_std nprog '["money_movement"]');  fire "non-progress-write-allows"        "$p" "src.py"               "PHASE: HANDOFF" 0
p=$(mk_std nbuild '["money_movement"]'); fire "non-handoff-progress-write-allows" "$p" ".sdd/feat/PROGRESS.md" "PHASE: BUILD"   0
p=$(mk_std nosvc '["money_movement"]'); rm -f "$p/service.json"
fire "no-service-json-inert" "$p" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
mkdir -p "$work/empty"
fire "no-active-feature-allows" "$work/empty" ".sdd/x/PROGRESS.md" "PHASE: HANDOFF" 0

# --- Fail closed ---
# traversal in the path → reject before the chokepoint
p=$(mk_std trav '["money_movement"]')
fire "traversal-rejected" "$p" ".sdd/../e/.sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

# unreadable ACTIVE → resolve_active errors under set -e → ERR trap → exit 2
up=$(mk_std unread '[]'); chmod 000 "$up/.sdd/ACTIVE"
rc=0; ( cd "$up" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | CLAUDE_PROJECT_DIR="$up" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$up/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-46s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-46s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

# jq missing while a feature is active → exit 2 + 'install jq' (require_jq, fail closed)
jp=$(mk_std jqmiss '[]')
stubnojq="$work/stubnojq"; mkdir -p "$stubnojq"
for b in bash head tr cat grep sed basename dirname find chmod mktemp pwd; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stubnojq/$b"; done
rc=0; err=$( cd "$jp" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | PATH="$stubnojq" CLAUDE_PROJECT_DIR="$jp" /bin/bash "$HOOK" 2>&1 >/dev/null ); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi "install jq"; then pass=$((pass+1)); printf 'ok   %-46s rc=2\n' "jq-missing-fails-closed-when-active"
else fail=$((fail+1)); printf 'FAIL %-46s want=2 got=%s err=[%s]\n' "jq-missing-fails-closed-when-active" "$rc" "$err"; fi

# --- Consumer blast-radius axis: a real superproject + an active member submodule, with
# plain sibling consumer dirs (catalog-derive globs $super/*/service.json — no submodule
# needed for the consumers). make_estate <name> <produces-json> <member-dc-json> [id:dcjson...]
make_estate() {
  local name="$1" produces="$2" memberdc="$3"; shift 3
  local super="$work/$name-super" src="$work/$name-src"
  mkdir -p "$super" "$src"
  ( cd "$src" && git init -q && git config user.email t@e && git config user.name t \
      && printf '{"id":"app","team":"t","lifecycle":"production","data_classes":%s,"produces":%s,"consumes":[]}' "$memberdc" "$produces" > service.json \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
  ( cd "$super" && git init -q && git config user.email t@e && git config user.name t && git commit --allow-empty -qm init \
      && git -c protocol.file.allow=always submodule add -q "$src" member ) >/dev/null 2>&1
  local spec id dc
  for spec in "$@"; do
    id="${spec%%:*}"; dc="${spec#*:}"
    mkdir -p "$super/$id"
    printf '{"id":"%s","team":"t","lifecycle":"production","data_classes":%s,"produces":[],"consumes":["ledger.post@1"]}' "$id" "$dc" > "$super/$id/service.json"
  done
  mkdir -p "$super/member/.sdd/feat"
  printf 'feat\n' > "$super/member/.sdd/ACTIVE"
  printf 'PHASE: CHANGE_REVIEW\n' > "$super/member/.sdd/feat/PROGRESS.md"
  printf '%s' "$super/member"
}

# write_approval <member> <sig> — record a HANDOFF_APPROVAL.md with the given signature.
write_approval() {
  local m="$1" s="$2"
  mkdir -p "$m/.sdd/feat"
  printf '# Handoff Approval — feat\n\nAPPROVED: 2026-06-28T00:00:00Z\nBLAST_RADIUS_SIGNATURE: %s\n' "$s" > "$m/.sdd/feat/HANDOFF_APPROVAL.md"
}
# add_consumer <member> <id> <dcjson> — add/overwrite a sibling consumer of ledger.post@1.
add_consumer() {
  local m="$1" id="$2" dc="$3"
  local super="${m%/member}"
  mkdir -p "$super/$id"
  printf '{"id":"%s","team":"t","lifecycle":"production","data_classes":%s,"produces":[],"consumes":["ledger.post@1"]}' "$id" "$dc" > "$super/$id/service.json"
}
# cursig <member> — the current blast-radius signature, exactly as the gate computes it.
cursig() { ( cd "$1" && bash "$SIGSCRIPT" | jq -r '.signature' ); }

git_ok=0
if command -v git >/dev/null 2>&1; then
  probe=$(make_estate probe '["ledger.post@1"]' '[]')
  [ -n "$(cd "$probe" && git rev-parse --show-superproject-working-tree 2>/dev/null)" ] && git_ok=1
fi

if [ "$git_ok" -eq 1 ]; then
  m=$(make_estate e1 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]" "c3:[]")
  fire "threshold-blast-blocks" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

  m=$(make_estate e2 '["ledger.post@1"]' '[]' 'c1:["money_movement"]')
  fire "money-movement-consumer-blocks" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

  # producer sensitive + clean below-threshold consumers: consumer axis WOULD allow (count 2,
  # no consumer flags); the producer self-check blocks on its own → 2.
  m=$(make_estate e3 '["ledger.post@1"]' '["money_movement"]' "c1:[]" "c2:[]")
  fire "producer-sensitive-clean-consumers-still-blocks" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

  # below threshold, all clean → allow
  m=$(make_estate e4 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]")
  fire "below-threshold-clean-allows" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

  # --- 6b: allow-when-approved + signature staleness (the tamper cycle) ---
  # approve at the current radius (3 consumers) → allow
  m=$(make_estate a1 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]" "c3:[]")
  write_approval "$m" "$(cursig "$m")"
  fire "approved-matching-signature-allows"     "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
  # widen the radius AFTER approval → recorded signature is now STALE → block (THE TAMPER TEST)
  add_consumer "$m" c4 '[]'
  fire "approval-stale-after-widening-blocks"    "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2
  # re-approve at the widened radius → allow again (re-pinned to the new blast radius)
  write_approval "$m" "$(cursig "$m")"
  fire "reapprove-after-widening-allows"         "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
  # a reached consumer gains money_movement after approval → stale → block
  m=$(make_estate a2 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]" "c3:[]")
  write_approval "$m" "$(cursig "$m")"
  add_consumer "$m" c1 '["money_movement"]'
  fire "approval-stale-after-class-appears-blocks" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 2

  # --- 6b INVERSE: an edit OUTSIDE the blast-radius signature must NOT invalidate the approval
  #     (else an over-binding digest silently wedges the gate on incidental mid-flight churn).
  #     These re-derive at HANDOFF and expect ALLOW; they FAIL against an over-binding digest. ---
  # estate churn unrelated to THIS contract's blast radius (a sensitive sibling that does NOT
  # consume ledger.post@1) → signature unchanged → approval SURVIVES.
  m=$(make_estate a3 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]" "c3:[]")
  write_approval "$m" "$(cursig "$m")"
  super="${m%/member}"; mkdir -p "$super/unrelated"
  printf '{"id":"unrelated","team":"t","lifecycle":"production","data_classes":["money_movement"],"produces":[],"consumes":["other.thing@1"]}' > "$super/unrelated/service.json"
  fire "unrelated-estate-churn-keeps-approval"     "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0
  # a NON-verdict field of the changed service's own descriptor (team/lifecycle/consumes) → SURVIVES.
  m=$(make_estate a4 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]" "c3:[]")
  write_approval "$m" "$(cursig "$m")"
  printf '{"id":"app","team":"RENAMED","lifecycle":"deprecated","data_classes":[],"produces":["ledger.post@1"],"consumes":["x.y@1"]}' > "$m/service.json"
  fire "non-verdict-descriptor-edit-keeps-approval" "$m" ".sdd/feat/PROGRESS.md" "PHASE: HANDOFF" 0

  # git missing → consumer axis skipped; member clean → allow (the fail-open boundary)
  stubgit="$work/stubgit"; mkdir -p "$stubgit"
  for b in bash basename dirname cat grep sed tr head find chmod mktemp jq sort pwd; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stubgit/$b"; done
  m=$(make_estate e5 '["ledger.post@1"]' '[]' "c1:[]" "c2:[]" "c3:[]")
  rc=0; ( cd "$m" && jq -nc '{tool_input:{file_path:".sdd/feat/PROGRESS.md",content:"PHASE: HANDOFF"}}' | PATH="$stubgit" CLAUDE_PROJECT_DIR="$m" /bin/bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-46s rc=0\n' "git-missing-inert"
  else fail=$((fail+1)); printf 'FAIL %-46s want=0 got=%s\n' "git-missing-inert" "$rc"; fi
else
  printf 'SKIP git-submodule fixtures (git unavailable or local-path submodules disabled)\n'
fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
