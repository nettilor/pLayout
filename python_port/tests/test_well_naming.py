"""WellNaming + PlateFormat — ports of CoreTests.WellNamingTests and the format-clamp tests."""
import pytest

from playout.model.plate_format import STANDARD, WELL96, WELL1536, PlateFormat, WellNaming


def test_row_labels_cover_large_plates():
    assert [WellNaming.row_label(i) for i in (0, 25, 26, 31, 63)] == ["A", "Z", "AA", "AF", "BL"]
    assert WellNaming.row_label(-1) == "?"


def test_row_index_inverts_row_label():
    for n in range(0, 40):
        assert WellNaming.row_index(WellNaming.row_label(n)) == n
    assert WellNaming.row_index("a") == 0
    assert WellNaming.row_index(" b ") == 1
    assert WellNaming.row_index("") is None
    assert WellNaming.row_index("A1") is None
    assert WellNaming.row_index("é") is None


def test_well_label_padding():
    assert WellNaming.well_label(1, 6, padded=False) == "B7"
    assert WellNaming.well_label(1, 6, padded=True) == "B07"
    assert WellNaming.col_label(99, padded=True) == "100"


def test_parse_well():
    assert WellNaming.parse_well("A1") == (0, 0)
    assert WellNaming.parse_well("a01") == (0, 0)
    assert WellNaming.parse_well(" B07 ") == (1, 6)
    assert WellNaming.parse_well("H12") == (7, 11)
    assert WellNaming.parse_well("AA5") == (26, 4)
    assert WellNaming.parse_well("12") is None
    assert WellNaming.parse_well("AB") is None
    assert WellNaming.parse_well("A0") is None
    assert WellNaming.parse_well("") is None


def test_standard_formats():
    assert [(f.rows, f.cols) for f in STANDARD] == [(2, 3), (3, 4), (4, 6), (6, 8), (8, 12), (16, 24), (32, 48)]
    assert WELL96.name == "96-well"
    assert WELL96.detailed_name == "96-well  (8×12)"
    assert WELL96.is_standard and not PlateFormat(5, 7).is_standard
    assert WELL1536.well_count == 1536
    assert PlateFormat.WELL96 is WELL96 and PlateFormat.STANDARD == STANDARD


def test_custom_sizes_are_clamped_on_construction():
    assert PlateFormat(0, 5000) == PlateFormat(1, 96)
    assert PlateFormat(-4, 7) == PlateFormat(1, 7)
    assert PlateFormat(100, 100) == PlateFormat(64, 96)


def test_indexing_is_row_major():
    f = PlateFormat(8, 12)
    assert f.index(1, 6) == 18
    assert (f.row_of(18), f.col_of(18)) == (1, 6)
    assert f.contains(7, 11) and not f.contains(8, 0) and not f.contains(0, -1)


def test_format_json_requires_both_keys_and_clamps():
    from playout.model.layout import LayoutDecodeError

    assert PlateFormat.from_json({"rows": 0, "cols": 5000}) == PlateFormat(1, 96)
    with pytest.raises(LayoutDecodeError):
        PlateFormat.from_json({"rows": 8})
    with pytest.raises(LayoutDecodeError):
        PlateFormat.from_json({"rows": "8", "cols": 12})
    assert PlateFormat(3, 4).to_json() == {"rows": 3, "cols": 4}
