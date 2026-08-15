"""PlateEditor core — ports of CoreTests.EditorTests, SidebarMultiSelectTests,
CustomFormatFlowTests, the model halves of OverviewModeTests / OrientationTests, the
editor-level rules of SelectionInteractionTests / PaintingInteractionTests, and the editor
half of NotesTests. See PORT.md §C0–C20 for the rules; the strings here are the Mac's."""
from dataclasses import replace

import pytest
from PySide6.QtCore import QSettings

from playout.editor.document import PlateDocument
from playout.editor.plate_editor import PlateEditor
from playout.editor.well_range import WellPos, WellRange
from playout.model.layout import Factor, Layout, Level, Plate, PlateOrientation, WellLabelMode, dumps, loads
from playout.model.plate_format import WELL96, PlateFormat
from playout.model.preferences import Preferences
from playout.model.templates import PlateTemplateStore


def make_editor(tmp_path, layout=None):
    settings = QSettings(str(tmp_path / "prefs.ini"), QSettings.Format.IniFormat)
    doc = PlateDocument(layout)
    return PlateEditor(doc, Preferences(settings), PlateTemplateStore(settings))


@pytest.fixture
def ed(tmp_path):
    return make_editor(tmp_path)


def flashes(editor):
    out = []
    editor.flash_message.connect(out.append)
    return out


def rect(r0, c0, r1, c1):
    return WellRange(WellPos(r0, c0), WellPos(r1, c1))


def level_at(editor, well, factor=None):
    f = factor or editor.active_factor
    return editor.plate.level_id(f.id, well)


def undo(editor):
    editor.document.undo_stack.undo()


def redo(editor):
    editor.document.undo_stack.redo()


# ---------------------------------------------------------------- initial state


def test_starter_editor_state(ed):
    assert ed.active_plate_id == ed.layout.plates[0].id
    assert ed.active_factor.name == "Condition"
    assert ed.armed_level.name == "Untreated"
    assert ed.selection == WellRange.at(0, 0) and ed.custom_wells is None
    assert not ed.is_overview and not ed.is_multi_selecting
    assert ed.format == WELL96 and ed.round_wells is True


def test_a_document_saved_in_overview_reopens_with_nothing_selected(tmp_path):
    layout = replace(Layout.starter(), well_label_mode=WellLabelMode.overview)
    editor = make_editor(tmp_path, loads(dumps(layout)))
    assert editor.is_overview and editor.active_factor_id is None and editor.armed_level_id is None


# ---------------------------------------------------------------- painting & undo


def test_paint_and_undo_is_one_step(ed):
    ed.select(rect(0, 0, 1, 2))
    ed.paint_selection()
    lv = ed.armed_level_id
    assert [level_at(ed, w) for w in (0, 1, 2, 12, 13, 14)] == [lv] * 6 and level_at(ed, 3) is None
    assert ed.document.undo_stack.count() == 1 and ed.document.undo_stack.undoText() == "Fill Selection"
    assert ed.selection == rect(0, 0, 1, 2)  # painting never moves the selection
    undo(ed)
    assert level_at(ed, 0) is None
    redo(ed)
    assert level_at(ed, 0) == lv


def test_paint_selection_guards_in_order(ed):
    seen = flashes(ed)
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.paint_selection()
    assert seen[-1] == "Overview is read-only — click a factor to start painting again."
    ed.set_active_factor(ed.layout.factors[0].id)
    ed.disarm_level()
    ed.paint_selection()
    assert seen[-1] == "Pick a condition first — press 1–9 or click one in the sidebar."
    ed.arm_level_at_index(0)
    ed.clear_selection_marquee()
    ed.paint_selection()
    assert seen[-1] == "Select some wells first."


def test_clear_selection_clears_only_the_active_factor(ed):
    ed.add_factor()  # "Factor" with Level 1, now active
    other = ed.layout.factors[0]
    ed.select(rect(0, 0, 0, 1))
    ed.paint_selection()                                    # Factor / Level 1 on A1,A2
    ed.set_active_factor(other.id)
    ed.paint_selection()                                    # Condition / Untreated on A1,A2
    ed.clear_selection()
    assert level_at(ed, 0, other) is None
    assert level_at(ed, 0, ed.layout.factors[1]) is not None
    assert ed.document.undo_stack.undoText() == "Clear Selection"


