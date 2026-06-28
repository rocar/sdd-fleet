#!/usr/bin/env bash
# scripts/jira-adapter.test.sh — the real Jira REST adapter, tested hermetically
# (no network): pure builders/mappers via `source`, and the three modes via execution
# (unconfigured-defer, dry-run record, live via a stub `curl`). The load-bearing case
# is the real-payload body-leak guard — the actual Jira request body must carry the id
# + a vault pointer and NEVER the plan/contract body — checked both directly and through
# the full epic-materialise -> adapter dry-run chain (the gap the fixture couldn't reach),
# using the single-source jira-payload-leak-check.sh guard.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$DIR/jira-adapter.sh"
MAT="$DIR/epic-materialise.sh"
LEAK="$DIR/jira-payload-leak-check.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-40s = %s\n' "$1" "$2";
       else fail=$((fail+1)); printf 'FAIL %-40s want[%s] got[%s]\n' "$1" "$3" "$2"; fi; }
ok() { pass=$((pass+1)); printf 'ok   %-40s %s\n' "$1" "${2:-}"; }
bad(){ fail=$((fail+1)); printf 'FAIL %-40s %s\n' "$1" "${2:-}"; }
q()  { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

if [ -f "$ADAPTER" ]; then ok "script-present"; else bad "script-present" "$ADAPTER missing"; fi

# ============================ unit tests (source) ===========================
# shellcheck source=./jira-adapter.sh
. "$ADAPTER"

# the single body-builder: id + repo + vault pointer; nothing else
desc="$(jira_story_description storyA member-a EPIC-9)"
case "$desc" in *storyA*member-a*EPIC-9*) ok "desc-has-ids" ;; *) bad "desc-has-ids" "[$desc]" ;; esac
case "$desc" in *.sdd/_epic*) ok "desc-has-vault-pointer" ;; *) bad "desc-has-vault-pointer" ;; esac

# the built story payload is leak-clean (real built body, checked by the single-source guard)
clean="$(build_story_payload storyA member-a EPIC-9)"
printf '%s' "$clean" | bash "$LEAK" --require storyA --require '.sdd/_epic' --forbid DAGBODY_SENTINEL; eq "built-payload-leak-clean" "$?" "0"

# guard: clean passes, tampered (extra text smuggled into the description) is refused
guard_story_payload "$clean" storyA member-a EPIC-9; eq "guard-clean-passes" "$?" "0"
tampered="$(printf '%s' "$clean" | jq -c '.fields.description.content[0].content[0].text += " DAGBODY_SENTINEL_leak"')"
guard_story_payload "$tampered" storyA member-a EPIC-9 2>/dev/null; eq "guard-tamper-caught" "$?" "1"

# decide_transition
eq "decide-noop"       "$(decide_transition Dispatched Dispatched)" "noop"
eq "decide-transition" "$(decide_transition 'To Do' Dispatched)"    "transition"

# map_search_response: labels -> id/repo/consumes; status mapping (NOT_STARTED / DISPATCHED / raw)
SEARCH='{"issues":[
 {"key":"SDD-2","fields":{"status":{"name":"To Do"},"labels":["sdd-id:storyA","sdd-repo:member-a"]}},
 {"key":"SDD-3","fields":{"status":{"name":"Dispatched"},"labels":["sdd-id:storyB","sdd-repo:member-b","sdd-consumes:c@1"]}},
 {"key":"SDD-4","fields":{"status":{"name":"Done"},"labels":["sdd-id:storyC","sdd-repo:member-c"]}}
]}'
snap="$(map_search_response EPIC-1 "$SEARCH")"
eq "map-epic"        "$(q "$snap" '.epic')" "EPIC-1"
eq "map-count"       "$(q "$snap" '.stories|length')" "3"
eq "map-A-id"        "$(q "$snap" '.stories[0].id')" "storyA"
eq "map-A-repo"      "$(q "$snap" '.stories[0].repo')" "member-a"
eq "map-A-status"    "$(q "$snap" '.stories[0].status')" "NOT_STARTED"
eq "map-B-status"    "$(q "$snap" '.stories[1].status')" "DISPATCHED"
eq "map-B-consumes"  "$(q "$snap" '.stories[1].consumes[0]')" "c@1"
eq "map-C-status-raw-not-NOTSTARTED" "$(q "$snap" '.stories[2].status')" "Done"

