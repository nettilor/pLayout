"""DocumentWindow + App, headless: menu actions drive the editor, the Factor submenu
rebuilds, titles follow the dirty state, save/open, close, recent files — and the real
user settings are never touched."""
import json
from pathlib import Path

import pytest
from PySide6.QtCore import QSettings

from playout.model.layout import Layout, WellLabelMode, loads
from playout.model.plate_format import PlateFormat
from playout.ui.sheets.custom_format import CustomFormatDialog
from tests.ui_helpers import make_app


@pytest.fixture
def app_and_window(qtbot, tmp_path):
    app = make_app(tmp_path)
    window = app.new_document(show=False)
    yield app, window
    # A dirty untitled window would ask "Save changes?" (modal) on close — mark every
    # document clean first; the prompt itself is exercised elsewhere.
    for w in list(app.windows):
        w.document.undo_stack.setClean()
        w.close()


def act(window, text):
    window.actions_by_text[text].trigger()


def test_menu_actions_drive_the_editor(app_and_window):
    app, w = app_and_window
    ed = w.editor
    act(w, "Add Plate")
    assert len(ed.layout.plates) == 2
    act(w, "Overview")
    assert ed.is_overview and w.overview_action.isChecked()
    act(w, "Overview")
    assert not ed.is_overview and not w.overview_action.isChecked()
    act(w, "Turn Plate 90°")
    assert ed.is_turned and w.turn_action.isChecked()
    act(w, "Add Condition")
    assert ed.armed_level.name == "Condition 4"
    act(w, "Select All Wells")
    act(w, "Fill Selection")
    assert len(ed.plate.assignments[ed.active_factor.id]) == 96
    act(w, "Copy")
    assert "Condition 4" in ed.clipboard.text()
    act(w, "Undo")
    assert ed.plate.assignments == {}
    act(w, "Redo")
    assert ed.plate.assignments != {}
    w.actions_by_text["Text in Wells: All factors"].trigger()
    assert ed.layout.well_label_mode is WellLabelMode.allFactors
    assert w.mode_actions[WellLabelMode.allFactors].isChecked()
    act(w, "Save State")
    assert ed.current_design_is_saved


def test_factor_submenu_rebuilds_with_ctrl_numbers(app_and_window):
    app, w = app_and_window
    ed = w.editor
    items = [a for a in w.factor_menu.actions() if a.isCheckable()]
    assert [a.text() for a in items] == ["Condition"] and items[0].shortcut().toString() == "Ctrl+1"
    act(w, "Add Condition")  # no change to factors
    ed.add_factor()
    items = [a for a in w.factor_menu.actions() if a.isCheckable()]
    assert [a.text() for a in items] == ["Condition", "Factor"]
    assert [a.shortcut().toString() for a in items] == ["Ctrl+1", "Ctrl+2"]
    assert items[1].isChecked() and not items[0].isChecked()
    ed.move_factors([1], 0)
    items = [a for a in w.factor_menu.actions() if a.isCheckable()]
    assert [a.text() for a in items] == ["Factor", "Condition"]
    items[1].trigger()
    assert ed.active_factor.name == "Condition"


def test_preferences_opens_the_apps_single_settings_window_and_nothing_is_disabled(app_and_window):
    app, w = app_and_window
    act(w, "Preferences…")
    dlg = app._preferences_dialog
    assert dlg.isVisible() and dlg.windowTitle() == "Settings"
    act(w, "Preferences…")
    assert app._preferences_dialog is dlg          # one instance, re-shown
    dlg.close()
    assert all(a.isEnabled() for t, a in w.actions_by_text.items() if t not in ("Undo", "Redo"))  # Qt greys Undo/Redo when empty


def test_title_follows_the_dirty_state_and_save(app_and_window, tmp_path):
    app, w = app_and_window
    assert w.windowTitle() == "Untitled"
    act(w, "Add Plate")
    assert w.windowTitle() == "Untitled — Edited"
    target = tmp_path / "a.plate"
    assert w.document.save(target)
    assert w.windowTitle() == "a"
    act(w, "Add Plate")
    assert w.windowTitle() == "a — Edited"
    assert app.recent_paths() == [] or str(target) in app.recent_paths()
    app.remember_recent(target)
    assert app.recent_paths()[0] == str(target)