def test_clear_all_factors_wipes_every_layer_even_in_overview(ed):
    ed.add_factor()
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()
    ed.set_active_factor(ed.layout.factors[0].id)
    ed.paint_selection()
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.clear_selection_all_factors()
    assert all(ed.plate.level_id(f.id, 0) is None for f in ed.layout.factors)
    assert ed.document.undo_stack.undoText() == "Clear All Factors"


def test_painting_is_off_while_multi_selecting_and_says_so(ed):
    seen = flashes(ed)
    levels = ed.active_factor.levels
    ed.toggle_level_in_multi_selection(levels[1].id)     # seeds from the armed level → 2 selected
    assert ed.is_multi_selecting and ed.armed_level_id is None
    ed.select(rect(0, 0, 0, 0))
    ed.paint([0], levels[0].id)
    assert seen[-1] == "Painting is off while several rows are selected — click a single row to continue."
    assert level_at(ed, 0) is None


def test_every_action_is_a_safe_no_op_with_nothing_selected(ed):
    ed.clear_selection_marquee()
    before = ed.document.undo_stack.count()
    ed.clear_selection()
    ed.clear_selection_all_factors()
    ed.randomize_selection()
    ed.copy_selection()
    assert ed.document.undo_stack.count() == before


# ---------------------------------------------------------------- selection


def test_toggle_well_adds_removes_and_never_paints(ed):
    ed.toggle_well(WellPos(2, 2))
    assert ed.selection is None and ed.custom_wells == {WellPos(0, 0), WellPos(2, 2)}  # seeded from A1
    assert ed.custom_focus == WellPos(2, 2)
    assert level_at(ed, 0) is None and level_at(ed, 26) is None
    ed.toggle_well(WellPos(0, 0))
    assert ed.custom_wells == {WellPos(2, 2)}
    ed.toggle_well(WellPos(2, 2))
    assert ed.custom_wells is None and not ed.has_selection   # last one off clears everything
    ed.toggle_well(WellPos(99, 99))
    assert not ed.has_selection


def test_add_to_selection_and_plain_select_restores_the_rectangle(ed):
    ed.toggle_well(WellPos(5, 5))
    base = ed.selection_as_positions
    ed.add_to_selection(base, rect(0, 0, 0, 2))
    assert ed.custom_wells == base | {WellPos(0, 0), WellPos(0, 1), WellPos(0, 2)}
    assert ed.custom_focus == WellPos(0, 2)
    ed.select(rect(1, 1, 2, 2))
    assert ed.custom_wells is None and ed.selection == rect(1, 1, 2, 2)


def test_fill_paints_a_discontiguous_selection_with_gaps_excluded(ed):
    ed.toggle_well(WellPos(0, 2))     # {A1, A3}
    ed.paint_selection()
    assert level_at(ed, 0) is not None and level_at(ed, 2) is not None and level_at(ed, 1) is None
    assert ed.selected_wells == [0, 2]


def test_copy_refuses_a_non_rectangular_selection(ed):
    seen = flashes(ed)
    ed.toggle_well(WellPos(0, 2))
    ed.copy_selection()
    assert seen[-1] == "Copy needs a rectangular selection."
    ed.cut_selection()
    assert seen[-1] == "Cut needs a rectangular selection."


def test_move_cursor_rules(ed):
    ed.move_cursor(1, 0)
    assert ed.selection == WellRange.at(1, 0)
    ed.move_cursor(0, 1, extend=True)
    assert ed.selection == WellRange(WellPos(1, 0), WellPos(1, 1))
    ed.clear_selection_marquee()
    ed.move_cursor(3, 3)                       # nothing selected → A1, delta ignored
    assert ed.selection == WellRange.at(0, 0)
    ed.toggle_well(WellPos(4, 4))
    ed.move_cursor(1, 0)                       # collapses onto the last toggled well
    assert ed.custom_wells is None and ed.selection == WellRange.at(5, 4)
    ed.move_cursor(-100, -100)
    assert ed.selection == WellRange.at(0, 0)  # clamped


def test_select_all_and_clear_marquee(ed):
    ed.select_all_wells()
    assert ed.selection == WellRange.whole_plate(WELL96) and len(ed.selected_wells) == 96
    ed.clear_selection_marquee()
    assert ed.selection is None and not ed.has_selection and ed.selected_wells == []


# ---------------------------------------------------------------- multi-select


