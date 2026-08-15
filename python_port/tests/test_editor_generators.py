"""Series fill, XY position fill, randomise, and the new-condition colour policy —
ports of CoreTests.SeriesTests / testRandomiseKeepsCounts, XYFillTests, and the palette
policy tests in PreferencesTests."""
import random
from collections import Counter
from dataclasses import replace

import pytest
from PySide6.QtCore import QSettings

from playout.editor.document import PlateDocument
from playout.editor.plate_editor import (
    PlateEditor,
    SeriesDirection,
    SeriesMode,
    SeriesSpec,
    XYFillSpec,
    XYPattern,
    format_value,
    xy_names,
)
from playout.editor.well_range import WellPos, WellRange
from playout.model import palette
from playout.model.layout import Layout, PlateOrientation, WellLabelMode
from playout.model.plate_format import WELL96, PlateFormat
from playout.model.preferences import NewConditionColors, Preferences
from playout.model.templates import PlateTemplateStore


def make_editor(tmp_path, layout=None):
    settings = QSettings(str(tmp_path / "prefs.ini"), QSettings.Format.IniFormat)
    return PlateEditor(PlateDocument(layout), Preferences(settings), PlateTemplateStore(settings))


@pytest.fixture
def ed(tmp_path):
    return make_editor(tmp_path)


def flashes(editor):
    out = []
    editor.flash_message.connect(out.append)
    return out


def rect(r0, c0, r1, c1):
    return WellRange(WellPos(r0, c0), WellPos(r1, c1))


def names_at(editor, wells, factor=None):
    f = factor or editor.active_factor
    out = []
    for w in wells:
        lid = editor.plate.level_id(f.id, w)
        out.append(f.level(lid).name if lid else None)
    return out


# ---------------------------------------------------------------- series


def test_three_fold_dilution_across_columns(ed):
    ed.select(rect(0, 0, 0, 5))
    assert ed.series_values(SeriesSpec()) == ["10", "3.33", "1.11", "0.37", "0.123", "0.0412"]


def test_last_position_can_be_vehicle(ed):
    ed.select(rect(0, 0, 0, 3))
    spec = SeriesSpec(start=100, fold_factor=10, last_is_zero=True)
    assert ed.series_values(spec) == ["100", "10", "1", "0"]


def test_linear_step_down_rows(ed):
    ed.select(rect(0, 0, 3, 0))
    spec = SeriesSpec(direction=SeriesDirection.downRows, mode=SeriesMode.linear, start=24, step=-6)
    assert ed.series_values(spec) == ["24", "18", "12", "6"]


def test_format_value_pins():
    assert format_value(0, 3) == "0"
    assert format_value(3.33333, 3) == "3.33"
    assert format_value(10.0, 3) == "10"
    assert format_value(1e-7, 3) == "1e-07"
    assert format_value(0.5, 1) == "0.5"


def test_apply_series_writes_every_row_sets_numeric_and_sorts_high_to_low(ed):
    seen = flashes(ed)
    ed.select(rect(0, 0, 1, 5))
    base = ed.active_factor.levels[0].color_hex
    ed.apply_series(SeriesSpec())
    f = ed.active_factor
    assert f.kind.value == "numeric"
    values = ["10", "3.33", "1.11", "0.37", "0.123", "0.0412"]
    assert names_at(ed, [WELL96.index(0, c) for c in range(6)]) == values
    assert names_at(ed, [WELL96.index(1, c) for c in range(6)]) == values
    assert names_at(ed, [WELL96.index(0, 6)]) == [None]
    # numeric levels first, high→low, then the non-numeric originals ascending
    assert [lv.name for lv in f.levels] == values + ["Treated", "Untreated", "Vehicle"]
    numeric_colours = [lv.color_hex for lv in f.levels[:6]]
    assert numeric_colours == palette.ramp(6, base)
    assert ed.armed_level.name == "10"
    assert seen[-1] == "Filled 6-point series: 10 → 0.0412"
    assert ed.document.undo_stack.undoText() == "Series Fill"


def test_series_needs_a_rectangular_selection_and_refuses_overview(ed):
    ed.toggle_well(WellPos(0, 3))
    assert ed.series_values(SeriesSpec()) == []
    ed.select(rect(0, 0, 0, 2))
    ed.set_well_label_mode(WellLabelMode.overview)
    seen = flashes(ed)
    n = ed.document.undo_stack.count()
    ed.apply_series(SeriesSpec())
    assert seen[-1] == "Overview is read-only — click a factor to start painting again."
    assert ed.document.undo_stack.count() == n


