"""Sidebar rows — click arms, Ctrl-click multi-selects, second click renames, hover
spotlights, reorder maps to the pre-move index rule, display controls drive the editor."""
import pytest
from PySide6.QtCore import QPoint, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from playout.model.layout import FactorKind, WellLabelMode
from playout.ui.sidebar import Sidebar, reorder_target
from playout.ui.status_bar import StatusRow
from tests.ui_helpers import CTRL, click, make_editor


@pytest.fixture
def setup(qtbot, tmp_path):
    editor = make_editor(tmp_path)
    bar = Sidebar(editor)
    qtbot.addWidget(bar)
    bar.resize(260, 700)
    bar.show()
    qtbot.waitExposed(bar)
    return editor, bar


def settle(qtbot):
    qtbot.wait(30)  # let the deferred refresh run


def row_centre(lst, index):
    r = lst.visualItemRect(lst.item(index))
    return (r.center().x(), r.center().y())


def test_rows_mirror_the_editor(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    assert bar.factor_list.count() == 1 and bar.level_list.count() == 3
    assert [bar.level_list.rows[i].name.label.text() for i in bar.level_list.ids()] == ["Untreated", "Vehicle", "Treated"]
    assert bar.level_list.currentRow() == 0
    editor.add_factor()
    settle(qtbot)
    assert bar.factor_list.count() == 2 and bar.factor_list.currentRow() == 1
    assert bar.conditions_header.text() == "Factor"


def test_click_arms_and_asks_for_canvas_focus(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    focus = []
    editor.focus_canvas_requested.connect(lambda: focus.append(1))
    click(bar.level_list.viewport(), row_centre(bar.level_list, 2))
    assert editor.armed_level.name == "Treated" and focus


def test_ctrl_click_multi_selects_without_arming(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    click(bar.level_list.viewport(), row_centre(bar.level_list, 2), mods=CTRL)
    assert editor.is_multi_selecting and editor.armed_level_id is None
    settle(qtbot)
    assert bar.level_list.rows[editor.active_factor.levels[2].id].cap._highlighted


def test_double_click_renames_enter_commits_escape_abandons(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    lst = bar.level_list
    x, y = row_centre(lst, 1)
    QTest.mouseDClick(lst.viewport(), Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier, QPoint(int(x), int(y)))
    row = lst.rows[editor.active_factor.levels[1].id]
    assert row.name.is_renaming
    row.name.edit.setText("  Control  ")
    QTest.keyClick(row.name.edit, Qt.Key.Key_Return)
    assert not row.name.is_renaming
    assert editor.active_factor.levels[1].name == "Control"
    assert editor.document.undo_stack.undoText() == "Rename Level"
    settle(qtbot)
    row = lst.rows[editor.active_factor.levels[1].id]
    row.name.begin_rename()
    row.name.edit.setText("Nope")
    QTest.keyClick(row.name.edit, Qt.Key.Key_Escape)
    assert not row.name.is_renaming and editor.active_factor.levels[1].name == "Control"


def test_refresh_waits_while_a_rename_is_open(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    row = bar.factor_list.rows[editor.active_factor.id]
    row.name.begin_rename()
    editor.add_factor()      # would rebuild the list
    settle(qtbot)
    assert row.name.is_renaming            # widget survived
    row.name.cancel()
    qtbot.wait(250)
    assert bar.factor_list.count() == 2


def test_reorder_target_uses_pre_move_indices():
    assert reorder_target(["a", "b", "c"], ["b", "a", "c"], "a") == (0, 2)   # moved down: target + 1
    assert reorder_target(["a", "b", "c"], ["c", "a", "b"], "c") == (2, 0)   # moved up
    assert reorder_target(["a", "b", "c"], ["a", "b", "c"], "b") is None
    assert reorder_target(["a"], ["a"], "zzz") is None


def test_hover_spotlights_and_leaving_clears(setup, qtbot):
    from PySide6.QtCore import QEvent, QPointF
    from PySide6.QtGui import QEnterEvent

    editor, bar = setup
    settle(qtbot)
    row = bar.level_list.rows[editor.active_factor.levels[1].id]
    p = QPointF(5, 5)
    QApplication.sendEvent(row, QEnterEvent(p, p, QPointF(row.mapToGlobal(p.toPoint()))))
    assert editor.spotlight_level_id == editor.active_factor.levels[1].id
    QApplication.sendEvent(row, QEvent(QEvent.Type.Leave))
    assert editor.spotlight_level_id is None


def test_context_menus_offer_the_right_items(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    fid = editor.active_factor.id
    menu = bar.factor_list.menu_for(fid)
    texts = [a.text() for a in menu.actions() if a.text()]
    assert texts[0] == "Treat as Numeric" and texts[-1] == "Delete Factor"
    assert not [a for a in menu.actions() if a.text() == "Delete Factor"][0].isEnabled()
    editor.set_factor_kind(fid, FactorKind.numeric)
    assert bar.factor_list.menu_for(fid).actions()[0].text() == "Treat as Categorical"
    lid = editor.active_factor.levels[0].id
    lmenu = bar.level_list.menu_for(lid)
    assert [a.text() for a in lmenu.actions() if a.text()][0] == "Fill Selection with Untreated"
    editor.toggle_level_in_multi_selection(editor.active_factor.levels[1].id)
    assert bar.level_list.menu_for(lid).actions()[0].text() == "Delete 2 Conditions"


def test_display_controls_drive_the_editor_and_follow_it(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    bar.mode_buttons[WellLabelMode.overview].click()
    assert editor.is_overview
    settle(qtbot)
    assert bar.overview_note.isVisible() and not bar.level_list.isVisible()
    assert not bar.show_secondary.isVisible()
    bar.mode_buttons[WellLabelMode.activeFactor].click()
    settle(qtbot)
    assert bar.show_secondary.isVisible() and not bar.show_secondary.isEnabled()  # <2 factors
    bar.round_wells.setChecked(False)
    assert editor.round_wells is False
    bar.pad_labels.setChecked(True)
    assert editor.layout.pad_well_labels is True
    editor.set_well_label_mode(WellLabelMode.allFactors)
    settle(qtbot)
    assert bar.mode_buttons[WellLabelMode.allFactors].isChecked()
    assert bar.mode_hint.text() == "Add a second factor to see stacked labels."


def test_unit_row_shows_for_numeric_and_commits(setup, qtbot):
    editor, bar = setup
    settle(qtbot)
    assert not bar.unit_container.isVisible()
    editor.set_factor_kind(editor.active_factor.id, FactorKind.numeric)
    settle(qtbot)
    assert bar.unit_container.isVisible()
    bar.unit_edit.setText("µM")
    bar.unit_edit.editingFinished.emit()
    assert editor.active_factor.unit == "µM"


def test_status_row_texts(qtbot, tmp_path):
    editor = make_editor(tmp_path)
    row = StatusRow(editor)
    qtbot.addWidget(row)
    row.resize(900, 26)
    row.show()
    assert row.armed.text() == "Condition: Untreated"
    assert row.selection.text() == "A1"
    from playout.editor.well_range import WellPos, WellRange

    editor.select(WellRange(WellPos(0, 0), WellPos(3, 5)))
    assert row.selection.text() == "A1:D6  ·  4×6 = 24"
    editor.toggle_well(WellPos(7, 7))
    assert row.selection.text() == "25 wells selected"
    editor.clear_selection_marquee()
    assert row.selection.text() == "No selection"
    editor.flash("hello")
    assert row.flash.text() == "hello"
    editor.set_well_label_mode(WellLabelMode.overview)
    assert row.armed.text() == "Overview — click a factor to start painting"
    assert not row.zoom_button.isVisible()
    editor.note_zoom_changed(2.0)
    assert row.zoom_button.text() == "200%"
