# Troubleshoot-fix bug lane — smoke test & walkthrough (v0.5)

A planted bug plus two ways to validate the lane end-to-end: an **automated** check of the
deterministic backbone (no plugin needed), and a **live** run through the real `/sdd-fleet:*`
commands with the plugin enabled.

---

## The planted bug

`fixture/pagination.py` ships a tiny pure function with one deliberate defect:

```python
def page_count(total_items, per_page):
    if per_page <= 0:
        raise ValueError("per_page must be positive")
    return total_items // per_page          # BUG: floor division drops the last partial page
```

**Symptom:** `page_count(31, 10)` returns `3`, but 31 items at 10/page need **4** pages — the
items on the final partial page are unreachable. **Why it belongs in the bug lane (not the
trivial path):** the symptom ("the last page of items is missing") does *not* name the cause; you
have to look at `page_count` to find the floor division. That's `cause_known: false` — diagnosis
is real work. (Contrast a *known-cause* report like "change `//` to ceil on line 8", which triage
bounces to `/sdd-fleet:jira-story`.)

The fixture also ships `pagination.fixed.py` (the one-line fix — ceiling division),
`repro_check.py` (the reproduction, RED vs the bug / GREEN vs the fix), and
`diagnosis.example.md` (a CONFIRMED-quality diagnosis for reference).

---

## 1. Automated — the deterministic backbone (no plugin required)

```bash
bash docs/v0.5/smoke/smoke.sh
```

It builds a throwaway project from the fixture and walks the bug through every phase, invoking the
**actual plugin hooks** at each gate, asserting:

- `validate-diagnosis-status` accepts the artifact at each STATUS (`REPORTED → … → FIXED`);
- the **source-write gates** block `pagination.py` until `diagnosis.md` is `CONFIRMED` **and** a
  reproducing test exists — but always allow `tests/` and `.sdd/` writes;
- the reproduction is **RED** against the bug and **GREEN** after the fix;
- the **counterfactual** holds (reverting the fix turns the test RED again);
- `/ship-fix`'s lock-clear frees `.sdd/ACTIVE`.

Expected tail: `passed=15 failed=0 … SMOKE PASS`.

> This harness is not ceremony: on its first run it caught a real **AC-7 deadlock** —
> `block-source-before-finalized` was blocking a bug's `tests/` writes pre-CONFIRMED, so the
> reproducing test (the precondition for ever reaching CONFIRMED) could never be written. The unit
> harnesses and four plugin-dev reviews had all missed it. Fixed; the case is now a regression test.

---

## 2. Live — the full lane with the plugin enabled

The classifier and the `diagnose.js` confirmation workflow are LLM-driven and can't be asserted by
a shell script — run them for real:

```bash
mkdir /tmp/bf-smoke && cp docs/v0.5/smoke/fixture/pagination.py /tmp/bf-smoke/
cd /tmp/bf-smoke && git init -q && git add -A && git commit -qm "planted bug"
claude --plugin-dir /Users/rocconno/sdd-fleet        # enable sdd-fleet here
```

Then drive the lane (watch the `SDD_FLEET_*` signal line each command prints **before** its prose):

| Step | Command | Expect (signal · state) |
|---|---|---|
| **REPORT** | `/sdd-fleet:jira-story "page_count(31,10) returns 3 — the last page of items is unreachable"` | `SDD_FLEET_TRIAGE {severity:sev1, cause_known:false, phase:REPORT}`. Scaffolds `.sdd/<bug>/diagnosis.md` (STATUS `REPORTED`, symptom verbatim) + `PROGRESS.md` (`LANE: bug`); sets `.sdd/ACTIVE`. *Verify:* an edit to `pagination.py` is refused by the gate. |
| **REPRODUCE** | `/sdd-fleet:feature-dev` | qa writes `tests/test_pagination.py` (RED), flips STATUS `REPORTED→REPRODUCING`. `SDD_FLEET_REPRO_READY {failing_tests:1}`, `PHASE: REPRODUCE`. |
| *(record the hypothesis)* | — | Whoever holds the reproduction fills `diagnosis.md`'s `## Root-cause hypothesis` / `## Blast radius` / `## Fix strategy` (see `diagnosis.example.md`). |
| **DIAGNOSE** | `/sdd-fleet:feature-dev` | Gates on the hypothesis, flips `→DIAGNOSED`, dispatches `diagnose.js` (`SDD_FLEET_WORKFLOW_LAUNCHED`). architect + coder try to refute it citing the reproduction; it survives → `confirmed`. The scribe records the verdict; `PHASE: FIX`. `/sdd-fleet:status` shows the verdict on completion. |
| **FIX** | `/sdd-fleet:feature-dev` | Flips `diagnosis.md → CONFIRMED` (unlocks source), coder applies ceiling division → test GREEN. `SDD_FLEET_FIX_DONE {tests_green:…}`. |
| **VERIFY** | `/sdd-fleet:feature-dev` | qa runs the **counterfactual** (revert the fix → test must go RED → restore); architect checks blast radius. Clean → `diagnosis.md → FIXED`, `PHASE: HANDOFF`. `SDD_FLEET_VERIFY {verdict:clean, counterfactual_ok:true}`. |
| **HANDOFF** | `/sdd-fleet:pr-review` | devops ships; `SDD_FLEET_SHIP_FIX`; **clears `.sdd/ACTIVE`**. `/sdd-fleet:status` → no active item. |

At any point, `/sdd-fleet:status` prints the bug view (phase · `SEV` · `diagnosis.md` STATUS ·
`CYCLE`/`FIX_CYCLE`).

### sev0 hotfix variant (optional)

Describe the bug as production-down (or set `SEV: sev0` in `PROGRESS.md`). Now `/sdd-fleet:feature-dev`
**short-circuits** — `SDD_FLEET_DIAGNOSE_SEV0_SKIP` — and you go straight to `/sdd-fleet:feature-dev`,
which takes the fast-path from `DIAGNOSED`, emits `SDD_FLEET_POSTHOC_DIAGNOSIS_DUE`, and flips to
CONFIRMED **without** the adversarial workflow. The reproducing-test gate still holds — sev0 never
ships source without a red-first test.

### Boundary check (the known-cause bounce)

`/sdd-fleet:jira-story "the per_page<=0 guard message has a typo: 'positve'"` → the classifier returns
`cause_known: true` → `SDD_FLEET_TRIAGE_KNOWN_CAUSE`, the scaffold is removed, the lock is freed,
and you're sent to the forward `/sdd-fleet:jira-story` trivial path. This is the sharp boundary.

---

## What each layer proves

- **`smoke.sh`** — the *deterministic* spine: the hook gates, the STATUS lifecycle, RED→GREEN, and
  the counterfactual. Fast, no LLM, no plugin install. Run it in CI.
- **The live run** — the *judgment* layer: cause-known routing, the inverted `diagnose.js` survival
  vote, and the role agents. Run it when changing prompts or the workflow.
