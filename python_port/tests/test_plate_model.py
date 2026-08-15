"""Model mutations — ports of CoreTests.PlateModelTests, the Layout halves of SavedStateTests /
PerPlateStateTests / NotesTests, and the naming helpers. Everything here is Qt-free."""
import pytest

from playout.model.layout import (
    MAX_SNAPSHOTS,
    Factor,
    Layout,
    LayoutSnapshot,
    Level,
    Plate,
    dumps,
    loads,
    new_id,
)
from playout.model.plate_format import WELL96, PlateFormat


def two_level_layout():
    f = Factor(name="Condition", levels=(Level("Untreated", "#5889BC"), Level("Treated", "#F28E2B")))
    return Layout(factors=(f,), plates=(Plate(name="Plate 1", format=WELL96),)), f


# ---------------------------------------------------------------- Plate assignments


def test_assignment_round_trip_and_column_pruning():
    layout, f = two_level_layout()
    lv = f.levels[0].id
    plate = layout.plates[0].set_level_id(lv, f.id, 5)
    assert plate.level_id(f.id, 5) == lv
    assert plate.level_id(f.id, 4) is None
    assert len(plate.assignments[f.id]) == 96
    cleared = plate.set_level_id(None, f.id, 5)
    assert f.id not in cleared.assignments            # the whole column goes when it empties
    assert cleared.set_level_id(None, f.id, 7) == cleared  # no-op stays value-equal


def test_set_level_id_ignores_out_of_range_wells_and_is_immutable():
    layout, f = two_level_layout()
    plate = layout.plates[0]
    assert plate.set_level_id(f.levels[0].id, f.id, 96) is plate
    assert plate.set_level_id(f.levels[0].id, f.id, -1) is plate
    painted = plate.set_level_id(f.levels[0].id, f.id, 0)
    assert plate.assignments == {} and painted is not plate


def test_batch_set_level_ids_touches_the_column_once():
    layout, f = two_level_layout()
    lv = f.levels[1].id
    plate = layout.plates[0].set_level_ids(f.id, {i: lv for i in range(12)})
    assert plate.assigned_well_count(f.id, lv) == 12
    assert plate.assigned_well_count(f.id, f.levels[0].id) == 0


def test_level_id_tolerates_garbage_values_like_the_mac():
    plate = Plate(name="P", format=PlateFormat(1, 2), assignments={"F": ("not-a-uuid", None)})
    assert plate.level_id("F", 0) is None
    assert plate.level_id("F", 1) is None
    assert plate.level_id("F", 2) is None


def test_format_change_keeps_row_and_column():
    layout, f = two_level_layout()
    lv = f.levels[0].id
    plate = layout.plates[0].set_level_id(lv, f.id, WELL96.index(1, 6))       # B7
    bigger = plate.change_format(PlateFormat(16, 24))
    assert bigger.level_id(f.id, PlateFormat(16, 24).index(1, 6)) == lv
    assert bigger.level_id(f.id, WELL96.index(1, 6)) is None
    assert plate.change_format(WELL96) is plate


def test_shrinking_detects_data_loss_and_then_discards():
    layout, f = two_level_layout()
    lv = f.levels[0].id
    plate = layout.plates[0].set_level_id(lv, f.id, WELL96.index(7, 11))      # H12
    small = PlateFormat(2, 3)
    assert plate.format_change_would_lose_data(small)
    assert not layout.plates[0].format_change_would_lose_data(small)          # nothing populated
    assert not plate.format_change_would_lose_data(PlateFormat(16, 24))       # growing never loses
    shrunk = plate.change_format(small)
    assert shrunk.assignments == {}


def test_notes_follow_their_well_through_a_resize_and_die_with_it():
    plate = Plate(name="P", format=WELL96).set_note("bubble", WELL96.index(1, 6)).set_note("edge", WELL96.index(7, 11))
    bigger = plate.change_format(PlateFormat(16, 24))
    assert bigger.note_for(PlateFormat(16, 24).index(1, 6)) == "bubble"
    smaller = plate.change_format(PlateFormat(2, 8))
    assert smaller.note_for(PlateFormat(2, 8).index(1, 6)) == "bubble"
    assert "edge" not in smaller.well_notes.values()


