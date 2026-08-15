"""Plate tab bar — mirrors the editor, click activates (selection to A1), rename, menu."""
import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest

from playout.editor.well_range import WellPos, WellRange
from playout.ui.plate_tabs import PlateTabBar
from tests.ui_helpers import make_editor


@pytest.fixture
def setup(qtbot, tmp_path):
    editor = make_editor(tmp_path)
    bar = PlateTabBar(editor)
    qtbot.addWidget(bar)
    bar.resize(800, 34)
    bar.show()
    qtbot.waitExposed(bar)
    return editor, bar


def test_tabs_mirror_the_plates_and_click_activates_with_a1_selected(setup):
    editor, bar = setup
    assert bar.tabs.count() == 1 and bar.tabs.tabText(0) == "Plate 1  ·  96-well"
    editor.add_plate()
    assert bar.tabs.count() == 2 and bar.tabs.currentIndex() == 1
    editor.select(WellRange(WellPos(2, 2), WellPos(3, 3)))
    bar.tabs.tabBarClicked.emit(0)
    assert editor.plate.name == "Plate 1" and editor.selection == WellRange.at(0, 0)
    assert bar.tabs.currentIndex() == 0


def test_add_button_adds_a_plate(setup):
    editor, bar = setup
    bar.add_button.click()
    assert len(editor.layout.plates) == 2 and editor.plate.name == "Plate"


def test_rename_inline_commits_and_escape_cancels(setup, qtbot):
    editor, bar = setup
    bar.begin_rename(0)
    edit = bar._rename_edit
    assert edit is not None and edit.text() == "Plate 1"
    edit.setText("Screen A")
    QTest.keyClick(edit, Qt.Key.Key_Return)
    assert editor.plate.name == "Screen A" and bar._rename_edit is None
    qtbot.wait(10)
    assert bar.tabs.tabText(0).startswith("Screen A")
    bar.begin_rename(0)
    bar._rename_edit.setText("Nope")
    QTest.keyClick(bar._rename_edit, Qt.Key.Key_Escape)
    assert editor.plate.name == "Screen A"


def test_context_menu_items(setup):
    editor, bar = setup
    menu = bar.menu_for(0)
    texts = [a.text() for a in menu.actions() if a.text()]
    assert texts == ["Rename Plate", "Duplicate Plate", "Plate Note…", "Delete Plate"]
    assert not menu.actions()[-1].isEnabled()
    editor.add_plate()
    assert bar.menu_for(0).actions()[-1].isEnabled()
    [a for a in bar.menu_for(0).actions() if a.text() == "Duplicate Plate"][0].trigger()
    assert [p.name for p in editor.layout.plates] == ["Plate 1", "Plate", "Plate 1 copy"]
