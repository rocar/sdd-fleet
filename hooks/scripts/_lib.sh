#!/usr/bin/env bash
# Shared helpers for sdd-fleet hooks. Source from each script. All paths
# below are relative to the project root, anchored just below.

# Anchor every relative path (.sdd/ACTIVE, PROGRESS.md, …) at the project
# root: hooks can be spawned with a drifted cwd, and an empty resolve_active
# would silently disable every gate (audit §3.3). Claude Code exports
# CLAUDE_PROJECT_DIR; when it is unset (tests, direct invocation) stay in cwd.
# A sourced `exit` ends the calling hook process, which is the intent.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0

# Require jq for JSON parsing. Fail CLOSED while a feature is active: a gate
# silently converted to a no-op by a missing tool is the audit §3.4 fail-open
# hole. With no active feature there is nothing to guard — allow (exit 0) so
# bootstrap and unrelated sessions never block on tooling.
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    local slug
    slug=$(resolve_active) || {
      echo "sdd-fleet: jq not found and .sdd/ACTIVE is unreadable — failing closed. Install jq (brew install jq / apt install jq)." >&2
      exit 2
    }
    if [ -n "$slug" ]; then
      echo "sdd-fleet: jq is required by the gate hooks while a feature is active. Install jq (brew install jq / apt install jq) to proceed." >&2
      exit 2
    fi
    echo "sdd-fleet: jq not found; no feature is active so hook checks are skipped. Install jq (brew install jq / apt install jq) to enable enforcement." >&2
    exit 0
  fi
}

# Echo the file path a Write/Edit/NotebookEdit tool call targets, or empty.
# NotebookEdit carries notebook_path instead of file_path (audit §3.2).
# Usage: file_path=$(extract_file_path "$input")
extract_file_path() {
  printf '%s' "$1" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty'
}

# Echo the active feature slug, or empty string if none.
resolve_active() {
  local active_file=".sdd/ACTIVE"
  [ -f "$active_file" ] || return 0
  head -n1 "$active_file" 2>/dev/null | tr -d '[:space:]'
}

# Echo a field value from .sdd/<slug>/PROGRESS.md.
# Usage: read_progress_field <slug> <field>
read_progress_field() {
  local slug="$1" field="$2"
  local f=".sdd/${slug}/PROGRESS.md"
  [ -f "$f" ] || return 0
  { grep -m1 "^${field}:" "$f" 2>/dev/null || true; } \
    | sed -E "s/^${field}:[[:space:]]*//" \
    | tr -d '\r '
}

# Echo the product slug if a product tier is engaged, else empty string.
# (v0.4 product tier — mirrors resolve_active.) Reads the .sdd/PRODUCT marker
# written by /sdd-fleet:new-product; falls back to the PRODUCT: field of
# .sdd/_product/PROGRESS.md for tiers scaffolded before the marker existed.
# DORMANT in M3.0 — no gate keys off it yet; M3.1/M3.2 wire it in.
resolve_product() {
  local marker=".sdd/PRODUCT"
  if [ -f "$marker" ]; then
    head -n1 "$marker" 2>/dev/null | tr -d '[:space:]'
    return 0
  fi
  local prog=".sdd/_product/PROGRESS.md"
  [ -f "$prog" ] || return 0
  { grep -m1 "^PRODUCT:" "$prog" 2>/dev/null || true; } \
    | sed -E 's/^PRODUCT:[[:space:]]*//' \
    | tr -d '\r '
}

# Echo a field value from .sdd/_product/PROGRESS.md.
# Usage: read_product_field <field>   (e.g. PHASE, SIZE)  — DORMANT in M3.0.
read_product_field() {
  local field="$1"
  local f=".sdd/_product/PROGRESS.md"
  [ -f "$f" ] || return 0
  { grep -m1 "^${field}:" "$f" 2>/dev/null || true; } \
    | sed -E "s/^${field}:[[:space:]]*//" \
    | tr -d '\r '
}

# Echo the spec STATUS value (DRAFT|IN_REVIEW|FINALIZED|BLOCKED) for the
# active feature, or empty if spec.md or its STATUS line is absent.
# Usage: read_spec_status <slug>
read_spec_status() {
  local slug="$1"
  local f=".sdd/${slug}/spec.md"
  [ -f "$f" ] || return 0
  { head -n30 "$f" 2>/dev/null | grep -m1 "^STATUS:" || true; } \
    | sed -E 's/^STATUS:[[:space:]]*//' \
    | tr -d '\r '
}

