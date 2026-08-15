"""App-local display preferences (QSettings) — mirrors `Sources/PLayout/Model/Preferences.swift`. M1.

App-wide display settings, shared by every open document and remembered between
launches. Deliberately *not* part of `Layout`: this is how someone likes to look at a
plate, not a property of the experiment, and it must not travel in a `.plate` file to a
colleague who prefers otherwise.

Storage is `QSettings(IniFormat, UserScope, "nettilor", "pLayout")` — the same keys as
the Mac app's UserDefaults. Ini round-trips every value as a *string* once the file is
re-read from disk, so every getter goes through a coercion helper that accepts the
Python type or its string form. Values are read live from the settings object (no
in-memory copy), which is what makes "an unknown stored value falls back" hold at every
read and not only at launch.

QtCore only: the font factory and the empty-well fill resolver, which need QtGui, live
in the ui layer.
"""
from __future__ import annotations

import enum
import re
from typing import Any

from PySide6.QtCore import QObject, QSettings, Signal

# --------------------------------------------------------------------------------------
# Display choices — each is a radio group in the Settings window: a fixed set of options,
# each with a name and a sentence saying what choosing it costs.
# --------------------------------------------------------------------------------------


class _DisplayChoice(enum.Enum):
    """Shared shape: `.raw` is the Swift rawValue (what is stored), `.label`/`.note` are
    the Settings-window strings, `lenient(raw)` never raises."""

    @property
    def raw(self) -> str:
        return str(self.value)

    @property
    def label(self) -> str:
        return self._LABELS[self.value]  # type: ignore[attr-defined]

    @property
    def note(self) -> str:
        return self._NOTES[self.value]  # type: ignore[attr-defined]

    @classmethod
    def default(cls):
        return next(iter(cls))

    @classmethod
    def lenient(cls, raw: Any):
        """Decoded leniently, like the document's own display settings: a value written
        by a newer build falls back rather than refusing to launch."""
        if isinstance(raw, cls):
            return raw
        try:
            return cls(str(raw))
        except (ValueError, TypeError):
            return cls.default()


class WellTextStyle(_DisplayChoice):
    """How a well's label picks its colour.

    The default reads the well and chooses whichever of black or white is legible on
    it. That is the safe answer, but it means a plate can carry both — which reads as a
    glitch to some people rather than as contrast — so the choice is offered outright.
    """

    automatic = "automatic"
    alwaysBlack = "alwaysBlack"
    alwaysWhite = "alwaysWhite"

    @property
    def prefers_dark_neutral(self) -> bool:
        """Overview draws on a neutral tile with no colour to contrast against, so the
        tile follows the ink rather than the other way round: white text gets a dark tile."""
        return self is WellTextStyle.alwaysWhite


WellTextStyle._LABELS = {  # type: ignore[attr-defined]
    "automatic": "Match the well",
    "alwaysBlack": "Always black",
    "alwaysWhite": "Always white",
}
WellTextStyle._NOTES = {  # type: ignore[attr-defined]
    "automatic": "Black on light conditions, white on dark ones. Always legible, but a plate can carry both.",
    "alwaysBlack": "One colour everywhere. Every colour the palette offers is light enough to read it — a very dark colour picked from Custom… will not be.",
    "alwaysWhite": "One colour everywhere. Suits a dark palette; pale conditions and yellows will be hard to read.",
}


class ActiveMarkerStyle(_DisplayChoice):
    """How the marker on the active factor's line is filled.

    It exists because that rail always *is* the well's own colour — both come from the
    factor being painted — so left alone it is invisible. Two ways out: ignore the
    colour and use the label's ink, or keep the colour and take it far darker.
    """

    matchLabel = "matchLabel"
    deeperShade = "deeperShade"


ActiveMarkerStyle._LABELS = {  # type: ignore[attr-defined]
    "matchLabel": "Match the label",
    "deeperShade": "Darker shade of the well",
}
ActiveMarkerStyle._NOTES = {  # type: ignore[attr-defined]
    "matchLabel": "A plain marker in the same colour as the text, so the active line reads the same way on every condition.",
    "deeperShade": "Keeps the condition's own colour, taken far enough down to stand out against the well it sits on.",
}


class WellShape(_DisplayChoice):
    """The shape a new document draws its wells in. Only the starting point — the sidebar
    keeps its own toggle, so a single layout can differ without changing the default."""

    round = "round"
    square = "square"

    @property
    def is_round(self) -> bool:
        return self is WellShape.round


WellShape._LABELS = {  # type: ignore[attr-defined]
    "round": "Round",
    "square": "Square",
}
WellShape._NOTES = {  # type: ignore[attr-defined]
    "round": "Looks like a plate. Ignored while stacked labels are showing — those need the full width of the well.",
    "square": "More room for text, and what the stacking modes fall back to anyway.",
}