# ---------------------------------------------------------------- XY


def test_xy_names_widen_only_when_needed():
    assert xy_names(96)[:2] == ["XY01", "XY02"] and xy_names(96)[-1] == "XY96"
    assert xy_names(384)[0] == "XY001" and xy_names(384)[-1] == "XY384"
    assert xy_names(0) == []


def test_nothing_selected_numbers_the_whole_plate_and_the_starter_survives(ed):
    seen = flashes(ed)
    ed.clear_selection_marquee()
    ed.apply_xy_fill(XYFillSpec())
    assert [f.name for f in ed.layout.factors] == ["Condition", "XY"]
    xy = ed.active_factor
    assert xy.name == "XY" and len(xy.levels) == 96
    assert names_at(ed, [0, 1, 95]) == ["XY01", "XY02", "XY96"]
    assert seen[-1] == "Numbered 96 positions: XY01 → XY96"
    assert ed.armed_level.name == "XY01"
    assert ed.document.undo_stack.undoText() == "XY Position Fill"


def test_the_resting_single_well_cursor_counts_as_nothing_selected(ed):
    ed.select(rect(3, 3, 3, 3))
    assert len(ed.xy_fill_wells(XYFillSpec())) == 96


def test_a_rectangle_numbers_only_itself(ed):
    ed.select(rect(1, 1, 2, 2))
    ed.apply_xy_fill(XYFillSpec())
    assert names_at(ed, [WELL96.index(1, 1), WELL96.index(1, 2), WELL96.index(2, 1), WELL96.index(2, 2)]) == ["XY01", "XY02", "XY03", "XY04"]
    assert names_at(ed, [0]) == [None]


def test_down_rows_walks_a_column_first_and_serpentine_reverses_alternate_rows(ed):
    ed.select(rect(0, 0, 1, 2))
    down = ed.xy_fill_wells(XYFillSpec(XYPattern.downRows))
    assert down == [WELL96.index(0, 0), WELL96.index(1, 0), WELL96.index(0, 1), WELL96.index(1, 1), WELL96.index(0, 2), WELL96.index(1, 2)]
    snake = ed.xy_fill_wells(XYFillSpec(XYPattern.serpentine))
    assert snake == [WELL96.index(0, 0), WELL96.index(0, 1), WELL96.index(0, 2), WELL96.index(1, 2), WELL96.index(1, 1), WELL96.index(1, 0)]


def test_rerunning_renumbers_the_one_xy_factor(ed):
    ed.select(rect(0, 0, 0, 3))
    ed.apply_xy_fill(XYFillSpec())
    ed.select(rect(0, 0, 0, 1))
    ed.apply_xy_fill(XYFillSpec(XYPattern.downRows))
    xy = [f for f in ed.layout.factors if f.name == "XY"]
    assert len(xy) == 1
    assert names_at(ed, [0, 1, 2, 3], xy[0]) == ["XY01", "XY02", "XY03", "XY04"]  # stale levels stay
    assert len(xy[0].levels) == 4


def test_a_turned_plate_numbers_along_the_rows_the_user_sees(tmp_path):
    layout = replace(Layout.starter(), orientation=PlateOrientation.turned)
    editor = make_editor(tmp_path, layout)
    editor.clear_selection_marquee()
    editor.apply_xy_fill(XYFillSpec())
    xy = editor.active_factor
    assert names_at(editor, [WELL96.index(7, 0)], xy) == ["XY01"]   # H1
    assert names_at(editor, [WELL96.index(0, 0)], xy) == ["XY08"]   # A1
    assert names_at(editor, [WELL96.index(7, 1)], xy) == ["XY09"]   # H2


def test_a_discontiguous_selection_is_numbered_in_pattern_order_skipping_gaps(ed):
    ed.toggle_well(WellPos(0, 5))          # {A1, A6}
    ed.toggle_well(WellPos(2, 2))          # + C3
    ed.toggle_well(WellPos(2, 0))          # + C1
    wells = ed.xy_fill_wells(XYFillSpec(XYPattern.serpentine))
    # rows present: 0 and 2 → rank 0 forwards, rank 1 backwards
    assert wells == [WELL96.index(0, 0), WELL96.index(0, 5), WELL96.index(2, 2), WELL96.index(2, 0)]
    ed.apply_xy_fill(XYFillSpec(XYPattern.serpentine))
    assert names_at(ed, [WELL96.index(0, 1)]) == [None]


