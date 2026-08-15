"""WellRange — ports of CoreTests.SelectionTests."""
from playout.editor.well_range import WellPos, WellRange
from playout.model.plate_format import WELL96, PlateFormat


def test_indices_are_row_major_and_clipped():
    r = WellRange(WellPos(1, 1), WellPos(2, 3))
    assert r.indices(WELL96) == [13, 14, 15, 25, 26, 27]
    assert r.min_row == 1 and r.max_row == 2 and r.min_col == 1 and r.max_col == 3
    assert r.row_count == 2 and r.col_count == 3 and r.well_count == 6 and not r.is_single_well
    reversed_range = WellRange(WellPos(2, 3), WellPos(1, 1))
    assert reversed_range.indices(WELL96) == r.indices(WELL96)


def test_out_of_bounds_selection_does_not_trap():
    """A stale range from a larger plate clamps to the last well — never empty, never a crash."""
    assert WellRange.at(40, 40).indices(WELL96) == [95]
    assert WellRange(WellPos(-5, -5), WellPos(-1, -1)).indices(WELL96) == [0]
    assert WellRange.at(0, 0).indices(PlateFormat(1, 1)) == [0]


def test_whole_row_and_column_and_plate():
    fmt = PlateFormat(2, 3)
    assert WellRange.whole_row(1, fmt).indices(fmt) == [3, 4, 5]
    assert WellRange.whole_column(2, fmt).indices(fmt) == [2, 5]
    assert WellRange.whole_plate(fmt).indices(fmt) == [0, 1, 2, 3, 4, 5]


def test_clamped_clamps_both_corners_independently():
    r = WellRange(WellPos(-2, 5), WellPos(20, 30)).clamped(WELL96)
    assert r.anchor == WellPos(0, 5) and r.focus == WellPos(7, 11)


def test_contains_and_positions():
    r = WellRange(WellPos(1, 1), WellPos(2, 2))
    assert r.contains(1, 2) and not r.contains(0, 2)
    assert r.contains_row(2) and not r.contains_col(3)
    assert r.positions(WELL96) == [WellPos(1, 1), WellPos(1, 2), WellPos(2, 1), WellPos(2, 2)]
