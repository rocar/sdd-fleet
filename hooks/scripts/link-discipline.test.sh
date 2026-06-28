#!/usr/bin/env bash
# Tests for hooks/scripts/link-discipline.sh (Slice 7).
# PreToolUse Write|Edit|NotebookEdit: on a write to a .sdd/**/*.md file —
#   Rule 1 (ALL tiers): no [[wikilink]].
#   Rule 2 (repo-level ONLY — member + standalone): a relative link that resolves
#           OUTSIDE the repo root. The workspace/superproject tier (.gitmodules at the
#           anchored root, not itself a submodule) skips rule 2 — down-links into
#           submodules are legal and must never be blocked.
# Inert (exit 0): non-.sdd write, non-.md write, no path. Fail closed (exit 2): a '..'
# write-target, a missing tool (jq), an unparseable payload.
# Two-sided on purpose: every BLOCK has a matching ALLOW so neither rule over- nor
# under-binds. Run: bash hooks/scripts/link-discipline.test.sh   (exit 0 = all pass)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/link-discipline.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0

assert_rc() { # name want got
  if [ "$3" -eq "$2" ]; then pass=$((pass+1)); printf 'ok   %-46s rc=%s\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL %-46s want=%s got=%s\n' "$1" "$2" "$3"; fi
}

# fire <name> <proj> <file_path> <content> <want> — a Write tool call (.content).
fire() {
  local name="$1" proj="$2" fp="$3" content="$4" want="$5" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" --arg c "$content" '{tool_input:{file_path:$f,content:$c}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  assert_rc "$name" "$want" "$rc"
}
# fire_edit — an Edit tool call (.new_string); covers the `// .tool_input.new_string` branch.
fire_edit() {
  local name="$1" proj="$2" fp="$3" ns="$4" want="$5" rc=0
  ( cd "$proj" && jq -nc --arg f "$fp" --arg s "$ns" '{tool_input:{file_path:$f,new_string:$s}}' \
      | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  assert_rc "$name" "$want" "$rc"
}
# fire_raw — a literal JSON payload (no jq build), for the no-path and malformed cases.
fire_raw() {
  local name="$1" proj="$2" json="$3" want="$4" rc=0
  ( cd "$proj" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); rc=$?
  assert_rc "$name" "$want" "$rc"
}

# --- standalone fixture (plain dir; not a submodule, no .gitmodules) → rule 2 APPLIES ---
sa="$work/standalone"; mkdir -p "$sa"

# Chokepoint / inert
fire     "non-sdd-write-inert"            "$sa" "src/app.py"            "see [[X]]"  0   # not under .sdd/ → not scanned
fire     "non-md-sdd-write-inert"         "$sa" ".sdd/feat/diagram.svg" "[[X]]"      0   # under .sdd/ but not .md
fire_raw "no-file-path-inert"             "$sa" '{"tool_input":{}}'                  0
fire     "write-target-traversal-closed"  "$sa" ".sdd/../escape.md"     "hi"         2   # '..' in the write target

# Rule 1 — wikilinks, all tiers (two-sided)
fire      "wikilink-blocks"                    "$sa" ".sdd/feat/spec.md" "See [[Other Page]] now."        2
fire      "clean-markdown-link-allows"         "$sa" ".sdd/feat/spec.md" "See [other](./other.md)."       0
fire      "bash-double-bracket-not-wikilink"   "$sa" ".sdd/feat/spec.md" 'Run `if [[ -f x ]]; then ...`'  0   # not a wikilink
fire_edit "edit-new-string-wikilink-blocks"    "$sa" ".sdd/feat/spec.md" "ref [[Page]]"                   2

# Rule 2 — standalone applies it (J2: NOT inert standalone); two-sided
fire "standalone-in-repo-dotdot-allows"  "$sa" ".sdd/feat/spec.md" "[x](../../x.md)"            0   # lands at repo root
fire "standalone-escape-blocks"          "$sa" ".sdd/feat/spec.md" "[s](../../../sibling/y.md)" 2   # climbs out of the repo
fire "standalone-plain-relative-allows"  "$sa" ".sdd/feat/spec.md" "[a](sub/child.md) and [b](./n.md)" 0
fire "standalone-url-and-anchor-allow"   "$sa" ".sdd/feat/spec.md" "[r](https://reg/ledger.post) and [s](#section)" 0

# --- workspace fixture (.gitmodules at root, not a submodule) → rule 1 on, rule 2 INERT ---
ws="$work/workspace"; mkdir -p "$ws"; : > "$ws/.gitmodules"
fire "workspace-downlink-allows"           "$ws" ".sdd/_epic/lessons/foo.md" "[m](../../../member/.sdd/story/x.md)" 0   # representative down-link
fire "workspace-rule2-inert-on-escape"     "$ws" ".sdd/_epic/lessons/foo.md" "[e](../../../../sibling/x.md)"        0   # WOULD escape under rule 2 → allowed only because the workspace tier skips it
fire "workspace-wikilink-still-blocks"     "$ws" ".sdd/_epic/lessons/foo.md" "[[Page]]"                            2   # rule 1 is NOT inert at workspace

# --- fail closed: a missing tool (jq) ---
stub="$work/stub"; mkdir -p "$stub"
for b in bash basename dirname cat grep sed tr head pwd git chmod; do s=$(command -v "$b" 2>/dev/null) && ln -sf "$s" "$stub/$b"; done
tm="$work/toolmiss"; mkdir -p "$tm"
rc=0; ( cd "$tm" && printf '{"tool_input":{"file_path":".sdd/feat/spec.md","content":"hi"}}' \
    | PATH="$stub" CLAUDE_PROJECT_DIR="$tm" /bin/bash "$HOOK" >/dev/null 2>&1 ); rc=$?
assert_rc "tool-missing-fails-closed" 2 "$rc"

# --- fail closed: an unparseable tool-call payload (the 'unreadable subject' case) ---
fire_raw "malformed-input-fails-closed" "$sa" '{bad json' 2

# --- member fixture: a REAL git submodule (resolve_superproject non-empty) → rule 2 APPLIES ---
make_member() { # <name> -> echoes the member working tree
  local name="$1"
  local super="$work/$name-super" src="$work/$name-src"
  mkdir -p "$super" "$src"
  ( cd "$src" && git init -q && git config user.email t@e && git config user.name t && git commit --allow-empty -qm init ) >/dev/null 2>&1
  ( cd "$super" && git init -q && git config user.email t@e && git config user.name t && git commit --allow-empty -qm init \
      && git -c protocol.file.allow=always submodule add -q "$src" member ) >/dev/null 2>&1
  printf '%s' "$super/member"
}
git_ok=0
if command -v git >/dev/null 2>&1; then
  probe=$(make_member probe)
  [ -n "$(cd "$probe" && git rev-parse --show-superproject-working-tree 2>/dev/null)" ] && git_ok=1
fi
if [ "$git_ok" -eq 1 ]; then
  m=$(make_member m1); fire "member-escape-blocks"        "$m" ".sdd/story/spec.md" "[s](../../../sibling/y.md)" 2
  m=$(make_member m2); fire "member-in-repo-dotdot-allows" "$m" ".sdd/story/spec.md" "[x](../../x.md)"           0
else
  printf 'SKIP member submodule fixtures (git unavailable or local-path submodules disabled)\n'
fi

echo "-----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