def test_xy_colours_are_one_ramp_from_the_next_auto_colour_or_a_chosen_base(ed):
    ed.select(rect(0, 0, 0, 3))
    ed.apply_xy_fill(XYFillSpec())
    xy = ed.active_factor
    assert [lv.color_hex for lv in xy.levels] == palette.ramp(4, palette.color_at(1))  # factors.count was 1
    ed.apply_xy_fill(XYFillSpec(base_hex="#E15759"))
    assert [lv.color_hex for lv in ed.active_factor.levels] == palette.ramp(4, "#E15759")


def test_xy_fill_is_one_undo_step_and_refuses_overview(ed):
    seen = flashes(ed)
    n = ed.document.undo_stack.count()
    ed.select(rect(0, 0, 0, 1))
    ed.apply_xy_fill(XYFillSpec())
    assert ed.document.undo_stack.count() == n + 1
    ed.document.undo_stack.undo()
    assert [f.name for f in ed.layout.factors] == ["Condition"] and ed.plate.assignments == {}
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.apply_xy_fill(XYFillSpec())
    assert seen[-1] == "Overview is read-only — click a factor to start painting again."


# ---------------------------------------------------------------- randomise


def test_randomise_keeps_counts_including_empties(ed):
    seen = flashes(ed)
    ed.rng = random.Random(0)
    ed.select(rect(0, 0, 0, 3))
    ed.paint_selection()                       # 4× Untreated
    ed.arm_level_at_index(1)
    ed.select(rect(0, 4, 0, 5))
    ed.paint_selection()                       # 2× Vehicle
    ed.select(rect(0, 0, 0, 7))                # + 2 empties
    before = Counter(names_at(ed, ed.selected_wells))
    n = ed.document.undo_stack.count()
    ed.randomize_selection()
    assert Counter(names_at(ed, ed.selected_wells)) == before
    assert ed.document.undo_stack.count() == n + 1 and seen[-1] == "Randomised 8 wells."


def test_randomise_of_one_well_is_a_silent_no_op(ed):
    seen = flashes(ed)
    ed.select(rect(0, 0, 0, 0))
    ed.randomize_selection()
    assert seen == []


# ---------------------------------------------------------------- colour policy


def test_by_default_every_factors_first_condition_is_the_same_blue(ed):
    ed.add_factor()
    ed.add_factor()
    assert all(f.levels[0].color_hex == palette.color_at(0) for f in ed.layout.factors)


def test_never_repeat_gives_new_levels_pasted_values_and_recolour_distinct_colours(ed):
    ed.preferences.new_condition_colors = NewConditionColors.neverRepeat
    ed.add_factor()
    ed.add_level()
    ed.add_level()
    ed.clipboard.set_text("P\tQ\tR")
    ed.select(rect(0, 0, 0, 0))
    ed.paste_from_clipboard()
    used = [lv.color_hex for f in ed.layout.factors for lv in f.levels]
    assert len(set(map(palette.normalized, used))) == len(used)
    ed.recolor_levels_from_palette()
    used = [lv.color_hex for f in ed.layout.factors for lv in f.levels]
    assert len(set(map(palette.normalized, used))) == len(used)


def test_new_level_color_first_twenty_picks_equal_the_categorical_cycle(ed):
    ed.preferences.new_condition_colors = NewConditionColors.neverRepeat
    layout = Layout()
    assert [ed.new_level_color(layout, i) for i in range(1)] == [palette.CATEGORICAL[0]]
    seen = []
    from playout.model.layout import Factor, Level

    for i in range(20):
        hx = ed.new_level_color(layout, i)
        seen.append(hx)
        layout = replace(layout, factors=layout.factors + (Factor(name=str(i), levels=(Level("x", hx),)),))
    assert seen == list(palette.CATEGORICAL)


def test_recolour_uses_a_ramp_for_numeric_factors(ed):
    ed.set_factor_kind(ed.active_factor.id, "numeric")
    ed.recolor_levels_from_palette()
    assert [lv.color_hex for lv in ed.active_factor.levels] == palette.ramp(3, palette.color_at(0))
    assert ed.document.undo_stack.undoText() == "Recolour Levels"
