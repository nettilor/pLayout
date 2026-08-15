"""The `.plate` compatibility contract — ports of LayoutCompatibilityTests, SavedStateTests'
persistence cases, PerPlateStateTests' legacy-adoption cases, NotesTests' decode cases and
OrientationTests' file cases, plus the round-trip of every real Mac-written fixture.

Every rule here is one the Mac app enforces or tolerates; see PORT.md §"Compatibility contract".
"""
import json

import pytest

from playout.model.layout import (
    APPLE_EPOCH,
    Factor,
    Layout,
    LayoutDecodeError,
    LayoutSnapshot,
    Level,
    Plate,
    PlateOrientation,
    WellLabelMode,
    dumps,
    loads,
    new_id,
)
from playout.model.plate_format import WELL96, PlateFormat

MAC_FIXTURES = ("allfactors.plate", "overview.plate", "big384.plate")

F1 = "11111111-1111-1111-1111-111111111111"
L1 = "22222222-2222-2222-2222-222222222222"
L2 = "33333333-3333-3333-3333-333333333333"
P1 = "44444444-4444-4444-4444-444444444444"


def minimal_doc(**overrides):
    doc = {
        "factors": [
            {
                "id": F1, "kind": "categorical", "name": "Condition", "unit": "",
                "levels": [
                    {"colorHex": "#5889BC", "id": L1, "name": "Untreated"},
                    {"colorHex": "#F28E2B", "id": L2, "name": "Treated"},
                ],
            }
        ],
        "formatVersion": 1,
        "notes": "",
        "orientation": "automatic",
        "padWellLabels": False,
        "plates": [
            {
                "assignments": {F1: [L1, L2, None, None, None, None]},
                "format": {"cols": 3, "rows": 2},
                "id": P1, "name": "Plate 1", "note": "",
                "wellNotes": {"1": "bubble"},
            }
        ],
        "snapshots": [],
        "wellLabelMode": "activeFactor",
    }
    doc.update(overrides)
    return doc


# ---------------------------------------------------------------- real Mac files


@pytest.mark.parametrize("name", MAC_FIXTURES)
def test_every_mac_fixture_opens_and_round_trips_value_exactly(fixtures_dir, name):
    text = (fixtures_dir / name).read_text(encoding="utf-8")
    layout = loads(text)
    assert layout.plates and layout.factors
    again = loads(dumps(layout))
    assert again == layout


@pytest.mark.parametrize("name", MAC_FIXTURES)
def test_re_encoding_a_mac_file_only_adds_the_defaults_it_predates(fixtures_dir, name):
    """The JSON we write differs from a Mac file only where the file predates a field
    (note/wellNotes/orientation) — exactly what the Mac would add on its own re-save."""
    original = json.loads((fixtures_dir / name).read_text(encoding="utf-8"))
    ours = json.loads(dumps(loads(json.dumps(original))))
    defaults_layout = {"orientation": "automatic", "notes": "", "snapshots": [], "padWellLabels": False}
    for key, value in defaults_layout.items():
        original.setdefault(key, value)
    for plate in original["plates"]:
        plate.setdefault("note", "")
        plate.setdefault("wellNotes", {})
        plate.setdefault("assignments", {})
    for snap in original["snapshots"]:
        for plate in snap["plates"]:
            plate.setdefault("note", "")
            plate.setdefault("wellNotes", {})
    assert ours == original


def test_written_json_has_the_mac_shape():
    text = dumps(loads(json.dumps(minimal_doc())))
    assert text.startswith('{\n  "factors" : [')          # 2-space indent, `"key" : value`, sorted keys
    assert '"wellLabelMode" : "activeFactor"' in text
    assert "µ" in dumps(Layout(factors=(Factor(name="Dose", unit="µM"),)))  # raw UTF-8, not \\u escapes


def test_ids_are_written_upper_case_and_read_case_insensitively():
    doc = minimal_doc()
    doc["factors"][0]["id"] = F1.lower()
    doc["factors"][0]["levels"][0]["id"] = L1.lower()
    doc["plates"][0]["id"] = P1.lower()
    layout = loads(json.dumps(doc))
    assert layout.factors[0].id == F1 and layout.factors[0].levels[0].id == L1 and layout.plates[0].id == P1
    nid = new_id()
    assert nid == nid.upper() and len(nid) == 36


