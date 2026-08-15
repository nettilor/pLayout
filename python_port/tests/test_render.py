"""The renderer — ports of the render halves of RenderPreviewTests / OverviewRenderTests /
MultiFactorRenderTests. Pixels are sampled on fills only, never on text."""
from dataclasses import replace

import pytest
from PySide6.QtGui import QColor, QImage, QPainter

from playout.editor.well_range import WellPos, WellRange
from playout.model.layout import Factor, Layout, Level, Plate, PlateOrientation, WellLabelMode
from playout.model.plate_format import STANDARD, WELL96, PlateFormat
from playout.ui.plate_geometry import Rect
from playout.ui.plate_renderer import Colors, RenderScene, label_plan, render_scene
from tests.ui_helpers import make_editor

W, H = 940, 560
BOUNDS = Rect(0, 0, W, H)


@pytest.fixture(autouse=True)
def _needs_a_gui_application(qapp):
    """Fonts and text drawing need a QGuiApplication; the offscreen one is fine."""


def paint_image(scene, bounds=BOUNDS):
    img = QImage(int(bounds.width), int(bounds.height), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(QColor(255, 255, 255))
    p = QPainter(img)
    geo = render_scene(scene, p, bounds)
    p.end()
    return img, geo


def sample(img, x, y):
    c = img.pixelColor(int(x), int(y))
    return (c.red(), c.green(), c.blue())


def four_factor_layout(fmt=WELL96):
    factors = tuple(
        Factor(name=n, levels=(Level(f"{n} a", h1), Level(f"{n} b", h2)))
        for n, h1, h2 in (("Cell line", "#5889BC", "#F28E2B"), ("Drug", "#59A14F", "#E15759"),
                          ("Dose", "#B07AA1", "#76B7B2"), ("Time", "#EDC948", "#928785"))
    )
    plate = Plate(name="P", format=fmt)
    for f in factors:
        plate = plate.set_level_ids(f.id, {w: f.levels[w % 2].id for w in range(0, fmt.well_count, 3)})
    return Layout(factors=factors, plates=(plate,))


def scene_for(tmp_path, layout, mode, export=False, **overrides):
    editor = make_editor(tmp_path, replace(layout, well_label_mode=mode))
    scene = RenderScene.from_editor(editor, Colors.light(), export_mode=export)
    for k, v in overrides.items():
        setattr(scene, k, v)
    return editor, scene


@pytest.mark.parametrize("mode", list(WellLabelMode))
@pytest.mark.parametrize("fmt", list(STANDARD) + [PlateFormat(1, 1), PlateFormat(64, 96), PlateFormat(5, 7)])
def test_every_mode_and_format_renders_inside_its_bounds(tmp_path, mode, fmt):
    _, scene = scene_for(tmp_path, four_factor_layout(fmt), mode)
    _, geo = paint_image(scene)
    frame = geo.frame_rect
    assert frame.x >= 0 and frame.y >= 0 and frame.max_x <= W + 1e-6 and frame.max_y <= H + 1e-6


@pytest.mark.parametrize("mode", list(WellLabelMode))
def test_a_turned_plate_renders_in_every_mode(tmp_path, mode):
    layout = replace(four_factor_layout(), orientation=PlateOrientation.turned)
    _, scene = scene_for(tmp_path, layout, mode)
    paint_image(scene)


def test_render_at_tiny_and_huge_canvases_does_not_raise(tmp_path):
    _, scene = scene_for(tmp_path, four_factor_layout(), WellLabelMode.allFactors)
    paint_image(scene, Rect(0, 0, 4, 4))
    paint_image(scene, Rect(0, 0, 3000, 1800))


def test_an_empty_well_takes_the_custom_background_pixel_identically(tmp_path):
    layout = four_factor_layout()
    editor, scene = scene_for(tmp_path, layout, WellLabelMode.none, export=True)
    editor.preferences.empty_well_color_hex = "#3A5F0B"
    f = layout.factors[0]
    green = Level("g", "#3A5F0B")
    editor.document.mutate("x", lambda l: l.with_factor(0, replace(f, levels=f.levels + (green,))).with_plate(
        0, l.plates[0].set_level_id(green.id, f.id, WELL96.index(0, 1))))
    editor.set_active_factor(f.id)
    scene = RenderScene.from_editor(editor, Colors.light(), export_mode=True)
    img, geo = paint_image(scene)
    empty = geo.cell_rect(0, 2)          # well 2 is empty
    painted = geo.cell_rect(0, 1)        # painted with the same hex
    y_off = geo.cell * 0.30
    assert sample(img, empty.mid_x, empty.mid_y - y_off) == sample(img, painted.mid_x, painted.mid_y - y_off)
    editor.preferences.empty_well_color_hex = None
    img2, _ = paint_image(RenderScene.from_editor(editor, Colors.light(), export_mode=True))
    assert sample(img2, empty.mid_x, empty.mid_y - y_off) != sample(img, empty.mid_x, empty.mid_y - y_off)


def test_overview_tiles_take_the_custom_background_too(tmp_path):
    layout = four_factor_layout()
    editor, _ = scene_for(tmp_path, layout, WellLabelMode.overview, export=True)
    editor.preferences.empty_well_color_hex = "#3A5F0B"
    scene = RenderScene.from_editor(editor, Colors.light(), export_mode=True)
    img, geo = paint_image(scene)
    r = geo.cell_rect(0, 2)
    # just inside the body's top-left corner: above the centred stack, left of the rails
    assert sample(img, r.x + 4, r.y + 4) == (0x3A, 0x5F, 0x0B)


def test_spotlight_dims_every_well_except_the_spotlit_condition(tmp_path):
    layout = four_factor_layout()
    editor, _ = scene_for(tmp_path, layout, WellLabelMode.none)
    f = layout.factors[0]
    editor.set_active_factor(f.id)
    plain = RenderScene.from_editor(editor, Colors.light())
    plain.selection = None
    img_plain, geo = paint_image(plain)
    lit = RenderScene.from_editor(editor, Colors.light())
    lit.selection = None
    lit.spotlight_level_id = f.levels[0].id
    img_lit, _ = paint_image(lit)
    a = geo.cell_rect(0, 0)   # well 0 → level a (spotlit)
    b = geo.cell_rect(0, 3)   # well 3 → level b
    assert sample(img_lit, a.mid_x, a.mid_y) == sample(img_plain, a.mid_x, a.mid_y)
    assert sample(img_lit, b.mid_x, b.mid_y) != sample(img_plain, b.mid_x, b.mid_y)


def test_export_ignores_selection_hover_and_spotlight(tmp_path):
    layout = four_factor_layout()
    editor, _ = scene_for(tmp_path, layout, WellLabelMode.activeFactor)
    base = RenderScene.from_editor(editor, Colors.light(), export_mode=True)
    img_a, _ = paint_image(base)
    busy = RenderScene.from_editor(editor, Colors.light(), export_mode=True)
    busy.selection = WellRange(WellPos(0, 0), WellPos(3, 3))
    busy.hovered = WellPos(2, 2)
    busy.spotlight_level_id = layout.factors[0].levels[0].id
    img_b, _ = paint_image(busy)
    assert img_a == img_b


def test_overview_never_colours_a_well_by_the_active_factor(tmp_path):
    layout = four_factor_layout()
    editor, _ = scene_for(tmp_path, layout, WellLabelMode.overview, export=True)
    scene = RenderScene.from_editor(editor, Colors.light(), export_mode=True)
    scene.active_factor_id = layout.factors[0].id   # even if a stale id sneaks in
    img, geo = paint_image(scene)
    r0 = geo.cell_rect(0, 0)
    r2 = geo.cell_rect(0, 2)
    assert sample(img, r0.x + 4, r0.y + 4) == sample(img, r2.x + 4, r2.y + 4)


# ---------------------------------------------------------------- label plan (LabelPlanTests)


def test_only_stacking_modes_stack_and_a_single_factor_never_stacks():
    assert label_plan(60, WellLabelMode.activeFactor, 4).line_count == 0
    assert label_plan(60, WellLabelMode.none, 4).line_count == 0
    assert label_plan(60, WellLabelMode.allFactors, 1).line_count == 0
    assert label_plan(60, WellLabelMode.allFactors, 4).line_count >= 2


def test_line_count_is_monotone_non_decreasing_in_cell_size_and_fits_the_body():
    from playout.ui.plate_renderer import body_inset

    for mode in (WellLabelMode.allFactors, WellLabelMode.overview):
        last = 0
        cell = 8.0
        while cell <= 100:
            plan = label_plan(cell, mode, 6)
            assert plan.line_count >= last
            if plan.line_count:
                assert plan.stack_height(plan.line_count) <= cell - 2 * body_inset(cell) + 1e-9
            last = plan.line_count
            cell += 0.5


def test_overview_never_shows_fewer_lines_than_all_factors_and_is_uniform():
    for cell in (20, 31.644, 47, 61, 62.25, 96):
        allp = label_plan(cell, WellLabelMode.allFactors, 5)
        over = label_plan(cell, WellLabelMode.overview, 5)
        assert over.line_count >= allp.line_count
        assert over.uniform and over.primary_size == over.secondary_size


def test_pinned_line_counts_at_the_reference_canvas():
    assert label_plan(16.0625, WellLabelMode.allFactors, 3).line_count == 0   # 1536: one label
    assert label_plan(62.25, WellLabelMode.allFactors, 3).line_count == 3     # 96: stacks 3
    assert label_plan(62.25, WellLabelMode.allFactors, 2).line_count == 2
