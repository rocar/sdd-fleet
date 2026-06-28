# `/build-fleet:new-feature` detail-intake — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `/build-fleet:new-feature` an optional inline detail argument and an interactive structured clarify loop, while keeping conversation/backlog sourcing.

**Architecture:** A prose-only edit to one slash command (`commands/new-feature.md`) plus its README doc surface. Description precedence becomes **inline arg → conversation → backlog intent** (arg wins); a ≥2-of-3 quality floor triggers an `AskUserQuestion` clarify loop when the description is empty *or* thin. Interactive-only; the inline arg is the headless channel. Design spec: `docs/history/2026-06-20-new-feature-detail-intake.md`.

**Tech Stack:** Claude Code slash-command markdown (YAML frontmatter + orchestration prose), the `AskUserQuestion` tool, the existing `scripts/intent-block.sh` helper, and `scripts/run-tests.sh` as the regression guard.

---

## Testing model (read first — this is not code)

build-fleet commands are **orchestration prose**, not scripts. The repo unit-tests only
`scripts/` and `hooks/` (each has a `.test.sh`); there is **no harness for command prose**
and the design spec deliberately adds none. So the standard "write a failing test first"
cycle does not apply here. Verification per task is **structural** (grep the changed region,
read it back for internal consistency). Once, at the end, run the full suite
(`bash scripts/run-tests.sh`) as a **regression guard** — prose edits must not break any
script/hook, and CLAUDE.md requires the suite stays green. Do not add new test files.

## Commit / branch policy (read first)

This repo enforces **release discipline: `main` always equals the latest tag.** Do **not**
commit to `main`. Task 1 creates a feature branch and every commit lands there. If you are
following the project's "bundle uncommitted work into the next release" pattern (as the
in-flight dynamic-workflow-enrichment slices currently are), you may **skip the per-task
commit steps** and leave the change as a single working-tree diff — the edits are tiny and
self-contained. The commit steps are written branch-safe for those who want them.

## File structure

- **Modify:** `commands/new-feature.md` — frontmatter (Task 2), Arguments section (Task 3),
  step 5 (Task 4), step 8 (Task 5). This is the entire behavior change.
- **Modify:** `README.md` — usage example + intake paragraph + command-reference row (Task 6).
- **No files created.** No new scripts, no new tests (see testing model).

---

### Task 1: Create the feature branch

**Files:** none (git only).

- [ ] **Step 1: Branch off main (never commit to main)**

Run:
```bash
git switch -c feat/new-feature-detail-intake
```
Expected: `Switched to a new branch 'feat/new-feature-detail-intake'`.

- [ ] **Step 2: Confirm clean starting point**

Run: `git status --short`
Expected: the only untracked files are the two `docs/history/2026-06-20-new-feature-detail-intake*.md` docs (and the loop-engineering research note, if still uncommitted). No modified tracked files.

---

### Task 2: Update frontmatter (arg hint + allow `AskUserQuestion`)

**Files:**
- Modify: `commands/new-feature.md:1-5` (YAML frontmatter)

- [ ] **Step 1: Replace the `argument-hint` and `allowed-tools` lines**

Find this exact block:
```yaml
---
description: Scaffold a feature workspace and draft its spec
argument-hint: "<feature-slug>"
allowed-tools: Read, Write, Edit, Task, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-block.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh":*)
---
```
Replace with:
```yaml
---
description: Scaffold a feature workspace and draft its spec
argument-hint: "<feature-slug> [feature details]"
allowed-tools: Read, Write, Edit, Task, AskUserQuestion, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-block.sh":*), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/acquire-active.sh":*)
---
```

- [ ] **Step 2: Verify the frontmatter changed and is intact**

Run: `sed -n '1,5p' commands/new-feature.md`
Expected: `argument-hint` ends with `[feature details]"`; `allowed-tools` contains `Task, AskUserQuestion, Bash(...)`; the `--- ... ---` fences are present and the `description` line is unchanged.

- [ ] **Step 3: Commit (branch only — or skip per policy)**

```bash
git add commands/new-feature.md
git commit -m "feat(new-feature): inline-detail arg hint + allow AskUserQuestion

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rewrite the Arguments section

**Files:**
- Modify: `commands/new-feature.md` — the `## Arguments` section (currently lines 16-19)