class NewConditionColors(_DisplayChoice):
    """Where a new condition's colour comes from.

    The default starts the palette over for every factor, so condition 1 is the same
    familiar blue everywhere — harmless while each factor colours only its own line of
    a well, but in the stacked label modes two factors sharing a hue put identical
    rails in one well. The alternative promises every condition in the document its
    own colour.
    """

    perFactor = "perFactor"
    neverRepeat = "neverRepeat"


NewConditionColors._LABELS = {  # type: ignore[attr-defined]
    "perFactor": "Start the palette over per factor",
    "neverRepeat": "Never repeat a colour",
}
NewConditionColors._NOTES = {  # type: ignore[attr-defined]
    "perFactor": "Every factor's first condition is the same familiar blue. Two factors can share a colour — they never paint the same line of a well.",
    "neverRepeat": "A new condition takes the first colour nothing else in the document is using: the twenty hues first, then lighter and darker takes of each.",
}


# Workbook export options (Swift keeps these beside the exporter in TableIO.swift; the
# port remembers them here because there is one QSettings). Stored and returned as their
# raw strings so this module does not depend on the io layer's enums.
WORKBOOK_SHEET_LAYOUTS: tuple[str, ...] = ("sheetPerFactor", "allFactorsOneSheet")
WORKBOOK_SCOPES: tuple[str, ...] = ("allPlates", "activePlate")

FONT_SCALE_RANGE: tuple[float, float] = (0.7, 1.8)

_HEX6 = re.compile(r"^#?[0-9A-Fa-f]{6}$")


# --------------------------------------------------------------------------------------
# Coercion — Ini hands back strings after a reload, the Python type before one.
# --------------------------------------------------------------------------------------


