#!/usr/bin/env bash
# Tests for scripts/next-story.sh — the developer PULL entry over the conductor's
# ready-frontier core (ADR-0001 anticipated it; ADR-0002 ratified it). Hermetic:
# a fixture Jira adapter (the conductor-tick.test.sh pattern) + a mktemp registry.
# The load-bearing invariants: it resolves the SAME frontier the conductor computes
# (ready-frontier.sh, never re-derived), it is READ-ONLY against Jira (its adapter
# call log contains jira-snapshot ONLY — never a transition, never a create), and
# it emits exactly one JSON status line per run.
# Run: bash scripts/next-story.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$DIR/next-story.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
eq()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-42s = %s\n' "$1" "$2";
        else fail=$((fail+1)); printf 'FAIL %-42s want[%s] got[%s]\n' "$1" "$3" "$2"; fi; }
ok()  { pass=$((pass+1)); printf 'ok   %-42s %s\n' "$1" "${2:-}"; }
bad() { fail=$((fail+1)); printf 'FAIL %-42s %s\n' "$1" "${2:-}"; }
q()   { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
countlines() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

NOW="2026-07-01T10:00:00Z"; SLUG="alpha"

if [ -f "$RESOLVER" ]; then ok "script-present"; else bad "script-present" "$RESOLVER missing"; fi

# ---- fixture Jira adapter: serves the snapshot, logs every call ----
fake="$work/fake-jira.sh"
cat > "$fake" <<'FJ'
#!/usr/bin/env bash
cmd="$1"; shift
echo "$cmd $*" >> "$FAKE_JIRA_LOG"
case "$cmd" in
  jira-snapshot) cat "$FAKE_JIRA_STATE" ;;
  *) printf '{"status":"unexpected-verb","verb":"%s"}\n' "$cmd"; exit 3 ;;
esac
FJ

# mk_epic <dir> <state-json>  — registry publishes c@1 only
mk_epic() {
  rm -rf "$1"; mkdir -p "$1/.sdd/_epic/$SLUG" "$1/registry/c"
  printf '{"contract":"c","version":"1.0.0","kind":"openapi"}\n' > "$1/registry/c/1.0.0.json"
  printf 'JIRA_EPIC: EPIC-1\n' > "$1/.sdd/_epic/$SLUG/JIRA_LINK.md"
  printf '%s' "$2" > "$1/state.json"
}
# run_ns <dir> [args...] -> sets $out,$rc
run_ns() {
  local d="$1"; shift
  out="$( (cd "$d" && SDD_JIRA_ADAPTER="$fake" FAKE_JIRA_LOG="$d/.jlog" FAKE_JIRA_STATE="$d/state.json" bash "$RESOLVER" "$@") 2>"$work/.err" )"; rc=$?
}

STATE_BASE='{"epic":"EPIC-1","stories":[
 {"id":"storyB","key":"ST-2","status":"NOT_STARTED","consumes":["d@1"],"repo":"svc-b"},
 {"id":"storyA","key":"ST-1","status":"NOT_STARTED","consumes":["c@1"],"repo":"svc-a"},
 {"id":"storyD","key":"ST-3","status":"Done","consumes":[],"repo":"svc-d"}
]}'

# ---- next: one ready story (storyA; storyB blocked on unpublished d@1) ----
p="$work/next"; mk_epic "$p" "$STATE_BASE"
run_ns "$p" "$SLUG" --now "$NOW"
eq "next-rc-0"       "$rc" "0"
eq "next-status"     "$(q "$out" '.status')" "next"
eq "next-story"      "$(q "$out" '.story')" "storyA"
eq "next-key"        "$(q "$out" '.key')" "ST-1"
eq "next-repo"       "$(q "$out" '.repo')" "svc-a"
eq "next-ready"      "$(q "$out" '.ready')" "1"
eq "next-done"       "$(q "$out" '.done')" "1"
eq "next-total"      "$(q "$out" '.total')" "3"
eq "next-one-line"   "$(printf '%s\n' "$out" | grep -c .)" "1"
# READ-ONLY lock: snapshot only — no transition, no creation (not a second conductor)
if grep -q 'jira-snapshot' "$p/.jlog"; then ok "snapshot-in-log(positive-ctl)"; else bad "snapshot-in-log(positive-ctl)"; fi
eq "no-transition-in-log" "$(countlines 'jira-transition|phase-transition' "$p/.jlog")" "0"
eq "no-create-in-log"     "$(countlines 'create-(story|epic)' "$p/.jlog")" "0"

# ---- deterministic pick: multiple ready -> the frontier's sorted first ----
p2="$work/sorted"
mk_epic "$p2" '{"epic":"EPIC-1","stories":[
 {"id":"zeta","key":"ST-9","status":"NOT_STARTED","consumes":["c@1"],"repo":"svc-z"},
 {"id":"alpha","key":"ST-8","status":"NOT_STARTED","consumes":[],"repo":"svc-a"}]}'
