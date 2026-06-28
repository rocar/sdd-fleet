#!/usr/bin/env bash
# scripts/pin-workflow.sh — the deterministic PIN keystone of Layer 2 (generate-then-pin).
#
# Freezes a generated workflow candidate from quarantine into the TARGET project's
# .claude/workflows/, but ONLY after it passes the determinism lint — so a workflow
# Claude authored on the fly becomes a static, replayable, project-committed artifact
# whose execution is bit-for-bit governable. The lint runs HERE (not just in the
# dispatching command's prose) so a non-deterministic candidate can never be pinned,
# regardless of how it was generated.
#
#   candidate: .sdd/_generated/<name>.js        (quarantine; gitignored scratch)
#   pinned:    .claude/workflows/<name>.js       (project-owned; invokable as /<name>)
#
# Usage:   pin-workflow.sh <name>     (<name>: kebab-case slug, no path separators)
# Output (stdout — the machine contract; see CLAUDE.md "signal lines"):
#   SDD_FLEET_WORKFLOW_PINNED:       {"name":"<name>","path":".claude/workflows/<name>.js"}
#   SDD_FLEET_WORKFLOW_PIN_REFUSED:  {"name":"<name>","reason":"<slug>"}
# Exit: 0 = pinned; 2 = refused (bad name / missing candidate / lint failed / error).
# bash 3.2 compatible; BSD + GNU coreutils compatible.
set -euo pipefail
# Resolve our own scripts/ dir FIRST — BASH_SOURCE[0] may be a relative path, and the
# cd below would invalidate it (so the sibling lint must be located before anchoring).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Anchor at the target project root (like the gate hooks); a drifted cwd must not
# silently relocate the quarantine or the pin destination.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

name="${1:-}"

refuse() {  # refuse <reason-slug> <message>
  echo "sdd-fleet: $2" >&2
  printf 'SDD_FLEET_WORKFLOW_PIN_REFUSED: {"name":"%s","reason":"%s"}\n' "$name" "$1"
  exit 2
}
# Fail CLOSED on any unexpected error (mirrors the gate hooks): a failed pin must
# refuse, never silently "succeed". Every deliberate success is the explicit exit 0.
trap 'refuse "internal-error" "pin-workflow errored unexpectedly — failing closed (refused)."' ERR

# --- validate the name: a bare kebab-case slug, no path tricks ---
[ -n "$name" ] || refuse "no-name" "no workflow name given. Usage: pin-workflow.sh <name>"
case "$name" in
  */*|*\\*) refuse "bad-name" "name '$name' must not contain a path separator." ;;
  *..*|.) refuse "bad-name" "name '$name' must not contain '..'." ;;
esac
# Restrict to the slug charset the rest of sdd-fleet uses (kebab-case).
case "$name" in
  *[!a-z0-9-]*) refuse "bad-name" "name '$name' must be kebab-case [a-z0-9-]." ;;
esac

candidate=".sdd/_generated/${name}.js"
dest_dir=".claude/workflows"
dest="${dest_dir}/${name}.js"

[ -f "$candidate" ] && [ -r "$candidate" ] \
  || refuse "no-candidate" "no readable candidate at ${candidate} — draft it first with /sdd-fleet:scaffold-workflow."

# --- HARD determinism gate: the candidate must pass the lint before it can be pinned ---
if ! bash "$DIR/workflow-determinism-lint.sh" "$candidate" >/dev/null 2>&1; then
  echo "sdd-fleet: ${candidate} failed the determinism lint — re-run the lint to see the violations:" >&2
  echo "  bash \"${DIR}/workflow-determinism-lint.sh\" \"${candidate}\"" >&2
  refuse "determinism-lint-failed" "candidate is not deterministic — refusing to pin."
fi

# --- pin: create the project workflows dir and copy the frozen artifact in ---
mkdir -p "$dest_dir"
cp "$candidate" "$dest"

printf 'SDD_FLEET_WORKFLOW_PINNED: {"name":"%s","path":"%s"}\n' "$name" "$dest"
echo "sdd-fleet: pinned ${candidate} → ${dest}. Run it with /${name} (it is now a frozen, replayable project workflow)." >&2
exit 0