- [ ] **Step 1: Replace the Arguments block**

Find this exact block:
```markdown
## Arguments

`$ARGUMENTS` — the feature slug. Kebab-case, no whitespace. If empty, refuse
and surface that the user must supply a slug.
```
Replace with:
```markdown
## Arguments

`$ARGUMENTS` — `<slug> [feature details…]`:

- The **first whitespace-delimited token is the feature slug** (kebab-case, no
  whitespace). If `$ARGUMENTS` is empty, refuse and surface that the user must
  supply a slug.
- **Everything after the first token is an optional inline feature description**
  (free text), trimmed. When present it is the authoritative description for this
  run (see step 5, "Establish the feature description") and is the channel headless
  / `claude -p` callers use to supply detail.
```

- [ ] **Step 2: Verify**

Run: `sed -n '/^## Arguments/,/^[0-9]\. /p' commands/new-feature.md | head -20`
Expected: shows the new two-bullet Arguments section ending before step 1 ("Acquire the in-flight lock").

- [ ] **Step 3: Commit (branch only — or skip per policy)**

```bash
git add commands/new-feature.md
git commit -m "feat(new-feature): document <slug> [details] argument shape

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Rewrite step 5 (the core change — precedence, floor, clarify loop)

**Files:**
- Modify: `commands/new-feature.md` — step 5, "Establish the feature description" (currently lines 89-123). Replace the entire numbered item 5 (everything from `5. **Establish the feature description.**` up to, but **not** including, `5b. **Inherit the product stack`).

- [ ] **Step 1: Replace the whole of step 5 with the new content**

New step 5 (verbatim):
```markdown
5. **Establish the feature description.** Before classifying or drafting,
   determine *what the feature actually is* — the slug alone is not a spec.
   Resolve the description from these sources, in precedence order (**an explicit
   inline arg wins**):

   1. **Inline detail arg.** If `$ARGUMENTS` carried text after the slug (see
      Arguments), that text is the authoritative description for this invocation —
      use it even if the conversation also holds detail (passing the arg is a
      deliberate "use *this*"). Headless / `claude -p` callers MUST use this
      channel; the clarify loop below cannot run without a human.
   2. **Conversation context.** If there was no inline arg, look back through the
      conversation for a description the user already gave (e.g. "build a
      celsius→fahrenheit converter that handles negatives", or the conclusions of a
      design/research discussion earlier in the same session).
   3. **Product backlog intent.** If neither of the above is present and
      `.sdd/_product/backlog.md` exists, run the shared intent-block extractor — the
      SAME script `/build-fleet:next-feature` uses, so the two always reach the same
      verdict (one grammar, one quality floor, one implementation):
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-block.sh" --slug "<slug>" .sdd/_product/backlog.md
      ```
      It prints the canonical intent block (the 1–3 indented lines under the feature
      row) and a final `INTENT_VERDICT: usable|too-thin` line. On `usable`, that
      intent is the **plan author's starting description** — carry it forward and
      label it to the PO as the inherited intent (step 8). (If the slug has no
      backlog row, the script errors — that just means there is no inherited intent;
      continue.)

   **Quality floor (≥2-of-3).** Whatever the source, the description must clear the
   floor: at least 2 of the 3 components — *what the feature is* / *its scope
   boundary* / *its non-goals*. For a backlog intent the floor is the script's
   deterministic `INTENT_VERDICT` (`usable` clears it; `too-thin` does not). For an
   inline arg or a conversation description there is no script — **you judge it
   against the same 3-component floor** (a judgment, not a deterministic gate —
   consistent with the `sdd-protocol` principle "gates are deterministic; judgments
   are adversarial"; the canonical prose definition lives in the `sdd-protocol`
   skill's `references/product-tier.md`). A bare slug-restatement ("the API client")
   or a one-word arg ("converter") is below the floor.

   **Clarify loop (interactive only) — run when the description is empty OR below the
   floor.** Do not infer requirements from the slug — a slug like `celsius-converter`
   names the feature but says nothing about behavior, inputs/outputs, edge cases, or
   constraints. Use **`AskUserQuestion`** to ask a structured, sectioned prompt
   targeting the *missing* components (behavior, inputs/outputs, edge cases,
   non-goals / scope boundary). **Repeat** until one of: the gathered description
   clears the ≥2-of-3 floor; the user chooses a "proceed anyway" option; or you have
   asked **3 rounds** — then proceed with whatever was gathered and tell the
   architect the description is thin (step 8). If an inline arg was present but
   thin while the conversation held detail, the arg stays the authoritative base; the
   loop may pre-fill or *suggest* answers from that context, but the user confirms.
   The classifier and architect both consume this description; classifying from a
   bare slug produces a hallucinated spec.

   > **Interactive-only.** This command is a human-driven entry point. In a headless
   > / `claude -p` run with no inline detail, `AskUserQuestion` has no responder and
   > the command cannot proceed — supply the description via the inline arg instead.

   - Carry the resolved description (from the arg, context, backlog, or the clarify
     loop) verbatim into the classifier prompt below and into the architect
     delegation in step 8.
```

