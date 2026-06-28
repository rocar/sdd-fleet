#!/usr/bin/env bash
# scripts/jira-adapter.sh — the real, DETERMINISTIC Jira backend for the
# SDD_JIRA_ADAPTER seam (epic-materialise.sh + the modelless conductor-tick.sh).
# A plain CLI: `bash jira-adapter.sh <verb> --flags` -> `JIRA_KEY: <key>` / JSON on
# stdout. NOT the Atlassian MCP server (that is a model-facing JSON-RPC server; the
# conductor has no model and the seam is a deterministic CLI — REST is the fit).
#
# Verbs (exact seam contracts):
#   create-epic    --slug <s> --now <iso>                                  -> JIRA_KEY: <key>
#   create-story   --epic-key <k> --story <id> --repo <r> --now <iso>      -> JIRA_KEY: <key>
#   jira-snapshot  --epic-key <k> --now <iso>   -> {"epic","stories":[{id,key,status,consumes,repo}]}
#   jira-transition --epic-key <k> --story <id> --to <status> --now <iso>  -> {"status":"transitioned"|"noop"}
#
# Three modes (DEFAULT = safe):
#   unconfigured (neither flag)        -> prints {"status":"unconfigured"} and exits 0; callers
#                                          soft-defer exactly as for "no adapter" (no network).
#   dry-run (SDD_JIRA_DRYRUN=1)         -> builds the real request + appends it to $SDD_JIRA_RECORD;
#                                          create-* return DRYRUN keys; no network. Preview + test.
#   live (SDD_JIRA_LIVE=1 + creds)      -> real curl against the Jira Cloud REST API.
#
# Config (env; instance-specific): JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN (Basic Auth),
#   JIRA_PROJECT_KEY, JIRA_EPIC_ISSUETYPE (Epic), JIRA_STORY_ISSUETYPE (Story),
#   JIRA_STATUS_NOTSTARTED (To Do), JIRA_STATUS_DISPATCHED (Dispatched).
#
# Body-leak guard (single-source): a story issue carries the id + a VAULT POINTER only,
# never the plan/contract body. jira_story_description is the ONE place a body is built;
# guard_story_payload fails CLOSED (no send) if a payload's description ever differs from it.
#
# STATED LIMIT: `consumes` edge-projection is not wired in epic-materialise yet, so a live
# jira-snapshot returns consumes:[] (the adapter reads an sdd-consumes label that nothing
# stamps today). Until that lands, DO NOT run the conductor live against a multi-dependency
# epic — it would dispatch every story immediately. See workspace-tier.md.
#
# Sourceable: defines functions; _jira_adapter_main runs only when executed directly, so the
# test can `source` this file to unit-test the pure builders/mappers without a network.

# ---------------- pure helpers (no clock, no network, no state) ----------------
adf_text() { jq -nc --arg t "$1" '{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$t}]}]}'; }

# THE single home where a story body is built: id + repo + a vault pointer ONLY.
jira_story_description() { # <id> <repo> <epic-key>
  printf 'sdd-fleet story %s (repo: %s) of epic %s. Plan, contracts, and acceptance live in the workspace .sdd/_epic/ vault; this issue carries intent and status only — never the plan body.' "$1" "${2:-}" "$3"
}

