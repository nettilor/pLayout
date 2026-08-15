"""Canvas font factory + the colour half of Preferences (the parts that need QtGui).

Mirrors `Preferences.canvasFont`, `emptyWellFill`, `labelInk`, `neutralInk` and the
`NSColor(hex:)` helpers used by the canvas. Every canvas font goes through `canvas_font`
so the family setting cannot miss a label; metrics are cached per (family, size, weight).
"""
from __future__ import annotations

from functools import lru_cache

from PySide6.QtGui import QColor, QFont, QFontDatabase, QFontMetricsF, QGuiApplication

from playout.model import palette
from playout.model.preferences import Preferences, WellTextStyle

WEIGHTS = {
    "regular": QFont.Weight.Normal,
    "medium": QFont.Weight.Medium,
    "semibold": QFont.Weight.DemiBold,
    "bold": QFont.Weight.Bold,
}


def _system_family() -> str:
    app = QGuiApplication.instance()
    return app.font().family() if app is not None else QFont().family()


@lru_cache(maxsize=512)
def _font(family: str, size_key: int, weight: str) -> QFont:
    f = QFont(family)
    f.setPointSizeF(size_key / 100.0)
    f.setWeight(WEIGHTS.get(weight, QFont.Weight.Normal))
    return f


_resolved_family: dict[str, str] = {}


def resolved_family(prefs: Preferences) -> str:
    """The family the canvas actually draws with — memoised per requested family, because
    `QFontDatabase.families()` is far too slow to ask for every fitted label."""
    requested = prefs.canvas_font_family or ""
    hit = _resolved_family.get(requested)
    if hit is not None:
        return hit
    family = requested if requested and requested in QFontDatabase.families() else _system_family()
    _resolved_family[requested] = family
    return family


def invalidate_font_cache() -> None:
    _resolved_family.clear()


def canvas_font(prefs: Preferences, size: float, weight: str = "medium") -> QFont:
    """The plate's typeface at `size` points. An uninstalled family falls back to the
    system font silently, as on the Mac."""
    return _font(resolved_family(prefs), int(round(max(size, 1.0) * 100)), weight)


@lru_cache(maxsize=512)
def _metrics(family: str, size_key: int, weight: str) -> QFontMetricsF:
    return QFontMetricsF(_font(family, size_key, weight))


def font_metrics(font: QFont) -> QFontMetricsF:
    return _metrics(font.family(), int(round(font.pointSizeF() * 100)), _weight_name(font))


def _weight_name(font: QFont) -> str:
    w = font.weight()
    for name, value in WEIGHTS.items():
        if value == w:
            return name
    return "regular"


# ---------------------------------------------------------------- colours


def qcolor(hex_text: str | None, alpha: float | None = None) -> QColor | None:
    rgb = palette.parse_hex(hex_text) if hex_text else None
    if rgb is None:
        return None
    c = QColor.fromRgbF(*rgb)
    if alpha is not None:
        c.setAlphaF(alpha)
    return c


def with_alpha(color: QColor, alpha: float) -> QColor:
    c = QColor(color)
    c.setAlphaF(alpha)
    return c


def hex_of_qcolor(color: QColor) -> str:
    return palette.hex_of(color.redF(), color.greenF(), color.blueF())


BLACK85 = QColor(0, 0, 0, int(round(0.85 * 255)))
WHITE = QColor(255, 255, 255)


def label_ink(hex_text: str, style: WellTextStyle) -> QColor:
    """The ink for text on a well of this colour under the chosen text style."""
    if style is WellTextStyle.alwaysBlack:
        return QColor(BLACK85)
    if style is WellTextStyle.alwaysWhite:
        return QColor(WHITE)
    return QColor(WHITE) if palette.label_is_white(hex_text) else QColor(BLACK85)


def neutral_ink(prefs: Preferences, system_label: QColor) -> QColor:
    """Ink on the neutral (Overview / empty) tile."""
    custom = prefs.empty_well_color_hex
    style = prefs.well_text_style
    if custom:
        return label_ink(custom, style)
    if style is WellTextStyle.alwaysBlack:
        return QColor(BLACK85)
    if style is WellTextStyle.alwaysWhite:
        return QColor(WHITE)
    return QColor(system_label)


def empty_well_fill(prefs: Preferences, quaternary_label: QColor, export_mode: bool) -> QColor:
    """Custom colour verbatim, else the faint appearance-following default (0.13 screen,
    0.10 export)."""
    custom = qcolor(prefs.empty_well_color_hex)
    if custom is not None:
        return custom
    return with_alpha(quaternary_label, 0.10 if export_mode else 0.13)


def neutral_fill(prefs: Preferences, quaternary_label: QColor, export_mode: bool) -> QColor:
    custom = qcolor(prefs.empty_well_color_hex)
    if custom is not None:
        return custom
    if prefs.well_text_style is WellTextStyle.alwaysWhite:
        return QColor.fromRgbF(0.32, 0.32, 0.32)
    return with_alpha(quaternary_label, 0.14 if export_mode else 0.18)


def secondary_text_color(widget) -> QColor:
    """Readable secondary ink: 62 % of the text colour blended over the window colour —
    darker than `palette(mid)`, which is too faint for captions."""
    pal = widget.palette()
    fg = pal.color(pal.ColorRole.WindowText)
    bg = pal.color(pal.ColorRole.Window)
    t = 0.62
    return QColor(
        int(round(fg.red() * t + bg.red() * (1 - t))),
        int(round(fg.green() * t + bg.green() * (1 - t))),
        int(round(fg.blue() * t + bg.blue() * (1 - t))),
    )


def secondary_css(widget) -> str:
    return f"color: {secondary_text_color(widget).name()};"