- [ ] **Step 2: Verify the splice is clean (step 5 → 5b boundary intact)**

Run: `grep -n "^5\. \*\*Establish\|^5b\. \*\*Inherit\|^6\. \*\*Run the classifier" commands/new-feature.md`
Expected: three matches in ascending line order — step 5, then 5b, then 6 — confirming the replacement didn't swallow 5b or step 6.

- [ ] **Step 3: Verify the new anchors are present**

Run: `grep -n "Inline detail arg\|Quality floor (≥2-of-3)\|Clarify loop (interactive only)\|Interactive-only" commands/new-feature.md`
Expected: one match for each of the four headings/callouts.

- [ ] **Step 4: Commit (branch only — or skip per policy)**

```bash
git add commands/new-feature.md
git commit -m "feat(new-feature): arg>context>backlog precedence + thin-triggered clarify loop

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Add the thin-description flag to step 8 (architect delegation)

**Files:**
- Modify: `commands/new-feature.md` — step 8, immediately before the "Tell PO not to set STATUS=IN_REVIEW" instruction (currently lines 251-252).

- [ ] **Step 1: Insert the thinness-flag instruction**

Find this exact block:
```markdown
   Tell PO not to set STATUS=IN_REVIEW regardless of tier — that's `/build-fleet:review`'s
   job (which trivial features skip; standard/large run normally).
```
Replace with:
```markdown
   **Thin description (clarify loop hit its cap).** If step 5's clarify loop ended
   below the quality floor (the 3-round cap or an explicit "proceed anyway"), say so
   plainly in the PO prompt — label the description "best-effort / below the usual
   detail floor" and instruct PO to surface the resulting gaps in `## Self-review
   notes` rather than inventing requirements. (Omit this block when the description
   cleared the floor.)

   Tell PO not to set STATUS=IN_REVIEW regardless of tier — that's `/build-fleet:review`'s
   job (which trivial features skip; standard/large run normally).
```

- [ ] **Step 2: Verify**

Run: `grep -n "Thin description (clarify loop hit its cap)\|Tell PO not to set STATUS=IN_REVIEW" commands/new-feature.md`
Expected: two matches, the "Thin description" line immediately preceding the "Tell PO" line.

- [ ] **Step 3: Commit (branch only — or skip per policy)**