build_epic_payload() { # <slug>
  jq -nc --arg pk "${JIRA_PROJECT_KEY:-SDD}" --arg it "${JIRA_EPIC_ISSUETYPE:-Epic}" --arg sum "$1" \
    '{fields:{project:{key:$pk},issuetype:{name:$it},summary:$sum}}'
}
build_story_payload() { # <id> <repo> <epic-key>
  jq -nc --arg pk "${JIRA_PROJECT_KEY:-SDD}" --arg it "${JIRA_STORY_ISSUETYPE:-Story}" \
    --arg sum "$1" --argjson desc "$(adf_text "$(jira_story_description "$1" "${2:-}" "$3")")" \
    --arg parent "$3" --arg lid "sdd-id:$1" --arg lrepo "sdd-repo:${2:-}" \
    '{fields:{project:{key:$pk},issuetype:{name:$it},summary:$sum,description:$desc,parent:{key:$parent},labels:[$lid,$lrepo]}}'
}
# Fail-closed structural guard: the description text must be EXACTLY the id+pointer template,
# proving nothing beyond the single builder reached the body. 0 = clean, 1 = leak (no send).
guard_story_payload() { # <payload-json> <id> <repo> <epic-key>
  local got exp
  got="$(printf '%s' "$1" | jq -r '.fields.description.content[0].content[0].text // ""' 2>/dev/null)"
  exp="$(jira_story_description "$2" "${3:-}" "$4")"
  if [ "$got" != "$exp" ]; then
    echo "jira-adapter: body-leak guard tripped — story description is not the id+vault-pointer template; refusing to send." >&2
    return 1
  fi
  return 0
}
build_search_payload() { # <epic-key>
  jq -nc --arg jql "parent = $1 ORDER BY created ASC" '{jql:$jql,fields:["status","labels","summary"],maxResults:100}'
}
map_search_response() { # <epic-key> <search-json>  -> the snapshot shape
  printf '%s' "$2" | jq -c --arg e "$1" --arg ns "${JIRA_STATUS_NOTSTARTED:-To Do}" --arg disp "${JIRA_STATUS_DISPATCHED:-Dispatched}" '
    def lbl($p): (.fields.labels // [] | map(select(startswith($p))) | (.[0] // "") | sub("^"+$p; ""));
    {epic:$e, stories: [ .issues[]? | {
      id:       lbl("sdd-id:"),
      key:      .key,
      status:   ((.fields.status.name // "") | if . == $ns then "NOT_STARTED" elif . == $disp then "DISPATCHED" else . end),
      consumes: (.fields.labels // [] | map(select(startswith("sdd-consumes:"))) | map(sub("^sdd-consumes:"; ""))),
      repo:     lbl("sdd-repo:")
    } ] }'
}
decide_transition() { # <current-mapped-status> <target>  -> "noop" | "transition"
  if [ "$1" = "$2" ]; then printf 'noop'; else printf 'transition'; fi
}

# ---------------- I/O helpers (live only) ----------------
_record() { # <method> <url> <body>
  [ -n "${SDD_JIRA_RECORD:-}" ] || return 0
  { printf '%s %s\n' "$1" "$2"; printf '%s\n' "$3"; } >> "$SDD_JIRA_RECORD"
}
_post() { # <url> <body> -> stdout response body; nonzero on curl/HTTP error
  local tmp code rc resp; tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" --data "$2" "$1" 2>/dev/null)"; rc=$?
  resp="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  [ "$rc" -eq 0 ] || { echo "jira-adapter: curl failed for $1" >&2; return 1; }
  case "$code" in 2*) printf '%s' "$resp"; return 0 ;; *) echo "jira-adapter: HTTP $code from $1: $resp" >&2; return 1 ;; esac
}
_get() { # <url> -> stdout response body; nonzero on curl/HTTP error
  local tmp code rc resp; tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H 'Accept: application/json' \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" "$1" 2>/dev/null)"; rc=$?
  resp="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  [ "$rc" -eq 0 ] || { echo "jira-adapter: curl failed for $1" >&2; return 1; }
  case "$code" in 2*) printf '%s' "$resp"; return 0 ;; *) echo "jira-adapter: HTTP $code from $1: $resp" >&2; return 1 ;; esac
}
_live_transition() { # <epic-key> <slug> <target-status>
  local sbody sresp key cur tresp tid
  sbody="$(jq -nc --arg jql "parent = $1 AND labels = \"sdd-id:$2\"" '{jql:$jql,fields:["status"],maxResults:1}')"
  sresp="$(_post "${JIRA_BASE_URL}/rest/api/3/search/jql" "$sbody")" || return 1
  key="$(printf '%s' "$sresp" | jq -r '.issues[0].key // empty')"
  cur="$(printf '%s' "$sresp" | jq -r '.issues[0].fields.status.name // empty')"
  [ -n "$key" ] || { echo "jira-adapter: jira-transition: story $2 not found under $1" >&2; return 1; }
  if [ "$(decide_transition "$cur" "$3")" = noop ]; then
    printf '{"status":"noop","story":"%s","to":"%s"}\n' "$2" "$3"; return 0
  fi
  tresp="$(_get "${JIRA_BASE_URL}/rest/api/3/issue/${key}/transitions")" || return 1
  tid="$(printf '%s' "$tresp" | jq -r --arg d "$3" '.transitions[]? | select(.to.name==$d) | .id' | head -n1)"
  [ -n "$tid" ] || { echo "jira-adapter: no transition into '$3' for $key" >&2; return 1; }
  _post "${JIRA_BASE_URL}/rest/api/3/issue/${key}/transitions" "$(jq -nc --arg id "$tid" '{transition:{id:$id}}')" >/dev/null || return 1
  printf '{"status":"transitioned","story":"%s","to":"%s"}\n' "$2" "$3"
}

