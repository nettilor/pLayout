"""PlateCanvas (QWidget) + PlateScrollArea (owns zoom).

Mirrors the NSView mouse/key handling and `PlateScrollView` in
`Sources/PLayout/Views/PlateCanvasView.swift`. The interaction table is PORT.md §C18; the
zoom rules are §D4. Every branch below calls an existing `PlateEditor` method — the canvas
holds only drag state and translates events.

Zoom: the scroll area owns `zoom` (1 = whole plate fits, the minimum; 10 max) and sizes the
canvas to `viewport × zoom`; the canvas paints with `painter.scale(zoom)` and lays the plate
out for `size / zoom` — the *unmagnified* viewport — so magnifying reveals part of the same
layout instead of re-fitting a smaller plate (the Mac's `tile()` invariant).
"""
from __future__ import annotations

from PySide6.QtCore import QEvent, QPointF, QRect, QSize, Qt
from PySide6.QtGui import QColor, QMouseEvent, QPainter, QPalette
from PySide6.QtWidgets import QAbstractScrollArea, QScrollArea, QSizePolicy, QWidget

from playout.editor.plate_editor import PlateEditor
from playout.editor.well_range import WellPos, WellRange
from playout.ui.plate_geometry import Hit, PlateGeometry, Rect
from playout.ui.plate_renderer import Colors, RenderScene, render_scene

MIN_ZOOM = 1.0
MAX_ZOOM = 10.0
ZOOM_STEP = 1.4


