"""The colour grid popover — mirrors `SwatchPicker` in `Sources/PLayout/Views/Controls.swift`
(PORT.md §A4). Columns are hues (the column *is* the meaning), rows are shades lightest to
darkest with the base hue in the middle; three families; the current colour outlined;
colours another condition already uses carry a dot; Custom… opens the system dialog."""
from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import (
    QButtonGroup, QColorDialog, QDialog, QFrame, QGridLayout, QHBoxLayout, QLabel, QPushButton,
    QToolButton, QVBoxLayout, QWidget,
)

from playout.model import palette
from playout.model.palette import FAMILIES, Family
from playout.ui import fonts

SHADE_COUNT = 5
SWATCH = 22
GAP = 5


class SwatchCell(QToolButton):
    def __init__(self, hex_text: str, current: bool, taken: bool, on_pick: Callable[[str], None]):
        super().__init__()
        self.hex_text = hex_text
        self.current = current
        self.taken = taken
        self.setFixedSize(SWATCH, SWATCH)
        self.setAutoRaise(True)
        self.setToolTip(f"{hex_text} — already used by another condition" if taken else hex_text)
        self.clicked.connect(lambda: on_pick(hex_text))

    def paintEvent(self, e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        colour = fonts.qcolor(self.hex_text) or QColor(128, 128, 128)
        r = QRectF(0.5, 0.5, SWATCH - 1, SWATCH - 1)
        p.setBrush(colour)
        if self.current:
            accent = self.palette().color(self.palette().ColorRole.Highlight)
            p.setPen(__import__("PySide6.QtGui", fromlist=["QPen"]).QPen(accent, 2))
            p.drawRoundedRect(r.adjusted(0.5, 0.5, -0.5, -0.5), 4, 4)
        else:
            p.setPen(QColor(0, 0, 0, 38))
            p.drawRoundedRect(r, 4, 4)
        if self.taken:
            ink = fonts.WHITE if palette.label_is_white(self.hex_text) else QColor(0, 0, 0, 217)
            p.setBrush(ink)
            p.setPen(Qt.PenStyle.NoPen)
            p.drawEllipse(QRectF(SWATCH - 2.5 - 5, 2.5, 5, 5))
        p.end()


class ColourGridPopover(QDialog):
    picked = Signal(str)

    def __init__(self, current_hex: str, used: list[str] | tuple[str, ...] = (), parent: QWidget | None = None,
                 family: Family | None = None):
        super().__init__(parent, Qt.WindowType.Popup)
        self.current_hex = current_hex
        self.used = list(used)
        self.family = family or FAMILIES[0]
        outer = QVBoxLayout(self)
        outer.setContentsMargins(12, 12, 12, 12)
        outer.setSpacing(8)
        fam_row = QHBoxLayout()
        fam_row.setSpacing(0)
        self.family_group = QButtonGroup(self)
        self.family_group.setExclusive(True)
        self.family_buttons: dict[Family, QToolButton] = {}
        for i, fam in enumerate(FAMILIES):
            b = QToolButton()
            b.setText(fam.label)
            b.setCheckable(True)
            b.setProperty("segmented", True)
            b.setProperty("first", i == 0)
            b.setProperty("last", i == len(FAMILIES) - 1)
            b.setChecked(fam is self.family)
            b.setSizePolicy(b.sizePolicy().horizontalPolicy().Expanding, b.sizePolicy().verticalPolicy())
            self.family_group.addButton(b, i)
            self.family_buttons[fam] = b
            fam_row.addWidget(b)
        self.family_group.idClicked.connect(self._family_clicked)
        outer.addLayout(fam_row)
        self.grid_host = QWidget()
        self.grid = QGridLayout(self.grid_host)
        self.grid.setContentsMargins(0, 0, 0, 0)
        self.grid.setSpacing(GAP)
        outer.addWidget(self.grid_host)
        self.note = QLabel()
        self.note.setWordWrap(True)
        self.note.setStyleSheet(fonts.secondary_css(self))
        self.note.setMinimumHeight(26)
        self.note.setFixedWidth(SWATCH * 8 + GAP * 7)
        outer.addWidget(self.note)
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        outer.addWidget(line)
        custom = QPushButton("Custom…")
        custom.setFlat(True)
        custom.clicked.connect(self._custom)
        outer.addWidget(custom, 0, Qt.AlignmentFlag.AlignLeft)
        self.cells: list[SwatchCell] = []
        self._rebuild()

    def _family_clicked(self, index: int) -> None:
        self.family = FAMILIES[index]
        self._rebuild()

    def _rebuild(self) -> None:
        for c in self.cells:
            self.grid.removeWidget(c)
            c.deleteLater()
        self.cells = []
        for col, hue in enumerate(self.family.hues):
            for row, shade in enumerate(palette.shades(hue, SHADE_COUNT)):
                current = palette.matches(shade, self.current_hex)
                taken = any(palette.matches(u, shade) for u in self.used)
                cell = SwatchCell(shade, current, taken, self._pick)
                self.grid.addWidget(cell, row, col)
                self.cells.append(cell)
        self.note.setText(self.family.note)

    def _pick(self, hex_text: str) -> None:
        self.picked.emit(hex_text)
        self.close()

    def _custom(self) -> None:
        colour = QColorDialog.getColor(fonts.qcolor(self.current_hex) or QColor(128, 128, 128), self, "Custom colour")
        if colour.isValid():
            self._pick(colour.name(QColor.NameFormat.HexRgb).upper())

    def shown_hexes(self) -> list[str]:
        return [c.hex_text for c in self.cells]

    def current_cells(self) -> list[SwatchCell]:
        return [c for c in self.cells if c.current]

    def taken_cells(self) -> list[SwatchCell]:
        return [c for c in self.cells if c.taken]


def show_colour_grid(anchor: QWidget, current_hex: str, used, on_pick: Callable[[str], None]) -> ColourGridPopover:
    pop = ColourGridPopover(current_hex, used, anchor.window())
    pop.picked.connect(on_pick)
    pop.move(anchor.mapToGlobal(anchor.rect().bottomLeft()))
    pop.show()
    return pop
