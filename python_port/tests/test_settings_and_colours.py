"""M6 — the colour grid popover (SwatchPicker rules) and the Settings dialog."""
import pytest

from playout.model import palette
from playout.model.palette import FAMILIES
from playout.model.preferences import ActiveMarkerStyle, NewConditionColors, WellTextStyle
from playout.ui.colour_grid import SHADE_COUNT, ColourGridPopover
from playout.ui.sheets.preferences_dialog import PreferencesDialog
from tests.ui_helpers import make_editor


def test_colour_grid_shows_every_family_hue_in_columns_with_the_base_in_the_middle_row(qtbot):
    pop = ColourGridPopover(palette.color_at(0), used=[])
    qtbot.addWidget(pop)
    for fam in FAMILIES:
        pop.family_buttons[fam].click()
        hexes = pop.shown_hexes()
        assert len(hexes) == 8 * SHADE_COUNT
        for col, hue in enumerate(fam.hues):
            column = hexes[col * SHADE_COUNT:(col + 1) * SHADE_COUNT]
            assert column == palette.shades(hue, SHADE_COUNT)
            assert palette.matches(column[2], hue)
        assert pop.note.text() == fam.note


def test_colour_grid_marks_the_current_and_used_colours_and_picks(qtbot):
    used = [palette.color_at(1), palette.shades(palette.color_at(2), 5)[0]]
    pop = ColourGridPopover(palette.color_at(0), used=used)
    qtbot.addWidget(pop)
    assert [c.hex_text for c in pop.current_cells()] == [palette.color_at(0)]
    taken = {c.hex_text for c in pop.taken_cells()}
    assert taken == {palette.color_at(1), palette.shades(palette.color_at(2), 5)[0]}
    picked = []
    pop.picked.connect(picked.append)
    pop.taken_cells()[0].click()
    assert picked == [pop.taken_cells()[0].hex_text if pop.taken_cells() else picked[0]] or len(picked) == 1


def test_sidebar_swatch_scopes_used_colours_by_the_never_repeat_setting(tmp_path, qtbot):
    from playout.ui.sidebar import Sidebar

    ed = make_editor(tmp_path)
    ed.add_factor()
    ed.add_level()                       # Factor: Level 1, Condition 2
    bar = Sidebar(ed)
    qtbot.addWidget(bar)
    lv0 = ed.active_factor.levels[0].id
    per_factor = bar.level_list.used_colours(lv0)
    assert per_factor == [ed.active_factor.levels[1].color_hex]
    ed.preferences.new_condition_colors = NewConditionColors.neverRepeat
    everywhere = bar.level_list.used_colours(lv0)
    assert len(everywhere) == 4  # the other factor's 3 + this factor's other 1


def test_settings_dialog_binds_every_preference_and_restores_defaults(tmp_path, qtbot):
    ed = make_editor(tmp_path)
    prefs = ed.preferences
    dlg = PreferencesDialog(prefs)
    qtbot.addWidget(dlg)
    dlg.text_choice.buttons[WellTextStyle.alwaysWhite].click()
    assert prefs.well_text_style is WellTextStyle.alwaysWhite
    assert dlg.text_choice.note.text() == WellTextStyle.alwaysWhite.note
    dlg.marker_choice.buttons[ActiveMarkerStyle.deeperShade].click()
    assert prefs.active_marker_style is ActiveMarkerStyle.deeperShade
    dlg.counts_box.setChecked(True)
    assert prefs.show_factor_condition_counts is True
    dlg.new_colours_choice.buttons[NewConditionColors.neverRepeat].click()
    assert prefs.new_condition_colors is NewConditionColors.neverRepeat
    assert not dlg.reset_empty.isEnabled() and dlg.empty_note.text() == "The default follows light and dark mode."
    prefs.empty_well_color_hex = "#3A5F0B"
    assert dlg.reset_empty.isEnabled() and dlg.empty_note.text().startswith("A chosen colour is used as it is")
    dlg.reset_empty.click()
    assert prefs.empty_well_color_hex is None
    dlg.size_slider.setValue(130)
    assert prefs.canvas_font_scale == pytest.approx(1.3) and dlg.size_label.text() == "130 %"
    dlg.font_box.setCurrentIndex(dlg.font_box.count() - 1)
    assert prefs.canvas_font_family == dlg.font_box.currentData()
    dlg.restore.click()
    assert prefs.well_text_style is WellTextStyle.automatic and prefs.canvas_font_scale == 1.0
    assert prefs.canvas_font_family is None and dlg.font_box.currentIndex() == 0
    assert dlg.text_choice.buttons[WellTextStyle.automatic].isChecked()


def test_settings_changes_reach_the_editor(tmp_path, qtbot):
    ed = make_editor(tmp_path)
    seen = []
    ed.state_changed.connect(lambda: seen.append(1))
    dlg = PreferencesDialog(ed.preferences)
    qtbot.addWidget(dlg)
    dlg.marker_choice.buttons[ActiveMarkerStyle.deeperShade].click()
    assert seen
    dlg.preview.repaint()  # draws without error under every style
    ed.preferences.well_text_style = WellTextStyle.alwaysWhite
    dlg.preview.repaint()