def test_level_multi_select_seeds_from_armed_and_collapses_back(ed):
    levels = ed.active_factor.levels
    ed.toggle_level_in_multi_selection(levels[2].id)
    assert ed.multi_selected_level_ids == {levels[0].id, levels[2].id}
    ed.toggle_level_in_multi_selection(levels[0].id)         # back to one → re-arms it
    assert not ed.is_multi_selecting and ed.armed_level_id == levels[2].id


def test_arming_by_number_key_exits_multi_select(ed):
    levels = ed.active_factor.levels
    ed.toggle_level_in_multi_selection(levels[1].id)
    ed.arm_level_at_index(1)
    assert not ed.is_multi_selecting and ed.armed_level_id == levels[1].id


def test_bulk_delete_levels_is_one_undo_step_and_arms_a_survivor(ed):
    levels = ed.active_factor.levels
    ed.toggle_level_in_multi_selection(levels[1].id)
    ed.delete_levels(ed.multi_selected_level_ids)
    assert [lv.name for lv in ed.active_factor.levels] == ["Treated"]
    assert ed.armed_level.name == "Treated" and not ed.is_multi_selecting
    assert ed.document.undo_stack.undoText() == "Delete Conditions"
    undo(ed)
    assert len(ed.active_factor.levels) == 3


def test_factor_multi_select_seeds_from_active_and_deleting_all_keeps_one(ed):
    seen = flashes(ed)
    ed.add_factor()
    ed.add_factor()
    ids = [f.id for f in ed.layout.factors]
    ed.toggle_factor_in_multi_selection(ids[0])              # active is ids[2]
    assert ed.multi_selected_factor_ids == {ids[2], ids[0]} and ed.armed_level_id is None
    ed.toggle_factor_in_multi_selection(ids[1])
    ed.delete_factors(ed.multi_selected_factor_ids)
    assert [f.id for f in ed.layout.factors] == [ids[0]]
    assert seen[-1] == "A layout needs at least one factor — Condition stays."
    assert not ed.is_multi_selecting and ed.armed_level_id is not None


def test_deleting_prunes_the_multi_selection_sets(ed):
    levels = ed.active_factor.levels
    ed.toggle_level_in_multi_selection(levels[1].id)
    ed.toggle_level_in_multi_selection(levels[2].id)         # 3 selected
    ed.document.mutate("x", lambda layout: layout.remove_level(levels[2].id, layout.factors[0].id))
    assert ed.multi_selected_level_ids == {levels[0].id, levels[1].id}
    ed.document.mutate("y", lambda layout: layout.remove_level(levels[1].id, layout.factors[0].id))
    assert ed.multi_selected_level_ids == frozenset()        # below two → none


# ---------------------------------------------------------------- levels & factors


def test_add_level_names_arms_and_is_undoable(ed):
    ed.add_level()
    assert ed.active_factor.levels[-1].name == "Condition 4" and ed.armed_level.name == "Condition 4"
    assert ed.document.undo_stack.undoText() == "Add Level"


def test_rename_trims_and_ignores_blank(ed):
    lv = ed.active_factor.levels[0]
    ed.rename_level(lv.id, "  Control  ")
    assert ed.active_factor.levels[0].name == "Control"
    ed.rename_level(lv.id, "   ")
    assert ed.active_factor.levels[0].name == "Control"
    ed.rename_factor(ed.active_factor.id, " Drug ")
    assert ed.active_factor.name == "Drug"
    ed.rename_plate(ed.plate.id, "  ")
    assert ed.plate.name == "Plate 1"


def test_delete_level_rearms_and_clears_wells(ed):
    lv = ed.armed_level
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()
    ed.delete_level(lv.id)
    assert ed.armed_level.name == "Vehicle" and level_at(ed, 0) is None
    assert ed.document.undo_stack.undoText() == "Delete Level"


def test_move_levels_uses_pre_move_offsets(ed):
    ed.move_levels([0], 3)      # moving down: target index + 1
    assert [lv.name for lv in ed.active_factor.levels] == ["Vehicle", "Treated", "Untreated"]
    ed.move_levels([2], 0)
    assert [lv.name for lv in ed.active_factor.levels] == ["Untreated", "Vehicle", "Treated"]


def test_add_factor_names_and_activates(ed):
    ed.add_factor()
    f = ed.active_factor
    assert f.name == "Factor" and [lv.name for lv in f.levels] == ["Level 1"] and ed.armed_level.name == "Level 1"
    ed.add_factor()
    assert ed.active_factor.name == "Factor 2"
    assert ed.document.undo_stack.undoText() == "Add Factor"


