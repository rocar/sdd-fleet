#!/usr/bin/env bash
# scripts/status-snapshot.sh — deterministic, LLM-free machine-readable snapshot of
# a sdd-fleet project's .sdd/ state. Emits EXACTLY ONE JSON object on stdout
# (schema sdd-fleet/status-snapshot@2) and writes nothing.
#
# Purpose: let an external orchestrator POLL project state cheaply — no subagent,
# no model call, no token cost. /sdd-fleet:status is the human-readable view;
# this is the machine view that a cron/adapter consumes. Orchestrator-agnostic:
# the script knows nothing about where (or whether) the snapshot is published.
#
# Run from the target project's repo root — like the hooks, all .sdd/ paths are
# resolved relative to cwd (see hooks/scripts/_lib.sh).
#
# External pollers: ${CLAUDE_PLUGIN_ROOT} resolves only inside Claude Code —
# call this script via a checkout/clone path instead, or vendor it PRESERVING
# the relative layout (it sources ../hooks/scripts/_lib.sh and invokes its
# sibling next-feature.sh). Stability: additive schema changes keep @2;
# breaking changes bump the @N and get a CHANGELOG Compatibility line — pin on
# the schema value you understand (README "Orchestrator integration / polling").
#
# Single source of truth: backlog RESOLUTION + counts come from next-feature.sh
# (the v0.4 resolver, with its own 18-case harness). This script only ADDS the
# per-feature row listing (backlog.features[]) for display + delta-detection,
# using the SAME row-matching rules so the two never disagree.
#
# Contract (null product => no product tier; null active => nothing in flight):
#   {
#     "schema":"sdd-fleet/status-snapshot@2",
#     "generated_at":"2026-06-06T12:34:56Z",
#     "has_product":true,
#     "product":{
#       "phase":"DEVELOPING"|null,
#       "vision":"<one-liner>"|null,
#       "stack":"<one-liner>"|null,
#       "backlog":{"done":4,"total":9,"phases":4,
#                  "features":[{"slug":"auth","state":"pending"|"done",
#                               "phase":"Phase 2: Core","handoff":"2026-06-04"|null}]},
#       "next":{...next-feature.sh output verbatim...}
#     }|null,
#     "active":{
#       "slug":"...","lane":"feature"|"bug","phase":"BUILD"|null,
#       "status":"FINALIZED"|null,           # spec STATUS, or diagnosis STATUS for bugs
#       "cycle":N|null,"change_cycle":N|null,# feature lane
#       "sev":"sev1"|null,"fix_cycle":N|null,# bug lane
#       "escalated":true|false
#     }|null
#   }
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/_lib.sh
. "${SCRIPT_DIR}/../hooks/scripts/_lib.sh"

require_jq   # the snapshot is JSON; without jq we cannot emit/escape it safely.

SCHEMA="sdd-fleet/status-snapshot@2"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKLOG=".sdd/_product/backlog.md"

# Echo a "KEY: value" field from a free-text markdown file (trimmed), or empty.
grep_field() {
  local f="$1" field="$2"
  [ -f "$f" ] || return 0
  { grep -m1 "^${field}:" "$f" 2>/dev/null || true; } \
    | sed -E "s/^${field}:[[:space:]]*//" \
    | tr -d '\r' | sed -E 's/[[:space:]]+$//'
}

# Echo the first "meaningful" line of a markdown file: skips blanks, ATX
# headings, HTML/marker comments, and KEY: field lines. Used to derive a
# one-liner from vision.md / STACK.md. Empty if none.
first_meaningful_line() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '
    { gsub(/\r/, "") }
    /^[[:space:]]*$/        { next }
    /^[[:space:]]*#/        { next }
    /^[[:space:]]*<!--/     { next }
    /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]/ { next }   # KEY: value line
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "$f"
}

