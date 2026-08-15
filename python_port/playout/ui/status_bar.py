"""The status row under the plate — mirrors the status bar in
`Sources/PLayout/Views/ContentView.swift` (PORT.md §A3). A plain widget row rather than a
`QStatusBar`, whose temporary message would hide the permanent widgets and whose own
timeout would fight the editor's 3 s flash."""
from __future__ import annotations

from PySide6.QtCore import QRectF, QSize, Qt
from PySide6.QtGui import QColor, QPainter, QPixmap
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QSizePolicy, QToolButton, QWidget

from playout.editor.plate_editor import PlateEditor
from playout.model.plate_format import WellNaming
from playout.ui import fonts

HEIGHT = 26


def _dot(hex_text: str | None) -> QPixmap:
    pm = QPixmap(18, 18)
    pm.setDevicePixelRatio(2.0)
    pm.fill(Qt.GlobalColor.transparent)
    if hex_text:
        p = QPainter(pm)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setBrush(fonts.qcolor(hex_text) or QColor(128, 128, 128))
        p.setPen(QColor(0, 0, 0, 50))
        p.drawEllipse(QRectF(0.5, 0.5, 8, 8))
        p.end()
    return pm


def _vline() -> QFrame:
    f = QFrame()
    f.setFrameShape(QFrame.Shape.VLine)
    f.setFrameShadow(QFrame.Shadow.Sunken)
    return f


class StatusRow(QWidget):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.setFixedHeight(HEIGHT)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(10, 0, 10, 0)
        lay.setSpacing(8)
        self.dot = QLabel()
        self.dot.setFixedSize(9, 9)
        self.armed = QLabel()
        self.summary = QLabel()
        self.summary.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        self.flash = QLabel()
        self.flash.setStyleSheet("color: palette(highlight);")
        self.zoom_button = QToolButton()
        self.zoom_button.setAutoRaise(True)
        self.zoom_button.setToolTip("Fit the plate to the window (Ctrl+0)")
        self.zoom_button.clicked.connect(editor.zoom_to_fit)
        self.zoom_button.hide()
        self.selection = QLabel()
        for w in (self.dot, self.armed, _vline(), self.summary):
            lay.addWidget(w)
        lay.addStretch(1)
        for w in (self.flash, self.zoom_button, _vline(), self.selection):
            lay.addWidget(w)
        self._summary_full = ""
        editor.state_changed.connect(self.refresh)
        editor.layout_changed.connect(self.refresh)
        editor.flash_message.connect(self._on_flash)
        editor.zoom_changed.connect(self.refresh)
        self.refresh()

    def _on_flash(self, text: str) -> None:
        self.flash.setText(text)

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self._elide()

    def _elide(self) -> None:
        m = self.summary.fontMetrics()
        self.summary.setText(m.elidedText(self._summary_full, Qt.TextElideMode.ElideMiddle, max(50, self.summary.width())))

    def refresh(self) -> None:
        ed = self.editor
        armed = ed.armed_level
        if armed is not None and ed.active_factor is not None:
            self.dot.setPixmap(_dot(armed.color_hex))
            self.armed.setText(f"{ed.active_factor.name}: {armed.name}")
        else:
            self.dot.setPixmap(_dot(None))
            self.armed.setText("Overview — click a factor to start painting" if ed.is_overview
                               else "No condition armed — press 1–9 to pick one")
        self._summary_full = self._summary_text()
        self._elide()
        self.flash.setText(ed.transient_message)
        if ed.can_zoom_out:
            self.zoom_button.setText(f"{round(ed.zoom_level * 100)}%")
            self.zoom_button.show()
        else:
            self.zoom_button.hide()
        self.selection.setText(self._selection_text())

    def _summary_text(self) -> str:
        ed = self.editor
        pos = ed.hovered
        if pos is None:
            if ed.selection is not None:
                pos = ed.selection.focus
            elif ed.custom_focus is not None:
                pos = ed.custom_focus
        return ed.summary(pos.row, pos.col) if pos is not None else ""

    def _selection_text(self) -> str:
        ed = self.editor
        if ed.custom_wells:
            return f"{len(ed.custom_wells)} wells selected"
        sel = ed.selection
        if sel is None:
            return "No selection"
        padded = ed.layout.pad_well_labels
        if sel.is_single_well:
            return WellNaming.well_label(sel.min_row, sel.min_col, padded)
        a = WellNaming.well_label(sel.min_row, sel.min_col, padded)
        b = WellNaming.well_label(sel.max_row, sel.max_col, padded)
        return f"{a}:{b}  ·  {sel.row_count}×{sel.col_count} = {sel.well_count}"
