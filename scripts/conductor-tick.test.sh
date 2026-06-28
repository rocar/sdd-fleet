#!/usr/bin/env bash
# scripts/conductor-tick.test.sh — proves the conductor tick is creation-free,
# count-invariant, crash-idempotent, level-triggered, and re-derives every
# decision from live state (never trusts a recorded flag), against a STATEFUL
# fake-jira adapter (the epic-materialise.test.sh fixture pattern, made stateful:
# a transition persists, so a re-snapshot reflects it). All decisions are checked
# from the adapter call log + the post-state; the fixture wiring is asserted
# (snapshot-in-log positive control) so a misconfigured run goes RED, not green.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK="$DIR/conductor-tick.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
eq()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-42s = %s\n' "$1" "$2";
        else fail=$((fail+1)); printf 'FAIL %-42s want[%s] got[%s]\n' "$1" "$3" "$2"; fi; }
ok()  { pass=$((pass+1)); printf 'ok   %-42s %s\n' "$1" "${2:-}"; }
bad() { fail=$((fail+1)); printf 'FAIL %-42s %s\n' "$1" "${2:-}"; }
sj()  { printf '%s' "$1" | grep -E '^\{' | tail -1; }                 # the final status JSON line
countlines() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

NOW="2026-06-28T10:00:00Z"; SLUG="alpha"

if [ -f "$TICK" ]; then ok "script-present"; else bad "script-present" "$TICK missing"; fi

# ---- the stateful fake-jira adapter (snapshot reads state; transition mutates it) ----
fake="$work/fake-jira.sh"
cat > "$fake" <<'FJ'
#!/usr/bin/env bash
cmd="$1"; shift
echo "$cmd $*" >> "$FAKE_JIRA_LOG"
state="$FAKE_JIRA_STATE"
story=""; to=""
while [ $# -gt 0 ]; do
  case "$1" in
    --story) story="$2"; shift 2 ;;
    --to)    to="$2";    shift 2 ;;
    --epic-key|--now) shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  jira-snapshot) cat "$state" ;;
  jira-transition)
    cur="$(jq -r --arg s "$story" '.stories[]|select(.id==$s)|.status' "$state" 2>/dev/null)"
    if [ "$cur" = "NOT_STARTED" ]; then
      tmp="$(mktemp)"; jq --arg s "$story" --arg to "$to" '(.stories[]|select(.id==$s)|.status)=$to' "$state" > "$tmp" && mv "$tmp" "$state"
      printf '{"status":"transitioned","story":"%s","to":"%s"}\n' "$story" "$to"
    else
      printf '{"status":"noop","story":"%s","to":"%s"}\n' "$story" "$to"
    fi ;;
  *) printf '{"status":"unknown-verb","verb":"%s"}\n' "$cmd"; exit 3 ;;
esac
FJ

STATE_BASE='{"epic":"EPIC-1","stories":[
 {"id":"S","key":"ST-S","status":"NOT_STARTED","consumes":["c@1"],"repo":"svc-a"},
 {"id":"B","key":"ST-B","status":"NOT_STARTED","consumes":["d@1"],"repo":"svc-b"},
 {"id":"D","key":"ST-D","status":"DONE","consumes":["c@1"],"repo":"svc-d"}
]}'

# mk_epic <dir> <state-json>  — registry has c@1 only (so S ready, B blocked on d@1)
mk_epic() {
  rm -rf "$1"; mkdir -p "$1/.sdd/_epic/$SLUG" "$1/registry/c"
  printf '{"contract":"c","version":"1.0.0","kind":"openapi"}\n' > "$1/registry/c/1.0.0.json"
  printf 'JIRA_EPIC: EPIC-1\n' > "$1/.sdd/_epic/$SLUG/JIRA_LINK.md"
  printf '%s' "$2" > "$1/state.json"
}
# run_tick <dir> [extra tick args...] -> sets $out,$rc
run_tick() {
  local d="$1"; shift
  out="$( (cd "$d" && SDD_JIRA_ADAPTER="$fake" FAKE_JIRA_LOG="$d/.jlog" FAKE_JIRA_STATE="$d/state.json" bash "$TICK" "$SLUG" --now "$NOW" "$@") 2>"$work/.err" )"; rc=$?
}

