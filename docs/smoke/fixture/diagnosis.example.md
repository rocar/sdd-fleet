STATUS: CONFIRMED

# Bug: pagination drops the last partial page

## Symptom + reproduction steps
`page_count(31, 10)` returns `3`, but 31 items at 10 per page need **4** pages — the item on
the final partial page (item 31) is unreachable. Reproduced by
`tests/test_pagination.py::test_partial_last_page_is_counted` (RED against the bug).

## Root-cause hypothesis
`page_count` computes `total_items // per_page` — floor division — which truncates the final
partial page. Any `total_items` that is not an exact multiple of `per_page` loses its remainder
page. (Not a crash and not an exception path: a silently-wrong count.)

## Blast radius
Every caller of `page_count()`: page-navigation controls, "page N of M" displays, and any loop
bounded by the page count. The error is always an **undercount by one** (never an overcount), and
only on non-exact-multiple totals. Read-path only — no data is written, no migration.

## Fix strategy
Ceiling division: `(total_items + per_page - 1) // per_page`. Minimal and local to `page_count`;
preserves the `per_page <= 0` guard and leaves exact-multiple totals unchanged. No new dependency,
no interface change. The reproducing test pins the boundary (31→4, 30→3, 0→0).
