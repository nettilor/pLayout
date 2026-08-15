"""The keyboard & mouse card behind the toolbar's keyboard button — mirrors `ShortcutsCard`
in `Sources/PLayout/Views/ContentView.swift`, with the key names spelled for the platform."""
from __future__ import annotations

import sys

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QDialog, QGridLayout, QLabel, QVBoxLayout, QWidget

MAC = sys.platform == "darwin"
CMD = "⌘" if MAC else "Ctrl+"
ALT = "⌥" if MAC else "Alt+"
SHIFT = "⇧" if MAC else "Shift+"
DEL = "⌫" if MAC else "Backspace"
CMD_WORD = "⌘" if MAC else "Ctrl"
ALT_WORD = "⌥" if MAC else "Alt"
SHIFT_WORD = "⇧" if MAC else "Shift"


def rows() -> list[tuple[str, str]]:
    return [
        ("1 – 9, 0", "Arm condition 1–10"),
        ("[ / ]", "Previous / next condition"),
        ("drag", "Paint a rectangle of wells"),
        (f"{CMD_WORD} drag", "Free-hand brush · adds to the selection when disarmed"),
        (f"{ALT_WORD} drag", "Erase wells"),
        ("click A / 1", "Paint a whole row or column"),
        ("space / F", "Fill the current selection"),
        (DEL, f"Clear active factor ({CMD}{DEL} clears all)"),
        (f"{CMD_WORD} click", "Add or remove one well from the selection"),
        (f"{SHIFT_WORD} click", f"Extend the selection · {SHIFT_WORD}arrows too"),
        (f"{CMD}A", "Select every well"),
        ("⎋" if MAC else "Esc", "Disarm — select without painting"),
        ("click away", "Deselect — click off the plate"),
        (f"{SHIFT}{CMD}D", "Series Fill"),
        (f"{SHIFT}{CMD}Y", "XY Position Fill"),
        (f"{SHIFT}{CMD}R", "Randomise the selection"),
        (f"{ALT}{CMD}N", "Note on the selected well"),
        (f"{CMD}1 … {CMD}9", "Switch factor"),
        (f"{CMD_WORD} click row", "Select several sidebar rows to delete together"),
        ("rest on row", "Spotlight a condition — the rest of the plate dims"),
        ("click ↻ corner", f"Turn the plate 90°, and back again ({SHIFT}{CMD}L)"),
        (f"{SHIFT}{CMD}O", "Overview"),
        ("pinch" if MAC else "Ctrl+wheel", f"Zoom in · {CMD}0 fits the plate again"),
        (f"{CMD}C / {CMD}V", "Copy / paste as Excel cells"),
        (f"{SHIFT}{CMD}C", "Copy including row & column headers"),
        (f"{CMD}P", "Print the plate as shown"),
        (f"{ALT}{CMD}S", "Save this layout as a state"),
        (f"{ALT}{CMD}R", "Revert to the last saved state"),
        (f"{CMD}Z", "Undo — including saving and reverting states"),
    ]


class ShortcutsCard(QDialog):
    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent, Qt.WindowType.Popup)
        lay = QVBoxLayout(self)
        title = QLabel("Keyboard & Mouse")
        f = title.font()
        f.setBold(True)
        title.setFont(f)
        lay.addWidget(title)
        grid = QGridLayout()
        grid.setHorizontalSpacing(12)
        grid.setVerticalSpacing(3)
        for i, (key, text) in enumerate(rows()):
            k = QLabel(key)
            k.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            k.setMinimumWidth(96)
            k.setStyleSheet("font-weight: 600;")
            grid.addWidget(k, i, 0)
            t = QLabel(text)
            t.setWordWrap(True)
            t.setMinimumWidth(260)
            grid.addWidget(t, i, 1)
        grid.setColumnStretch(1, 1)
        lay.addLayout(grid)
        self.setMinimumWidth(420)
        self.adjustSize()