def test_setting_an_empty_note_deletes_the_entry():
    plate = Plate(name="P", format=WELL96).set_note("  hello \n", 3)
    assert plate.note_for(3) == "hello"
    assert plate.set_note("   \n", 3).well_notes == {}
    assert plate.set_note("x", 96) is plate  # out of range ignored


# ---------------------------------------------------------------- Factor / Layout


def test_ensure_level_is_case_insensitive_and_stable():
    f = Factor(name="Drug", levels=(Level("DMSO", "#5889BC"),))
    same, lid = f.ensure_level("  dmso ")
    assert same is f and lid == f.levels[0].id
    grown, new = f.ensure_level(" Cisplatin ", "#000000")
    assert len(grown.levels) == 2 and grown.levels[1].name == "Cisplatin" and grown.levels[1].id == new
    assert grown.levels[1].color_hex == "#000000"


def test_ensure_level_default_colour_follows_the_palette_index():
    from playout.model.palette import color_at

    f = Factor(name="Drug", levels=(Level("A", "#000000"), Level("B", "#000000")))
    grown, _ = f.ensure_level("C")
    assert grown.levels[2].color_hex == color_at(2)


def test_remove_level_clears_wells_everywhere_and_leaves_siblings():
    layout, f = two_level_layout()
    a, b = f.levels[0].id, f.levels[1].id
    p2 = Plate(name="Plate 2", format=WELL96)
    layout = Layout(factors=layout.factors, plates=(layout.plates[0], p2))
    layout = layout.with_plate(0, layout.plates[0].set_level_ids(f.id, {0: a, 1: b}))
    layout = layout.with_plate(1, layout.plates[1].set_level_ids(f.id, {5: a}))
    pruned = layout.remove_level(a, f.id)
    assert [lv.id for lv in pruned.factors[0].levels] == [b]
    assert pruned.plates[0].level_id(f.id, 0) is None and pruned.plates[0].level_id(f.id, 1) == b
    assert f.id not in pruned.plates[1].assignments  # emptied column removed


def test_remove_factor_drops_its_column_from_every_plate():
    layout, f = two_level_layout()
    layout = layout.with_plate(0, layout.plates[0].set_level_id(f.levels[0].id, f.id, 0))
    gone = layout.remove_factor(f.id)
    assert gone.factors == () and gone.plates[0].assignments == {}


def test_prune_unused_levels_drops_only_unreferenced_levels():
    layout, f = two_level_layout()
    layout = layout.with_plate(0, layout.plates[0].set_level_id(f.levels[1].id, f.id, 3))
    pruned = layout.prune_unused_levels(f.id)
    assert [lv.name for lv in pruned.factors[0].levels] == ["Treated"]
    assert pruned.prune_unused_levels(f.id) is pruned


def test_value_name_and_lookups():
    layout, f = two_level_layout()
    layout = layout.with_plate(0, layout.plates[0].set_level_id(f.levels[1].id, f.id, 3))
    assert layout.value_name(0, f, 3) == "Treated"
    assert layout.value_name(0, f, 4) is None
    assert layout.value_name(1, f, 3) is None
    assert layout.factor(f.id) == layout.factors[0] and layout.factor_index(f.id) == 0
    assert layout.factor(None) is None and layout.plate(layout.plates[0].id) is layout.plates[0]


def test_unique_names_are_case_insensitive_and_count_from_two():
    layout, _ = two_level_layout()
    assert layout.unique_factor_name("Factor") == "Factor"
    assert layout.unique_factor_name("condition") == "condition 2"
    assert layout.unique_plate_name("Plate") == "Plate"          # "Plate 1" does not collide with "Plate"
    assert layout.unique_plate_name("Plate 1") == "Plate 1 2"
    three = Layout(plates=(Plate(name="X"), Plate(name="x 2"), Plate(name="X 3")))
    assert three.unique_plate_name("x") == "x 4"


