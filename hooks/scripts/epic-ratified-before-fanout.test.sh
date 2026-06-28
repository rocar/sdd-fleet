#!/usr/bin/env bash
# Tests for hooks/scripts/epic-ratified-before-fanout.sh.
# The estate fan-out gate: while a story governed by an UNRATIFIED epic is active,
# block writes into its .sdd/<slug>/ spec dir. Cross-level: the hook runs in a member
# repo (submodule) and resolves the superproject via git to read the epic's
# RATIFICATION.md. Standalone repos / non-epic stories / git-missing are INERT.
# Run: bash hooks/scripts/epic-ratified-before-fanout.test.sh   (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/epic-ratified-before-fanout.sh"
DIGEST="$DIR/../../scripts/plan-digest.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# check <name> <member-working-tree> <file_path> <want_rc> [path_override_env...]
check() {
  local name="$1" proj="$2" fp="$3" want="$4" rc=0
  ( cd "$proj" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}
check_json() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s rc=%s\n' "$name" "$rc"
  else fail=$((fail+1)); printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$rc"; fi
}

# --- standalone (no git superproject): the gate is INERT ---
# A plain mktemp dir is not a git submodule, so resolve_superproject is empty → allow.
sp="$work/standalone"; mkdir -p "$sp/.sdd/feat"; printf 'feat\n' > "$sp/.sdd/ACTIVE"; printf 'STATUS: DRAFT\n' > "$sp/.sdd/feat/spec.md"
check "standalone-sdd-write-allows" "$sp" ".sdd/feat/spec.md" 0
# no active item → allow (before any git call)
sp2="$work/noactive"; mkdir -p "$sp2/.sdd"; : > "$sp2/.sdd/ACTIVE"
check "no-active-allows" "$sp2" ".sdd/feat/spec.md" 0
# active but no path → allow
sp3="$work/nopath"; mkdir -p "$sp3/.sdd/feat"; printf 'feat\n' > "$sp3/.sdd/ACTIVE"
check_json "no-path-allows" "$sp3" '{"tool_input":{}}' 0
# write outside the active story's dir is not this hook's concern → allow
check "outside-active-dir-allows" "$sp" "src/app.py" 0

