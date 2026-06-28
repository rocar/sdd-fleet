#!/usr/bin/env bash
# scripts/workflow-determinism-lint.sh — determinism + sandbox-safety gate for a
# *generated* workflow script, before it may be pinned into workflows/ (the
# "generate-then-pin" enrichment lane). sdd-fleet's auditable execution path is
# 100% static; this gate is the keystone that lets a workflow Claude authored on
# the fly become a committed, replayable workflow ONLY once it is proven free of
# the non-determinism and sandbox-escape patterns that would break repeatable,
# auditable execution.
#
# It statically rejects exactly what the Workflow runtime forbids (and thus what
# would throw or vary at run time), so a bad script is caught at authoring/pin
# time with a clear reason instead of mid-run:
#   - Date.now()           wall clock -> non-deterministic (runtime throws)
#   - Math.random()        non-deterministic (runtime throws)
#   - argless new Date()   wall clock (runtime throws). new Date(args.now) is fine.
#   - require() / import / process. / eval() / new Function / fetch() /
#     child_process / globalThis / __dirname / __filename
#                          filesystem/network/Node escape — unavailable in the
#                          sandbox; non-replayable side effects.
#   - missing `export const meta`   not a workflow contract.
#
# Comments and string/template literals are stripped BEFORE scanning, so a header
# that DOCUMENTS the banned patterns (e.g. workflows/review.js's own
# "NO Date.now()/Math.random()/new Date()" contract note) never false-trips.
#
# Conservative by design (mirrors guard-bash-writes.sh): a regex literal, or code
# inside a `${...}` template interpolation, can slip a pattern past the stripper
# (a false-ALLOW) — backstopped by the human ratification + adversarial review
# gates. A false-BLOCK is acceptable (fail-closed): the author revises and re-runs.
#
# Usage:   workflow-determinism-lint.sh <candidate-workflow.js>
# Output (stdout — the machine contract; see CLAUDE.md "signal lines"):
#   SDD_FLEET_LINT_VIOLATION: {"rule":"<slug>","line":<n>}   (one per finding)
#   SDD_FLEET_LINT_PASS: {"file":"<path>"}                   (clean)
#   SDD_FLEET_LINT_FAIL: {"violations":<n>}                  (>=1 finding)
#   SDD_FLEET_LINT_ERROR: {"reason":"<slug>"}                (fail-closed: bad input)
# Exit: 0 = clean; 2 = rejected (violations) OR fail-closed error.
# bash 3.2 compatible; BSD + GNU coreutils compatible; read-only.
set -euo pipefail
# Fail CLOSED on any unexpected runtime error (mirrors the gate hooks, audit §3.5):
# exit 2 = reject, never a silent non-blocking exit 1.
trap 'echo "sdd-fleet: workflow-determinism-lint errored unexpectedly — failing closed (reject)." >&2; printf "SDD_FLEET_LINT_ERROR: {\"reason\":\"internal-error\"}\n"; exit 2' ERR

file="${1:-}"

err() {  # err <reason-slug> <message>
  echo "sdd-fleet: $2" >&2
  printf 'SDD_FLEET_LINT_ERROR: {"reason":"%s"}\n' "$1"
  exit 2
}

[ -n "$file" ] || err "no-file" "no candidate workflow file given. Usage: workflow-determinism-lint.sh <file.js>"
# Reject any `..` segment before touching the path (audit §3.1 path traversal).
case "$file" in */../*|../*|*/..|..) err "path-traversal" "path '$file' contains a '..' segment — refused." ;; esac
[ -f "$file" ] && [ -r "$file" ] || err "unreadable" "'$file' is not a readable file."

# ---- strip comments + string/template literals (line numbers preserved) ----
# Char-level state machine: comment/string content becomes spaces; line count and
# newlines are preserved so violation line numbers match the source. State carries
# across lines (block comments, template literals). The single quote is passed in
# via -v sq because the awk program is itself single-quoted. See the conservatism
# note in the header for the documented false-ALLOW edges (regex literals, ${…}).
stripped="$(awk -v sq="'" '
  BEGIN { state = "code" }
  {
    line = $0; out = ""; n = length(line); i = 1
    while (i <= n) {
      c = substr(line, i, 1)
      d = (i < n) ? substr(line, i + 1, 1) : ""
      if (state == "code") {
        if (c == "/" && d == "/") { i = n + 1 }                       # line comment: drop rest
        else if (c == "/" && d == "*") { out = out "  "; i += 2; state = "block" }
        else if (c == "\"") { out = out " "; i += 1; state = "str_d" }
        else if (c == sq)   { out = out " "; i += 1; state = "str_s" }
        else if (c == "`")  { out = out " "; i += 1; state = "str_b" }
        else { out = out c; i += 1 }
      } else if (state == "block") {
        if (c == "*" && d == "/") { out = out "  "; i += 2; state = "code" }
        else { out = out " "; i += 1 }
      } else {                                                        # str_d / str_s / str_b
        if (c == "\\") { out = out "  "; i += 2 }                     # escape: drop \ + next char
        else if ((state == "str_d" && c == "\"") || (state == "str_s" && c == sq) || (state == "str_b" && c == "`")) { out = out " "; i += 1; state = "code" }
        else { out = out " "; i += 1 }
      }
    }
    print out
  }
