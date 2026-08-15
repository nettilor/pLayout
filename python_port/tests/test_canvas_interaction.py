"""Canvas mouse/keyboard/zoom — ports of PaintingInteractionTests, SelectionInteractionTests
and the ZoomTests intent, driven with synthetic QMouseEvents / QTest key clicks."""
import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest

from playout.editor.well_range import WellPos, WellRange
from playout.model.plate_format import WELL96
from playout.ui.plate_canvas import PlateScrollArea
from tests.ui_helpers import (
    ALT, CTRL, SHIFT, cell_centre, click, column_header_centre, corner_centre, drag, hover,
    make_editor, outside_point, press, release, row_header_centre,
)


@pytest.fixture
def setup(qtbot, tmp_path):
    editor = make_editor(tmp_path)
    area = PlateScrollArea(editor)
    qtbot.addWidget(area)
    area.resize(940, 560)
    area.show()
    qtbot.waitExposed(area)
    return editor, area, area.canvas


def level_at(editor, row, col):
    return editor.plate.level_id(editor.active_factor.id, WELL96.index(row, col))


def painted(editor):
    return {w for w in range(96) if editor.plate.level_id(editor.active_factor.id, w) is not None}


def rect(r0, c0, r1, c1):
    return WellRange(WellPos(r0, c0), WellPos(r1, c1))


# ---------------------------------------------------------------- painting


def test_drag_paints_the_rectangle_it_covers_and_nothing_outside(setup):
    editor, area, canvas = setup
    drag(canvas, cell_centre(canvas, 1, 1), cell_centre(canvas, 2, 3))
    assert painted(editor) == {WELL96.index(r, c) for r in (1, 2) for c in (1, 2, 3)}
    assert editor.selection == rect(1, 1, 2, 3)
    assert editor.document.undo_stack.undoText() == "Paint Wells" and editor.document.undo_stack.count() == 1


def test_up_and_left_drags_work(setup):
    editor, area, canvas = setup
    drag(canvas, cell_centre(canvas, 3, 4), cell_centre(canvas, 1, 2))
    assert painted(editor) == {WELL96.index(r, c) for r in (1, 2, 3) for c in (2, 3, 4)}


def test_disarmed_drag_selects_but_does_not_paint(setup):
    editor, area, canvas = setup
    editor.disarm_level()
    drag(canvas, cell_centre(canvas, 0, 0), cell_centre(canvas, 1, 1))
    assert painted(editor) == set() and editor.selection == rect(0, 0, 1, 1)


def test_column_and_row_header_click_selects_and_paints_the_whole_line(setup):
    editor, area, canvas = setup
    click(canvas, column_header_centre(canvas, 3))
    assert painted(editor) == {WELL96.index(r, 3) for r in range(8)}
    assert editor.selection == rect(0, 3, 7, 3)
    click(canvas, row_header_centre(canvas, 2))
    assert {WELL96.index(2, c) for c in range(12)} <= painted(editor)


def test_corner_click_turns_the_plate_and_paints_nothing(setup):
    editor, area, canvas = setup
    click(canvas, corner_centre(canvas))
    assert editor.is_turned and painted(editor) == set()
    click(canvas, corner_centre(canvas))    # re-read: the corner moved
    assert not editor.is_turned


def test_alt_drag_erases_only_what_it_covers(setup):
    editor, area, canvas = setup
    drag(canvas, cell_centre(canvas, 0, 0), cell_centre(canvas, 2, 2))
    drag(canvas, cell_centre(canvas, 0, 0), cell_centre(canvas, 0, 2), mods=ALT)
    assert painted(editor) == {WELL96.index(r, c) for r in (1, 2) for c in (0, 1, 2)}
    assert editor.document.undo_stack.undoText() == "Erase Wells"


def test_shift_click_extends_from_the_anchor(setup):
    editor, area, canvas = setup
    click(canvas, cell_centre(canvas, 1, 1))
    click(canvas, cell_centre(canvas, 3, 4), mods=SHIFT)
    assert editor.selection == rect(1, 1, 3, 4)


def test_dragging_beyond_the_plate_clamps_to_the_last_row_and_column(setup):
    editor, area, canvas = setup
    drag(canvas, cell_centre(canvas, 6, 10), (canvas.width() - 1, canvas.height() - 1))
    assert editor.selection == rect(6, 10, 7, 11)