def test_lower_case_assignment_keys_match_nothing_like_the_mac():
    """`Plate.assignments` is keyed by the raw upper-case string; a lower-case key decodes but
    is invisible — the plate looks unpainted. Values, though, are parsed case-insensitively."""
    fid, lid = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "FFFFFFFF-0000-4111-8222-333333333333"
    doc = minimal_doc()
    doc["factors"][0]["id"] = fid
    doc["factors"][0]["levels"][0]["id"] = lid
    doc["plates"][0]["assignments"] = {fid.lower(): [lid.lower(), None, None, None, None, None]}
    layout = loads(json.dumps(doc))
    plate = layout.plates[0]
    assert layout.factors[0].id == fid
    assert plate.level_id(fid, 0) is None                 # the upper-case key finds nothing
    assert plate.level_id(fid.lower(), 0) == lid          # values parse case-insensitively


# ---------------------------------------------------------------- Layout-level tolerance


def test_document_saved_before_the_new_fields_still_opens():
    layout = loads(json.dumps({"factors": [], "plates": []}))
    assert layout.well_label_mode is WellLabelMode.activeFactor
    assert layout.orientation is PlateOrientation.automatic
    assert layout.snapshots == () and layout.notes == "" and layout.pad_well_labels is False
    assert layout.format_version == 1


def test_an_empty_object_is_a_valid_empty_layout():
    assert loads("{}") == Layout()


def test_null_values_take_the_default_like_absent_keys():
    layout = loads(json.dumps(minimal_doc(orientation=None, notes=None, wellLabelMode=None, snapshots=None)))
    assert layout.orientation is PlateOrientation.automatic and layout.notes == ""
    assert layout.well_label_mode is WellLabelMode.activeFactor and layout.snapshots == ()


def test_unknown_label_mode_falls_back_instead_of_throwing():
    layout = loads(json.dumps(minimal_doc(wellLabelMode="holographic")))
    assert layout.well_label_mode is WellLabelMode.activeFactor


def test_unknown_orientation_refuses_to_open_like_the_mac():
    with pytest.raises(LayoutDecodeError):
        loads(json.dumps(minimal_doc(orientation="sideways")))


@pytest.mark.parametrize("mode", ["none", "activeFactor", "allFactors", "overview"])
def test_every_label_mode_round_trips(mode):
    layout = loads(json.dumps(minimal_doc(wellLabelMode=mode)))
    assert layout.well_label_mode.value == mode
    assert loads(dumps(layout)).well_label_mode.value == mode


@pytest.mark.parametrize("orientation", ["automatic", "upright", "turned"])
def test_every_orientation_round_trips(orientation):
    layout = loads(json.dumps(minimal_doc(orientation=orientation)))
    assert layout.orientation.value == orientation
    assert loads(dumps(layout)).orientation.value == orientation


@pytest.mark.parametrize(
    "extra, expected",
    [
        ({"transposedView": True}, "turned"),
        ({"transposedView": False}, "automatic"),
        ({"quarterTurns": 0}, "automatic"),
        ({"quarterTurns": 1}, "turned"),
        ({"quarterTurns": 3}, "turned"),
        ({"transposedView": True, "orientation": "upright"}, "upright"),  # explicit key wins
    ],
)
def test_retired_orientation_keys_are_still_honoured(extra, expected):
    doc = minimal_doc()
    del doc["orientation"]
    doc.update(extra)
    layout = loads(json.dumps(doc))
    assert layout.orientation.value == expected
    assert "transposedView" not in dumps(layout) and "quarterTurns" not in dumps(layout)


def test_unknown_keys_at_every_level_are_ignored_and_not_preserved():
    doc = minimal_doc(bogus="x")
    doc["factors"][0]["bogus"] = 1
    doc["factors"][0]["levels"][0]["bogus"] = [1, 2]
    doc["plates"][0]["bogus"] = {"a": 1}
    doc["plates"][0]["format"]["bogus"] = True
    doc["snapshots"] = [{"id": new_id(), "name": "S", "savedAt": 0, "factors": [], "plates": [], "bogus": 3}]
    layout = loads(json.dumps(doc))
    assert "bogus" not in dumps(layout)
    assert layout == loads(dumps(layout))


