#!/usr/bin/env bash
# Tests for scripts/epic-materialise.sh.
# STEP 3 of the epic spine (post-ratification, deterministic code): reads the ratified
# plan and creates the Jira epic + one story per plan node THROUGH THE ADAPTER SEAM
# (SDD_JIRA_ADAPTER), recording the created keys in JIRA_LINK.md. Refuses if not ratified
# or already materialised; soft-defers when no adapter is configured (the C-slice state —
# the real backend slots in behind the seam later). --now injected, no clock.
# Run: bash scripts/epic-materialise.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/epic-materialise.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
NOW="2026-06-27T12:00:00Z"

pass=0; fail=0
out=""; rc=0
ok() { pass=$((pass+1)); printf 'ok   %-40s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %-40s :: %s\n' "$1" "$2"; }
expect() { local n="$1" wrc="$2" sub="$3"
  if [ "$rc" -eq "$wrc" ] && printf '%s' "$out" | grep -qF "$sub"; then ok "$n"
  else no "$n" "want rc=$wrc/$sub got rc=$rc out=$out"; fi
}

# A deterministic fixture adapter: logs calls to $FAKE_JIRA_LOG, returns fake keys.
fake="$work/fake-jira.sh"
cat > "$fake" <<'ADP'
#!/usr/bin/env bash
cmd="$1"; shift
echo "$cmd $*" >> "${FAKE_JIRA_LOG:-/dev/null}"
case "$cmd" in
  create-epic) echo "JIRA_KEY: EPIC-1" ;;
  create-story)
    slug=""; while [ $# -gt 0 ]; do [ "$1" = "--story" ] && slug="$2"; shift; done
    echo "JIRA_KEY: STORY-$slug" ;;
  *) exit 3 ;;
esac
ADP

# mkrat <name> [no-ratify] -> workspace root with epic 'ep' (2 stories), ratified unless no-ratify
mkrat() {
  local p e; p="$work/$1"; e="$p/.sdd/_epic/ep"; mkdir -p "$e"
  printf 'EPIC: ep\n\n## Stories\n- id: storyA\n  repo: member-a\n  consumes: []\n- id: storyB\n  repo: member-b\n  consumes: [thing@1]\n' > "$e/plan.md"
  printf 'EPIC: ep\n\n## Contracts\n### thing\n- kind: openapi\n' > "$e/contracts.md"
  [ "${2:-}" = no-ratify ] || printf 'RATIFIED: %s\nPLAN_DIGEST: x\n' "$NOW" > "$e/RATIFICATION.md"
  printf '%s' "$p"
}

run_adapter() { local p="$1"; shift; : > "$work/.jlog"; out=$( cd "$p" && SDD_JIRA_ADAPTER="$fake" FAKE_JIRA_LOG="$work/.jlog" bash "$SCRIPT" "$@" 2>"$work/.err" ); rc=$?; }
run_noadapter() { local p="$1"; shift; out=$( cd "$p" && SDD_JIRA_ADAPTER="$work/does-not-exist.sh" bash "$SCRIPT" "$@" 2>"$work/.err" ); rc=$?; }
# the REAL adapter present but unconfigured (no creds, no dry-run) -> it emits an
# "unconfigured" signal; materialise must soft-defer (not adapter-error).
run_unconfigured() { local p="$1"; shift; out=$( cd "$p" && SDD_JIRA_ADAPTER="$DIR/jira-adapter.sh" bash "$SCRIPT" "$@" 2>"$work/.err" ); rc=$?; }

# --- happy path: materialise via the adapter ---
p=$(mkrat happy)
run_adapter "$p" ep --now "$NOW"
expect "materialise-ok" 0 '"status":"materialised"'
expect "materialise-reports-epic-key" 0 '"jira_epic":"EPIC-1"'
expect "materialise-reports-story-count" 0 '"stories":2'
JL="$p/.sdd/_epic/ep/JIRA_LINK.md"
[ -f "$JL" ] && grep -q "^JIRA_EPIC: EPIC-1" "$JL" \
  && grep -qF "storyA" "$JL" && grep -qF "STORY-storyA" "$JL" \
  && grep -qF "storyB" "$JL" && grep -qF "STORY-storyB" "$JL" \
  && ok "jira-link-written" || no "jira-link-written" "JIRA_LINK.md missing keys/stories"