def test_starter_document():
    from playout.model.palette import color_at

    layout = Layout.starter()
    assert [f.name for f in layout.factors] == ["Condition"]
    assert [lv.name for lv in layout.factors[0].levels] == ["Untreated", "Vehicle", "Treated"]
    assert [lv.color_hex for lv in layout.factors[0].levels] == [color_at(0), color_at(1), color_at(2)]
    assert layout.plates[0].name == "Plate 1" and layout.plates[0].format == WELL96
    assert loads(dumps(layout)) == layout


def test_used_level_colors_normalises_and_can_exclude_a_factor():
    a = Factor(name="A", levels=(Level("x", "#5889bc"),))
    b = Factor(name="B", levels=(Level("y", "#F28E2B"),))
    layout = Layout(factors=(a, b))
    assert layout.used_level_colors() == {"#5889BC", "#F28E2B"}
    assert layout.used_level_colors(excluding=a.id) == {"#F28E2B"}


def test_layout_equality_is_by_value_and_cheap_on_shared_structure():
    layout, f = two_level_layout()
    edited = layout.with_plate(0, layout.plates[0].set_level_id(f.levels[0].id, f.id, 0))
    assert edited != layout
    assert edited.factors is layout.factors  # untouched sub-objects are shared
    assert edited.with_plate(0, layout.plates[0]) == layout


# ---------------------------------------------------------------- saved states (Layout half)


def painted(layout, f, wells, level_index=0):
    return layout.with_plate(0, layout.plates[0].set_level_ids(f.id, {w: f.levels[level_index].id for w in wells}))


def test_capture_snapshot_names_numbers_and_stores_one_plate_only():
    layout, f = two_level_layout()
    p2 = Plate(name="Plate 2", format=WELL96)
    layout = Layout(factors=layout.factors, plates=(layout.plates[0], p2))
    layout, dropped = layout.capture_snapshot(0.0, layout.plates[0].id)
    assert dropped == 0
    layout, _ = layout.capture_snapshot(1.0, layout.plates[0].id)
    layout, _ = layout.capture_snapshot(2.0, p2.id)
    names = [(s.name, s.plate_id) for s in layout.snapshots]
    assert names == [("State 1", layout.plates[0].id), ("State 2", layout.plates[0].id), ("State 1", p2.id)]
    assert all(len(s.plates) == 1 and s.plates[0].id == s.plate_id for s in layout.snapshots)
    assert [s.name for s in layout.snapshots_for(p2.id)] == ["State 1"]
    assert layout.capture_snapshot(3.0, new_id()) == (layout, 0)


def test_snapshot_numbering_skips_taken_names_within_the_plate():
    layout, _ = two_level_layout()
    pid = layout.plates[0].id
    layout, _ = layout.capture_snapshot(0.0, pid)
    layout = layout.rename_snapshot(layout.snapshots[0].id, "State 2")
    layout, _ = layout.capture_snapshot(1.0, pid)
    assert [s.name for s in layout.snapshots] == ["State 2", "State 3"]


def test_snapshot_cap_is_document_wide_and_drops_the_oldest():
    layout, _ = two_level_layout()
    pid = layout.plates[0].id
    for i in range(MAX_SNAPSHOTS):
        layout, dropped = layout.capture_snapshot(float(i), pid)
        assert dropped == 0
    layout, dropped = layout.capture_snapshot(99.0, pid)
    assert dropped == 1 and len(layout.snapshots) == MAX_SNAPSHOTS
    assert layout.snapshots[0].saved_at == 1.0