class PlateCanvas(QWidget):
    """The plate grid. Model coordinates everywhere; the geometry owns the rotation."""

    def __init__(self, editor: PlateEditor, scroll_area: "PlateScrollArea"):
        super().__init__()
        self.editor = editor
        self._scroll = scroll_area
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMouseTracking(True)
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        self.setAttribute(Qt.WidgetAttribute.WA_OpaquePaintEvent, True)
        # drag state (Swift PlateCanvasView fields)
        self._drag_kind = "none"          # none | wells | columns | rows
        self._drag_anchor_well: WellPos | None = None
        self._drag_anchor_line = 0
        self._freeform_brush = False
        self._custom_drag_base: frozenset | None = None
        self._pending_wells: set[int] = set()
        self._pending_level_id: str | None = None
        self._pending_is_erase = False
        self._is_painting_drag = False
        self._hovering_corner = False
        editor.state_changed.connect(self.update)
        editor.layout_changed.connect(self.update)

    # ------------------------------------------------------------------ geometry
    @property
    def zoom(self) -> float:
        return self._scroll.zoom

    def unmagnified_bounds(self) -> Rect:
        z = self.zoom
        return Rect(0, 0, max(1.0, self.width() / z), max(1.0, self.height() / z))

    def plate_geometry(self) -> PlateGeometry:
        return PlateGeometry.fit(self.editor.format, self.unmagnified_bounds(), self.editor.quarter_turns)

    def _model_point(self, pos: QPointF) -> tuple[float, float]:
        z = self.zoom
        return pos.x() / z, pos.y() / z

    # ------------------------------------------------------------------ painting
    def paintEvent(self, event) -> None:
        p = QPainter(self)
        colors = Colors.from_palette(self.palette())
        # The workspace is white (Base) so the sidebar's grey panel reads as a panel.
        colors.window_background = self.palette().color(QPalette.ColorRole.Base)
        scene = RenderScene.from_editor(self.editor, colors)
        if scene is None:
            p.fillRect(self.rect(), colors.window_background)
            return
        z = self.zoom
        p.scale(z, z)
        scene.hovering_corner = self._hovering_corner
        scene.pending_wells = frozenset(self._pending_wells)
        scene.pending_level_id = self._pending_level_id
        scene.pending_is_erase = self._pending_is_erase
        scene.is_painting_drag = self._is_painting_drag
        r = event.rect()
        dirty = Rect(r.x() / z, r.y() / z, r.width() / z, r.height() / z)
        render_scene(scene, p, self.unmagnified_bounds(), dirty)
        p.end()

    def export_scene(self, colors: Colors | None = None) -> RenderScene | None:
        """The scene for PNG/PDF/print: export mode, light colours, no transient state."""
        return RenderScene.from_editor(self.editor, colors or Colors.light(), export_mode=True)

    # ------------------------------------------------------------------ mouse
    def mousePressEvent(self, e: QMouseEvent) -> None:
        if e.button() != Qt.MouseButton.LeftButton:
            return super().mousePressEvent(e)
        self.setFocus(Qt.FocusReason.MouseFocusReason)
        editor = self.editor
        if editor.plate is None:
            return
        mods = e.modifiers()
        extend = bool(mods & Qt.KeyboardModifier.ShiftModifier)
        self._freeform_brush = bool(mods & Qt.KeyboardModifier.ControlModifier)
        self._pending_is_erase = bool(mods & Qt.KeyboardModifier.AltModifier)
        self._pending_level_id = editor.armed_level_id
        self._is_painting_drag = self._pending_is_erase or self._pending_level_id is not None
        self._pending_wells = set()
        self._custom_drag_base = None
        self._drag_anchor_well = None
        geo = self.plate_geometry()
        x, y = self._model_point(e.position())
        hit = geo.hit(x, y)
        fmt = editor.format
        if hit.kind == Hit.WELL:
            pos = hit.well
            self._drag_kind = "wells"
            self._drag_anchor_well = pos
            if self._freeform_brush:
                self._custom_drag_base = editor.selection_as_positions
                editor.toggle_well(pos)
            elif extend:
                anchor = editor.selection.anchor if editor.selection is not None else editor.custom_focus
                editor.select(WellRange(anchor or pos, pos))
            else:
                editor.select(WellRange.single(pos))
        elif hit.kind == Hit.COLUMN_HEADER:
            col = hit.index
            self._drag_kind = "columns"
            self._drag_anchor_line = editor.selection.anchor.col if (extend and editor.selection is not None) else col
            editor.select(WellRange(WellPos(0, self._drag_anchor_line), WellPos(fmt.rows - 1, col)))
        elif hit.kind == Hit.ROW_HEADER:
            row = hit.index
            self._drag_kind = "rows"
            self._drag_anchor_line = editor.selection.anchor.row if (extend and editor.selection is not None) else row
            editor.select(WellRange(WellPos(self._drag_anchor_line, 0), WellPos(row, fmt.cols - 1)))
        elif hit.kind == Hit.CORNER:
            self._drag_kind = "none"
            self._is_painting_drag = False
            editor.rotate_plate()
            self.update()
            return
        else:
            self._drag_kind = "none"
            self._is_painting_drag = False
            editor.clear_selection_marquee()
            self.update()
            return
        self._refresh_pending()
        self.update()

    def mouseDoubleClickEvent(self, e: QMouseEvent) -> None:
        # Qt turns the second press of a double click into this event; the Mac saw two
        # mouseDowns, so treat it as one.
        self.mousePressEvent(e)

    def mouseMoveEvent(self, e: QMouseEvent) -> None:
        editor = self.editor
        geo = self.plate_geometry()
        x, y = self._model_point(e.position())
        if e.buttons() & Qt.MouseButton.LeftButton and self._drag_kind != "none":
            fmt = editor.format
            pos = geo.nearest_well(x, y)
            anchor = self._drag_anchor_well or pos
            if self._drag_kind == "wells":
                if self._freeform_brush and self._is_painting_drag:
                    editor.select(WellRange(anchor, pos))
                    self._pending_wells.add(fmt.index(pos.row, pos.col))
                elif self._freeform_brush:
                    editor.add_to_selection(self._custom_drag_base or frozenset(), WellRange(anchor, pos))
                else:
                    editor.select(WellRange(anchor, pos))
            elif self._drag_kind == "columns":
                editor.select(WellRange(WellPos(0, self._drag_anchor_line), WellPos(fmt.rows - 1, geo.nearest_column(x, y))))
            elif self._drag_kind == "rows":
                editor.select(WellRange(WellPos(self._drag_anchor_line, 0), WellPos(geo.nearest_row(x, y), fmt.cols - 1)))
            self._refresh_pending()
            self.update()
            return
        hit = geo.hit(x, y)
        hovered = hit.well if hit.kind == Hit.WELL else None
        corner = hit.kind == Hit.CORNER
        changed = corner != self._hovering_corner
        self._hovering_corner = corner
        editor.set_hovered(hovered)
        if changed:
            self.update()

    def mouseReleaseEvent(self, e: QMouseEvent) -> None:
        if e.button() != Qt.MouseButton.LeftButton:
            return super().mouseReleaseEvent(e)
        if self._is_painting_drag and self._pending_wells:
            erase = self._pending_is_erase
            self.editor.paint(sorted(self._pending_wells), None if erase else self._pending_level_id,
                              "Erase Wells" if erase else "Paint Wells")
        self._drag_kind = "none"
        self._drag_anchor_well = None
        self._freeform_brush = False
        self._custom_drag_base = None
        self._pending_wells = set()
        self._pending_level_id = None
        self._pending_is_erase = False
        self._is_painting_drag = False
        self.update()

    def leaveEvent(self, e) -> None:
        self.editor.set_hovered(None)
        if self._hovering_corner:
            self._hovering_corner = False
            self.update()
        super().leaveEvent(e)

    def _refresh_pending(self) -> None:
        """Header clicks and plain drags paint the whole selection; the freehand brush
        paints only what it visited (a Ctrl-click itself never paints)."""
        if not self._is_painting_drag:
            return
        if self._freeform_brush and self._drag_kind == "wells":
            return
        self._pending_wells = set(self.editor.selected_wells)

    # ------------------------------------------------------------------ keys
    def event(self, e) -> bool:
        if e.type() == QEvent.Type.KeyPress and e.key() in (Qt.Key.Key_Tab, Qt.Key.Key_Backtab):
            back = e.key() == Qt.Key.Key_Backtab or bool(e.modifiers() & Qt.KeyboardModifier.ShiftModifier)
            self.editor.cycle_factor(-1 if back else 1)
            return True
        return super().event(e)

    def keyPressEvent(self, e) -> None:
        mods = e.modifiers()
        if mods & Qt.KeyboardModifier.ControlModifier and not mods & Qt.KeyboardModifier.AltModifier:
            e.ignore()
            return  # menu shortcuts (Ctrl+…) are the menu's business
        mods &= ~Qt.KeyboardModifier.KeypadModifier
        shift = bool(mods & Qt.KeyboardModifier.ShiftModifier)
        editor = self.editor
        key = e.key()
        if key == Qt.Key.Key_Up:
            return editor.move_cursor(-1, 0, extend=shift)
        if key == Qt.Key.Key_Down:
            return editor.move_cursor(1, 0, extend=shift)
        if key == Qt.Key.Key_Left:
            return editor.move_cursor(0, -1, extend=shift)
        if key == Qt.Key.Key_Right:
            return editor.move_cursor(0, 1, extend=shift)
        if key in (Qt.Key.Key_Backspace, Qt.Key.Key_Delete):
            return editor.clear_selection_all_factors() if shift else editor.clear_selection()
        if key == Qt.Key.Key_Escape:
            return editor.disarm_level()
        if key in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            return editor.paint_selection()
        text = e.text()
        low = text.lower()
        if low and low in "123456789" and len(low) == 1:
            return editor.arm_level_at_index(int(low) - 1)
        if low == "0":
            return editor.arm_level_at_index(9)
        if low == "[":
            return editor.cycle_level(-1)
        if low == "]":
            return editor.cycle_level(1)
        if low in ("f", " "):
            return editor.paint_selection()
        e.ignore()
        super().keyPressEvent(e)


