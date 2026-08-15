"""PlateGeometry — ports of the geometry half of OrientationTests and the geometry
assertions of RenderPreviewTests (cell-size table, never overflow, hit bands, 1×1 canvas)."""
import pytest

from playout.editor.well_range import WellPos, WellRange
from playout.model.plate_format import STANDARD, WELL6, WELL96, WELL384, WELL1536, PlateFormat
from playout.ui.plate_geometry import Hit, PlateGeometry, Rect

CANVAS = Rect(0, 0, 940, 560)


@pytest.mark.parametrize(
    "fmt, cell",
    [(WELL6, 96), (PlateFormat(3, 4), 96), (PlateFormat(4, 6), 96), (PlateFormat(6, 8), 83),
     (WELL96, 62.25), (WELL384, 31.644), (WELL1536, 16.0625)],
)
def test_standard_formats_keep_their_pinned_cell_sizes(fmt, cell):
    assert PlateGeometry.fit(fmt, CANVAS).cell == pytest.approx(cell, abs=0.001)


def test_every_standard_format_gets_a_readable_cell_at_the_reference_canvas():
    for fmt in STANDARD:
        assert PlateGeometry.fit(fmt, CANVAS).cell >= 9


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
@pytest.mark.parametrize("size", [(300, 200), (940, 560), (1600, 400), (200, 900)])
@pytest.mark.parametrize("fmt", [WELL6, WELL96, WELL1536, PlateFormat(1, 8), PlateFormat(64, 96), PlateFormat(1, 1)])
def test_geometry_never_overflows_its_bounds(fmt, size, turns):
    bounds = Rect(0, 0, *size)
    g = PlateGeometry.fit(fmt, bounds, turns)
    frame = g.frame_rect
    assert frame.x >= 0 and frame.y >= 0
    assert frame.max_x <= bounds.width + 1e-6 and frame.max_y <= bounds.height + 1e-6
    for row in range(fmt.rows):
        for col in range(fmt.cols):
            r = g.cell_rect(row, col)
            assert frame.x - 1e-6 <= r.x and r.max_x <= frame.max_x + 1e-6
            assert frame.y - 1e-6 <= r.y and r.max_y <= frame.max_y + 1e-6


def test_a_1x1_canvas_does_not_divide_by_zero():
    g = PlateGeometry.fit(WELL96, Rect(0, 0, 1, 1))
    assert g.cell > 0
    assert g.hit(0.5, 0.5).kind in (Hit.WELL, Hit.OUTSIDE, Hit.CORNER, Hit.ROW_HEADER, Hit.COLUMN_HEADER)
    assert g.nearest_well(1e9, -1e9) is not None


# ---------------------------------------------------------------- rotation


def cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_every_turn_is_a_rotation_and_not_a_reflection(turns):
    """Step one model column and one model row; the handedness of the two screen vectors
    (their cross product's sign) is invariant under rotation and flips under reflection."""
    g = PlateGeometry.fit(WELL96, CANVAS, turns)
    o = g.cell_rect(0, 0)
    dc = g.cell_rect(0, 1)
    dr = g.cell_rect(1, 0)
    col_step = (dc.x - o.x, dc.y - o.y)
    row_step = (dr.x - o.x, dr.y - o.y)
    assert cross(col_step, row_step) > 0


def test_a1_travels_round_the_corners_clockwise():
    corners = []
    for turns in range(4):
        g = PlateGeometry.fit(WELL96, CANVAS, turns)
        r = g.cell_rect(0, 0)
        grid = g.grid_rect
        left = abs(r.x - grid.x) < 1e-6
        top = abs(r.y - grid.y) < 1e-6
        corners.append((top, left))
    assert corners == [(True, True), (True, False), (False, False), (False, True)]


def test_four_turns_is_the_identity_and_the_pair_are_inverses():
    for turns in range(-4, 9):
        g = PlateGeometry.fit(WELL384, CANVAS, turns)
        assert g.quarter_turns == turns % 4
        for row in range(0, 16, 3):
            for col in range(0, 24, 5):
                d = g.display_position(row, col)
                assert g.model_position(*d) == WellPos(row, col)


