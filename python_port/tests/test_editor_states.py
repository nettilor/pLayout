"""Saved states through the editor — ports of SavedStateTests and PerPlateStateTests."""
from dataclasses import replace

import pytest
from PySide6.QtCore import QSettings

from playout.editor.document import PlateDocument
from playout.editor.plate_editor import PlateEditor
from playout.editor.well_range import WellPos, WellRange
from playout.model.layout import Layout, LayoutSnapshot, WellLabelMode, dumps, loads
from playout.model.plate_format import WELL96, PlateFormat
from playout.model.preferences import Preferences
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


def paint(editor, r0, c0, r1, c1, level_index=0):
    editor.arm_level_at_index(level_index)
    editor.select(rect(r0, c0, r1, c1))
    editor.paint_selection()


def undo(editor):
    editor.document.undo_stack.undo()


def redo(editor):
    editor.document.undo_stack.redo()


# ---------------------------------------------------------------- saving


def test_saving_captures_the_plate_and_factors_and_is_named_state_n(ed):
    paint(ed, 0, 0, 0, 2)
    ed.save_state()
    assert [s.name for s in ed.saved_states] == ["State 1"]
    state = ed.saved_states[0]
    assert state.plates == (ed.plate,) and state.factors == ed.layout.factors and state.plate_id == ed.plate.id
    paint(ed, 1, 0, 1, 0, 1)
    ed.save_state()
    assert [s.name for s in ed.saved_states] == ["State 1", "State 2"]
    assert [s.name for s in ed.saved_states_newest_first] == ["State 2", "State 1"]


def test_saving_is_undoable(ed):
    ed.save_state()
    assert ed.document.undo_stack.undoText() == "Save State"
    undo(ed)
    assert ed.saved_states == () and not ed.current_design_is_saved
    redo(ed)
    assert len(ed.saved_states) == 1 and ed.current_design_is_saved


def test_saving_the_same_design_twice_is_refused_and_says_so(ed):
    seen = flashes(ed)
    ed.save_state()
    n = ed.document.undo_stack.count()
    ed.save_state()
    assert seen[-1] == "Plate 1 is already saved as State 1." and ed.document.undo_stack.count() == n