# Echo the count of "## Phase N:" headings in the backlog (0 if none/absent).
count_phases() {
  local f="$1" n
  [ -f "$f" ] || { printf '0'; return 0; }
  n=$(grep -cE '^##[[:space:]]+Phase[[:space:]]+[0-9]+:' "$f" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

# Emit the backlog feature rows as a JSON array. Mirrors next-feature.sh's
# matching rules EXACTLY (checkbox = done/pending; second token must be the
# state word so prose/star-bullet notes and indented intent lines are ignored)
# so backlog.features[] agrees with next-feature.sh's done/total. awk emits TSV;
# jq does all the JSON escaping.
parse_rows() {
  local f="$1"
  [ -f "$f" ] || { printf '[]'; return 0; }
  awk '
    function trim(s){ gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    { gsub(/\r/, "") }
    /^##[ \t]+Phase[ \t]+[0-9]+:/ {
      phase = $0
      sub(/^##[ \t]+/, "", phase)
      sub(/[ \t]+STATUS:.*$/, "", phase)
      sub(/[^A-Za-z0-9)]+$/, "", phase)
      next
    }
    /^[-*][ \t]+\[[ xX]\]/ {
      line = $0; rest = line
      sub(/^[-*][ \t]+\[[ xX]\][ \t]+/, "", rest)
      ntok = split(rest, tok, /[ \t]+/)
      word = (ntok >= 2) ? tolower(tok[2]) : ""
      if (word != "pending" && word != "done") next
      slug  = tok[1]
      state = (tolower(line) ~ /\[x\]/) ? "done" : "pending"
      handoff = ""
      if (match(rest, /handoff:[ \t]*/)) {
        handoff = substr(rest, RSTART + RLENGTH)
        sub(/[ \t].*$/, "", handoff)
        handoff = trim(handoff)
      }
      printf "%s\t%s\t%s\t%s\n", slug, state, phase, handoff
    }
  ' "$f" | jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t")) |
    map({slug:.[0], state:.[1], phase:(.[2] // ""),
         handoff:(if (.[3] // "") == "" then null else .[3] end)})'
}

# ---- product block ---------------------------------------------------------
product_json=null
if [ -f "$BACKLOG" ]; then
  prod_phase="$(read_product_field PHASE)"          # empty for pre-M3.1 tiers
  vision="$(grep_field .sdd/_product/vision.md OUTCOME)"
  [ -z "$vision" ] && vision="$(first_meaningful_line .sdd/_product/vision.md)"
  stack="$(first_meaningful_line .sdd/_product/STACK.md)"
  next_json="$(bash "${SCRIPT_DIR}/next-feature.sh" "$BACKLOG")"
  done_n="$(printf '%s' "$next_json"  | jq -r '.done  // 0')"
  total_n="$(printf '%s' "$next_json" | jq -r '.total // 0')"
  phases_n="$(count_phases "$BACKLOG")"
  features_json="$(parse_rows "$BACKLOG")"
  product_json="$(jq -n \
    --arg     phase    "$prod_phase" \
    --arg     vision   "$vision" \
    --arg     stack    "$stack" \
    --argjson done     "$done_n" \
    --argjson total    "$total_n" \
    --argjson phases   "$phases_n" \
    --argjson features "$features_json" \
    --argjson next     "$next_json" \
    '{phase:  (if $phase  == "" then null else $phase  end),
      vision: (if $vision == "" then null else $vision end),
      stack:  (if $stack  == "" then null else $stack  end),
      backlog:{done:$done, total:$total, phases:$phases, features:$features},
      next:$next}')"
fi

# ---- active item block -----------------------------------------------------
active_json=null
slug="$(resolve_active)"
if [ -n "$slug" ] && [ -d ".sdd/${slug}" ]; then
  lane="$(resolve_lane "$slug")"
  phase="$(read_progress_field "$slug" PHASE)"
  escalated=false
  [ -f ".sdd/${slug}/ESCALATION.md" ] && escalated=true
  if [ "$lane" = "bug" ]; then
    status="$(read_diagnosis_status "$slug")"
    sev="$(read_progress_field "$slug" SEV)"
    cycle="$(read_progress_field "$slug" CYCLE)"
    fix_cycle="$(read_progress_field "$slug" FIX_CYCLE)"
    active_json="$(jq -n \
      --arg slug "$slug" --arg lane "$lane" --arg phase "$phase" \
      --arg status "$status" --arg sev "$sev" \
      --arg cycle "$cycle" --arg fix_cycle "$fix_cycle" \
      --argjson escalated "$escalated" \
      '{slug:$slug, lane:$lane,
        phase: (if $phase  == "" then null else $phase  end),
        status:(if $status == "" then null else $status end),
        sev:   (if $sev    == "" then null else $sev    end),
        cycle:     (if $cycle     == "" then null else ($cycle|tonumber? // $cycle)         end),
        fix_cycle: (if $fix_cycle == "" then null else ($fix_cycle|tonumber? // $fix_cycle) end),
        escalated:$escalated}')"
  else
    status="$(read_spec_status "$slug")"
    cycle="$(read_progress_field "$slug" CYCLE)"
    change_cycle="$(read_progress_field "$slug" CHANGE_CYCLE)"
    active_json="$(jq -n \
      --arg slug "$slug" --arg lane "$lane" --arg phase "$phase" \
      --arg status "$status" --arg cycle "$cycle" --arg change_cycle "$change_cycle" \
      --argjson escalated "$escalated" \
      '{slug:$slug, lane:$lane,
        phase: (if $phase  == "" then null else $phase  end),
        status:(if $status == "" then null else $status end),
        cycle:        (if $cycle        == "" then null else ($cycle|tonumber? // $cycle)               end),
        change_cycle: (if $change_cycle == "" then null else ($change_cycle|tonumber? // $change_cycle) end),
        escalated:$escalated}')"
  fi
fi

# ---- assemble --------------------------------------------------------------
jq -n \
  --arg     schema       "$SCHEMA" \
  --arg     generated_at "$NOW" \
  --argjson product      "$product_json" \
  --argjson active       "$active_json" \
  '{schema:$schema, generated_at:$generated_at,
    has_product:($product != null), product:$product, active:$active}'
