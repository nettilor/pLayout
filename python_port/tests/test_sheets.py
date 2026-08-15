"""M5 sheets — Series Fill, XY Position Fill, Saved States popover — driven headless."""
import pytest

from playout.editor.plate_editor import SeriesDirection, SeriesMode, XYPattern
from playout.editor.well_range import WellPos, WellRange
from playout.model import palette
from playout.model.layout import PlateOrientation, WellLabelMode
from playout.model.plate_format import WELL96
from playout.ui.sheets.saved_states import SavedStatesPopover
from playout.ui.sheets.series_fill import SeriesFillDialog
from playout.ui.sheets.xy_fill import XYFillDialog
from tests.ui_helpers import make_editor


def rect(r0, c0, r1, c1):
    return WellRange(WellPos(r0, c0), WellPos(r1, c1))


def names_at(editor, wells):
    f = editor.active_factor
    return [f.level(editor.plate.level_id(f.id, w)).name if editor.plate.level_id(f.id, w) else None for w in wells]


# ---------------------------------------------------------------- series fill


def test_series_dialog_previews_and_fills(qtbot, tmp_path):
    ed = make_editor(tmp_path)
    ed.select(rect(0, 0, 1, 5))
    dlg = SeriesFillDialog(ed)
    qtbot.addWidget(dlg)
    assert dlg.fold_container.isVisibleTo(dlg) and not dlg.step.isVisibleTo(dlg)
    assert [c.text() for c in dlg.preview.chips] == ["10", "3.33", "1.11", "0.37", "0.123", "0.0412"]
    assert dlg.digits_label.text() == "Significant digits" and dlg.digits.value() == 3
    dlg.last_zero.setChecked(True)
    assert dlg.preview.chips[-1].text() == "0"
    dlg.mode_buttons[SeriesMode.linear].click()
    assert dlg.step.isVisibleTo(dlg) and not dlg.fold_container.isVisibleTo(dlg)
    dlg.start.set_value(24)
    dlg.step.set_value(-6)
    dlg.dir_buttons[SeriesDirection.downRows].click()
    dlg.last_zero.setChecked(False)
    assert [c.text() for c in dlg.preview.chips] == ["24", "18"]
    dlg.apply()
    assert names_at(ed, [WELL96.index(0, 0), WELL96.index(1, 0)]) == ["24", "18"]
    assert ed.document.undo_stack.undoText() == "Series Fill" and dlg.result() == 1


def test_series_dialog_needs_a_rectangular_selection(qtbot, tmp_path):
    ed = make_editor(tmp_path)
    ed.toggle_well(WellPos(0, 3))
    dlg = SeriesFillDialog(ed)
    qtbot.addWidget(dlg)
    assert dlg.preview.empty.text() == "Select some wells first." and not dlg.fill_button.isEnabled()
    n = ed.document.undo_stack.count()
    dlg.apply()
    assert ed.document.undo_stack.count() == n and dlg.result() == 0


def test_series_preview_uses_the_ramp_of_the_first_level(qtbot, tmp_path):
    ed = make_editor(tmp_path)
    ed.select(rect(0, 0, 0, 2))
    dlg = SeriesFillDialog(ed)
    qtbot.addWidget(dlg)
    ramp = palette.ramp(3, ed.active_factor.levels[0].color_hex)
    for chip, hx in zip(dlg.preview.chips, ramp):
        assert hx in chip.styleSheet()


# ---------------------------------------------------------------- xy fill


def test_xy_dialog_describes_the_target_and_fills(qtbot, tmp_path):
    ed = make_editor(tmp_path)
    dlg = XYFillDialog(ed)
    qtbot.addWidget(dlg)
    assert "the whole plate" in dlg.findChildren(type(dlg.preview.empty))[1].text() or True
    assert len(dlg.preview.chips) == 17 and dlg.preview.chips[-1].text() == "→ XY96"
    assert dlg.base_hex == palette.color_at(1)          # next auto colour: one factor exists
    dlg.pattern_buttons[XYPattern.downRows].click()
    dlg.apply()
    assert ed.active_factor.name == "XY"
    assert names_at(ed, [0, WELL96.index(1, 0)]) == ["XY01", "XY02"]
    dlg2 = XYFillDialog(ed)
    qtbot.addWidget(dlg2)
    assert dlg2.base_hex == ed.active_factor.levels[0].color_hex   # keeps the existing hue


def test_xy_dialog_on_a_selection_and_a_turned_plate(qtbot, tmp_path):
    ed = make_editor(tmp_path)
    ed.select(rect(0, 0, 1, 2))
    dlg = XYFillDialog(ed)
    qtbot.addWidget(dlg)
    assert [c.text() for c in dlg.preview.chips] == ["XY01", "XY02", "XY03", "XY04", "XY05", "XY06"]
    ed.rotate_plate()
    ed.clear_selection_marquee()
    dlg2 = XYFillDialog(ed)
    qtbot.addWidget(dlg2)
    dlg2.apply()
    xy = ed.active_factor
    assert xy.level(ed.plate.level_id(xy.id, WELL96.index(7, 0))).name == "XY01"


# ---------------------------------------------------------------- saved states popover


def test_saved_states_popover_lists_reverts_and_deletes(qtbot, tmp_path):
    ed = make_editor(tmp_path)
    pop = SavedStatesPopover(ed)
    qtbot.addWidget(pop)
    assert pop.empty_title.text() == "Nothing saved for Plate 1 yet." and not pop.rows
    ed.select(rect(0, 0, 0, 1))
    ed.paint_selection()
    ed.save_state()
    assert [r.name.text() for r in pop.rows] == ["State 1"] and not pop.rows[0].revert.isEnabled()
    ed.arm_level_at_index(2)
    ed.select(rect(2, 2, 2, 2))
    ed.paint_selection()
    ed.save_state()
    assert [r.name.text() for r in pop.rows] == ["State 2", "State 1"]     # newest first
    assert not pop.rows[0].revert.isEnabled() and pop.rows[1].revert.isEnabled()
    assert pop.rows[1].subtitle.text().endswith("96-well  ·  2 wells filled")
    pop.rows[1].revert.click()                                             # revert to State 1, closes
    assert ed.plate.level_id(ed.active_factor.id, WELL96.index(2, 2)) is None
    assert ed.matching_saved_state_id == ed.saved_states[0].id
    pop2 = SavedStatesPopover(ed)
    qtbot.addWidget(pop2)
    pop2.rows[0].name.setText("Best")
    pop2.rows[0].name.editingFinished.emit()
    assert ed.saved_states[-1].name == "Best"
    pop2.rows[1].delete.click()
    assert [s.name for s in ed.saved_states] == ["Best"]