def test_the_cap_drops_the_oldest_and_flashes(ed):
    seen = flashes(ed)
    for i in range(20):
        paint(ed, i // 12, i % 12, i // 12, i % 12, i % 3)   # each save is a new design
        ed.save_state()
    assert len(ed.layout.snapshots) == 20
    paint(ed, 7, 11, 7, 11, 2)
    ed.save_state()
    assert len(ed.layout.snapshots) == 20 and seen[-1] == "Saved. Keeping the 20 most recent states."
    assert ed.layout.snapshots[-1].name == "State 21"


def test_save_flash_names_the_state_and_plate(ed):
    seen = flashes(ed)
    ed.save_state()
    assert seen[-1].startswith("Saved State 1 for Plate 1.") and "undoes this" in seen[-1]


# ---------------------------------------------------------------- reverting


def test_revert_restores_the_design_and_is_undoable(ed):
    paint(ed, 0, 0, 0, 2)
    ed.save_state()
    saved_plate = ed.plate
    paint(ed, 3, 3, 4, 4, 2)
    assert ed.plate != saved_plate
    ed.revert_to_latest_state()
    assert ed.plate == saved_plate and ed.document.undo_stack.undoText() == "Revert to State 1"
    undo(ed)
    assert ed.plate != saved_plate
    redo(ed)
    assert ed.plate == saved_plate


def test_revert_keeps_the_bookmarks_and_display_settings(ed):
    ed.save_state()
    ed.set_well_label_mode(WellLabelMode.none)
    ed.set_pad_well_labels(True)
    paint(ed, 0, 0, 0, 0)
    ed.revert_to_latest_state()
    assert len(ed.saved_states) == 1
    assert ed.layout.well_label_mode is WellLabelMode.none and ed.layout.pad_well_labels is True


def test_any_older_state_can_be_reverted_to(ed):
    paint(ed, 0, 0, 0, 0)
    ed.save_state()
    first = ed.plate
    paint(ed, 1, 1, 1, 1)
    ed.save_state()
    paint(ed, 2, 2, 2, 2)
    ed.revert_to_state(ed.saved_states[0].id)
    assert ed.plate == first


def test_reverting_with_no_states_says_so_and_changes_nothing(ed):
    seen = flashes(ed)
    n = ed.document.undo_stack.count()
    ed.revert_to_latest_state()
    assert seen[-1] == "No saved states for Plate 1 yet — use the bookmark button first."
    assert ed.document.undo_stack.count() == n


def test_reverting_to_a_matching_state_says_already_matches(ed):
    seen = flashes(ed)
    ed.save_state()
    ed.revert_to_latest_state()
    assert seen[-1] == "Already matches State 1."


def test_rename_and_delete_states(ed):
    seen = flashes(ed)
    ed.save_state()
    sid = ed.saved_states[0].id
    ed.rename_state(sid, "  Best  ")
    assert ed.saved_states[0].name == "Best" and ed.document.undo_stack.undoText() == "Rename State"
    ed.rename_state(sid, "   ")
    assert ed.saved_states[0].name == "Best"
    undo(ed)
    assert ed.saved_states[0].name == "State 1"
    paint(ed, 0, 0, 0, 0)
    before = ed.plate
    ed.delete_state(sid)
    assert ed.saved_states == () and ed.plate == before and "Deleted State 1." in seen[-1]
    undo(ed)
    assert len(ed.saved_states) == 1


# ---------------------------------------------------------------- matching bookmark


def test_bookmark_fills_on_save_clears_on_edit_and_refills_on_revert(ed):
    assert not ed.current_design_is_saved
    ed.save_state()
    assert ed.current_design_is_saved
    paint(ed, 0, 0, 0, 0)
    assert not ed.current_design_is_saved
    ed.revert_to_latest_state()
    assert ed.current_design_is_saved


def test_bookmark_tracks_undo_and_redo_and_deletion(ed):
    ed.save_state()
    paint(ed, 0, 0, 0, 0)
    undo(ed)
    assert ed.current_design_is_saved
    redo(ed)
    assert not ed.current_design_is_saved
    undo(ed)
    ed.delete_state(ed.saved_states[0].id)
    assert not ed.current_design_is_saved


def test_display_only_changes_do_not_break_the_match(ed):
    ed.save_state()
    ed.set_well_label_mode(WellLabelMode.allFactors)
    ed.set_pad_well_labels(True)
    ed.rotate_plate()
    assert ed.current_design_is_saved


# ---------------------------------------------------------------- structural


def test_revert_across_format_change_and_factor_deletion_leaves_the_editor_valid(ed):
    ed.add_factor()
    paint(ed, 0, 0, 0, 0)
    ed.save_state()
    ed.set_format(PlateFormat(2, 3))
    ed.delete_factor(ed.layout.factors[1].id)
    ed.select(rect(1, 2, 1, 2))
    ed.revert_to_latest_state()
    assert ed.plate.format == WELL96 and ed.layout.factor(ed.active_factor_id) is not None
    assert ed.layout.plate(ed.active_plate_id) is not None
    assert ed.selection == rect(1, 2, 1, 2)


def test_reverting_one_plate_keeps_what_the_rest_of_the_document_gained(ed):
    paint(ed, 0, 0, 0, 0)
    ed.save_state()
    ed.add_plate()
    ed.add_factor()
    paint(ed, 0, 0, 0, 0)          # new factor on plate 2
    ed.set_active_plate(ed.layout.plates[0].id)
    paint(ed, 1, 1, 1, 1)
    ed.revert_to_latest_state()
    assert len(ed.layout.plates) == 2 and len(ed.layout.factors) == 2
    p2 = ed.layout.plates[1]
    assert p2.level_id(ed.layout.factors[1].id, 0) is not None


def test_reverting_puts_back_a_level_that_was_deleted_since(ed):
    paint(ed, 0, 0, 0, 0, 2)          # Treated
    ed.save_state()
    treated = ed.active_factor.levels[2]
    ed.delete_level(treated.id)
    assert ed.plate.level_id(ed.active_factor.id, 0) is None
    ed.revert_to_latest_state()
    assert ed.active_factor.level(treated.id) == treated
    assert ed.plate.level_id(ed.active_factor.id, 0) == treated.id


def test_revert_does_not_rearm_a_disarmed_level_but_replaces_a_stale_one(ed):
    ed.save_state()
    paint(ed, 0, 0, 0, 0)
    ed.disarm_level()
    ed.revert_to_latest_state()
    assert ed.armed_level_id is None
    ed.add_level()                       # armed := Condition 4 (not in the state's factor list...)
    ed.save_state()
    stale = ed.armed_level_id
    ed.delete_level(stale.__str__())     # gone from the document
    ed.revert_to_state(ed.saved_states[0].id)   # the first state's factors do not have it
    assert ed.armed_level_id is not None and ed.active_factor.level(ed.armed_level_id) is not None


# ---------------------------------------------------------------- per plate


def test_each_plate_sees_only_its_own_states_numbered_within_the_plate(ed):
    ed.save_state()
    ed.add_plate()
    assert ed.saved_states == ()
    ed.save_state()
    assert [s.name for s in ed.saved_states] == ["State 1"]
    ed.set_active_plate(ed.layout.plates[0].id)
    assert [s.name for s in ed.saved_states] == ["State 1"]
    assert all(len(s.plates) == 1 and s.plates[0].id == s.plate_id for s in ed.layout.snapshots)


def test_reverting_one_plate_leaves_the_other_byte_identical(ed):
    ed.add_plate()
    other_before = ed.layout.plates[0]
    ed.save_state()
    paint(ed, 0, 0, 0, 0)
    ed.revert_to_latest_state()
    assert ed.layout.plates[0] == other_before


def test_bookmark_follows_the_selected_plate_without_a_document_change(ed):
    ed.save_state()
    ed.add_plate()
    assert not ed.current_design_is_saved
    ed.set_active_plate(ed.layout.plates[0].id)
    assert ed.current_design_is_saved


def test_the_same_layout_on_a_different_plate_still_saves(ed):
    ed.save_state()
    ed.add_plate()
    ed.save_state()
    assert len(ed.layout.snapshots) == 2


def test_revert_to_latest_means_this_plates_latest(ed):
    seen = flashes(ed)
    paint(ed, 0, 0, 0, 0)
    ed.save_state()
    ed.add_plate()
    ed.revert_to_latest_state()
    assert seen[-1] == "No saved states for Plate yet — use the bookmark button first."


def test_legacy_single_plate_snapshot_is_adopted_and_multi_plate_stays_global(tmp_path):
    starter = Layout.starter()
    legacy_one = LayoutSnapshot(name="Old", plate_id=None, factors=starter.factors, plates=starter.plates)
    layout = loads(dumps(replace(starter, snapshots=(legacy_one,))))
    editor = make_editor(tmp_path, layout)
    assert editor.saved_states[0].plate_id == editor.plate.id
    two = replace(starter, plates=starter.plates + (replace(starter.plates[0], id="AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", name="P2"),))
    legacy_two = LayoutSnapshot(name="Old", plate_id=None, factors=two.factors, plates=two.plates)
    layout2 = loads(dumps(replace(two, snapshots=(legacy_two,))))
    editor2 = make_editor(tmp_path, layout2)
    assert editor2.saved_states[0].plate_id is None
    editor2.set_active_plate(layout2.plates[1].id)
    assert len(editor2.saved_states) == 1
    assert "whole document, 2 plates" in editor2.subtitle_for(editor2.saved_states[0])


def test_subtitle_and_title(ed):
    paint(ed, 0, 0, 0, 1)
    ed.save_state()
    s = ed.saved_states[0]
    assert ed.subtitle_for(s).startswith("Saved ") and ed.subtitle_for(s).endswith("  ·  96-well  ·  2 wells filled")
    assert ed.title_for(s).startswith("State 1  ·  ")