# --- fail closed on unexpected error: unreadable .sdd/ACTIVE ---
sp4="$work/unreadable"; mkdir -p "$sp4/.sdd/feat"; printf 'feat\n' > "$sp4/.sdd/ACTIVE"; printf 'STATUS: DRAFT\n' > "$sp4/.sdd/feat/spec.md"
chmod 000 "$sp4/.sdd/ACTIVE"
rc=0; ( cd "$sp4" && printf '{"tool_input":{"file_path":".sdd/feat/spec.md"}}' | CLAUDE_PROJECT_DIR="$sp4" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
chmod 644 "$sp4/.sdd/ACTIVE"
if [ "$rc" -eq 2 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=2\n' "unreadable-ACTIVE-fails-closed"
else fail=$((fail+1)); printf 'FAIL %-40s want=2 got=%s\n' "unreadable-ACTIVE-fails-closed" "$rc"; fi

# --- git-dependent cases: a real superproject + submodule member ---
# make_member <name> <ratified:yes|no> <planned-story> <active-story> -> echoes member working tree
make_member() {
  local name="$1" ratified="$2" planned="$3" active="$4"
  local super="$work/$name-super" src="$work/$name-src"
  mkdir -p "$super" "$src"
  ( cd "$src" && git init -q && git config user.email t@e && git config user.name t && git commit --allow-empty -qm init ) >/dev/null 2>&1
  ( cd "$super" && git init -q && git config user.email t@e && git config user.name t && git commit --allow-empty -qm init \
      && git -c protocol.file.allow=always submodule add -q "$src" member ) >/dev/null 2>&1
  mkdir -p "$super/.sdd/_epic/myepic"
  printf 'EPIC: myepic\n\n## Stories\n- id: %s\n  repo: member\n' "$planned" > "$super/.sdd/_epic/myepic/plan.md"
  printf 'EPIC: myepic\n\n## Contracts\n### thing\n- kind: openapi\n' > "$super/.sdd/_epic/myepic/contracts.md"
  if [ "$ratified" = yes ]; then
    dg=$(bash "$DIGEST" "$super/.sdd/_epic/myepic/plan.md" "$super/.sdd/_epic/myepic/contracts.md")
    printf 'RATIFIED: 2026-06-27T00:00:00Z\nPLAN_DIGEST: %s\n' "$dg" > "$super/.sdd/_epic/myepic/RATIFICATION.md"
  fi
  mkdir -p "$super/member/.sdd/$active"
  printf '%s\n' "$active" > "$super/member/.sdd/ACTIVE"
  printf '%s' "$super/member"
}

git_ok=0
if command -v git >/dev/null 2>&1; then
  probe=$(make_member probe no s1 s1)
  if [ -n "$(cd "$probe" && git rev-parse --show-superproject-working-tree 2>/dev/null)" ]; then git_ok=1; fi
fi

if [ "$git_ok" -eq 1 ]; then
  # epic governs the active story, epic NOT ratified → block the spec write
  m=$(make_member e1 no storyA storyA); check "unratified-epic-blocks-spec"   "$m" ".sdd/storyA/spec.md" 2
  # epic governs the active story, epic ratified → allow
  m=$(make_member e2 yes storyA storyA); check "ratified-epic-allows-spec"     "$m" ".sdd/storyA/spec.md" 0
  # active story is NOT in any epic plan (a standalone story under a superproject) → allow
  m=$(make_member e3 no storyA storyB); check "non-epic-story-allows"          "$m" ".sdd/storyB/spec.md" 0
  # substring must not falsely match (active 'story' vs planned 'storyA') → allow
  m=$(make_member e4 no storyA story);  check "substring-story-not-matched"    "$m" ".sdd/story/spec.md" 0
  # unratified epic, but the write is OUTSIDE the active story's dir → not gated → allow
  m=$(make_member e5 no storyA storyA); check "unratified-write-outside-dir-allows" "$m" ".sdd/other/x.md" 0

  # --- digest re-validation: a present RATIFICATION.md is NOT enough ---
  # tamper: ratify, then edit plan.md after sign-off → recomputed digest != recorded → REFUSE
  m=$(make_member t1 yes storyA storyA)
  printf 'EDIT AFTER SIGN-OFF\n' >> "$work/t1-super/.sdd/_epic/myepic/plan.md"
  check "tamper-edits-plan-after-ratify-refuses" "$m" ".sdd/storyA/spec.md" 2
  # RATIFICATION.md with no PLAN_DIGEST line → cannot verify integrity → REFUSE
  m=$(make_member t2 yes storyA storyA)
  rat="$work/t2-super/.sdd/_epic/myepic/RATIFICATION.md"
  grep -v '^PLAN_DIGEST:' "$rat" > "$rat.tmp" && mv "$rat.tmp" "$rat"
  check "ratified-missing-digest-refuses" "$m" ".sdd/storyA/spec.md" 2
  # contracts.md removed after ratify → cannot recompute the digest → REFUSE
  m=$(make_member t3 yes storyA storyA)
  rm -f "$work/t3-super/.sdd/_epic/myepic/contracts.md"
  check "ratified-missing-contracts-refuses" "$m" ".sdd/storyA/spec.md" 2

  # git-missing while in an estate member → INERT (allow), the deliberate fail-open boundary
  stub="$work/stubbin"; mkdir -p "$stub"
  for b in dirname basename head tail tr cat grep sed find date stat jq; do
    src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$stub/$b"
  done
  m=$(make_member g1 no storyA storyA)
  rc=0; ( cd "$m" && printf '{"tool_input":{"file_path":".sdd/storyA/spec.md"}}' | PATH="$stub" CLAUDE_PROJECT_DIR="$m" /bin/bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf 'ok   %-40s rc=0\n' "git-missing-is-inert"
  else fail=$((fail+1)); printf 'FAIL %-40s want=0 got=%s\n' "git-missing-is-inert" "$rc"; fi
else
  printf 'SKIP git-submodule fixtures (git unavailable or local-path submodules disabled)\n'
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
