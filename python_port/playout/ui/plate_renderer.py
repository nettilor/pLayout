"""One `render()` for screen, PNG, PDF and print.

Mirrors `render()`, `labelPlan`, `drawFactorStack`, `drawSecondaryStripe`, `drawLineKey`,
`drawHeaders`, `drawOrientationCorner`, `drawFitted` in
`Sources/PLayout/Views/PlateCanvasView.swift`. Widget-free: the canvas builds a
`RenderScene` and hands it a `QPainter`; export paths do the same with `export_mode=True`
and the fixed light `Colors`.

Everything here is *behaviour* from PORT.md §D2/§D3 (what is drawn where, which lines
stack, the fit thresholds); stroke widths and radii are the Mac's numbers too, but those
are taste and may drift.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPalette, QPen

from playout.editor.plate_editor import PlateEditor
from playout.editor.well_range import WellPos, WellRange
from playout.model import palette
from playout.model.layout import Factor, Layout, Level, Plate, WellLabelMode
from playout.model.preferences import ActiveMarkerStyle, Preferences, WellTextStyle
from playout.ui import fonts
from playout.ui.plate_geometry import PlateGeometry, Rect

# ---------------------------------------------------------------- label plan


@dataclass
class LabelPlan:
    line_count: int
    primary_size: float
    secondary_size: float
    gap: float
    uniform: bool = False

    @property
    def primary_height(self) -> float:
        return self.primary_size * 1.18

    @property
    def secondary_height(self) -> float:
        return self.secondary_size * 1.18

    def stack_height(self, lines: int, primary: bool = True) -> float:
        if lines <= 0:
            return 0.0
        return (self.primary_height if primary else self.secondary_height) + (lines - 1) * (self.secondary_height + self.gap)


def body_inset(cell: float) -> float:
    """Ramped, never stepped: a jump would make the line count non-monotonic."""
    return min(2.0, max(1.0, cell * 0.1))


def label_plan(cell: float, mode: WellLabelMode, factor_count: int, scale: float = 1.0) -> LabelPlan:
    """Sizes are continuous functions of the cell size with no rounding, and the stack is
    measured against the whole well body — see PORT.md §D2."""
    primary = max(7.0, min(cell * 0.30, 13.0)) * scale
    secondary = max(6.5 * scale, primary * 0.80)
    gap = max(0.5, secondary * 0.16)
    plan = LabelPlan(0, primary, secondary, gap)
    if mode.is_overview:
        plan.primary_size = secondary
        plan.uniform = True
    if not mode.stacks_every_factor or factor_count < 2:
        return plan
    available = cell - body_inset(cell) * 2
    if plan.primary_height > available:
        return plan
    lines = 1
    while plan.stack_height(lines + 1) <= available:
        lines += 1
    plan.line_count = min(lines, factor_count)
    if plan.line_count < 2:
        plan.line_count = 0
    if plan.uniform and plan.line_count >= 2:
        n = plan.line_count
        reserved = max(3.0, cell * 0.15) + 2 if factor_count > n else 0.0
        fitted = (available - reserved - (n - 1) * gap) / (n * 1.18)
        size = max(secondary, min(primary, fitted))
        plan.primary_size = size
        plan.secondary_size = size
    return plan


def primary_slot(lines: list[Factor], active_factor_id: str | None, uniform: bool) -> int | None:
    if uniform or active_factor_id is None:
        return None
    for i, f in enumerate(lines):
        if f.id == active_factor_id:
            return i
    return None


# ---------------------------------------------------------------- scene


@dataclass
class Colors:
    """The appearance-dependent colours. Screen: from the widget palette. Export: fixed light."""

    window_background: QColor
    text_background: QColor
    label: QColor
    secondary_label: QColor
    quaternary_label: QColor
    separator: QColor
    accent: QColor

    @classmethod
    def from_palette(cls, pal: QPalette) -> "Colors":
        label = pal.color(QPalette.ColorRole.WindowText)
        try:
            accent = pal.color(QPalette.ColorRole.Accent)
        except AttributeError:  # Qt < 6.6
            accent = pal.color(QPalette.ColorRole.Highlight)
        return cls(
            window_background=pal.color(QPalette.ColorRole.Window),
            text_background=pal.color(QPalette.ColorRole.Base),
            label=label,
            secondary_label=fonts.with_alpha(label, 0.55),
            quaternary_label=fonts.with_alpha(label, 1.0),  # alpha applied by the fill helpers
            separator=fonts.with_alpha(label, 0.2),
            accent=accent,
        )

    @classmethod
    def light(cls) -> "Colors":
        return cls(
            window_background=QColor(255, 255, 255),
            text_background=QColor(255, 255, 255),
            label=QColor(0, 0, 0),
            secondary_label=QColor(0, 0, 0, 140),
            quaternary_label=QColor(0, 0, 0),
            separator=QColor(0, 0, 0, 50),
            accent=QColor(0, 122, 255),
        )


@dataclass
class RenderScene:
    layout: Layout
    plate: Plate
    prefs: Preferences
    quarter_turns: int
    colors: Colors
    active_factor_id: str | None = None
    show_secondary_factors: bool = True
    round_wells: bool = True
    export_mode: bool = False
    # screen-only state
    selection: WellRange | None = None
    custom_wells: frozenset | None = None
    hovered: WellPos | None = None
    hovering_corner: bool = False
    spotlight_level_id: str | None = None
    # in-progress drag preview
    pending_wells: frozenset = field(default_factory=frozenset)
    pending_level_id: str | None = None
    pending_is_erase: bool = False
    is_painting_drag: bool = False

    @classmethod
    def from_editor(cls, editor: PlateEditor, colors: Colors, export_mode: bool = False) -> "RenderScene | None":
        plate = editor.plate
        if plate is None:
            return None
        scene = cls(
            layout=editor.layout, plate=plate, prefs=editor.preferences, quarter_turns=editor.quarter_turns,
            colors=colors, active_factor_id=editor.active_factor_id,
            show_secondary_factors=editor.show_secondary_factors, round_wells=editor.round_wells,
            export_mode=export_mode,
        )
        if not export_mode:
            scene.selection = editor.selection.clamped(plate.format) if editor.selection is not None else None
            scene.custom_wells = editor.custom_wells
            scene.hovered = editor.hovered
            scene.spotlight_level_id = editor.spotlight_level_id
        return scene


def _qrect(r: Rect) -> QRectF:
    return QRectF(r.x, r.y, r.width, r.height)


def _rounded(painter: QPainter, r: QRectF, radius: float, fill: QColor | None, stroke: QColor | None = None, width: float = 1.0) -> None:
    path = QPainterPath()
    path.addRoundedRect(r, radius, radius)
    if fill is not None:
        painter.fillPath(path, fill)
    if stroke is not None:
        painter.setPen(QPen(stroke, width))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)


# ---------------------------------------------------------------- the renderer


class PlateRenderer:
    def __init__(self, scene: RenderScene, geo: PlateGeometry, bounds: Rect):
        self.s = scene
        self.geo = geo
        self.bounds = bounds
        self.prefs = scene.prefs

    # -- text ---------------------------------------------------------------
    def font(self, size: float, weight: str = "medium") -> QFont:
        return fonts.canvas_font(self.prefs, size, weight)

    def _width(self, text: str, font: QFont) -> float:
        return fonts.font_metrics(font).horizontalAdvance(text)

    def draw_text(self, p: QPainter, text: str, rect: QRectF, font: QFont, color: QColor, center: bool = True) -> None:
        if not text:
            return
        p.setFont(font)
        p.setPen(color)
        m = fonts.font_metrics(font)
        w = m.horizontalAdvance(text)
        h = m.height()
        x = rect.center().x() - w / 2 if center else rect.left()
        y = rect.center().y() - h / 2 + m.ascent()
        p.drawText(QPointF(x, y), text)

    def draw_fitted(self, p: QPainter, text: str, rect: QRectF, max_size: float, min_size: float | None = None,
                    weight: str = "medium", center: bool = True, color: QColor | None = None) -> None:
        trimmed = text.strip(" \t")
        if not trimmed or rect.width() <= 8:
            return
        padding = max(2.0, rect.width() * 0.12) if center else 1.0
        available = rect.width() - padding
        if available <= 2:
            return
        floor_size = max(6.0, min(min_size if min_size is not None else 7.0, max_size))
        measured = self._width(trimmed, self.font(max_size, weight))
        if measured <= 0:
            return
        size = max(floor_size, min(max_size, max_size * available / measured))
        font = self.font(size, weight)
        width = self._width(trimmed, font)
        attempts = 0
        while width > available and size > floor_size and attempts < 8:
            size = max(floor_size, size * min(0.97, available / width))
            font = self.font(size, weight)
            width = self._width(trimmed, font)
            attempts += 1
        shown = trimmed
        if width > available:
            per_char = width / len(trimmed)
            fits = max(1, int(available / per_char))
            shown = trimmed[: max(1, fits - 1)] + "…" if fits < len(trimmed) else trimmed
        self.draw_text(p, shown, rect, font, color or self.s.colors.label, center)

    # -- level resolution ---------------------------------------------------
    def resolved_level(self, index: int, factor: Factor | None) -> Level | None:
        if factor is None:
            return None
        s = self.s
        if s.is_painting_drag and index in s.pending_wells:
            if s.pending_is_erase:
                return None
            return factor.level(s.pending_level_id)
        return factor.level(s.plate.level_id(factor.id, index))

    def level_for(self, factor: Factor, index: int) -> Level | None:
        if factor.id == self.s.active_factor_id:
            return self.resolved_level(index, factor)
        return factor.level(self.s.plate.level_id(factor.id, index))

    # -- main entry -----------------------------------------------------------
    def render(self, p: QPainter, dirty: Rect | None = None) -> None:
        s, geo, c = self.s, self.geo, self.s.colors
        plate, fmt, layout, prefs = s.plate, s.plate.format, s.layout, self.prefs
        mode = layout.well_label_mode
        text_style = prefs.well_text_style
        marker_style = prefs.active_marker_style
        factor = None if mode.is_overview else layout.factor(s.active_factor_id)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        p.setRenderHint(QPainter.RenderHint.TextAntialiasing, True)

        selected_rows: set[int] = set()
        selected_cols: set[int] = set()
        if s.custom_wells is not None:
            selected_rows = {w.row for w in s.custom_wells}
            selected_cols = {w.col for w in s.custom_wells}
        elif s.selection is not None:
            selected_rows = set(range(s.selection.min_row, s.selection.max_row + 1))
            selected_cols = set(range(s.selection.min_col, s.selection.max_col + 1))

        p.fillRect(_qrect(self.bounds), QColor(255, 255, 255) if s.export_mode else c.window_background)
        _rounded(p, _qrect(geo.grid_rect), 3, c.text_background)
        self.draw_headers(p, selected_rows, selected_cols)

        plan = label_plan(geo.cell, mode, len(layout.factors), prefs.canvas_font_scale)
        stacked = list(layout.factors[: plan.line_count]) if plan.line_count >= 2 else []
        overflow = list(layout.factors[plan.line_count:]) if stacked else []
        show_single_text = mode.shows_text and not stacked and geo.cell >= 17
        solo_factor = layout.factors[0] if (mode.is_overview and show_single_text and layout.factors) else None
        secondary = [f for f in layout.factors if f.id != s.active_factor_id] if (s.show_secondary_factors or mode.is_overview) else []
        if solo_factor is not None:
            secondary = [f for f in secondary if f.id != solo_factor.id]
        stripe_factors = secondary if not stacked else overflow
        stripe_height = 0.0
        if stripe_factors:
            if not stacked:
                stripe_height = max(3.0, geo.cell * 0.15) if geo.cell >= (10 if mode.is_overview else 22) else 0.0
            else:
                leftover = geo.cell - body_inset(geo.cell) * 2 - plan.stack_height(len(stacked))
                stripe_height = min(max(3.0, geo.cell * 0.15), leftover - 2) if leftover >= 5 else 0.0
            if stripe_height == 0:
                stripe_factors = []
        hidden_count = 0 if not stacked else len(overflow) - len(stripe_factors)

        well_font_size = max(7.0, min(geo.cell * 0.30, 13.0)) * prefs.canvas_font_scale
        empty_fill = fonts.empty_well_fill(prefs, c.quaternary_label, s.export_mode)
        neutral_fill = fonts.neutral_fill(prefs, c.quaternary_label, s.export_mode)
        neutral_ink = fonts.neutral_ink(prefs, c.label)
        hairline = fonts.with_alpha(c.separator, 0.6)
        draw_hairlines = geo.cell >= 4
        dirty_rect = _qrect(dirty) if dirty is not None else None

        for row in range(fmt.rows):
            for col in range(fmt.cols):
                cell_r = geo.cell_rect(row, col)
                cell = _qrect(cell_r)
                if dirty_rect is not None and not dirty_rect.intersects(cell.adjusted(-1, -1, 1, 1)):
                    continue
                index = fmt.index(row, col)
                if draw_hairlines:
                    p.setPen(QPen(hairline, 0.5))
                    p.setBrush(Qt.BrushStyle.NoBrush)
                    p.drawRect(cell.adjusted(0.25, 0.25, -0.25, -0.25))
                level = self.resolved_level(index, factor)
                body = self.well_body(cell, stripe_height if not stacked else 0.0, square=not stacked)
                round_well = s.round_wells and not stacked and body.width() >= 8
                path = QPainterPath()
                if round_well:
                    path.addEllipse(body)
                else:
                    r = min(2.5, body.width() / 5)
                    path.addRoundedRect(body, r, r)
                on_colour = fonts.qcolor(level.color_hex) if level else None
                if level is not None and on_colour is not None:
                    p.fillPath(path, on_colour)
                    stroke = QColor(on_colour.red() * 0.75, on_colour.green() * 0.75, on_colour.blue() * 0.75)
                    stroke.setAlphaF(0.55)
                    p.setPen(QPen(stroke, 0.75))
                    p.setBrush(Qt.BrushStyle.NoBrush)
                    p.drawPath(path)
                    if show_single_text:
                        self.draw_fitted(p, level.name, body, well_font_size, color=fonts.label_ink(level.color_hex, text_style))
                else:
                    p.fillPath(path, neutral_fill if mode.is_overview else empty_fill)
                    if solo_factor is not None:
                        lid = plate.level_id(solo_factor.id, index)
                        lv = solo_factor.level(lid) if lid else None
                        if lv is not None:
                            self.draw_fitted(p, lv.name, body, well_font_size, color=neutral_ink)
                if stacked:
                    self.draw_factor_stack(p, body, stacked, index, plan, on_colour, stripe_height, text_style, neutral_ink, marker_style)
                if stripe_height > 0:
                    if not stacked:
                        band = QRectF(cell.left() + 2, cell.bottom() - stripe_height - 2, max(1.0, cell.width() - 4), stripe_height)
                    else:
                        band = QRectF(body.left(), body.bottom() - stripe_height, body.width(), stripe_height)
                    self.draw_secondary_stripe(p, band, stripe_factors, index)

        if stacked:
            self.draw_line_key(p, stacked, len(stripe_factors), hidden_count)

        if s.export_mode:
            return

        # notes corner marks
        if plate.well_notes:
            ink = fonts.with_alpha(c.label, 0.45)
            for key in plate.well_notes:
                try:
                    well = int(key)
                except ValueError:
                    continue
                if not 0 <= well < fmt.well_count:
                    continue
                r = _qrect(geo.cell_rect(well // fmt.cols, well % fmt.cols))
                side = max(4.0, min(r.width() * 0.16, 7.0))
                tri = QPainterPath()
                tri.moveTo(r.right() - 1.5 - side, r.top() + 1.5)
                tri.lineTo(r.right() - 1.5, r.top() + 1.5)
                tri.lineTo(r.right() - 1.5, r.top() + 1.5 + side)
                tri.closeSubpath()
                p.fillPath(tri, ink)

        # spotlight
        if s.spotlight_level_id is not None and s.active_factor_id is not None:
            dim = fonts.with_alpha(c.text_background, 0.8)
            for row in range(fmt.rows):
                for col in range(fmt.cols):
                    index = fmt.index(row, col)
                    if plate.level_id(s.active_factor_id, index) == s.spotlight_level_id:
                        continue
                    p.fillRect(_qrect(geo.cell_rect(row, col)), dim)

        accent = c.accent
        if s.custom_wells is not None:
            for pos in s.custom_wells:
                if not fmt.contains(pos.row, pos.col):
                    continue
                r = _qrect(geo.cell_rect(pos.row, pos.col))
                p.fillRect(r, fonts.with_alpha(accent, 0.10))
                p.setPen(QPen(accent, 2))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRect(r.adjusted(1, 1, -1, -1))
        elif s.selection is not None:
            sel = _qrect(geo.rect_of(s.selection))
            p.fillRect(sel, fonts.with_alpha(accent, 0.10))
            p.setPen(QPen(accent, 2))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRect(sel.adjusted(1, 1, -1, -1))
            if not s.selection.is_single_well:
                focus = _qrect(geo.cell_rect(s.selection.focus.row, s.selection.focus.col))
                p.setPen(QPen(fonts.with_alpha(accent, 0.9), 1.5))
                p.drawRect(focus.adjusted(1.5, 1.5, -1.5, -1.5))

        if s.hovered is not None and fmt.contains(s.hovered.row, s.hovered.col):
            p.setPen(QPen(fonts.with_alpha(c.label, 0.35), 1))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRect(_qrect(geo.cell_rect(s.hovered.row, s.hovered.col)).adjusted(1, 1, -1, -1))

    # -- pieces ---------------------------------------------------------------
    @staticmethod
    def well_body(cell: QRectF, stripe_height: float, square: bool = True) -> QRectF:
        inset = body_inset(cell.width())
        r = cell.adjusted(inset, inset, -inset, -inset)
        if stripe_height > 0:
            r.setHeight(r.height() - (stripe_height + 1))
        if square and r.width() > r.height():
            dx = (r.width() - r.height()) / 2
            r = QRectF(r.left() + dx, r.top(), r.height(), r.height())
        return r

    def draw_factor_stack(self, p: QPainter, body: QRectF, factors: list[Factor], index: int, plan: LabelPlan,
                          on_colour: QColor | None, reserved_bottom: float, style: WellTextStyle,
                          neutral_ink: QColor, marker: ActiveMarkerStyle) -> None:
        s = self.s
        line_count = min(plan.line_count, len(factors))
        if line_count < 1:
            return
        pslot = primary_slot(factors[:line_count], s.active_factor_id, plan.uniform)
        if on_colour is not None:
            text_color = fonts.label_ink(fonts.hex_of_qcolor(on_colour), style)
        else:
            text_color = QColor(neutral_ink) if plan.uniform else fonts.with_alpha(neutral_ink, 0.75)
        rail_w = max(2.5, min(5.5, body.width() * 0.09))
        active_rail_w = rail_w * 1.45
        inset = max(2.5, body.width() * 0.055)
        text_gap = max(2.0, rail_w * 0.75)
        text_start = body.left() + inset + active_rail_w + text_gap
        usable = body.height() - reserved_bottom
        stack_h = plan.stack_height(line_count, primary=pslot is not None)
        y = body.top() + (usable - stack_h) / 2
        on_hex = fonts.hex_of_qcolor(on_colour) if on_colour is not None else None
        for slot in range(line_count):
            f = factors[slot]
            is_primary = slot == pslot
            height = plan.primary_height if is_primary else plan.secondary_height
            level = self.level_for(f, index)
            if is_primary and height >= 8 and body.width() >= 24:
                bleed = min(1.5, plan.gap * 0.6)
                band = QRectF(body.left() + 1, y - bleed, body.width() - 2, height + bleed * 2)
                _rounded(p, band, min(3.0, band.height() / 3), fonts.with_alpha(text_color, 0.15))
            this_rail = active_rail_w if is_primary else rail_w
            rail = QRectF(body.left() + inset, y + height * 0.14, this_rail, height * 0.72)
            radius = this_rail / 2
            colour = fonts.qcolor(level.color_hex) if level else None
            if level is not None and colour is not None:
                is_marker = is_primary and on_hex is not None and palette.normalized(level.color_hex) == on_hex
                if is_marker:
                    fill = fonts.qcolor(palette.contrasting_shade(level.color_hex)) if marker is ActiveMarkerStyle.deeperShade else text_color
                    _rounded(p, rail, radius, fill)
                else:
                    wall = max(0.9, this_rail * 0.19) if is_primary else 0.75
                    _rounded(p, rail, radius, colour)
                    _rounded(p, rail.adjusted(wall / 2, wall / 2, -wall / 2, -wall / 2), radius, None,
                             fonts.with_alpha(text_color, 1.0 if is_primary else 0.7), wall)
                text_rect = QRectF(text_start, y, body.right() - inset - text_start, height)
                size = plan.primary_size if is_primary else plan.secondary_size
                self.draw_fitted(p, level.name, text_rect, size, size * 0.85,
                                 weight="semibold" if is_primary else "regular", center=False,
                                 color=text_color if (is_primary or plan.uniform) else fonts.with_alpha(text_color, 0.86))
            else:
                _rounded(p, rail, radius, fonts.with_alpha(text_color, 0.16))
            y += height + plan.gap

    def draw_secondary_stripe(self, p: QPainter, band: QRectF, factors: list[Factor], index: int) -> None:
        if not factors or band.width() <= 0:
            return
        seg_w = band.width() / len(factors)
        for i, f in enumerate(factors):
            seg = QRectF(band.left() + i * seg_w, band.top(), seg_w - (0.75 if len(factors) > 1 else 0), band.height())
            level = self.level_for(f, index)
            colour = fonts.qcolor(level.color_hex) if level else None
            if colour is None:
                continue
            _rounded(p, seg, 1, colour)

    def draw_line_key(self, p: QPainter, stacked: list[Factor], striped: int, hidden: int) -> None:
        b = self.bounds
        frame = self.geo.frame_rect
        strip = QRectF(b.x + 4, max(frame.max_y, b.max_y - 14), max(0.0, b.width - 8), min(14.0, max(0.0, b.max_y - frame.max_y)))
        if strip.height() < 8 or strip.width() <= 24:
            return
        parts = [f"{i + 1} {f.name}" for i, f in enumerate(stacked)]
        if striped > 0:
            parts.append(f"+{striped} in stripe")
        if hidden > 0:
            parts.append(f"+{hidden} not shown")
        text = "Well lines:  " + "   ".join(parts)
        self.draw_fitted(p, text, strip, 9.5, 7, weight="medium", center=False, color=self.s.colors.secondary_label)

    def draw_headers(self, p: QPainter, selected_rows: set[int], selected_cols: set[int]) -> None:
        s, geo, c = self.s, self.geo, self.s.colors
        size = max(7.0, min(geo.header_h * 0.55, geo.cell * 0.42, 12.0)) * self.prefs.canvas_font_scale
        font = self.font(size, "semibold")
        stride = 1 if geo.cell >= 15 else (2 if geo.cell >= 10 else 4)
        from playout.model.plate_format import WellNaming

        def draw(label: str, r: Rect, highlighted: bool) -> None:
            qr = _qrect(r)
            if highlighted and not s.export_mode:
                p.fillRect(qr, fonts.with_alpha(c.accent, 0.16))
            if label:
                self.draw_text(p, label, qr, font, c.accent if (highlighted and not s.export_mode) else c.secondary_label)

        def label(well: WellPos, axis_is_row: bool, index: int) -> tuple[str, bool]:
            if axis_is_row:
                return WellNaming.row_label(well.row), well.row in selected_rows
            shown = str(well.col + 1) if (index % stride == 0 or index == 0) else ""
            return shown, well.col in selected_cols

        for i in range(geo.display_cols):
            well = geo.model_position(0, i)
            text, on = label(well, geo.is_turned_on_end, i)
            draw(text, geo.horizontal_header_rect(i), on)
        for i in range(geo.display_rows):
            well = geo.model_position(i, 0)
            text, on = label(well, not geo.is_turned_on_end, i)
            draw(text, geo.vertical_header_rect(i), on)
        self.draw_orientation_corner(p)

    def draw_orientation_corner(self, p: QPainter) -> None:
        s, geo, c = self.s, self.geo, self.s.colors
        if s.export_mode:
            return
        r = _qrect(geo.corner_rect)
        if r.width() < 16 or r.height() < 12:
            return
        if s.hovering_corner:
            _rounded(p, r.adjusted(1.5, 1.5, -1.5, -1.5), 3, fonts.with_alpha(c.accent, 0.14))
        size = min(r.width() - 8, r.height() - 6, 14)
        if size < 8:
            return
        ink = fonts.with_alpha(c.accent if s.hovering_corner else c.secondary_label, 1.0 if s.hovering_corner else 0.8)
        self.draw_turn_arrow(p, r.center(), size / 2, geo.quarter_turns == 0, ink)

    @staticmethod
    def draw_turn_arrow(p: QPainter, centre: QPointF, radius: float, clockwise: bool, ink: QColor) -> None:
        if radius < 3.5:
            return
        sweep = 260.0
        start = 150.0 if clockwise else 30.0
        end = start + sweep if clockwise else start - sweep
        path = QPainterPath()
        steps = 40
        for step in range(steps + 1):
            deg = start + (end - start) * step / steps
            rad = math.radians(deg)
            pt = QPointF(centre.x() + radius * math.cos(rad), centre.y() + radius * math.sin(rad))
            if step == 0:
                path.moveTo(pt)
            else:
                path.lineTo(pt)
        pen = QPen(ink, max(1.2, radius * 0.22))
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawPath(path)
        end_rad = math.radians(end)
        tip = QPointF(centre.x() + radius * math.cos(end_rad), centre.y() + radius * math.sin(end_rad))
        way = 1.0 if clockwise else -1.0
        tangent = QPointF(-math.sin(end_rad) * way, math.cos(end_rad) * way)
        normal = QPointF(-tangent.y(), tangent.x())
        reach = max(2.8, radius * 0.85)
        half = max(2.0, radius * 0.55)
        head = QPainterPath()
        head.moveTo(tip.x() + tangent.x() * reach, tip.y() + tangent.y() * reach)
        head.lineTo(tip.x() + normal.x() * half, tip.y() + normal.y() * half)
        head.lineTo(tip.x() - normal.x() * half, tip.y() - normal.y() * half)
        head.closeSubpath()
        p.fillPath(head, ink)


def render_scene(scene: RenderScene, painter: QPainter, bounds: Rect, dirty: Rect | None = None) -> PlateGeometry:
    """Draw the whole plate into `bounds` (unmagnified units). Returns the geometry used."""
    geo = PlateGeometry.fit(scene.plate.format, bounds, scene.quarter_turns)
    PlateRenderer(scene, geo, bounds).render(painter, dirty)
    return geo
