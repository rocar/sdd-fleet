#!/usr/bin/env bash
# scripts/jira-payload-leak-check.sh — the SINGLE-SOURCE body-leak guard.
#
# Reads a payload on stdin and asserts it carries every --require token (positive
# controls, so a "no forbidden token" pass cannot be vacuous) and NONE of the
# --forbid tokens (the structured plan / contract body that must never reach Jira —
# story issues carry only high-level context + a vault pointer). Exit 0 = clean;
# 1 = a required token missing or a forbidden token present (which/why to stderr).
#
# One home for the guard, applied at two boundaries: epic-materialise.test.sh checks
# the script→adapter argv, jira-adapter.test.sh checks the adapter→Jira request body.
# Pure: no clock, no network, no state. Substring (grep -F) matching.
#   Usage: ... | jira-payload-leak-check.sh [--require <tok>]... [--forbid <tok>]...
set -uo pipefail
require=()
forbid=()
while [ $# -gt 0 ]; do
  case "$1" in
    --require) require+=("${2:-}"); shift 2 ;;
    --forbid)  forbid+=("${2:-}");  shift 2 ;;
    *) echo "jira-payload-leak-check: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

payload="$(cat)"
rc=0
# "${arr[@]:-}" keeps an empty array safe under set -u (bash 3.2); the "" iteration
# is skipped by the -n guard.
for t in "${require[@]:-}"; do
  [ -n "$t" ] || continue
  if ! printf '%s' "$payload" | grep -qF -- "$t"; then
    echo "jira-payload-leak-check: REQUIRED token absent (positive control failed): '$t'" >&2
    rc=1
  fi
done
for t in "${forbid[@]:-}"; do
  [ -n "$t" ] || continue
  if printf '%s' "$payload" | grep -qF -- "$t"; then
    echo "jira-payload-leak-check: FORBIDDEN token present (body leak): '$t'" >&2
    rc=1
  fi
done
exit $rc