# =========================== integration (execute) ==========================
# unconfigured (no flags) -> defer signal, exit 0 (safe default — no network)
out="$(bash "$ADAPTER" create-epic --slug x --now N 2>/dev/null)"; rc=$?
eq "unconfigured-exit0" "$rc" "0"
eq "unconfigured-signal" "$(q "$out" '.status')" "unconfigured"

# live opt-in but creds incomplete -> fail closed (exit 2)
out="$(SDD_JIRA_LIVE=1 bash "$ADAPTER" create-epic --slug x --now N 2>/dev/null)"; rc=$?
eq "live-incomplete-creds-exit2" "$rc" "2"

# dry-run contract shapes + record
rec="$work/rec"; : > "$rec"
out="$(SDD_JIRA_DRYRUN=1 SDD_JIRA_RECORD="$rec" bash "$ADAPTER" create-epic --slug ep --now N 2>/dev/null)"
eq "dryrun-create-epic-key" "$out" "JIRA_KEY: DRYRUN-EPIC-ep"
out="$(SDD_JIRA_DRYRUN=1 SDD_JIRA_RECORD="$rec" bash "$ADAPTER" create-story --epic-key EP-1 --story storyA --repo member-a --now N 2>/dev/null)"
eq "dryrun-create-story-key" "$out" "JIRA_KEY: DRYRUN-storyA"
out="$(SDD_JIRA_DRYRUN=1 bash "$ADAPTER" jira-snapshot --epic-key EP-1 --now N 2>/dev/null)"
eq "dryrun-snapshot-shape" "$(q "$out" '.epic')" "EP-1"
eq "dryrun-snapshot-empty" "$(q "$out" '.stories|length')" "0"
out="$(SDD_JIRA_DRYRUN=1 bash "$ADAPTER" jira-transition --epic-key EP-1 --story storyA --to Dispatched --now N 2>/dev/null)"
eq "dryrun-transition" "$(q "$out" '.status')" "transitioned"

# real-payload body-leak: the RECORDED create-story request body carries the id + vault
# pointer and NONE of the plan/contract markers
bash "$LEAK" --require storyA --require '.sdd/_epic' --forbid DAGBODY_SENTINEL --forbid CONTRACTBODY_SENTINEL < "$rec"; eq "dryrun-record-leak-clean" "$?" "0"

# real-payload body-leak through the FULL epic-materialise -> jira-adapter dry-run chain
e="$work/epic/.sdd/_epic/big"; mkdir -p "$e"
printf 'EPIC: big\n\n## Stories\n- id: storyA\n  repo: member-a\n\n## Dependency DAG\nDAGBODY_SENTINEL_must_not_reach_jira\n' > "$e/plan.md"
printf 'EPIC: big\n\n## Contracts\n### thing\n- interface: CONTRACTBODY_SENTINEL_must_not_reach_jira\n' > "$e/contracts.md"
printf 'RATIFIED: N\nPLAN_DIGEST: x\n' > "$e/RATIFICATION.md"
chainrec="$work/chainrec"; : > "$chainrec"
mout="$( cd "$work/epic" && SDD_JIRA_DRYRUN=1 SDD_JIRA_RECORD="$chainrec" bash "$MAT" big --now N 2>/dev/null )"; mrc=$?
eq "chain-materialise-ok" "$(q "$mout" '.status')" "materialised"
[ -s "$chainrec" ] && ok "chain-record-nonempty" || bad "chain-record-nonempty" "no payloads recorded"
bash "$LEAK" --require storyA --forbid DAGBODY_SENTINEL --forbid CONTRACTBODY_SENTINEL < "$chainrec"; eq "chain-real-payload-leak-clean" "$?" "0"