def test_display_dimensions_swap_on_odd_turns_and_a_tall_plate_is_drawn_wide():
    g = PlateGeometry.fit(WELL96, CANVAS, 1)
    assert (g.display_rows, g.display_cols) == (12, 8) and g.is_turned_on_end
    tall = PlateFormat(8, 6)
    assert PlateGeometry.fit(tall, CANVAS, 1).grid_rect.width > PlateGeometry.fit(tall, CANVAS, 1).grid_rect.height


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
@pytest.mark.parametrize("fmt", [WELL6, WELL96, PlateFormat(5, 7), PlateFormat(1, 8)])
def test_every_well_gets_a_distinct_in_grid_cell_and_clicking_its_centre_hits_it(fmt, turns):
    g = PlateGeometry.fit(fmt, CANVAS, turns)
    seen = set()
    for row in range(fmt.rows):
        for col in range(fmt.cols):
            r = g.cell_rect(row, col)
            key = (round(r.x, 3), round(r.y, 3))
            assert key not in seen
            seen.add(key)
            assert g.grid_rect.contains(r.mid_x, r.mid_y)
            assert g.hit(r.mid_x, r.mid_y) == Hit.well_at(WellPos(row, col))
            assert g.nearest_well(r.mid_x, r.mid_y) == WellPos(row, col)


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_headers_name_the_model_axis_regardless_of_which_strip_they_sit_on(turns):
    g = PlateGeometry.fit(WELL96, CANVAS, turns)
    for col in range(12):
        r = g.column_header_rect(col)
        assert g.hit(r.mid_x, r.mid_y) == Hit.column_header(col)
    for row in range(8):
        r = g.row_header_rect(row)
        assert g.hit(r.mid_x, r.mid_y) == Hit.row_header(row)


def test_strips_sit_on_the_edge_their_axis_travelled_to():
    upright = PlateGeometry.fit(WELL96, CANVAS, 0)
    assert upright.row_header_rect(0).max_x <= upright.grid_rect.x + 1e-6          # letters left
    assert upright.column_header_rect(0).max_y <= upright.grid_rect.y + 1e-6       # numbers top
    turned = PlateGeometry.fit(WELL96, CANVAS, 1)
    assert turned.row_header_rect(0).max_y <= turned.grid_rect.y + 1e-6            # letters top
    assert turned.column_header_rect(0).x >= turned.grid_rect.max_x - 1e-6         # numbers right
    # A now sits on the right of the top strip: the letters run backwards.
    assert turned.row_header_rect(0).x > turned.row_header_rect(7).x


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_the_corner_travels_with_the_strips_and_never_overlaps_the_wells(turns):
    g = PlateGeometry.fit(WELL96, CANVAS, turns)
    c = g.corner_rect
    assert not c.intersects(g.grid_rect)
    assert g.hit(c.mid_x, c.mid_y) == Hit.corner()
    # It touches both strips.
    assert abs(c.x - g.row_header_rect(0).x) < 1e-6 or abs(c.y - g.row_header_rect(0).y) < 1e-6


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_off_plate_drags_clamp_to_a_real_corner(turns):
    g = PlateGeometry.fit(WELL96, CANVAS, turns)
    far = g.nearest_well(1e6, 1e6)
    near = g.nearest_well(-1e6, -1e6)
    for pos in (far, near):
        assert WELL96.contains(pos.row, pos.col)
    assert g.hit(-50, -50) == Hit.outside()


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_a_selection_rectangle_covers_the_same_wells_at_every_turn(turns):
    g = PlateGeometry.fit(WELL96, CANVAS, turns)
    rng = WellRange(WellPos(1, 2), WellPos(3, 5))
    box = g.rect_of(rng)
    for row in range(8):
        for col in range(12):
            r = g.cell_rect(row, col)
            inside = box.contains(r.mid_x, r.mid_y)
            assert inside == rng.contains(row, col)
