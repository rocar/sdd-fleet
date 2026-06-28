# pagination.py — FIXED: ceiling division counts the final partial page.
# The diff against the buggy pagination.py is the whole fix (one line).


def page_count(total_items, per_page):
    """Number of pages needed to show total_items at per_page items each."""
    if per_page <= 0:
        raise ValueError("per_page must be positive")
    # Ceiling division — the final partial page is counted.
    return (total_items + per_page - 1) // per_page