def test_restore_puts_the_plate_back_and_leaves_display_settings_and_states_alone():
    layout, f = two_level_layout()
    pid = layout.plates[0].id
    layout = painted(layout, f, [0, 1, 2])
    saved, _ = layout.capture_snapshot(0.0, pid)
    later = painted(saved, f, [3, 4], level_index=1)
    from playout.model.layout import WellLabelMode
    from dataclasses import replace

    later = replace(later, well_label_mode=WellLabelMode.overview, pad_well_labels=True)
    restored, ok = later.restore_snapshot(saved.snapshots[0].id)
    assert ok
    assert restored.plates[0] == saved.plates[0]
    assert restored.well_label_mode is WellLabelMode.overview and restored.pad_well_labels is True
    assert restored.snapshots == later.snapshots
    assert later.restore_snapshot(new_id()) == (later, False)


def test_reverting_reinstates_lost_levels_and_factors_but_never_removes():
    layout, f = two_level_layout()
    pid = layout.plates[0].id
    layout = painted(layout, f, [0], level_index=1)
    saved, _ = layout.capture_snapshot(0.0, pid)
    # Since then: level "Treated" deleted, a new factor added, an extra level added.
    later = saved.remove_level(f.levels[1].id, f.id)
    extra = Factor(name="Extra", levels=(Level("e", "#000000"),))
    from dataclasses import replace

    later = replace(later, factors=later.factors + (extra,))
    later = later.with_factor(0, later.factors[0].with_levels(later.factors[0].levels + (Level("New", "#111111"),)))
    restored, ok = later.restore_snapshot(saved.snapshots[0].id)
    assert ok
    names = [lv.name for lv in restored.factors[0].levels]
    assert "Treated" in names and "New" in names          # deleted level back, added level kept
    assert restored.factors[-1].name == "Extra"            # factor added since survives
    assert restored.plates[0].level_id(f.id, 0) == f.levels[1].id


def test_reverting_a_deleted_plate_appends_it_back():
    layout, f = two_level_layout()
    p2 = Plate(name="Plate 2", format=WELL96)
    layout = Layout(factors=layout.factors, plates=(layout.plates[0], p2))
    saved, _ = layout.capture_snapshot(0.0, p2.id)
    from dataclasses import replace

    without = replace(saved, plates=(saved.plates[0],))
    restored, ok = without.restore_snapshot(saved.snapshots[0].id)
    assert ok and [p.id for p in restored.plates] == [saved.plates[0].id, p2.id]


def test_legacy_whole_document_snapshot_replaces_every_plate():
    layout, f = two_level_layout()
    old_plates = layout.plates
    legacy = LayoutSnapshot(name="Old", plate_id=None, factors=layout.factors, plates=old_plates)
    from dataclasses import replace

    layout = replace(layout, snapshots=(legacy,))
    changed = replace(layout, plates=(Plate(name="Other"),))
    restored, ok = changed.restore_snapshot(legacy.id)
    assert ok and restored.plates == old_plates


def test_snapshot_matching_compares_the_plate_only_and_prefers_the_newest():
    layout, f = two_level_layout()
    pid = layout.plates[0].id
    layout = painted(layout, f, [0])
    layout, _ = layout.capture_snapshot(0.0, pid)
    layout, _ = layout.capture_snapshot(1.0, pid)   # same design saved twice → newest wins
    assert layout.snapshot_matching(pid) is layout.snapshots[-1]
    renamed = layout.with_factor(0, Factor(name="Renamed", levels=f.levels, id=f.id))
    assert renamed.snapshot_matching(pid) is not None    # factors are not compared
    edited = painted(layout, f, [1])
    assert edited.snapshot_matching(pid) is None
    assert layout.snapshot_matching(None) is None and layout.snapshot_matching(new_id()) is None


def test_rename_and_remove_snapshot():
    layout, _ = two_level_layout()
    layout, _ = layout.capture_snapshot(0.0, layout.plates[0].id)
    sid = layout.snapshots[0].id
    assert layout.rename_snapshot(sid, "   ") is layout
    assert layout.rename_snapshot(sid, "  Best  ").snapshots[0].name == "Best"
    assert layout.remove_snapshot(sid).snapshots == ()
    assert layout.remove_snapshot(new_id()) is layout