run_ns "$p2" "$SLUG" --now "$NOW"
eq "sorted-first-story" "$(q "$out" '.story')" "alpha"

# ---- waiting: nothing ready, work remains (blocked + in flight) ----
p3="$work/waiting"
mk_epic "$p3" '{"epic":"EPIC-1","stories":[
 {"id":"blocked","key":"ST-4","status":"NOT_STARTED","consumes":["d@1"],"repo":"svc-b"},
 {"id":"running","key":"ST-5","status":"DISPATCHED","consumes":[],"repo":"svc-a"},
 {"id":"done","key":"ST-6","status":"Done","consumes":[],"repo":"svc-d"}]}'
run_ns "$p3" "$SLUG" --now "$NOW"
eq "waiting-status"      "$(q "$out" '.status')" "waiting"
eq "waiting-not-started" "$(q "$out" '.not_started')" "1"
eq "waiting-in-flight"   "$(q "$out" '.in_flight')" "1"
eq "waiting-done"        "$(q "$out" '.done')" "1"

# ---- a DISPATCHED story is claimed, never re-surfaced as next ----
p4="$work/claimed"
mk_epic "$p4" '{"epic":"EPIC-1","stories":[
 {"id":"running","key":"ST-5","status":"DISPATCHED","consumes":[],"repo":"svc-a"}]}'
run_ns "$p4" "$SLUG" --now "$NOW"
eq "claimed-not-next" "$(q "$out" '.status')" "waiting"

# ---- complete: every story done (case-insensitive DONE per Jira) ----
p5="$work/complete"
mk_epic "$p5" '{"epic":"EPIC-1","stories":[
 {"id":"a","key":"ST-1","status":"Done","consumes":[],"repo":"r"},
 {"id":"b","key":"ST-2","status":"DONE","consumes":[],"repo":"r"}]}'
run_ns "$p5" "$SLUG" --now "$NOW"
eq "complete-status" "$(q "$out" '.status')" "complete"
eq "complete-done"   "$(q "$out" '.done')" "2"
eq "complete-total"  "$(q "$out" '.total')" "2"

# ---- empty: the epic has no materialised stories ----
p6="$work/empty"; mk_epic "$p6" '{"epic":"EPIC-1","stories":[]}'
run_ns "$p6" "$SLUG" --now "$NOW"
eq "empty-status" "$(q "$out" '.status')" "empty"

# ---- not-materialised / deferred (no adapter; real adapter unconfigured) ----
p7="$work/notmat"; rm -rf "$p7"; mkdir -p "$p7/.sdd/_epic/$SLUG"   # no JIRA_LINK.md
run_ns "$p7" "$SLUG" --now "$NOW"
eq "not-materialised" "$(q "$out" '.status')" "not-materialised"

p8="$work/noadapter"; mk_epic "$p8" "$STATE_BASE"
out="$( (cd "$p8" && SDD_JIRA_ADAPTER="$p8/nope.sh" bash "$RESOLVER" "$SLUG" --now "$NOW") 2>/dev/null )"
eq "deferred-no-adapter" "$(q "$out" '.status')" "deferred"

p9="$work/unconf"; mk_epic "$p9" "$STATE_BASE"
out="$( (cd "$p9" && SDD_JIRA_ADAPTER="$DIR/jira-adapter.sh" bash "$RESOLVER" "$SLUG" --now "$NOW") 2>/dev/null )"
eq "deferred-unconfigured" "$(q "$out" '.status')" "deferred"
eq "deferred-reason"       "$(q "$out" '.reason')" "jira-adapter-unconfigured"

# ---- arg validation: no clock read (--now required), no traversal, no bare call ----
p10="$work/args"; mk_epic "$p10" "$STATE_BASE"
( cd "$p10" && bash "$RESOLVER" "$SLUG" ) >/dev/null 2>&1; rc=$?
eq "missing-now-rejected" "$rc" "2"
( cd "$p10" && bash "$RESOLVER" "../escape" --now "$NOW" ) >/dev/null 2>&1; rc=$?
eq "traversal-slug-rejected" "$rc" "2"
( cd "$p10" && bash "$RESOLVER" ) >/dev/null 2>&1; rc=$?
eq "missing-slug-rejected" "$rc" "2"

# no-clock lint: the resolver never reads a clock or randomness (caller injects --now)
if grep -nE '(^|[^-A-Za-z])date([^A-Za-z-]|$)|\$RANDOM' "$RESOLVER" >/dev/null 2>&1; then
  bad "no-clock-no-randomness" "$(grep -nE '(^|[^-A-Za-z])date([^A-Za-z-]|$)|\$RANDOM' "$RESOLVER" | head -2)"
else
  ok "no-clock-no-randomness"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