def test_delete_factor_refuses_the_last_and_reconciles_the_active(ed):
    seen = flashes(ed)
    ed.delete_factor(ed.active_factor.id)
    assert seen[-1] == "A layout needs at least one factor." and len(ed.layout.factors) == 1
    ed.add_factor()
    added = ed.active_factor
    ed.delete_factor(added.id)
    assert ed.active_factor.name == "Condition" and ed.armed_level.name == "Untreated"


def test_factors_can_be_reordered_and_undone_keeping_every_assignment(ed):
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()
    ed.add_factor()
    ed.paint_selection()
    before = ed.plate.assignments
    ed.move_factors([1], 0)
    assert [f.name for f in ed.layout.factors] == ["Factor", "Condition"]
    assert ed.plate.assignments == before
    undo(ed)
    assert [f.name for f in ed.layout.factors] == ["Condition", "Factor"]


def test_set_kind_and_unit(ed):
    f = ed.active_factor
    ed.set_factor_kind(f.id, "numeric")
    ed.set_factor_unit(f.id, " µM ")
    assert ed.active_factor.kind.value == "numeric" and ed.active_factor.display_name == "Condition (µM)"


def test_remove_unused_levels_flashes(ed):
    seen = flashes(ed)
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()
    ed.remove_unused_levels()
    assert seen[-1] == "Removed 2 unused condition(s)." and [lv.name for lv in ed.active_factor.levels] == ["Untreated"]
    ed.remove_unused_levels()
    assert seen[-1] == "No unused conditions."


# ---------------------------------------------------------------- plates & formats


def test_add_duplicate_delete_plate(ed):
    seen = flashes(ed)
    ed.delete_plate(ed.plate.id)
    assert seen[-1] == "A layout needs at least one plate."
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()
    ed.add_plate()
    assert ed.plate.name == "Plate" and ed.plate.assignments == {} and ed.selection == WellRange.at(0, 0)
    ed.set_active_plate(ed.layout.plates[0].id)
    ed.duplicate_plate()
    assert ed.plate.name == "Plate 1 copy" and ed.plate.assignments == ed.layout.plates[0].assignments
    assert ed.plate.id != ed.layout.plates[0].id
    ed.delete_plate(ed.plate.id)
    assert ed.plate.name == "Plate 1"
    assert ed.document.undo_stack.undoText() == "Delete Plate"


def test_setting_the_same_format_is_a_successful_no_op(ed):
    n = ed.document.undo_stack.count()
    assert ed.set_format(WELL96) is True and ed.document.undo_stack.count() == n


def test_applying_a_format_that_loses_data_is_all_or_nothing(ed):
    ed.select(rect(7, 11, 7, 11))
    ed.paint_selection()
    ed.confirm = lambda title, message: False
    assert ed.apply_custom_format(5, 7, "Tiny") is False
    assert ed.format == WELL96 and ed.template_store.templates == []
    ed.confirm = lambda title, message: True
    assert ed.apply_custom_format(5, 7, "Tiny") is True
    assert ed.format == PlateFormat(5, 7) and ed.plate.assignments == {}
    assert ed.template_store.templates[0].name == "Tiny"
    assert ed.format_display_name(PlateFormat(5, 7)) == "Tiny"
    assert ed.selection == WellRange.at(4, 6)   # re-clamped
    assert ed.document.undo_stack.undoText() == "Change Plate Format"


def test_custom_format_applies_and_names_itself(ed):
    assert ed.apply_custom_format(5, 7, None)
    assert ed.format_display_name(ed.format) == "35-well" and ed.format_detailed_name(ed.format) == "35-well  (5×7)"


def test_undo_redo_of_a_shrink_reclamps_the_selection(ed):
    ed.select(rect(6, 10, 7, 11))
    ed.set_format(PlateFormat(2, 3))
    assert ed.selection == rect(1, 2, 1, 2)
    undo(ed)
    ed.select(rect(6, 10, 7, 11))
    redo(ed)
    assert ed.selection == rect(1, 2, 1, 2)


# ---------------------------------------------------------------- orientation