```bash
git add commands/new-feature.md
git commit -m "feat(new-feature): flag below-floor descriptions to architect

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Update README (usage example + intake paragraph + command-reference row)

**Files:**
- Modify: `README.md:268` (feature-only usage example)
- Modify: `README.md:275-277` (intake paragraph)
- Modify: `README.md:524` (command-reference table row)

- [ ] **Step 1: Update the feature-only usage example (line 268)**

Find this exact line:
```
/build-fleet:new-feature my-feature   # asks what it should do if not in context
```
Replace with:
```
/build-fleet:new-feature my-feature "what it should do"   # inline detail; omit to use context, else it asks
```

- [ ] **Step 2: Update the intake paragraph (lines 275-277)**

Find this exact block:
```markdown
`new-feature` will **ask you what the feature should do** if it can't find a
description in the conversation *or* a usable backlog intent — the slug alone is
never treated as a spec. The exact path depends on the routing tier (below).
```
Replace with:
```markdown
You can describe the feature three ways, in precedence order: **inline after the
slug** (`/build-fleet:new-feature <slug> "<what it should do>"`), in the
**conversation** before you run it, or via a **backlog intent** (product tier). An
inline description wins. If none is found — or what's found is too thin —
`new-feature` **asks you in a short structured loop** until it has enough; the slug
alone is never treated as a spec. (The clarify loop is interactive; headless callers
pass the inline description.) The exact path depends on the routing tier (below).
```

- [ ] **Step 3: Update the command-reference table row (line 524)**

Find this exact line:
```markdown
| `/build-fleet:new-feature <slug>` | SPEC | Scaffolds `.sdd/<slug>/`, runs the classifier, has PO draft `spec.md` + `acceptance.md`. Inherits the product stack + backlog intent if present; asks for a description otherwise. |
```
Replace with:
```markdown
| `/build-fleet:new-feature <slug> [details]` | SPEC | Scaffolds `.sdd/<slug>/`, runs the classifier, has PO draft `spec.md` + `acceptance.md`. Takes the feature description from an optional inline `[details]` arg (wins), else the conversation, else a backlog intent; asks in a structured clarify loop if none is usable. Inherits the product stack if present. |
```

- [ ] **Step 4: Verify all three README edits landed**

Run: `grep -n 'inline detail; omit to use context\|three ways, in precedence order\|new-feature <slug> \[details\]' README.md`
Expected: three matches (one per edit), no leftover copies of the old phrasings.

- [ ] **Step 5: Commit (branch only — or skip per policy)**

```bash
git add README.md
git commit -m "docs(readme): document new-feature inline detail + clarify loop

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Regression guard + final consistency pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full suite (must stay green)**

Run: `bash scripts/run-tests.sh`
Expected: every hook + script suite passes and the smoke test passes — same result as before the change (prose edits touch no script/hook). If anything fails, the failure is pre-existing or unrelated; investigate before proceeding.

- [ ] **Step 2: Read the changed command end-to-end against the spec**

Run: `sed -n '1,130p' commands/new-feature.md`
Confirm by eye, against `docs/history/2026-06-20-new-feature-detail-intake.md`:
- Frontmatter: arg hint `[feature details]`, `AskUserQuestion` in `allowed-tools`.
- Arguments: first-token slug + optional inline detail.
- Step 5: precedence arg → context → backlog; arg wins; ≥2-of-3 floor; clarify loop on empty-or-thin; interactive-only callout; thin-arg-with-context ruling.
- Step 5b / 6 / 7 / 7b unchanged and still in order.
- Step 8: thin-description flag present before the IN_REVIEW line.

- [ ] **Step 3: Confirm no stale references**

Run: `grep -n "the feature slug. Kebab-case, no whitespace. If empty" commands/new-feature.md; grep -n "ask you what the feature should do" README.md`
Expected: **no output** from either grep (the old Arguments sentence and old README phrasing are fully replaced).

- [ ] **Step 4: Final commit (branch only — or skip per policy)**

Only if Steps 1-3 are clean and you committed earlier tasks:
```bash
git status --short
```
Expected: clean tree (all changes committed) — or, if following the no-commit policy, exactly the two modified files (`commands/new-feature.md`, `README.md`) plus the docs.

---

## Self-review (run by the plan author — completed)

- **Spec coverage:** A (Arguments/parsing) → Tasks 2-3; B (precedence + floor, arg-wins,
  thin-arg-with-context) → Task 4; C (clarify loop, AskUserQuestion, bounded, interactive-only,
  thin→PO flag) → Tasks 2 (allow tool), 4, 5; D (files: new-feature.md + README, no new tests,
  next-feature out of scope) → Tasks 2-6 + testing-model note. All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO; every edit shows exact find/replace content and exact verify
  commands with expected output.
- **Consistency:** the four step-5 anchors used in Task 4's verify (Step 3) match the headings
  written in Task 4 Step 1; the README grep strings in Task 6 Step 4 match the replacement text;
  the "thin description" string in Task 5's verify matches the inserted heading.
- **Scope:** single command + its README — one focused plan, no decomposition needed.