def test_a_click_off_the_plate_deselects_and_paints_nothing_even_armed(setup):
    editor, area, canvas = setup
    click(canvas, outside_point(canvas))
    assert editor.selection is None and painted(editor) == set()
    drag(canvas, outside_point(canvas), cell_centre(canvas, 2, 2))
    assert painted(editor) == set()


def test_hover_tracks_the_well_and_clears_outside(setup):
    editor, area, canvas = setup
    hover(canvas, cell_centre(canvas, 1, 6))
    assert editor.hovered == WellPos(1, 6) and editor.summary(1, 6).startswith("B7")
    hover(canvas, outside_point(canvas))
    assert editor.hovered is None


def test_double_click_acts_as_a_second_press(setup, qtbot):
    editor, area, canvas = setup
    x, y = cell_centre(canvas, 2, 2)
    QTest.mouseDClick(canvas, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier, canvas.rect().topLeft().__class__(int(x), int(y)))
    assert editor.selection == rect(2, 2, 2, 2)


# ---------------------------------------------------------------- discontiguous selection


def test_ctrl_click_adds_a_well_and_never_paints_even_armed(setup):
    editor, area, canvas = setup
    click(canvas, cell_centre(canvas, 2, 2), mods=CTRL)
    assert editor.custom_wells == {WellPos(0, 0), WellPos(2, 2)} and painted(editor) == set()
    click(canvas, cell_centre(canvas, 2, 2), mods=CTRL)
    assert editor.custom_wells == {WellPos(0, 0)}
    click(canvas, cell_centre(canvas, 0, 0), mods=CTRL)
    assert editor.custom_wells is None and not editor.has_selection


def test_armed_ctrl_drag_is_the_freehand_brush(setup):
    editor, area, canvas = setup
    click(canvas, outside_point(canvas))
    drag(canvas, cell_centre(canvas, 0, 0), cell_centre(canvas, 0, 3), mods=CTRL,
         via=[cell_centre(canvas, 0, 1), cell_centre(canvas, 0, 2)])
    assert painted(editor) == {0, 1, 2, 3}
    assert editor.custom_wells is None      # the brush leaves the rectangular model alone
    assert editor.document.undo_stack.count() == 1


def test_freehand_brush_paints_only_the_visited_path_not_the_bounding_box(setup):
    editor, area, canvas = setup
    click(canvas, outside_point(canvas))
    drag(canvas, cell_centre(canvas, 0, 0), cell_centre(canvas, 2, 2), mods=CTRL, via=[cell_centre(canvas, 1, 1)])
    assert painted(editor) == {WELL96.index(0, 0), WELL96.index(1, 1), WELL96.index(2, 2)}


def test_disarmed_ctrl_drag_adds_a_rectangle_to_the_custom_set(setup):
    editor, area, canvas = setup
    editor.disarm_level()
    click(canvas, cell_centre(canvas, 5, 5), mods=CTRL)          # {A1, F6}
    drag(canvas, cell_centre(canvas, 0, 2), cell_centre(canvas, 1, 3), mods=CTRL,
         via=[cell_centre(canvas, 0, 3)])
    assert editor.custom_wells == {WellPos(0, 0), WellPos(5, 5), WellPos(0, 2), WellPos(0, 3), WellPos(1, 2), WellPos(1, 3)}
    assert painted(editor) == set()


def test_a_plain_click_returns_to_the_rectangular_model(setup):
    editor, area, canvas = setup
    click(canvas, cell_centre(canvas, 2, 2), mods=CTRL)
    click(canvas, cell_centre(canvas, 4, 4))
    assert editor.custom_wells is None and editor.selection == rect(4, 4, 4, 4)


def test_shift_click_extends_from_the_last_toggled_well(setup):
    editor, area, canvas = setup
    click(canvas, cell_centre(canvas, 2, 2), mods=CTRL)
    click(canvas, cell_centre(canvas, 4, 5), mods=SHIFT)
    assert editor.selection == rect(2, 2, 4, 5) and editor.custom_wells is None


def test_fill_paints_a_discontiguous_selection_and_copy_refuses_it(setup):
    editor, area, canvas = setup
    seen = []
    editor.flash_message.connect(seen.append)
    click(canvas, cell_centre(canvas, 0, 3), mods=CTRL)
    QTest.keyClick(canvas, Qt.Key.Key_Space)
    assert painted(editor) == {0, 3}
    editor.copy_selection()
    assert seen[-1] == "Copy needs a rectangular selection."


