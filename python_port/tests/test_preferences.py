"""Preferences — port of the storage/reset/lenient parts of `PreferencesTests.swift`,
plus the Ini string-coercion trap (PORT.md pitfall 6). Every test uses a QSettings on
a temp Ini file, never the real user profile."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest
from PySide6.QtCore import QSettings

from playout.model.preferences import (
    FONT_SCALE_RANGE,
    ActiveMarkerStyle,
    NewConditionColors,
    Preferences,
    WellShape,
    WellTextStyle,
)


@pytest.fixture
def ini(tmp_path: Path) -> Path:
    return tmp_path / "prefs.ini"


@pytest.fixture
def settings(ini: Path) -> QSettings:
    return QSettings(str(ini), QSettings.Format.IniFormat)


@pytest.fixture
def prefs(settings: QSettings) -> Preferences:
    return Preferences(settings)


def reopened(settings: QSettings) -> Preferences:
    """A second Preferences over the same settings object — what a relaunch sees."""
    return Preferences(settings)


def reloaded_from_disk(ini: Path) -> Preferences:
    """Qt shares one in-process cache per file path, so a fresh QSettings on the *same*
    path still hands back typed values. Copying the file to a new path forces a real
    parse from disk — the string-typed world a relaunch lives in."""
    copy = ini.with_name(ini.stem + "-copy.ini")
    shutil.copy(ini, copy)
    return Preferences(QSettings(str(copy), QSettings.Format.IniFormat))


class Counter:
    def __init__(self, signal) -> None:
        self.count = 0
        signal.connect(self._bump)

    def _bump(self) -> None:
        self.count += 1


# -- enums ------------------------------------------------------------------------------


def test_choice_enums_carry_raw_label_note_and_lenient_decoding():
    assert [c.raw for c in WellTextStyle] == ["automatic", "alwaysBlack", "alwaysWhite"]
    assert [c.raw for c in ActiveMarkerStyle] == ["matchLabel", "deeperShade"]
    assert [c.raw for c in WellShape] == ["round", "square"]
    assert [c.raw for c in NewConditionColors] == ["perFactor", "neverRepeat"]

    assert WellTextStyle.automatic.label == "Match the well"
    assert WellTextStyle.alwaysBlack.note.startswith("One colour everywhere.")
    assert ActiveMarkerStyle.deeperShade.label == "Darker shade of the well"
    assert WellShape.square.note == "More room for text, and what the stacking modes fall back to anyway."
    assert NewConditionColors.neverRepeat.label == "Never repeat a colour"
    for cls in (WellTextStyle, ActiveMarkerStyle, WellShape, NewConditionColors):
        for member in cls:
            assert member.label and member.note

    assert WellTextStyle.lenient("alwaysWhite") is WellTextStyle.alwaysWhite
    assert WellTextStyle.lenient("iridescent") is WellTextStyle.automatic
    assert WellTextStyle.lenient(None) is WellTextStyle.automatic
    assert ActiveMarkerStyle.lenient("engraved") is ActiveMarkerStyle.matchLabel
    assert WellShape.lenient("hexagonal") is WellShape.round
    assert NewConditionColors.lenient("") is NewConditionColors.perFactor
    assert WellShape.round.is_round and not WellShape.square.is_round
    assert WellTextStyle.alwaysWhite.prefers_dark_neutral
    assert not WellTextStyle.automatic.prefers_dark_neutral


# -- storage ----------------------------------------------------------------------------


def test_defaults_are_the_automatic_ones(prefs: Preferences):
    assert prefs.well_text_style is WellTextStyle.automatic
    assert prefs.active_marker_style is ActiveMarkerStyle.matchLabel
    assert prefs.new_document_well_shape is WellShape.round
    assert prefs.new_condition_colors is NewConditionColors.perFactor
    assert prefs.empty_well_color_hex is None
    assert prefs.canvas_font_family is None
    assert prefs.canvas_font_scale == 1.0
    assert prefs.show_factor_condition_counts is False
    assert prefs.check_for_updates_automatically is True
    assert prefs.workbook_sheet_layout == "sheetPerFactor"
    assert prefs.workbook_scope == "allPlates"
    assert prefs.workbook_joint_map_enabled is False
    assert prefs.workbook_joint_map_separator == ""


def test_factor_condition_counts_remember_and_reset(prefs: Preferences, settings: QSettings):
    prefs.show_factor_condition_counts = True
    assert reopened(settings).show_factor_condition_counts is True

    prefs.reset_to_defaults()
    assert prefs.show_factor_condition_counts is False
    assert reopened(settings).show_factor_condition_counts is False


def test_the_well_shape_default_is_remembered_and_readable(prefs: Preferences, settings: QSettings):
    prefs.new_document_well_shape = WellShape.square
    assert not prefs.new_document_well_shape.is_round
    assert reopened(settings).new_document_well_shape is WellShape.square

    settings.setValue("newDocumentWellShape", "hexagonal")
    assert reopened(settings).new_document_well_shape is WellShape.round


def test_choices_survive_a_relaunch(prefs: Preferences, settings: QSettings, ini: Path):
    prefs.well_text_style = WellTextStyle.alwaysWhite
    prefs.active_marker_style = ActiveMarkerStyle.deeperShade
    prefs.new_condition_colors = NewConditionColors.neverRepeat

    again = reopened(settings)
    assert again.well_text_style is WellTextStyle.alwaysWhite
    assert again.active_marker_style is ActiveMarkerStyle.deeperShade
    assert again.new_condition_colors is NewConditionColors.neverRepeat

    from_disk = reloaded_from_disk(ini)
    assert from_disk.well_text_style is WellTextStyle.alwaysWhite
    assert from_disk.active_marker_style is ActiveMarkerStyle.deeperShade
    assert from_disk.new_condition_colors is NewConditionColors.neverRepeat


def test_setters_accept_raw_strings_too(prefs: Preferences):
    prefs.well_text_style = "alwaysBlack"
    assert prefs.well_text_style is WellTextStyle.alwaysBlack
    prefs.well_text_style = "nonsense"
    assert prefs.well_text_style is WellTextStyle.automatic


def test_an_unknown_stored_value_falls_back(settings: QSettings):
    settings.setValue("wellTextStyle", "iridescent")
    settings.setValue("activeMarkerStyle", "engraved")
    settings.setValue("newConditionColors", "rainbow")
    settings.setValue("workbookSheetLayout", "origami")
    settings.setValue("workbookScope", "everything")
    prefs = Preferences(settings)
    assert prefs.well_text_style is WellTextStyle.automatic
    assert prefs.active_marker_style is ActiveMarkerStyle.matchLabel
    assert prefs.new_condition_colors is NewConditionColors.perFactor
    assert prefs.workbook_sheet_layout == "sheetPerFactor"
    assert prefs.workbook_scope == "allPlates"


def test_restore_defaults_puts_everything_back_and_emits_once(prefs: Preferences, settings: QSettings):
    prefs.well_text_style = WellTextStyle.alwaysBlack
    prefs.active_marker_style = ActiveMarkerStyle.deeperShade
    prefs.new_document_well_shape = WellShape.square
    prefs.new_condition_colors = NewConditionColors.neverRepeat
    prefs.empty_well_color_hex = "#EEF2D8"
    prefs.canvas_font_family = "Georgia"
    prefs.canvas_font_scale = 1.3
    prefs.show_factor_condition_counts = True
    prefs.check_for_updates_automatically = False

    counter = Counter(prefs.changed)
    prefs.reset_to_defaults()
    assert counter.count == 1

    for p in (prefs, reopened(settings)):
        assert p.well_text_style is WellTextStyle.automatic
        assert p.active_marker_style is ActiveMarkerStyle.matchLabel
        assert p.new_document_well_shape is WellShape.round
        assert p.new_condition_colors is NewConditionColors.perFactor
        assert p.empty_well_color_hex is None
        assert p.canvas_font_family is None
        assert p.canvas_font_scale == 1.0
        assert p.show_factor_condition_counts is False
        assert p.check_for_updates_automatically is True
    for key in Preferences.DISPLAY_KEYS:
        assert not settings.contains(key), f"{key} was left behind"

    # Nothing to put back → nothing to announce.
    prefs.reset_to_defaults()
    assert counter.count == 1


def test_restore_defaults_leaves_the_workbook_choices_alone(prefs: Preferences):
    prefs.workbook_sheet_layout = "allFactorsOneSheet"
    prefs.workbook_scope = "activePlate"
    prefs.workbook_joint_map_enabled = True
    prefs.workbook_joint_map_separator = " / "
    prefs.reset_to_defaults()
    assert prefs.workbook_sheet_layout == "allFactorsOneSheet"
    assert prefs.workbook_scope == "activePlate"
    assert prefs.workbook_joint_map_enabled is True
    assert prefs.workbook_joint_map_separator == " / "


# -- empty well colour ------------------------------------------------------------------


def test_empty_well_colour_remembers_resets_and_shrugs_off_garbage(prefs: Preferences, settings: QSettings):
    assert prefs.empty_well_color_hex is None

    prefs.empty_well_color_hex = "#EEF2D8"
    assert prefs.empty_well_color_hex == "#EEF2D8"
    assert reopened(settings).empty_well_color_hex == "#EEF2D8"

    settings.setValue("emptyWellColorHex", "chartreuse")
    assert reopened(settings).empty_well_color_hex is None
    settings.setValue("emptyWellColorHex", "#12345")
    assert reopened(settings).empty_well_color_hex is None

    prefs.empty_well_color_hex = "#EEF2D8"
    prefs.reset_to_defaults()
    assert prefs.empty_well_color_hex is None
    assert not settings.contains("emptyWellColorHex")

    prefs.empty_well_color_hex = "#ABCDEF"
    prefs.empty_well_color_hex = None
    assert not settings.contains("emptyWellColorHex")


# -- plate text -------------------------------------------------------------------------


def test_plate_font_remembers_clamps_and_resets(prefs: Preferences, settings: QSettings):
    assert prefs.canvas_font_family is None
    assert prefs.canvas_font_scale == 1.0

    prefs.canvas_font_family = "Georgia"
    prefs.canvas_font_scale = 1.3
    again = reopened(settings)
    assert again.canvas_font_family == "Georgia"
    assert again.canvas_font_scale == pytest.approx(1.3)

    lo, hi = FONT_SCALE_RANGE
    settings.setValue("canvasFontScale", 9.0)
    assert reopened(settings).canvas_font_scale == hi
    settings.setValue("canvasFontScale", 0.01)
    assert reopened(settings).canvas_font_scale == lo
    settings.setValue("canvasFontScale", "not a number")
    assert reopened(settings).canvas_font_scale == 1.0

    settings.setValue("canvasFontFamily", "")
    assert reopened(settings).canvas_font_family is None

    prefs.reset_to_defaults()
    assert prefs.canvas_font_family is None
    assert prefs.canvas_font_scale == 1.0


# -- the Ini string trap ----------------------------------------------------------------


def test_bools_and_floats_survive_a_real_reload_as_strings(prefs: Preferences, ini: Path):
    prefs.show_factor_condition_counts = True
    prefs.check_for_updates_automatically = False
    prefs.canvas_font_scale = 1.3
    prefs.workbook_joint_map_enabled = True
    prefs.workbook_joint_map_separator = ", "

    from_disk = reloaded_from_disk(ini)
    # The raw values really are strings now — that is the trap the helpers exist for.
    raw = from_disk.settings
    assert raw.value("showFactorConditionCounts") == "true"
    assert raw.value("checkForUpdatesAutomatically") == "false"
    assert isinstance(raw.value("canvasFontScale"), str)

    assert from_disk.show_factor_condition_counts is True
    assert from_disk.check_for_updates_automatically is False
    assert from_disk.canvas_font_scale == pytest.approx(1.3)
    assert from_disk.workbook_joint_map_enabled is True
    assert from_disk.workbook_joint_map_separator == ", "


def test_hand_written_ini_strings_are_coerced(tmp_path: Path):
    ini = tmp_path / "hand.ini"
    ini.write_text(
        "[General]\n"
        "showFactorConditionCounts=true\n"
        "checkForUpdatesAutomatically=false\n"
        "canvasFontScale=1.5\n"
        "workbookJointMapEnabled=1\n"
        "wellTextStyle=alwaysWhite\n",
        encoding="utf-8",
    )
    prefs = Preferences(QSettings(str(ini), QSettings.Format.IniFormat))
    assert prefs.show_factor_condition_counts is True
    assert prefs.check_for_updates_automatically is False
    assert prefs.canvas_font_scale == 1.5
    assert prefs.workbook_joint_map_enabled is True
    assert prefs.well_text_style is WellTextStyle.alwaysWhite


# -- change notification ----------------------------------------------------------------


def test_changed_is_emitted_only_on_a_real_change(prefs: Preferences):
    counter = Counter(prefs.changed)

    prefs.well_text_style = WellTextStyle.automatic  # already the default
    prefs.show_factor_condition_counts = False
    prefs.canvas_font_scale = 1.0
    prefs.empty_well_color_hex = None
    prefs.workbook_scope = "allPlates"
    assert counter.count == 0

    prefs.well_text_style = WellTextStyle.alwaysBlack
    assert counter.count == 1
    prefs.well_text_style = WellTextStyle.alwaysBlack
    assert counter.count == 1
    prefs.well_text_style = "alwaysBlack"
    assert counter.count == 1

    prefs.canvas_font_scale = 1.3
    prefs.canvas_font_scale = 1.3
    assert counter.count == 2

    prefs.empty_well_color_hex = "#EEF2D8"
    prefs.empty_well_color_hex = "#EEF2D8"
    assert counter.count == 3
    prefs.empty_well_color_hex = None
    assert counter.count == 4

    prefs.workbook_joint_map_separator = "+"
    prefs.workbook_joint_map_separator = "+"
    assert counter.count == 5


def test_shared_is_a_lazy_singleton(monkeypatch, settings: QSettings):
    monkeypatch.setattr(Preferences, "_shared", None)
    monkeypatch.setattr("playout.model.preferences.default_settings", lambda: settings)
    first = Preferences.shared()
    assert first is Preferences.shared()
    assert first.settings is settings