# the adapter was called once for the epic and once per story
[ "$(grep -c '^create-epic ' "$work/.jlog")" = "1" ] && [ "$(grep -c '^create-story ' "$work/.jlog")" = "2" ] \
  && ok "adapter-called-epic+each-story" || no "adapter-called-epic+each-story" "$(cat "$work/.jlog")"
# create-story carries the per-story repo (member assignment from the plan)
grep -q 'create-story .*--repo member-a' "$work/.jlog" && grep -q 'create-story .*--repo member-b' "$work/.jlog" \
  && ok "adapter-gets-per-story-repo" || no "adapter-gets-per-story-repo" "$(cat "$work/.jlog")"

# --- idempotency guard: already materialised ---
run_adapter "$p" ep --now "$NOW"
expect "already-materialised-refused" 1 '"status":"already-materialised"'

# --- not ratified: refuse, do not touch Jira ---
p=$(mkrat unrat no-ratify)
run_adapter "$p" ep --now "$NOW"
expect "not-ratified-refused" 1 '"status":"not-ratified"'
[ -f "$p/.sdd/_epic/ep/JIRA_LINK.md" ] && no "not-ratified-no-jira-link" "JIRA_LINK.md should not exist" || ok "not-ratified-no-jira-link"

# --- no adapter configured: soft-defer (ratification already stuck; exit 0) ---
p=$(mkrat defer)
run_noadapter "$p" ep --now "$NOW"
expect "no-adapter-defers" 0 '"status":"deferred"'
[ -f "$p/.sdd/_epic/ep/JIRA_LINK.md" ] && no "deferred-no-jira-link" "JIRA_LINK.md should not exist" || ok "deferred-no-jira-link"

# --- unconfigured adapter (present, no creds/dry-run) soft-defers, never errors ---
p=$(mkrat unconf)
run_unconfigured "$p" ep --now "$NOW"
expect "unconfigured-adapter-defers" 0 '"status":"deferred"'
[ -f "$p/.sdd/_epic/ep/JIRA_LINK.md" ] && no "unconfigured-no-jira-link" "JIRA_LINK.md should not exist" || ok "unconfigured-no-jira-link"

# --- body-leak lock: the structured plan body (DAG / contract design) must NOT reach the
# story payload — only identifiers (id/repo/epic-key) do. Sentinels in the plan/contract
# bodies must be absent from everything sent to the adapter. A positive control (the story
# id IS passed) proves the log captures the payload, so the negative assertion has teeth. ---
p="$work/leak"; e="$p/.sdd/_epic/ep"; mkdir -p "$e"
printf 'EPIC: ep\n\n## Stories\n- id: storyA\n  repo: member-a\n\n## Dependency DAG\nDAGBODY_SENTINEL_must_not_reach_jira\n' > "$e/plan.md"
printf 'EPIC: ep\n\n## Contracts\n### thing\n- kind: openapi\n- interface: CONTRACTBODY_SENTINEL_must_not_reach_jira\n' > "$e/contracts.md"
printf 'RATIFIED: %s\nPLAN_DIGEST: x\n' "$NOW" > "$e/RATIFICATION.md"
run_adapter "$p" ep --now "$NOW"
# Single-source guard (scripts/jira-payload-leak-check.sh), applied here at the script->adapter
# argv boundary and again at the adapter->Jira payload boundary in jira-adapter.test.sh.
if bash "$DIR/jira-payload-leak-check.sh" --require 'create-story' --require 'storyA' --forbid SENTINEL < "$work/.jlog"; then ok "no-plan-body-in-payload (single-source guard)"
else no "no-plan-body-in-payload" "log=$(cat "$work/.jlog")"; fi

# --- usage: missing --now / missing slug ---
p=$(mkrat usage)
out=$( cd "$p" && SDD_JIRA_ADAPTER="$fake" bash "$SCRIPT" ep 2>/dev/null ); rc=$?
[ "$rc" -eq 1 ] && ok "missing-now-usage-error" || no "missing-now-usage-error" "rc=$rc"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