# ---------------------------------------------------------------- keys


def test_number_keys_arm_space_fills_backspace_clears(setup):
    editor, area, canvas = setup
    canvas.setFocus()
    QTest.keyClick(canvas, Qt.Key.Key_2)
    assert editor.armed_level.name == "Vehicle"
    QTest.keyClick(canvas, Qt.Key.Key_Space)
    assert level_at(editor, 0, 0) == editor.armed_level_id
    QTest.keyClick(canvas, Qt.Key.Key_Backspace)
    assert level_at(editor, 0, 0) is None
    QTest.keyClick(canvas, Qt.Key.Key_F)
    assert level_at(editor, 0, 0) is not None
    QTest.keyClick(canvas, Qt.Key.Key_Backspace, Qt.KeyboardModifier.ShiftModifier)
    assert editor.plate.assignments == {}


def test_bracket_keys_cycle_escape_disarms_arrows_move_tab_cycles_factor(setup):
    editor, area, canvas = setup
    canvas.setFocus()
    QTest.keyClick(canvas, Qt.Key.Key_BracketRight)
    assert editor.armed_level.name == "Vehicle"
    QTest.keyClick(canvas, Qt.Key.Key_BracketLeft)
    assert editor.armed_level.name == "Untreated"
    QTest.keyClick(canvas, Qt.Key.Key_Escape)
    assert editor.armed_level_id is None
    QTest.keyClick(canvas, Qt.Key.Key_Right)
    QTest.keyClick(canvas, Qt.Key.Key_Down, Qt.KeyboardModifier.ShiftModifier)
    assert editor.selection == rect(0, 1, 1, 1)
    editor.add_factor()
    QTest.keyClick(canvas, Qt.Key.Key_Tab)
    assert editor.active_factor.name == "Condition"
    QTest.keyClick(canvas, Qt.Key.Key_Backtab, Qt.KeyboardModifier.ShiftModifier)
    assert editor.active_factor.name == "Factor"


def test_arrow_with_no_selection_restarts_at_a1(setup):
    editor, area, canvas = setup
    click(canvas, outside_point(canvas))
    QTest.keyClick(canvas, Qt.Key.Key_Down)
    assert editor.selection == rect(0, 0, 0, 0)


def test_ctrl_keys_are_left_to_the_menu(setup):
    editor, area, canvas = setup
    canvas.setFocus()
    QTest.keyClick(canvas, Qt.Key.Key_2, Qt.KeyboardModifier.ControlModifier)
    assert editor.armed_level.name == "Untreated"      # not armed by the canvas


# ---------------------------------------------------------------- zoom


def test_zoom_magnifies_rather_than_refitting_and_never_goes_below_fit(setup):
    editor, area, canvas = setup
    vp = area.viewport().size()
    assert canvas.size() == vp and editor.zoom_level == 1.0
    cell_before = canvas.plate_geometry().cell
    area.set_zoom(1.4)
    assert abs(canvas.width() - vp.width() * 1.4) <= 1 and abs(canvas.height() - vp.height() * 1.4) <= 1
    assert canvas.plate_geometry().cell == pytest.approx(cell_before, abs=1e-6)   # same layout, magnified
    assert editor.zoom_level == pytest.approx(1.4) and editor.can_zoom_out
    area.set_zoom(0.3)
    assert area.zoom == 1.0 and canvas.size() == vp
    area.set_zoom(99)
    assert area.zoom == 10.0
    editor.zoom_to_fit()
    assert area.zoom == 1.0 and not editor.can_zoom_out


def test_clicks_still_hit_the_same_well_when_zoomed(setup):
    editor, area, canvas = setup
    area.set_zoom(2.0)
    click(canvas, cell_centre(canvas, 3, 4))
    assert editor.selection == rect(3, 4, 3, 4)


def test_resizing_while_zoomed_keeps_the_canvas_at_viewport_times_zoom(setup, qtbot):
    editor, area, canvas = setup
    area.set_zoom(2.0)
    area.resize(600, 400)
    qtbot.wait(20)
    vp = area.viewport().size()
    assert abs(canvas.width() - vp.width() * 2) <= 1 and abs(canvas.height() - vp.height() * 2) <= 1
