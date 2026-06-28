#!/usr/bin/env bash
# Tests for scripts/status-snapshot.sh (v0.3a machine-readable snapshot).
# Self-contained: builds .sdd/ fixtures in temp project dirs, runs the snapshot
# with cwd = that dir, asserts on the emitted JSON via jq.
# Run: bash scripts/status-snapshot.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="$DIR/status-snapshot.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
# eq <name> <actual> <expected>
eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'ok   %-32s = %s\n' "$name" "$got"
  else
    fail=$((fail+1)); printf 'FAIL %-32s want[%s] got[%s]\n' "$name" "$want" "$got"
  fi
}
# valid_json <name> <text>
valid_json() {
  local name="$1" text="$2"
  if printf '%s' "$text" | jq -e . >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   %-32s (valid json)\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %-32s (INVALID json) [%s]\n' "$name" "$text"
  fi
}
# q <text> <jq-filter>  -> raw value
q() { printf '%s' "$1" | jq -r "$2"; }

# ---- 1. bare repo (not a sdd-fleet project) ------------------------------
p="$work/bare"; mkdir -p "$p"
o="$(cd "$p" && bash "$SNAP")"
valid_json "bare-json" "$o"
eq "bare-has_product" "$(q "$o" '.has_product')" "false"
eq "bare-product"     "$(q "$o" '.product')"     "null"
eq "bare-active"      "$(q "$o" '.active')"       "null"
eq "bare-schema"      "$(q "$o" '.schema')"       "sdd-fleet/status-snapshot@2"

# ---- 2. product tier, no active feature ------------------------------------
p="$work/prod"; mkdir -p "$p/.sdd/_product"
printf 'OUTCOME: ship a fast CLI\n# Vision\nSome prose here.\n' > "$p/.sdd/_product/vision.md"
printf '# Stack\nGo + Cobra + Postgres\n'                       > "$p/.sdd/_product/STACK.md"
printf 'PRODUCT: acme\nPHASE: DEVELOPING\n'                     > "$p/.sdd/_product/PROGRESS.md"
cat > "$p/.sdd/_product/backlog.md" <<'EOF'
PRODUCT: acme
STATUS: FINALIZED

## Phase 1: Foundations — STATUS: complete
- [x] scaffold   DONE   depends-on: none   handoff:2026-06-01
## Phase 2: Core — STATUS: in-progress
- [ ] auth   PENDING   depends-on: scaffold
- [ ] api    PENDING   depends-on: scaffold
EOF
o="$(cd "$p" && bash "$SNAP")"
valid_json "prod-json" "$o"
eq "prod-has_product"   "$(q "$o" '.has_product')"                       "true"
eq "prod-phase"         "$(q "$o" '.product.phase')"                     "DEVELOPING"
eq "prod-vision"        "$(q "$o" '.product.vision')"                    "ship a fast CLI"
eq "prod-stack"         "$(q "$o" '.product.stack')"                     "Go + Cobra + Postgres"
eq "prod-done"          "$(q "$o" '.product.backlog.done')"             "1"
eq "prod-total"         "$(q "$o" '.product.backlog.total')"            "3"
eq "prod-phases"        "$(q "$o" '.product.backlog.phases')"           "2"
eq "prod-next-slug"     "$(q "$o" '.product.next.slug')"                "auth"
eq "prod-rows-len"      "$(q "$o" '.product.backlog.features | length')" "3"
eq "prod-row0-slug"     "$(q "$o" '.product.backlog.features[0].slug')"    "scaffold"
eq "prod-row0-state"    "$(q "$o" '.product.backlog.features[0].state')"   "done"
eq "prod-row0-phase"    "$(q "$o" '.product.backlog.features[0].phase')"   "Phase 1: Foundations"
eq "prod-row0-handoff"  "$(q "$o" '.product.backlog.features[0].handoff')" "2026-06-01"
eq "prod-row1-state"    "$(q "$o" '.product.backlog.features[1].state')"   "pending"
eq "prod-row1-handoff"  "$(q "$o" '.product.backlog.features[1].handoff')" "null"
eq "prod-active-null"   "$(q "$o" '.active')"                            "null"