def test_open_path_replaces_a_lone_clean_untitled_window(app_and_window, tmp_path, fixtures_dir):
    app, w = app_and_window
    src = fixtures_dir / "allfactors.plate"
    copy = tmp_path / "copy.plate"
    copy.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
    w2 = app.open_path(copy, show=False)
    assert w2 is not None and w2.windowTitle() == "copy"
    assert w2.editor.layout == loads(src.read_text(encoding="utf-8"))
    assert app.recent_paths()[0] == str(copy)
    again = app.open_path(copy, show=False)
    assert again is w2                                   # already open → same window


def test_open_of_a_bad_file_warns_and_returns_none(app_and_window, tmp_path, monkeypatch):
    app, w = app_and_window
    from PySide6.QtWidgets import QMessageBox

    warned = []
    monkeypatch.setattr(QMessageBox, "warning", lambda *a, **k: warned.append(a))
    bad = tmp_path / "bad.plate"
    bad.write_text('{"orientation": "sideways"}', encoding="utf-8")
    assert app.open_path(bad, show=False) is None and warned


def test_close_of_a_clean_window_unregisters_it(app_and_window):
    app, w = app_and_window
    assert w in app.windows
    w.close()
    assert w not in app.windows


def test_real_user_settings_are_never_written(app_and_window, tmp_path):
    app, w = app_and_window
    act(w, "Add Plate")
    app.remember_recent(tmp_path / "x.plate")
    w.editor.preferences.canvas_font_scale = 1.3
    ini = QSettings(QSettings.Format.IniFormat, QSettings.Scope.UserScope, "nettilor", "pLayout").fileName()
    # the injected settings file exists; the real one, if it exists at all, was not touched by us
    assert (tmp_path / "prefs.ini").exists()
    if Path(ini).exists():
        text = Path(ini).read_text(encoding="utf-8", errors="ignore")
        assert "x.plate" not in text


# ---------------------------------------------------------------- Custom Plate Size dialog


def test_custom_format_dialog_applies_and_saves_a_template(app_and_window, qtbot):
    app, w = app_and_window
    ed = w.editor
    dlg = CustomFormatDialog(ed, w)
    qtbot.addWidget(dlg)
    dlg.rows.setValue(4)
    dlg.cols.setValue(7)
    assert dlg.rows_hint.text() == "A–D" and dlg.count_label.text() == "28 wells"
    assert dlg.wells_label.text() == "Wells A1 – D7"
    assert dlg.save_box.isEnabled() and dlg.name_edit.placeholderText() == "4×7 plate"
    dlg.apply()
    assert ed.format == PlateFormat(4, 7)
    assert [t.name for t in ed.template_store.templates] == ["4×7 plate"]
    assert ed.format_display_name(ed.format) == "4×7 plate"


def test_custom_format_dialog_stays_open_when_the_user_backs_out(app_and_window, qtbot):
    app, w = app_and_window
    ed = w.editor
    ed.select_all_wells()
    ed.paint_selection()
    ed.confirm = lambda title, message: False
    dlg = CustomFormatDialog(ed, w)
    qtbot.addWidget(dlg)
    dlg.rows.setValue(2)
    dlg.cols.setValue(5)
    assert dlg.warning.isVisibleTo(dlg)
    dlg.apply()
    assert ed.format.rows == 8 and dlg.result() == 0 and ed.template_store.templates == []


def test_custom_format_dialog_refuses_to_template_a_standard_size(app_and_window, qtbot):
    app, w = app_and_window
    dlg = CustomFormatDialog(w.editor, w)
    qtbot.addWidget(dlg)
    dlg.rows.setValue(2)
    dlg.cols.setValue(3)
    assert not dlg.save_box.isEnabled()
    assert dlg.status.text() == "6-well is a standard plate — it is already in the menu."