# --- Troubleshoot-fix bug lane (v0.5 M0 foundations — DORMANT until M2) ---
# The bug lane's source-of-truth artifact is diagnosis.md (the analog of spec.md).
# These mirror the forward-machine resolvers. No M0 hook keys off them; M2 wires
# read_diagnosis_status + resolve_lane into block-source-before-finalized's second
# unlock and require-reproducing-test.sh, which also consumes tests_exist. Added in
# foundations, same dormant-helper pattern as resolve_product/read_product_field.

# Echo the diagnosis STATUS (REPORTED|REPRODUCING|DIAGNOSED|CONFIRMED|FIXED) for the
# active bug, or empty if diagnosis.md or its STATUS line is absent. Mirrors
# read_spec_status. Usage: read_diagnosis_status <slug>
read_diagnosis_status() {
  local slug="$1"
  local f=".sdd/${slug}/diagnosis.md"
  [ -f "$f" ] || return 0
  { head -n30 "$f" 2>/dev/null | grep -m1 "^STATUS:" || true; } \
    | sed -E 's/^STATUS:[[:space:]]*//' \
    | tr -d '\r '
}

# Echo "bug" if the slug's workspace carries a diagnosis.md (the bug lane's
# source-of-truth artifact), else "feature". Presence of diagnosis.md is the
# structural discriminator; the PROGRESS `LANE:` field is the parseable mirror.
# Usage: resolve_lane <slug>
resolve_lane() {
  local slug="$1"
  if [ -f ".sdd/${slug}/diagnosis.md" ]; then
    printf 'bug'
  else
    printf 'feature'
  fi
}

# Return 0 if at least one regular file exists under tests/, else 1. The
# reproducing-test precondition for M2's require-reproducing-test.sh: a bug source
# write requires a reproduction to already exist. Usage: tests_exist
tests_exist() {
  [ -d tests ] || return 1
  [ -n "$(find tests -type f 2>/dev/null | head -n1)" ]
}

# Return 0 if the path lives anywhere under .sdd/.
# Usage: path_in_sdd <file_path>
# Matches relative forms plus both the symlinked ($PWD) and physical (pwd -P)
# absolute cwd — necessary because a caller may address files via the canonical
# path (e.g. macOS /tmp -> /private/tmp) while $PWD holds the symlinked form.
path_in_sdd() {
  local p="$1"
  # Reject any `..` segment before the prefix match — `.sdd/../src/x` must
  # never count as inside .sdd/ (audit §3.1 path traversal).
  case "$p" in */../*|../*|*/..|..) return 1 ;; esac
  local phys; phys=$(pwd -P 2>/dev/null)
  case "$p" in
    .sdd/*|./.sdd/*|"$PWD/.sdd/"*|"$phys/.sdd/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Return 0 if the path lives under .sdd/<slug>/ specifically.
# Usage: path_in_active_sdd <file_path> <slug>
# Same symlinked-vs-physical cwd handling as path_in_sdd.
path_in_active_sdd() {
  local p="$1" slug="$2"
  # Reject any `..` segment before the prefix match (audit §3.1).
  case "$p" in */../*|../*|*/..|..) return 1 ;; esac
  local phys; phys=$(pwd -P 2>/dev/null)
  case "$p" in
    .sdd/"${slug}"/*|./.sdd/"${slug}"/*|"$PWD/.sdd/${slug}/"*|"$phys/.sdd/${slug}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Return 0 if the path lives under tests/ (the bug lane's reproducing-test home,
# always writable — even before CONFIRMED). Mirrors path_in_sdd's relative +
# symlinked/physical-cwd handling. Usage: path_in_tests <file_path>
path_in_tests() {
  local p="$1"
  # Reject any `..` segment before the prefix match (audit §3.1).
  case "$p" in */../*|../*|*/..|..) return 1 ;; esac
  local phys; phys=$(pwd -P 2>/dev/null)
  case "$p" in
    tests/*|./tests/*|"$PWD/tests/"*|"$phys/tests/"*) return 0 ;;
    *) return 1 ;;
  esac
}