' "$file")"

violations=0

emit() {  # emit <rule> <line> <stderr-detail>
  printf 'SDD_FLEET_LINT_VIOLATION: {"rule":"%s","line":%s}\n' "$1" "$2"
  printf '  %s (line %s): %s\n' "$1" "$2" "$3" >&2
  violations=$((violations + 1))
}

# scan <rule> <ERE> : report every matching line in the stripped source.
scan() {
  local rule="$1" re="$2" matches m ln txt
  matches="$(printf '%s\n' "$stripped" | grep -nE "$re" || true)"
  [ -n "$matches" ] || return 0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    ln="${m%%:*}"; txt="${m#*:}"
    txt="$(printf '%s' "$txt" | sed -e 's/^[[:space:]]*//')"
    emit "$rule" "$ln" "$txt"
  done <<< "$matches"
}

# A non-identifier left boundary so e.g. `updateDate.now`, `retrieval(`, or
# `renew Function` never match. POSIX `\b` is not portable across BSD/GNU; this is.
WB='(^|[^A-Za-z0-9_])'

# --- non-determinism (mirrors the runtime's banned APIs) ---
scan "date-now"         "${WB}Date\.now"
scan "math-random"      "${WB}Math\.random"
scan "argless-new-date" "${WB}new[[:space:]]+Date[[:space:]]*\([[:space:]]*\)"

# --- sandbox escape / Node + network API (unavailable; non-replayable) ---
scan "forbidden-api" "${WB}require[[:space:]]*\("
scan "forbidden-api" "${WB}import[[:space:]]*\("
scan "forbidden-api" "^[[:space:]]*import[[:space:]]"
scan "forbidden-api" "${WB}process\."
scan "forbidden-api" "${WB}child_process"
scan "forbidden-api" "${WB}globalThis"
scan "forbidden-api" "${WB}(__dirname|__filename)"
scan "forbidden-api" "${WB}eval[[:space:]]*\("
scan "forbidden-api" "${WB}new[[:space:]]+Function"
scan "forbidden-api" "${WB}fetch[[:space:]]*\("

# --- contract: a workflow must declare `export const meta` ---
if ! printf '%s\n' "$stripped" | grep -qE 'export[[:space:]]+const[[:space:]]+meta'; then
  emit "missing-meta" 0 "no 'export const meta' declaration — not a workflow contract"
fi

# --- TDZ ordering: SCRIBE_RESULT_SCHEMA must be declared ABOVE the first
# applyScribe() CALL. applyScribe is a hoisted function declaration, so the call
# resolves anywhere; but it reads the SCRIBE_RESULT_SCHEMA const via
# agent(...,{schema}). If the const's declaration line is at/below the first call
# site, every scribe apply throws "Cannot access 'SCRIBE_RESULT_SCHEMA' before
# initialization" (temporal dead zone) at run time — a deterministic failure
# `node --check` cannot see. This guards the exact bug class that hit
# review.js (fixed in 9e50f8a), deep-build.js, diagnose.js, and plan-review.js.
# We scan the stripped source (comments/strings are blanked), and exclude the
# hoisted `function applyScribe` declaration line so only CALL sites count.
scribe_call_line="$(printf '%s\n' "$stripped" | grep -nE "${WB}applyScribe[[:space:]]*\(" | grep -vE 'function[[:space:]]+applyScribe' | head -n1 | cut -d: -f1 || true)"
if [ -n "$scribe_call_line" ]; then
  schema_decl_line="$(printf '%s\n' "$stripped" | grep -nE "${WB}const[[:space:]]+SCRIBE_RESULT_SCHEMA${WB}" | head -n1 | cut -d: -f1 || true)"
  if [ -z "$schema_decl_line" ]; then
    emit "scribe-schema-tdz" "$scribe_call_line" "applyScribe() is called (line $scribe_call_line) but SCRIBE_RESULT_SCHEMA is never declared — the scribe schema read will throw at run time"
  elif [ "$schema_decl_line" -ge "$scribe_call_line" ]; then
    emit "scribe-schema-tdz" "$schema_decl_line" "SCRIBE_RESULT_SCHEMA declared at line $schema_decl_line, at/after the first applyScribe() call at line $scribe_call_line — temporal dead zone; every scribe apply throws 'Cannot access ... before initialization'. Hoist the const above the first call site."
  fi
fi

if [ "$violations" -gt 0 ]; then
  printf 'SDD_FLEET_LINT_FAIL: {"violations":%s}\n' "$violations"
  echo "sdd-fleet: $violations determinism/safety violation(s) — this generated workflow must NOT be pinned until fixed." >&2
  exit 2
fi

printf 'SDD_FLEET_LINT_PASS: {"file":"%s"}\n' "$file"
exit 0