def test_automatic_turns_only_tall_plates_and_the_control_toggles(ed):
    assert ed.quarter_turns == 0
    ed.set_format(PlateFormat(8, 6))
    assert ed.quarter_turns == 1 and ed.is_turned
    ed.rotate_plate()
    assert ed.layout.orientation is PlateOrientation.upright and ed.quarter_turns == 0
    ed.rotate_plate()
    assert ed.layout.orientation is PlateOrientation.turned and ed.quarter_turns == 1
    ed.rotate_plate()
    assert ed.layout.orientation is PlateOrientation.upright        # 2-state, never a 4-way cycle
    assert ed.document.undo_stack.undoText() == "Turn Plate"


def test_turning_changes_no_data_and_flashes_where_a1_went(ed):
    seen = flashes(ed)
    ed.select(rect(0, 0, 1, 1))
    ed.paint_selection()
    before = ed.plate
    ed.rotate_plate()
    assert seen[-1] == "Turned 90°. A1 is now top right." and ed.plate == before
    ed.rotate_plate()
    assert seen[-1] == "Upright. A1 is top left."
    assert loads(dumps(ed.layout)).orientation is ed.layout.orientation


# ---------------------------------------------------------------- overview


def test_entering_overview_clears_active_and_armed_and_leaving_restores(ed):
    ed.set_well_label_mode(WellLabelMode.none)
    f = ed.active_factor
    ed.set_active_factor(f.id)
    ed.set_well_label_mode(WellLabelMode.overview)
    assert ed.is_overview and ed.active_factor_id is None and ed.armed_level_id is None
    ed.toggle_overview()
    assert ed.layout.well_label_mode is WellLabelMode.none and ed.active_factor_id == f.id
    assert ed.armed_level_id == f.levels[0].id
    ed.toggle_overview()
    assert ed.is_overview
    ed.set_active_factor(f.id)                        # clicking a factor leaves, to the previous mode
    assert ed.layout.well_label_mode is WellLabelMode.none and ed.active_factor_id == f.id


def test_undo_and_redo_in_and_out_of_overview_keep_the_editor_in_step(ed):
    ed.set_well_label_mode(WellLabelMode.overview)
    undo(ed)
    assert not ed.is_overview and ed.active_factor_id is not None
    redo(ed)
    assert ed.is_overview and ed.active_factor_id is None and ed.armed_level_id is None


def test_tab_from_overview_lands_on_first_or_last_factor(ed):
    ed.add_factor()
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.cycle_factor(-1)
    assert ed.active_factor.name == "Factor" and not ed.is_overview
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.cycle_factor(1)
    assert ed.active_factor.name == "Condition"


def test_overview_refuses_edits_out_loud(ed):
    seen = flashes(ed)
    sheets = []
    ed.sheet_requested.connect(sheets.append)
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.open_series_sheet()
    ed.open_xy_fill_sheet()
    ed.clipboard.set_text("A\tB")
    ed.paste_from_clipboard()
    ed.randomize_selection()
    assert sheets == [] and seen.count("Overview is read-only — click a factor to start painting again.") == 4
    ed.set_active_factor(ed.layout.factors[0].id)
    ed.open_series_sheet()
    assert sheets == ["series"]


def test_deleting_a_factor_in_overview_selects_none(ed):
    ed.add_factor()
    ed.set_well_label_mode(WellLabelMode.overview)
    ed.delete_factor(ed.layout.factors[1].id)
    assert ed.is_overview and ed.active_factor_id is None


# ---------------------------------------------------------------- reconcile


def test_redo_of_a_factor_deletion_cannot_strand_the_editor(ed):
    ed.add_factor()
    doomed = ed.active_factor
    ed.delete_factor(doomed.id)
    undo(ed)
    ed.set_active_factor(doomed.id)
    redo(ed)
    assert ed.layout.factor(ed.active_factor_id) is not None and ed.armed_level is not None
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()                                    # lands in a live factor
    assert level_at(ed, 0) is not None


def test_redo_of_a_plate_deletion_cannot_strand_the_editor(ed):
    ed.add_plate()
    added = ed.plate
    ed.delete_plate(added.id)
    undo(ed)
    ed.set_active_plate(added.id)
    redo(ed)
    assert ed.layout.plate(ed.active_plate_id) is not None


def test_undoing_add_factor_leaves_a_valid_active_factor_and_armed_level(ed):
    ed.add_factor()
    undo(ed)
    assert ed.active_factor.name == "Condition" and ed.armed_level.name == "Untreated"


def test_disarmed_stays_disarmed_across_edits_but_a_stale_level_is_replaced(ed):
    ed.disarm_level()
    ed.add_plate()
    assert ed.armed_level_id is None
    ed.arm_level_at_index(2)
    ed.document.mutate("drop", lambda layout: layout.remove_level(layout.factors[0].levels[2].id, layout.factors[0].id))
    assert ed.armed_level.name == "Untreated"