class PlateScrollArea(QScrollArea):
    """Hosts the canvas; owns the zoom (fit = 1 = minimum, 10 = maximum)."""

    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.zoom = 1.0
        self.canvas = PlateCanvas(editor, self)
        self.setWidget(self.canvas)
        self.setWidgetResizable(False)
        self.setFrameShape(QScrollArea.Shape.NoFrame)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.setFocusProxy(self.canvas)
        self.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        self.viewport().setAutoFillBackground(True)
        vp_pal = self.viewport().palette()
        vp_pal.setColor(QPalette.ColorRole.Window, vp_pal.color(QPalette.ColorRole.Base))
        self.viewport().setPalette(vp_pal)
        editor.zoom_requested.connect(self.set_zoom)
        editor.note_zoom_changed(1.0)

    # ------------------------------------------------------------------ tiling
    def _retile(self) -> None:
        vp = self.viewport().size()
        self.canvas.resize(max(1, int(round(vp.width() * self.zoom))), max(1, int(round(vp.height() * self.zoom))))

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self._retile()

    def showEvent(self, e) -> None:
        super().showEvent(e)
        self._retile()

    # ------------------------------------------------------------------ zoom
    def set_zoom(self, value: float) -> None:
        z1 = min(max(float(value), MIN_ZOOM), MAX_ZOOM)
        vp = self.viewport().size()
        hbar, vbar = self.horizontalScrollBar(), self.verticalScrollBar()
        cx = (hbar.value() + vp.width() / 2) / self.zoom
        cy = (vbar.value() + vp.height() / 2) / self.zoom
        self.zoom = z1
        self._retile()
        hbar.setValue(int(round(cx * z1 - vp.width() / 2)))
        vbar.setValue(int(round(cy * z1 - vp.height() / 2)))
        self.canvas.update()
        self.editor.note_zoom_changed(z1)

    def zoom_in(self) -> None:
        self.set_zoom(self.zoom * ZOOM_STEP)

    def zoom_out(self) -> None:
        self.set_zoom(self.zoom / ZOOM_STEP)

    def zoom_to_fit(self) -> None:
        self.set_zoom(1.0)

    def wheelEvent(self, e) -> None:
        if e.modifiers() & Qt.KeyboardModifier.ControlModifier:
            notches = e.angleDelta().y() / 120.0
            if notches:
                self.set_zoom(self.zoom * (ZOOM_STEP ** notches))
            e.accept()
            return
        super().wheelEvent(e)

    def event(self, e) -> bool:
        if e.type() == QEvent.Type.NativeGesture and e.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            self.set_zoom(self.zoom * (1.0 + e.value()))
            return True
        return super().event(e)
