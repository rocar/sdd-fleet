---
name: test-plan
description: QA's test design checklist for .sdd/<feature>/TEST_PLAN.md. Maps each acceptance criterion to one or more test cases and a coverage type (unit, integration, e2e). Consult during BUILD when drafting the test plan and during CHANGE_REVIEW when reviewing coverage.
---

# Test Plan

This skill defines the structure and discipline of
`.sdd/<feature>/TEST_PLAN.md`. QA is the sole author. Architect and
architect read it during CHANGE_REVIEW to verify coverage before
handoff.

## When to write the plan

Once `spec.md` STATUS is `FINALIZED` and `PROGRESS.md` PHASE is `BUILD`.
TEST_PLAN.md is drafted first; then tests are implemented against it. If
the plan reveals an acceptance criterion is untestable, that's a spec
problem — surface it to the orchestrator and stop. Do not invent
creative tests to paper over an unclear criterion.

**Tests-first ordering.** The failing test suite must exist in `tests/` BEFORE
coder begins implementation. The orchestrator dispatches qa via `/sdd-fleet:feature-dev`'s
pass-output sequence; qa signals `SDD_FLEET_QA_TESTS_READY: <count> failing tests in tests/` once
the plan + suite are in place; only then is coder dispatched. CHANGE_REVIEW verifies
each test would FAIL if coder's source change were reverted (the counterfactual gate).

## File structure

````markdown
# Test Plan — <feature>

Source of truth: [acceptance.md](./acceptance.md).
Tests live at: <path/relative/to/project/root>

## Coverage matrix

| Criterion | Test name | Type | Location |
|---|---|---|---|
| AC-1 | `<test_function_name>` | unit | `tests/foo_test.py::test_x` |
| AC-1 | `<test_function_name>` | integration | `tests/integration/foo_test.py::test_y` |
| AC-2 | ... | ... | ... |

## Coverage types

- **unit**: in-process, no I/O. Pure function-level checks of behavior in
  the source.
- **integration**: crosses a real boundary (DB, file system, an in-process
  HTTP server, etc.). Mocks the *outside* world, not the *inside* of the
  feature.
- **e2e**: drives the system as a user would. Slowest, fewest, highest
  signal.

## Failure-path notes

For each acceptance criterion with non-trivial failure behavior, list the
failure tests separately with a `(failure)` suffix on the test name. The
goal: a future reader can grep `(failure)` and see every error path that
has a test.

## Coverage gaps

If you cannot map an acceptance criterion to a test (because the criterion
is untestable as written, or because the project lacks the infrastructure
to test it), list it under a final section:

```markdown
## Gaps

- AC-N: <criterion text> — <reason it can't be tested as written>.
  Recommendation: <revise spec | add infra | escalate>.
```

A non-empty `## Gaps` section is a `[blocker]` for CHANGE_REVIEW until
resolved.
````

## Discipline rules

- Every acceptance criterion appears in the coverage matrix at least once,
  or in `## Gaps` with a reason.
- Every test in the matrix actually exists in the codebase (CHANGE_REVIEW
  will verify).
- Tests fail before the corresponding implementation lands, pass after.
  If a test passes against an empty implementation, it isn't testing
  behavior; rewrite it.
- Mock at the boundary the spec is *not* about. If the spec is "calls
  service X with payload Y", a test that mocks the producer of Y is
  decorative.
- Cover failure paths, not just happy paths. The system's behavior under
  malformed input, partial failure, and concurrent callers is part of the
  spec even when the spec is silent — qa raised that as `[major]` in
  REVIEW; the tests close it.

## CHANGE_REVIEW use

When reviewing the diff:

1. For each acceptance criterion, find its row in the matrix and confirm
   the test actually exists and is run by the project's test command.
2. Run the test suite locally. If `stop-tests` would catch a regression,
   coverage is real. If the test exists but the suite skips it,
   `[blocker]`.
3. Approve only when the matrix is complete and the suite is green.
