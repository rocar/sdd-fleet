# repro_check.py — the reproduction for "pagination drops the last partial page".
#
# Deliberately NOT named test_*.py / *_test.py so pytest does not auto-collect it in the
# plugin repo (it asserts against buggy code). The smoke driver copies it into the temp
# workspace as tests/test_pagination.py — where it IS the lane's reproducing test.
#
# Run directly: `python3 repro_check.py`  (exit 0 = GREEN, exit 1 = RED).
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from pagination import page_count


def test_partial_last_page_is_counted():
    # 31 items at 10/page need 4 pages — the 31st item lives on page 4. The bug returns 3.
    got = page_count(31, 10)
    assert got == 4, f"expected 4 pages for 31 items @10/page, got {got}"


def test_exact_multiple_unchanged():
    assert page_count(30, 10) == 3


def test_empty_has_no_pages():
    assert page_count(0, 10) == 0


if __name__ == "__main__":
    failures = []
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            try:
                _fn()
            except AssertionError as exc:
                failures.append(f"{_name}: {exc}")
    if failures:
        print("RED:")
        for f in failures:
            print("  " + f)
        sys.exit(1)
    print("GREEN: all reproduction checks pass")
    sys.exit(0)