# ---------------- main (runs only when executed, not when sourced) ----------------
_jira_adapter_main() {
  set -uo pipefail
  command -v jq >/dev/null 2>&1 || { echo "jira-adapter: jq is required — failing closed." >&2; return 2; }
  local verb="${1:-}"; shift 2>/dev/null || true
  local slug="" epic_key="" story="" repo="" to="" now=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --epic-key) epic_key="${2:-}"; shift 2 ;;
      --story) story="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --to) to="${2:-}"; shift 2 ;;
      --now) now="${2:-}"; shift 2 ;;
      *) echo "jira-adapter: unknown argument '$1'" >&2; return 2 ;;
    esac
  done

  local mode=unconfigured
  if [ "${SDD_JIRA_DRYRUN:-}" = "1" ]; then
    mode=dryrun
  elif [ "${SDD_JIRA_LIVE:-}" = "1" ]; then
    if [ -n "${JIRA_BASE_URL:-}" ] && [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_API_TOKEN:-}" ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
      mode=live
    else
      echo "jira-adapter: SDD_JIRA_LIVE=1 but JIRA_BASE_URL/JIRA_EMAIL/JIRA_API_TOKEN/JIRA_PROJECT_KEY incomplete — failing closed." >&2
      return 2
    fi
  fi
  if [ "$mode" = unconfigured ]; then
    printf '{"status":"unconfigured","adapter":"jira-rest","reason":"set SDD_JIRA_DRYRUN=1 to preview, or SDD_JIRA_LIVE=1 + JIRA_* creds to enable"}\n'
    return 0
  fi

  local base="${JIRA_BASE_URL:-https://example.invalid}"
  local disp="${JIRA_STATUS_DISPATCHED:-Dispatched}"
  local body url resp key
  case "$verb" in
    create-epic)
      [ -n "$slug" ] || { echo "jira-adapter: create-epic requires --slug" >&2; return 2; }
      body="$(build_epic_payload "$slug")"; url="${base}/rest/api/3/issue"
      if [ "$mode" = dryrun ]; then _record POST "$url" "$body"; printf 'JIRA_KEY: DRYRUN-EPIC-%s\n' "$slug"; return 0; fi
      resp="$(_post "$url" "$body")" || return 1
      key="$(printf '%s' "$resp" | jq -r '.key // empty')"
      [ -n "$key" ] || { echo "jira-adapter: create-epic: no key in response: $resp" >&2; return 1; }
      printf 'JIRA_KEY: %s\n' "$key" ;;
    create-story)
      { [ -n "$story" ] && [ -n "$epic_key" ]; } || { echo "jira-adapter: create-story requires --epic-key + --story" >&2; return 2; }
      body="$(build_story_payload "$story" "$repo" "$epic_key")"; url="${base}/rest/api/3/issue"
      guard_story_payload "$body" "$story" "$repo" "$epic_key" || return 1
      if [ "$mode" = dryrun ]; then _record POST "$url" "$body"; printf 'JIRA_KEY: DRYRUN-%s\n' "$story"; return 0; fi
      resp="$(_post "$url" "$body")" || return 1
      key="$(printf '%s' "$resp" | jq -r '.key // empty')"
      [ -n "$key" ] || { echo "jira-adapter: create-story: no key in response: $resp" >&2; return 1; }
      printf 'JIRA_KEY: %s\n' "$key" ;;
    jira-snapshot)
      [ -n "$epic_key" ] || { echo "jira-adapter: jira-snapshot requires --epic-key" >&2; return 2; }
      body="$(build_search_payload "$epic_key")"; url="${base}/rest/api/3/search/jql"
      if [ "$mode" = dryrun ]; then _record POST "$url" "$body"; jq -nc --arg e "$epic_key" '{epic:$e,stories:[]}'; return 0; fi
      resp="$(_post "$url" "$body")" || return 1
      map_search_response "$epic_key" "$resp" ;;
    jira-transition)
      { [ -n "$epic_key" ] && [ -n "$story" ]; } || { echo "jira-adapter: jira-transition requires --epic-key + --story" >&2; return 2; }
      if [ "$mode" = dryrun ]; then
        _record POST "${base}/rest/api/3/issue/<key-of-${story}>/transitions" "$(jq -nc --arg s "$story" --arg t "${to:-$disp}" '{story:$s,to:$t}')"
        printf '{"status":"transitioned","story":"%s","to":"%s"}\n' "$story" "${to:-DISPATCHED}"; return 0
      fi
      _live_transition "$epic_key" "$story" "${to:-$disp}" ;;
    *) echo "jira-adapter: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _jira_adapter_main "$@"
  exit $?
fi