# ================= count-invariant + creation-free runtime lock =============
p="$work/c"; mk_epic "$p" "$STATE_BASE"
eq "pre-count-3(positive-control)" "$(jq '.stories|length' "$p/state.json")" "3"
run_tick "$p"
eq "tick-rc-0"            "$rc" "0"
s="$(sj "$out")"
eq "frontier-1"          "$(printf '%s' "$s" | jq -r '.frontier')" "1"
eq "dispatched-1"        "$(printf '%s' "$s" | jq -r '.dispatched')" "1"
if printf '%s' "$out" | grep -q '^SDD_FLEET_DISPATCH:.*"story":"S"'; then ok "dispatch-signal-S"; else bad "dispatch-signal-S" "[$out]"; fi
eq "post-count-3(no-creation)" "$(jq '.stories|length' "$p/state.json")" "3"
eq "dispatched-rose-by-1" "$(jq '[.stories[]|select(.status=="DISPATCHED")]|length' "$p/state.json")" "1"
eq "S-now-dispatched"     "$(jq -r '.stories[]|select(.id=="S")|.status' "$p/state.json")" "DISPATCHED"
eq "B-still-not-started"  "$(jq -r '.stories[]|select(.id=="B")|.status' "$p/state.json")" "NOT_STARTED"
# creation-free runtime lock: log shows snapshot+transition, NEVER create-*
if [ -s "$p/.jlog" ]; then ok "log-nonempty"; else bad "log-nonempty"; fi
eq "no-create-in-log"     "$(countlines 'create-(story|epic)' "$p/.jlog")" "0"
if grep -q 'jira-snapshot' "$p/.jlog"; then ok "snapshot-in-log(positive-ctl)"; else bad "snapshot-in-log(positive-ctl)"; fi
eq "S-transitioned-once"  "$(countlines 'jira-transition .*--story S' "$p/.jlog")" "1"

# ================= crash-idempotency (re-run; state persists) ===============
run_tick "$p"   # tick-2 against the now-updated state (S already DISPATCHED)
s2="$(sj "$out")"
eq "tick2-dispatched-0"   "$(printf '%s' "$s2" | jq -r '.dispatched')" "0"
eq "tick2-frontier-0"     "$(printf '%s' "$s2" | jq -r '.frontier')" "0"
eq "S-transition-still-1" "$(countlines 'jira-transition .*--story S' "$p/.jlog")" "1"   # never double-dispatched

# ================= re-read teeth: seeded DISPATCHED, no local record ========
# A conductor that reasoned "no record of S => dispatch it" would RED here.
p2="$work/reread"
mk_epic "$p2" '{"epic":"EPIC-1","stories":[{"id":"S","key":"ST-S","status":"DISPATCHED","consumes":["c@1"],"repo":"svc-a"}]}'
run_tick "$p2"
eq "reread-dispatched-0"  "$(printf '%s' "$(sj "$out")" | jq -r '.dispatched')" "0"
eq "reread-no-transition-S" "$(countlines 'jira-transition .*--story S' "$p2/.jlog")" "0"

# ================= level-triggered inverse + teeth ==========================
# Publish B's dep between ticks: tick-2 must dispatch B (re-derive + advance),
# while NOT re-dispatching S. An "idempotent-by-suppression" tick would miss B.
p3="$work/level"; mk_epic "$p3" "$STATE_BASE"
run_tick "$p3"                                   # tick-1: dispatches S
mkdir -p "$p3/registry/d"; printf '{"contract":"d","version":"1.0.0","kind":"openapi"}\n' > "$p3/registry/d/1.0.0.json"
run_tick "$p3"                                   # tick-2: d@1 now published
eq "level-tick2-dispatched-1" "$(printf '%s' "$(sj "$out")" | jq -r '.dispatched')" "1"
eq "level-B-transitioned-once" "$(countlines 'jira-transition .*--story B' "$p3/.jlog")" "1"
eq "level-S-not-redispatched"  "$(countlines 'jira-transition .*--story S' "$p3/.jlog")" "1"