# ---------------------------------------------------------------- clipboard / import


def test_copy_produces_tab_separated_text(ed):
    ed.select(rect(0, 0, 0, 1))
    ed.paint([0], ed.armed_level_id)
    ed.copy_selection()
    assert ed.clipboard.text() == "Untreated\t"
    ed.copy_selection(include_headers=True)
    assert ed.clipboard.text() == "\t1\t2\nA\tUntreated\t"


def test_paste_creates_missing_conditions_and_moves_the_selection(ed):
    seen = flashes(ed)
    ed.select(rect(1, 1, 1, 1))
    ed.clipboard.set_text("Untreated\tNew A\nnew a\tNew B")
    ed.paste_from_clipboard()
    names = [lv.name for lv in ed.active_factor.levels]
    assert names == ["Untreated", "Vehicle", "Treated", "New A", "New B"]
    assert seen[-1] == "Added 2 new conditions from pasted values."
    assert ed.selection == rect(1, 1, 2, 2)
    f = ed.active_factor
    assert f.level(level_at(ed, WELL96.index(2, 1))).name == "New A"   # case-insensitive reuse
    assert ed.document.undo_stack.undoText() == "Paste"


def test_paste_with_no_selection_lands_at_a1_and_headers_are_stripped(ed):
    ed.clear_selection_marquee()
    ed.clipboard.set_text("\t1\t2\nA\tX\tY\nB\t\tZ")
    ed.paste_from_clipboard()
    f = ed.active_factor
    assert f.level(level_at(ed, 0)).name == "X" and f.level(level_at(ed, 1)).name == "Y"
    assert level_at(ed, 12) is None and f.level(level_at(ed, 13)).name == "Z"
    assert ed.selection == rect(0, 0, 1, 1)


def test_cut_copies_then_clears(ed):
    ed.select(rect(0, 0, 0, 0))
    ed.paint_selection()
    ed.cut_selection()
    assert ed.clipboard.text() == "Untreated" and level_at(ed, 0) is None


def test_import_table_text_applies_at_a1(ed):
    seen = flashes(ed)
    assert ed.import_table_text("P,Q\nR,S\n", is_csv=True)
    f = ed.active_factor
    assert [f.level(level_at(ed, w)).name for w in (0, 1, 12, 13)] == ["P", "Q", "R", "S"]
    assert seen[-1] == "Imported 2 × 2 values into Condition."
    assert not ed.import_table_text("", is_csv=False)
    assert seen[-1] == "That file did not contain a readable table."


# ---------------------------------------------------------------- notes


def test_note_targets_the_selection_focus_and_edits_are_undoable(ed):
    targets = []
    ed.note_sheet_requested.connect(targets.append)
    ed.select(rect(0, 0, 2, 3))            # anchor A1, focus C4
    ed.open_well_note_sheet()
    assert targets[-1].well == WELL96.index(2, 3) and ed.note_title(targets[-1]) == "Note for C4"
    ed.save_note("  bubble ", targets[-1])
    assert ed.plate.note_for(WELL96.index(2, 3)) == "bubble"
    assert ed.summary(2, 3).endswith("  ·  ✎ bubble") and "✎" not in ed.summary(0, 0)
    assert ed.document.undo_stack.undoText() == "Edit Well Note"
    ed.save_note("", targets[-1])
    assert ed.plate.well_notes == {}
    ed.open_plate_note_sheet()
    assert targets[-1].is_plate and ed.note_title(targets[-1]) == "Note for Plate 1"
    ed.save_note("edge effects\n", targets[-1])
    assert ed.plate.note == "edge effects" and ed.document.undo_stack.undoText() == "Edit Plate Note"


def test_note_needs_a_well(ed):
    seen = flashes(ed)
    ed.clear_selection_marquee()
    ed.open_well_note_sheet()
    assert seen[-1] == "Select a well first."


def test_summary_format(ed):
    ed.select(rect(1, 6, 1, 6))
    ed.paint_selection()
    assert ed.summary(1, 6) == "B7  ·  Condition: Untreated"
    assert ed.summary(1, 7) == "B8 — empty"
    ed.set_pad_well_labels(True)
    assert ed.summary(1, 7) == "B08 — empty"
    assert ed.summary(50, 50) == ""