# ---- 3. active feature, no product tier ------------------------------------
# (PROGRESS carries the SDD_SCHEMA stamp — readers grep named fields and must
# ignore it; every assertion below doubles as the graceful-ignore check.)
p="$work/feat"; mkdir -p "$p/.sdd/auth"
printf 'auth\n'                                                  > "$p/.sdd/ACTIVE"
printf 'SDD_SCHEMA: 1\nPHASE: BUILD\nCYCLE: 1\nCHANGE_CYCLE: 0\nUPDATED: x\n' > "$p/.sdd/auth/PROGRESS.md"
printf 'STATUS: FINALIZED\n# Spec\n'                             > "$p/.sdd/auth/spec.md"
o="$(cd "$p" && bash "$SNAP")"
valid_json "feat-json" "$o"
eq "feat-product-null"  "$(q "$o" '.product')"            "null"
eq "feat-has_product"   "$(q "$o" '.has_product')"        "false"
eq "feat-slug"          "$(q "$o" '.active.slug')"        "auth"
eq "feat-lane"          "$(q "$o" '.active.lane')"        "feature"
eq "feat-phase"         "$(q "$o" '.active.phase')"       "BUILD"
eq "feat-status"        "$(q "$o" '.active.status')"      "FINALIZED"
eq "feat-cycle"         "$(q "$o" '.active.cycle')"       "1"
eq "feat-change_cycle"  "$(q "$o" '.active.change_cycle')" "0"
eq "feat-escalated"     "$(q "$o" '.active.escalated')"   "false"

# ---- 4. escalated feature --------------------------------------------------
printf 'phase: BUILD\ncycle 3 exhausted\n' > "$p/.sdd/auth/ESCALATION.md"
o="$(cd "$p" && bash "$SNAP")"
eq "esc-escalated"      "$(q "$o" '.active.escalated')"   "true"

# ---- 5. bug lane -----------------------------------------------------------
p="$work/bug"; mkdir -p "$p/.sdd/login-500"
printf 'login-500\n'                                                   > "$p/.sdd/ACTIVE"
printf 'SDD_SCHEMA: 1\nPHASE: DIAGNOSE\nLANE: bug\nSEV: sev1\nCYCLE: 2\nFIX_CYCLE: 0\n' > "$p/.sdd/login-500/PROGRESS.md"
printf 'STATUS: CONFIRMED\n# Diagnosis\n'                              > "$p/.sdd/login-500/diagnosis.md"
o="$(cd "$p" && bash "$SNAP")"
valid_json "bug-json" "$o"
eq "bug-lane"           "$(q "$o" '.active.lane')"                    "bug"
eq "bug-status"         "$(q "$o" '.active.status')"                  "CONFIRMED"
eq "bug-sev"            "$(q "$o" '.active.sev')"                     "sev1"
eq "bug-phase"          "$(q "$o" '.active.phase')"                   "DIAGNOSE"
eq "bug-cycle"          "$(q "$o" '.active.cycle')"                   "2"
eq "bug-fix_cycle"      "$(q "$o" '.active.fix_cycle')"               "0"
eq "bug-no-changecycle" "$(q "$o" '.active.change_cycle // "absent"')" "absent"

# ---- 6. prose / star-bullet rows excluded from features[] ------------------
p="$work/prose"; mkdir -p "$p/.sdd/_product"
cat > "$p/.sdd/_product/backlog.md" <<'EOF'
PRODUCT: x
STATUS: FINALIZED

## Phase 1: P1 — STATUS: in-progress
* [x] we decided to use postgres
- [ ] real-feature   PENDING   depends-on: none
EOF
o="$(cd "$p" && bash "$SNAP")"
eq "prose-rows-len"     "$(q "$o" '.product.backlog.features | length')" "1"
eq "prose-row-slug"     "$(q "$o" '.product.backlog.features[0].slug')"  "real-feature"
eq "prose-total"        "$(q "$o" '.product.backlog.total')"             "1"

# ---- 7. indented intent lines invisible to features[] ----------------------
p="$work/intent"; mkdir -p "$p/.sdd/_product"
cat > "$p/.sdd/_product/backlog.md" <<'EOF'
PRODUCT: x
STATUS: FINALIZED

## Phase 1: P1 — STATUS: in-progress
- [x] cli   DONE   depends-on: none   handoff:2026-06-03
      An indented intent line that must be ignored.
- [ ] api   PENDING   depends-on: cli
EOF
o="$(cd "$p" && bash "$SNAP")"
eq "intent-rows-len"    "$(q "$o" '.product.backlog.features | length')" "2"
eq "intent-row1-slug"   "$(q "$o" '.product.backlog.features[1].slug')"  "api"

# ---- 8. stale ACTIVE pointing at a missing dir -> active null --------------
p="$work/stale"; mkdir -p "$p/.sdd"
printf 'ghost\n' > "$p/.sdd/ACTIVE"
o="$(cd "$p" && bash "$SNAP")"
valid_json "stale-json" "$o"
eq "stale-active-null"  "$(q "$o" '.active')" "null"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