def test_wrong_typed_layout_values_are_decode_errors():
    for bad in (dict(padWellLabels="yes"), dict(notes=5), dict(factors={}), dict(formatVersion=1.5)):
        with pytest.raises(LayoutDecodeError):
            loads(json.dumps(minimal_doc(**bad)))


def test_format_version_is_read_but_never_a_gate():
    assert loads(json.dumps(minimal_doc(formatVersion=99))).format_version == 99


# ---------------------------------------------------------------- Factor / Level / Plate strictness


@pytest.mark.parametrize("missing", ["id", "name", "kind", "unit", "levels"])
def test_factor_requires_every_key(missing):
    doc = minimal_doc()
    del doc["factors"][0][missing]
    with pytest.raises(LayoutDecodeError):
        loads(json.dumps(doc))


@pytest.mark.parametrize("missing", ["id", "name", "colorHex"])
def test_level_requires_every_key(missing):
    doc = minimal_doc()
    del doc["factors"][0]["levels"][0][missing]
    with pytest.raises(LayoutDecodeError):
        loads(json.dumps(doc))


def test_unknown_factor_kind_is_an_error():
    doc = minimal_doc()
    doc["factors"][0]["kind"] = "ordinal"
    with pytest.raises(LayoutDecodeError):
        loads(json.dumps(doc))


@pytest.mark.parametrize("missing", ["id", "name", "format"])
def test_plate_requires_id_name_format(missing):
    doc = minimal_doc()
    del doc["plates"][0][missing]
    with pytest.raises(LayoutDecodeError):
        loads(json.dumps(doc))


def test_plate_saved_before_notes_still_decodes():
    doc = minimal_doc()
    del doc["plates"][0]["wellNotes"]
    del doc["plates"][0]["note"]
    plate = loads(json.dumps(doc)).plates[0]
    assert plate.well_notes == {} and plate.note == ""


def test_notes_round_trip_and_keys_are_well_indices_as_strings():
    doc = minimal_doc()
    doc["plates"][0]["note"] = "edge effects"
    doc["plates"][0]["wellNotes"] = {"0": "first", "5": "last"}
    layout = loads(json.dumps(doc))
    plate = layout.plates[0]
    assert plate.note == "edge effects" and plate.note_for(0) == "first" and plate.note_for(5) == "last"
    assert plate.note_for(3) is None
    assert loads(dumps(layout)) == layout


def test_decoding_clamps_an_impossible_plate_size():
    doc = minimal_doc()
    doc["plates"][0]["format"] = {"rows": 0, "cols": 5000}
    doc["plates"][0]["assignments"] = {}
    assert loads(json.dumps(doc)).plates[0].format == PlateFormat(1, 96)


def test_custom_formats_round_trip_through_a_document():
    for rows, cols in ((5, 7), (1, 8), (1, 1), (64, 96)):
        layout = Layout(plates=(Plate(name="P", format=PlateFormat(rows, cols)),))
        again = loads(dumps(layout))
        assert again.plates[0].format == PlateFormat(rows, cols)
        assert again.plates[0].format.well_count == rows * cols


def test_decoding_normalises_mismatched_assignment_columns():
    doc = minimal_doc()
    doc["plates"][0]["assignments"] = {F1: [L1, L2]}                          # too short → padded
    short = loads(json.dumps(doc)).plates[0]
    assert short.assignments[F1] == (L1, L2, None, None, None, None)
    doc["plates"][0]["assignments"] = {F1: [L1] + [None] * 10}                # too long → truncated
    long_ = loads(json.dumps(doc)).plates[0]
    assert long_.assignments[F1] == (L1, None, None, None, None, None)


def test_an_all_null_column_is_kept_when_correctly_sized_and_dropped_when_resized():
    """The Mac only prunes a column it had to resize; a well-formed all-null column survives
    decode (it is pruned the first time a well in it is written)."""
    doc = minimal_doc()
    doc["plates"][0]["assignments"] = {F1: [None] * 6}
    assert loads(json.dumps(doc)).plates[0].assignments == {F1: (None,) * 6}
    doc["plates"][0]["assignments"] = {F1: [None] * 4}
    assert loads(json.dumps(doc)).plates[0].assignments == {}