# =================== live mode via a stub curl (hermetic) ===================
stub="$work/stub"; mkdir -p "$stub"
cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
method=GET; out=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -u|-H|-w) shift 2 ;;
    -sS|-s|-S) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$data" ] && printf '%s\n' "$data" >> "$STUB_LOG"
def_search='{"issues":[]}'
def_trans='{"transitions":[{"id":"31","to":{"name":"Dispatched"}}]}'
key="${STUB_KEY:-SDD-1}"; ecode="${STUB_CODE:-201}"
code=200; body='{}'
case "$method:$url" in
  POST:*/rest/api/3/issue)  code="$ecode"; body="{\"key\":\"$key\"}" ;;
  POST:*/search/jql)        code=200; body="${STUB_SEARCH:-$def_search}" ;;
  GET:*/transitions)        code=200; body="${STUB_TRANS:-$def_trans}" ;;
  POST:*/transitions)       code=204; body='{}' ;;
esac
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '%s' "$code"
STUB
chmod +x "$stub/curl"
LIVE_ENV=(SDD_JIRA_LIVE=1 JIRA_BASE_URL=https://x.atlassian.net JIRA_EMAIL=a@b.c JIRA_API_TOKEN=tok JIRA_PROJECT_KEY=SDD)

# create-epic happy
out="$(PATH="$stub:$PATH" STUB_LOG="$work/.slog" STUB_KEY=SDD-10 env "${LIVE_ENV[@]}" bash "$ADAPTER" create-epic --slug ep --now N 2>/dev/null)"
eq "live-create-epic-key" "$out" "JIRA_KEY: SDD-10"

# create-story happy + the POSTed body (captured by the stub) is leak-clean
: > "$work/.slog"
out="$(PATH="$stub:$PATH" STUB_LOG="$work/.slog" STUB_KEY=SDD-11 env "${LIVE_ENV[@]}" bash "$ADAPTER" create-story --epic-key SDD-10 --story storyA --repo member-a --now N 2>/dev/null)"
eq "live-create-story-key" "$out" "JIRA_KEY: SDD-11"
bash "$LEAK" --require storyA --require '.sdd/_epic' --forbid DAGBODY_SENTINEL < "$work/.slog"; eq "live-posted-body-leak-clean" "$?" "0"

# HTTP error -> exit 1
out="$(PATH="$stub:$PATH" STUB_LOG="$work/.slog" STUB_CODE=400 env "${LIVE_ENV[@]}" bash "$ADAPTER" create-epic --slug ep --now N 2>/dev/null)"; rc=$?
eq "live-http-error-exit1" "$rc" "1"

# transition happy (issue at 'To Do' -> transitioned) and noop (already Dispatched)
SR_TODO='{"issues":[{"key":"SDD-11","fields":{"status":{"name":"To Do"}}}]}'
SR_DISP='{"issues":[{"key":"SDD-11","fields":{"status":{"name":"Dispatched"}}}]}'
out="$(PATH="$stub:$PATH" STUB_LOG="$work/.slog" STUB_SEARCH="$SR_TODO" env "${LIVE_ENV[@]}" JIRA_STATUS_DISPATCHED=Dispatched bash "$ADAPTER" jira-transition --epic-key SDD-10 --story storyA --to Dispatched --now N 2>/dev/null)"
eq "live-transition-transitioned" "$(q "$out" '.status')" "transitioned"
out="$(PATH="$stub:$PATH" STUB_LOG="$work/.slog" STUB_SEARCH="$SR_DISP" env "${LIVE_ENV[@]}" JIRA_STATUS_DISPATCHED=Dispatched bash "$ADAPTER" jira-transition --epic-key SDD-10 --story storyA --to Dispatched --now N 2>/dev/null)"
eq "live-transition-noop" "$(q "$out" '.status')" "noop"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
