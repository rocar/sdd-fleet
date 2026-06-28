#!/usr/bin/env bash
# scripts/acquire-active.sh — atomic acquisition + release of the .sdd/ACTIVE
# in-flight lock (audit §3.32a: the previous check-then-write prose in
# /sdd-fleet:jira-story and /sdd-fleet:jira-story was a read-modify-write race).
#
# Acquisition is atomic via a noclobber (`set -C`) create of .sdd/ACTIVE.lock —
# exactly one caller can create the lock file; everyone else loses and is told
# who holds it. The lock carries owner metadata so a conflict names its holder:
#
#   OWNER: <caller-supplied id, e.g. "sdd-fleet:jira-story">
#   SLUG: <slug>
#   ACQUIRED: <iso8601, supplied via --now>
#
# On a successful acquire the slug is then written into .sdd/ACTIVE (the file
# every gate hook resolves — see hooks/scripts/_lib.sh resolve_active). Release
# verifies the slug, removes the lock, and EMPTIES .sdd/ACTIVE (the protocol's
# "empty = nothing active" convention; the file is never deleted).
#
# Determinism: this script never reads the wall clock — the timestamp comes in
# via --now from the caller (commands pass the same `now` they stamp into
# PROGRESS.md UPDATED), so runs are reproducible and testable. Consequently
# there is NO stale-lock auto-expiry: staleness is the CALLER'S judgment.
# `status` exposes owner/slug/held-since so a human or orchestrator can decide
# whether a holder is dead and release deliberately (release <slug>, or
# /sdd-fleet:park for the full sanctioned path).
#
# Scope: the lock serializes acquisition WITHIN one working tree. sdd-fleet
# assumes one orchestrator session per worktree; two clones of the same repo
# each have their own .sdd/ACTIVE[.lock] (both are gitignored per the .sdd/
# git policy in the sdd-protocol skill) and are not serialized against each
# other.
#
# Compatibility: an .sdd/ACTIVE that is non-empty with NO lock file (state
# scaffolded before this script existed, or a hand edit) still counts as held —
# acquire refuses against it (owner reported as "unknown") and release accepts
# the matching slug.
#
# Usage:
#   acquire-active.sh acquire <slug> --owner <id> --now <iso8601>
#   acquire-active.sh release <slug>
#   acquire-active.sh status
#
# Output (stdout, one line):
#   acquire ok   {"status":"acquired","slug":…,"owner":…,"held_since":…}
#   acquire held SDD_FLEET_ACTIVE_CONFLICT: {"requested":…,"active":…,"owner":…,"held_since":…}
#   release ok   {"status":"released","slug":…}
#   status       {"status":"held","slug":…,"owner":…,"held_since":…} | {"status":"free"}
# Exit: 0 = ok; 1 = conflict / refused / usage error (detail on stderr).
# Run from the target project's repo root (.sdd/ paths are cwd-relative, like
# the hooks). bash 3.2 compatible.
set -uo pipefail

SDD=".sdd"
ACTIVE="$SDD/ACTIVE"
LOCK="$SDD/ACTIVE.lock"

usage() {
  echo "usage: acquire-active.sh acquire <slug> --owner <id> --now <iso8601> | release <slug> | status" >&2
  exit 1
}

# Minimal JSON string escaping (backslash + double quote).
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Echo a "KEY: value" field from the lock file, or empty.
lock_field() {
  [ -f "$LOCK" ] || return 0
  { grep -m1 "^$1:" "$LOCK" 2>/dev/null || true; } \
    | sed -E "s/^$1:[[:space:]]*//" | tr -d '\r' | sed -E 's/[[:space:]]+$//'
}

# Echo the current .sdd/ACTIVE slug, or empty.
active_slug() {
  [ -f "$ACTIVE" ] || return 0
  head -n1 "$ACTIVE" 2>/dev/null | tr -d '[:space:]'
}

emit_conflict() { # <requested-slug> <active-slug> <owner> <held-since>
  printf 'SDD_FLEET_ACTIVE_CONFLICT: {"requested":"%s","active":"%s","owner":"%s","held_since":"%s"}\n' \
    "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")" "$(json_str "$4")"
  echo "acquire-active.sh: .sdd/ACTIVE is held — owner '${3}', slug '${2}', since '${4}'. Not acquired. (Stale? A human decides: release '${2}' or /sdd-fleet:park.)" >&2
}