def _bool(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in ("true", "1", "yes", "on"):
        return True
    if text in ("false", "0", "no", "off"):
        return False
    return default


def _float(value: Any, default: float) -> float:
    if value is None or isinstance(value, bool):
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _str(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("utf-8", "replace")
    return str(value)


def _enum_raw(value: Any) -> Any:
    """A setter accepts the raw string or an enum member from anywhere (`.value`)."""
    if isinstance(value, enum.Enum):
        return value.value
    return value


def _valid_hex(text: str | None) -> str | None:
    """Garbage in the store behaves as "no opinion", not as a black well or a crash.
    Local six-hex-digit check on purpose — this module must not import the palette."""
    if text is None:
        return None
    return text if _HEX6.match(text.strip()) else None


def default_settings() -> QSettings:
    """The app's one settings file: `~/.config/nettilor/pLayout.ini` on macOS/Linux,
    `%APPDATA%\\nettilor\\pLayout.ini` on Windows. Ini rather than Native so it never
    touches the registry, nor the Mac app's own `com.nettilor.playout` domain."""
    return QSettings(QSettings.Format.IniFormat, QSettings.Scope.UserScope, "nettilor", "pLayout")


# --------------------------------------------------------------------------------------
# Preferences
# --------------------------------------------------------------------------------------


class Preferences(QObject):
    """App-wide display settings. `changed` fires after any real change so canvases
    repaint; a setter that writes back the value already stored emits nothing."""

    changed = Signal()

    # Keys — the Mac app's UserDefaults keys, verbatim.
    WELL_TEXT_STYLE_KEY = "wellTextStyle"
    ACTIVE_MARKER_STYLE_KEY = "activeMarkerStyle"
    WELL_SHAPE_KEY = "newDocumentWellShape"
    NEW_CONDITION_COLORS_KEY = "newConditionColors"
    EMPTY_WELL_COLOR_KEY = "emptyWellColorHex"
    CANVAS_FONT_FAMILY_KEY = "canvasFontFamily"
    CANVAS_FONT_SCALE_KEY = "canvasFontScale"
    FACTOR_CONDITION_COUNTS_KEY = "showFactorConditionCounts"
    CHECK_FOR_UPDATES_KEY = "checkForUpdatesAutomatically"
    WORKBOOK_SHEET_LAYOUT_KEY = "workbookSheetLayout"
    WORKBOOK_SCOPE_KEY = "workbookScope"
    WORKBOOK_JOINT_MAP_ENABLED_KEY = "workbookJointMapEnabled"
    WORKBOOK_JOINT_MAP_SEPARATOR_KEY = "workbookJointMapSeparator"

    # What "Restore Defaults" puts back — the Settings-window preferences, exactly the
    # set Swift's `resetToDefaults()` touches. The remembered workbook choices are export
    # panel state, not display taste, and are left alone.
    DISPLAY_KEYS: tuple[str, ...] = (
        WELL_TEXT_STYLE_KEY,
        ACTIVE_MARKER_STYLE_KEY,
        WELL_SHAPE_KEY,
        NEW_CONDITION_COLORS_KEY,
        EMPTY_WELL_COLOR_KEY,
        CANVAS_FONT_FAMILY_KEY,
        CANVAS_FONT_SCALE_KEY,
        FACTOR_CONDITION_COUNTS_KEY,
        CHECK_FOR_UPDATES_KEY,
    )

    _shared: "Preferences | None" = None

    def __init__(self, settings: QSettings | None = None, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._settings = settings if settings is not None else default_settings()

    @classmethod
    def shared(cls) -> "Preferences":
        """The app-wide instance over the real settings file (lazy)."""
        if cls._shared is None:
            cls._shared = cls()
        return cls._shared

    @property
    def settings(self) -> QSettings:
        return self._settings

    # -- storage plumbing ------------------------------------------------------------

    def _read(self, key: str) -> Any:
        return self._settings.value(key)

    def _write(self, key: str, value: Any) -> None:
        """Write (or remove for None), flush to disk, and announce a change only if the
        value as *read back* differs from what was there before."""
        before = self._snapshot()
        if value is None:
            self._settings.remove(key)
        else:
            self._settings.setValue(key, value)
        self._settings.sync()
        if self._snapshot() != before:
            self.changed.emit()

    def _snapshot(self) -> dict[str, Any]:
        return {
            "well_text_style": self.well_text_style,
            "active_marker_style": self.active_marker_style,
            "new_document_well_shape": self.new_document_well_shape,
            "new_condition_colors": self.new_condition_colors,
            "empty_well_color_hex": self.empty_well_color_hex,
            "canvas_font_family": self.canvas_font_family,
            "canvas_font_scale": self.canvas_font_scale,
            "show_factor_condition_counts": self.show_factor_condition_counts,
            "check_for_updates_automatically": self.check_for_updates_automatically,
            "workbook_sheet_layout": self.workbook_sheet_layout,
            "workbook_scope": self.workbook_scope,
            "workbook_joint_map_enabled": self.workbook_joint_map_enabled,
            "workbook_joint_map_separator": self.workbook_joint_map_separator,
        }

    # -- display choices -------------------------------------------------------------

    @property
    def well_text_style(self) -> WellTextStyle:
        return WellTextStyle.lenient(_str(self._read(self.WELL_TEXT_STYLE_KEY)))

    @well_text_style.setter
    def well_text_style(self, value: WellTextStyle | str) -> None:
        self._write(self.WELL_TEXT_STYLE_KEY, WellTextStyle.lenient(value).raw)

    @property
    def active_marker_style(self) -> ActiveMarkerStyle:
        return ActiveMarkerStyle.lenient(_str(self._read(self.ACTIVE_MARKER_STYLE_KEY)))

    @active_marker_style.setter
    def active_marker_style(self, value: ActiveMarkerStyle | str) -> None:
        self._write(self.ACTIVE_MARKER_STYLE_KEY, ActiveMarkerStyle.lenient(value).raw)

    @property
    def new_document_well_shape(self) -> WellShape:
        """Only read when a document opens: the sidebar toggle is the live control, and a
        preference that reached back into open windows would fight with it."""
        return WellShape.lenient(_str(self._read(self.WELL_SHAPE_KEY)))

    @new_document_well_shape.setter
    def new_document_well_shape(self, value: WellShape | str) -> None:
        self._write(self.WELL_SHAPE_KEY, WellShape.lenient(value).raw)

    @property
    def new_condition_colors(self) -> NewConditionColors:
        return NewConditionColors.lenient(_str(self._read(self.NEW_CONDITION_COLORS_KEY)))

    @new_condition_colors.setter
    def new_condition_colors(self, value: NewConditionColors | str) -> None:
        self._write(self.NEW_CONDITION_COLORS_KEY, NewConditionColors.lenient(value).raw)

    # -- empty-well colour -----------------------------------------------------------

    @property
    def empty_well_color_hex(self) -> str | None:
        """The fill for wells with no value, as a hex string — or None for the default,
        which follows light and dark mode. Stored as "no opinion" rather than as a copy
        of the default colour, so Reset genuinely restores default *behaviour*. Garbage
        in the store reads as None."""
        return _valid_hex(_str(self._read(self.EMPTY_WELL_COLOR_KEY)))

    @empty_well_color_hex.setter
    def empty_well_color_hex(self, value: str | None) -> None:
        self._write(self.EMPTY_WELL_COLOR_KEY, None if value is None else str(value))

    # -- plate text ------------------------------------------------------------------

    @property
    def canvas_font_family(self) -> str | None:
        """The plate's typeface — None for the system font. Scoped to the canvas and to
        what the canvas renders (exports, print); the window's controls keep theirs."""
        family = _str(self._read(self.CANVAS_FONT_FAMILY_KEY))
        return family if family else None

    @canvas_font_family.setter
    def canvas_font_family(self, value: str | None) -> None:
        self._write(self.CANVAS_FONT_FAMILY_KEY, None if value is None else str(value))

    @property
    def canvas_font_scale(self) -> float:
        """A multiplier on every text size the canvas computes, not a point size.
        Clamped on read to what stays usable."""
        lo, hi = FONT_SCALE_RANGE
        return min(max(_float(self._read(self.CANVAS_FONT_SCALE_KEY), 1.0), lo), hi)

    @canvas_font_scale.setter
    def canvas_font_scale(self, value: float) -> None:
        self._write(self.CANVAS_FONT_SCALE_KEY, float(value))

    # -- toggles ---------------------------------------------------------------------

    @property
    def show_factor_condition_counts(self) -> bool:
        """Whether each factor row in the sidebar carries its number of conditions at
        the trailing edge. Off by default: the count is one click away."""
        return _bool(self._read(self.FACTOR_CONDITION_COUNTS_KEY), False)

    @show_factor_condition_counts.setter
    def show_factor_condition_counts(self, value: bool) -> None:
        self._write(self.FACTOR_CONDITION_COUNTS_KEY, bool(value))

    @property
    def check_for_updates_automatically(self) -> bool:
        """Whether launching the app may look at GitHub for a newer release — at most
        once a day, silently unless there is one. On by default."""
        return _bool(self._read(self.CHECK_FOR_UPDATES_KEY), True)

    @check_for_updates_automatically.setter
    def check_for_updates_automatically(self, value: bool) -> None:
        self._write(self.CHECK_FOR_UPDATES_KEY, bool(value))

    # -- workbook export options (remembered between exports) ------------------------

    @property
    def workbook_sheet_layout(self) -> str:
        raw = _str(self._read(self.WORKBOOK_SHEET_LAYOUT_KEY))
        return raw if raw in WORKBOOK_SHEET_LAYOUTS else WORKBOOK_SHEET_LAYOUTS[0]

    @workbook_sheet_layout.setter
    def workbook_sheet_layout(self, value: Any) -> None:
        raw = str(_enum_raw(value))
        if raw not in WORKBOOK_SHEET_LAYOUTS:
            raw = WORKBOOK_SHEET_LAYOUTS[0]
        self._write(self.WORKBOOK_SHEET_LAYOUT_KEY, raw)

    @property
    def workbook_scope(self) -> str:
        raw = _str(self._read(self.WORKBOOK_SCOPE_KEY))
        return raw if raw in WORKBOOK_SCOPES else WORKBOOK_SCOPES[0]

    @workbook_scope.setter
    def workbook_scope(self, value: Any) -> None:
        raw = str(_enum_raw(value))
        if raw not in WORKBOOK_SCOPES:
            raw = WORKBOOK_SCOPES[0]
        self._write(self.WORKBOOK_SCOPE_KEY, raw)

    @property
    def workbook_joint_map_enabled(self) -> bool:
        return _bool(self._read(self.WORKBOOK_JOINT_MAP_ENABLED_KEY), False)

    @workbook_joint_map_enabled.setter
    def workbook_joint_map_enabled(self, value: bool) -> None:
        self._write(self.WORKBOOK_JOINT_MAP_ENABLED_KEY, bool(value))

    @property
    def workbook_joint_map_separator(self) -> str:
        """As typed in the panel; blank falls back to "+" at build time (in the
        exporter), so clearing the field never silently glues values together."""
        return _str(self._read(self.WORKBOOK_JOINT_MAP_SEPARATOR_KEY)) or ""

    @workbook_joint_map_separator.setter
    def workbook_joint_map_separator(self, value: str) -> None:
        self._write(self.WORKBOOK_JOINT_MAP_SEPARATOR_KEY, str(value))

    # -- reset -----------------------------------------------------------------------

    def reset_to_defaults(self) -> None:
        """Restore Defaults: forget every display preference (the key is removed, so a
        later build's default is picked up rather than a frozen copy of today's).
        Emits `changed` once, and only if something was actually different."""
        before = self._snapshot()
        for key in self.DISPLAY_KEYS:
            self._settings.remove(key)
        self._settings.sync()
        if self._snapshot() != before:
            self.changed.emit()
