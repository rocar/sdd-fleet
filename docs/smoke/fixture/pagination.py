# pagination.py — a tiny pure-function paginator. Contains the PLANTED BUG.
#
# Symptom: page_count(31, 10) returns 3, but 31 items at 10/page need 4 pages —
# the items on the final partial page are unreachable.


def page_count(total_items, per_page):
    """Number of pages needed to show total_items at per_page items each."""
    if per_page <= 0:
        raise ValueError("per_page must be positive")
    # BUG: floor division truncates the final partial page, so the last items
    # are unreachable. Any total that isn't an exact multiple loses its remainder page.
    return total_items // per_page