mode="${1:-}"
case "$mode" in

  acquire)
    slug="${2:-}"
    case "$slug" in ""|--*) echo "acquire-active.sh: acquire requires a <slug>" >&2; usage ;; esac
    shift 2
    owner="" now=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --owner) owner="${2:-}"; shift 2 || usage ;;
        --now)   now="${2:-}";   shift 2 || usage ;;
        *) echo "acquire-active.sh: unknown argument '$1'" >&2; usage ;;
      esac
    done
    [ -n "$owner" ] || { echo "acquire-active.sh: acquire requires --owner <id>" >&2; usage; }
    [ -n "$now" ]   || { echo "acquire-active.sh: acquire requires --now <iso8601> (callers pass their own clock — this script never reads one)" >&2; usage; }

    mkdir -p "$SDD"
    # The atomic step: noclobber create. Exactly one concurrent caller wins.
    if ( set -C; printf 'OWNER: %s\nSLUG: %s\nACQUIRED: %s\n' "$owner" "$slug" "$now" > "$LOCK" ) 2>/dev/null; then
      # Lock won. Guard the pre-lock legacy state: ACTIVE non-empty without a
      # lock file still means an item is in flight — roll our lock back.
      cur="$(active_slug)"
      if [ -n "$cur" ] && [ "$cur" != "$slug" ]; then
        rm -f "$LOCK"
        emit_conflict "$slug" "$cur" "unknown" "unknown"
        exit 1
      fi
      printf '%s\n' "$slug" > "$ACTIVE"
      printf '{"status":"acquired","slug":"%s","owner":"%s","held_since":"%s"}\n' \
        "$(json_str "$slug")" "$(json_str "$owner")" "$(json_str "$now")"
      exit 0
    fi
    # Lock already exists → conflict. Report the holder's metadata.
    cur_owner="$(lock_field OWNER)"; cur_slug="$(lock_field SLUG)"; cur_since="$(lock_field ACQUIRED)"
    [ -n "$cur_slug" ] || cur_slug="$(active_slug)"
    emit_conflict "$slug" "${cur_slug:-unknown}" "${cur_owner:-unknown}" "${cur_since:-unknown}"
    exit 1
    ;;

  release)
    slug="${2:-}"
    [ -n "$slug" ] || { echo "acquire-active.sh: release requires a <slug>" >&2; usage; }
    [ $# -le 2 ] || { echo "acquire-active.sh: release takes only a <slug>" >&2; usage; }
    cur="$(active_slug)"
    lock_slug="$(lock_field SLUG)"
    if [ -z "$cur" ] && [ ! -f "$LOCK" ]; then
      echo "acquire-active.sh: lock is free — nothing to release for '$slug'." >&2
      exit 1
    fi
    # Verify the slug against ACTIVE (or the lock, for a crashed mid-acquire
    # where the lock was written but ACTIVE not yet).
    if [ "$cur" != "$slug" ] && ! { [ -z "$cur" ] && [ "$lock_slug" = "$slug" ]; }; then
      echo "acquire-active.sh: refused — .sdd/ACTIVE holds '${cur:-$lock_slug}', not '$slug'. Release the slug that actually holds the lock." >&2
      exit 1
    fi
    rm -f "$LOCK"
    : > "$ACTIVE"   # empty, never delete — "empty = nothing active"
    printf '{"status":"released","slug":"%s"}\n' "$(json_str "$slug")"
    exit 0
    ;;

  status)
    [ $# -le 1 ] || usage
    cur="$(active_slug)"
    if [ -f "$LOCK" ]; then
      printf '{"status":"held","slug":"%s","owner":"%s","held_since":"%s"}\n' \
        "$(json_str "$(lock_field SLUG)")" "$(json_str "$(lock_field OWNER)")" "$(json_str "$(lock_field ACQUIRED)")"
    elif [ -n "$cur" ]; then
      # Pre-lock legacy state: held, but no metadata to report.
      printf '{"status":"held","slug":"%s","owner":"unknown","held_since":"unknown"}\n' "$(json_str "$cur")"
    else
      printf '{"status":"free"}\n'
    fi
    exit 0
    ;;

  *)
    usage
    ;;
esac