def test_a_lossy_normalisation_means_resave_is_not_byte_identical():
    doc = minimal_doc()
    doc["plates"][0]["assignments"] = {F1: [L1, L2]}
    text = json.dumps(doc)
    assert json.loads(dumps(loads(text))) != json.loads(text)


# ---------------------------------------------------------------- snapshots


def snapshot_doc(plate_id=P1, plates=None, plateID_present=True):
    doc = minimal_doc()
    snap = {
        "factors": doc["factors"],
        "id": new_id(),
        "name": "State 1",
        "plates": plates if plates is not None else [doc["plates"][0]],
        "savedAt": 807762329.387518,
    }
    if plateID_present:
        snap["plateID"] = plate_id
    doc["snapshots"] = [snap]
    return doc


def test_snapshots_round_trip_and_do_not_nest():
    layout = loads(json.dumps(snapshot_doc()))
    assert len(layout.snapshots) == 1
    text = dumps(layout)
    assert text.count('"snapshots"') == 1
    assert loads(text) == layout
    assert layout.snapshots[0].saved_at == 807762329.387518
    assert '"savedAt" : 807762329.387518' in text


def test_saved_at_is_apple_epoch_seconds():
    snap = loads(json.dumps(snapshot_doc())).snapshots[0]
    when = snap.saved_at_datetime()
    assert when.year == 2026 and when.month == 8
    assert LayoutSnapshot.apple_seconds(when) == pytest.approx(807762329.387518, abs=1e-6)
    assert LayoutSnapshot().saved_at == -APPLE_EPOCH  # the Unix epoch, as the Mac decodes an absent date


def test_a_legacy_single_plate_snapshot_is_adopted_by_that_plate():
    snap = loads(json.dumps(snapshot_doc(plateID_present=False))).snapshots[0]
    assert snap.plate_id == P1
    assert snap.belongs_to(P1) and not snap.belongs_to(new_id())


def test_a_legacy_multi_plate_snapshot_belongs_to_every_plate():
    doc = minimal_doc()
    other = dict(doc["plates"][0], id=new_id(), name="Plate 2")
    doc = snapshot_doc(plates=[doc["plates"][0], other], plateID_present=False)
    snap = loads(json.dumps(doc)).snapshots[0]
    assert snap.plate_id is None
    assert snap.belongs_to(P1) and snap.belongs_to(new_id())
    assert "plateID" not in dumps(loads(json.dumps(doc)))  # encodeIfPresent: omitted when nil


def test_snapshot_defaults_when_keys_are_absent():
    doc = minimal_doc()
    doc["snapshots"] = [{}]
    snap = loads(json.dumps(doc)).snapshots[0]
    assert snap.name == "State" and snap.factors == () and snap.plates == () and snap.plate_id is None


def test_a_document_without_snapshots_still_opens():
    doc = minimal_doc()
    del doc["snapshots"]
    assert loads(json.dumps(doc)).snapshots == ()


# ---------------------------------------------------------------- misc


def test_document_json_round_trip_of_a_built_layout():
    layout = Layout(
        factors=(Factor(name="Dose", kind="numeric", unit="µM", levels=(Level("10", "#5889BC"),)),),
        plates=(Plate(name="P", format=WELL96).set_level_id("X", "F", 3),),
        pad_well_labels=True,
        well_label_mode=WellLabelMode.overview,
        orientation=PlateOrientation.turned,
        notes="hello",
    )
    assert loads(dumps(layout)) == layout


def test_pad_well_labels_and_units_round_trip():
    layout = loads(json.dumps(minimal_doc(padWellLabels=True)))
    assert layout.pad_well_labels is True
    doc = minimal_doc()
    doc["factors"][0]["unit"] = "µM"
    doc["factors"][0]["kind"] = "numeric"
    layout = loads(json.dumps(doc))
    assert layout.factors[0].display_name == "Condition (µM)"
    assert loads(dumps(layout)) == layout