# ================= lease: mutual exclusion (different owner) ================
p4="$work/busy"; mk_epic "$p4" "$STATE_BASE"
printf 'OWNER: conductor:other\nACQUIRED: %s\n' "$NOW" > "$p4/.sdd/_epic/$SLUG/.conductor.lock"
run_tick "$p4"
eq "busy-status"          "$(printf '%s' "$(sj "$out")" | jq -r '.status')" "busy"
eq "busy-no-transition"   "$(countlines 'jira-transition' "$p4/.jlog")" "0"
eq "busy-lock-not-stolen" "$( { grep -m1 '^OWNER:' "$p4/.sdd/_epic/$SLUG/.conductor.lock" || true; } | sed -E 's/^OWNER:[[:space:]]*//' | tr -d '\r ')" "conductor:other"

# ================= lease: same-owner re-entrant crash recovery =============
p5="$work/reentrant"; mk_epic "$p5" "$STATE_BASE"
printf 'OWNER: conductor:%s\nACQUIRED: %s\n' "$SLUG" "$NOW" > "$p5/.sdd/_epic/$SLUG/.conductor.lock"
run_tick "$p5"
eq "reentrant-status"     "$(printf '%s' "$(sj "$out")" | jq -r '.status')" "dispatched"
eq "reentrant-dispatched-1" "$(printf '%s' "$(sj "$out")" | jq -r '.dispatched')" "1"
if [ -f "$p5/.sdd/_epic/$SLUG/.conductor.lock" ]; then bad "reentrant-lock-released" "lock still present"; else ok "reentrant-lock-released"; fi

# ================= soft-defer / not-materialised / arg validation ===========
p6="$work/notmat"; rm -rf "$p6"; mkdir -p "$p6/.sdd/_epic/$SLUG"   # no JIRA_LINK.md
run_tick "$p6"
eq "not-materialised"     "$(printf '%s' "$(sj "$out")" | jq -r '.status')" "not-materialised"

p7="$work/noadapter"; mk_epic "$p7" "$STATE_BASE"
out="$( (cd "$p7" && SDD_JIRA_ADAPTER="$p7/nope.sh" bash "$TICK" "$SLUG" --now "$NOW") 2>/dev/null )"
eq "deferred-no-adapter"  "$(printf '%s' "$(sj "$out")" | jq -r '.status')" "deferred"

( cd "$p" && bash "$TICK" "$SLUG" ) >/dev/null 2>&1; rc=$?
eq "missing-now-rejected" "$rc" "2"
( cd "$p" && bash "$TICK" "../escape" --now "$NOW" ) >/dev/null 2>&1; rc=$?
eq "traversal-slug-rejected" "$rc" "2"

# ================= conductor-loop: one sweep fires the tick per epic =========
LOOP="$DIR/conductor-loop.sh"
p8="$work/loop"; mk_epic "$p8" "$STATE_BASE"
out="$( (cd "$p8" && SDD_JIRA_ADAPTER="$fake" FAKE_JIRA_LOG="$p8/.jlog" FAKE_JIRA_STATE="$p8/state.json" bash "$LOOP" --now "$NOW") 2>/dev/null )"
eq "loop-swept-1"         "$(printf '%s' "$out" | grep -E '^\{' | tail -1 | jq -r '.epics')" "1"
eq "loop-dispatched-S"    "$(jq -r '.stories[]|select(.id=="S")|.status' "$p8/state.json")" "DISPATCHED"
p9="$work/loop-empty"; rm -rf "$p9"; mkdir -p "$p9"
out="$( (cd "$p9" && bash "$LOOP" --now "$NOW") 2>/dev/null )"
eq "loop-no-epics"        "$(printf '%s' "$out" | jq -r '.status')" "no-epics"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
