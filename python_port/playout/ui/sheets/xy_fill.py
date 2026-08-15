"""XY Position Fill — mirrors `Sources/PLayout/Views/XYFillSheet.swift` (PORT.md §A4).
Numbers wells as Keyence-style imaging positions in the order the stage visits them,
walking the plate as displayed. The order and naming live in `PlateEditor.xy_fill_wells`."""
from __future__ import annotations

from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QLayout,
    QColorDialog, QDialog, QDialogButtonBox, QGridLayout, QHBoxLayout, QLabel, QVBoxLayout, QWidget,
)

from playout.editor.plate_editor import PlateEditor, XYFillSpec, XYPattern, xy_names
from playout.model import palette
from playout.ui import fonts
from playout.ui.controls import SwatchButton
from playout.ui.sheets.series_fill import ChipRow, _segmented

PREVIEW_CHIPS = 16


class XYFillDialog(QDialog):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.setWindowTitle("XY Position Fill")
        self.setModal(True)
        self.setMinimumWidth(460)
        outer = QVBoxLayout(self)
        outer.setSizeConstraint(QLayout.SizeConstraint.SetFixedSize)
        title = QLabel("XY Position Fill")
        f = title.font()
        f.setBold(True)
        f.setPointSizeF(f.pointSizeF() + 2)
        title.setFont(f)
        outer.addWidget(title)
        sub = QLabel(f"Numbers {self._target_description()} as factor “XY”, in the order the microscope visits them.")
        sub.setWordWrap(True)
        sub.setStyleSheet(fonts.secondary_css(self))
        outer.addWidget(sub)

        grid = QGridLayout()
        grid.setColumnMinimumWidth(0, 120)
        grid.addWidget(QLabel("Pattern"), 0, 0)
        pat_lay, self.pattern_group, self.pattern_buttons = _segmented([(p.label, p) for p in XYPattern], self)
        grid.addLayout(pat_lay, 0, 1)
        grid.addWidget(QLabel("Gradient colour"), 1, 0)
        existing = editor.existing_xy_factor()
        if existing is not None and existing.levels:
            self.base_hex = existing.levels[0].color_hex
        else:
            self.base_hex = editor.new_level_color(editor.layout, len(editor.layout.factors))
        swatch_row = QHBoxLayout()
        self.swatch = SwatchButton(self.base_hex)
        self.swatch.setToolTip("Pick the hue for the position gradient")
        self.swatch.clicked.connect(self._pick_colour)
        swatch_row.addWidget(self.swatch)
        swatch_row.addStretch(1)
        grid.addLayout(swatch_row, 1, 1)
        outer.addLayout(grid)

        head = QLabel("Preview")
        head.setStyleSheet(fonts.secondary_css(self) + " margin-top: 8px;")
        outer.addWidget(head)
        self.preview = ChipRow()
        outer.addWidget(self.preview)

        buttons = QDialogButtonBox()
        self.fill_button = buttons.addButton("Fill", QDialogButtonBox.ButtonRole.AcceptRole)
        self.fill_button.setDefault(True)
        cancel = buttons.addButton(QDialogButtonBox.StandardButton.Cancel)
        cancel.setAutoDefault(False)
        cancel.setDefault(False)
        self.fill_button.setAutoDefault(True)
        self.fill_button.setDefault(True)
        buttons.accepted.connect(self.apply)
        buttons.rejected.connect(self.reject)
        outer.addWidget(buttons)

        self.pattern_buttons[XYPattern.acrossColumns].setChecked(True)
        self.pattern_group.idClicked.connect(self._sync)
        self._sync()

    def _target_description(self) -> str:
        ed = self.editor
        if ed.custom_wells:
            return f"the {len(ed.custom_wells)} selected wells"
        sel = ed.selection
        if sel is None or sel.is_single_well:
            return "the whole plate"
        return f"{sel.row_count}×{sel.col_count} wells"

    @property
    def spec(self) -> XYFillSpec:
        pattern = next(p for p, b in self.pattern_buttons.items() if b.isChecked())
        return XYFillSpec(pattern=pattern, base_hex=self.base_hex)

    def _pick_colour(self) -> None:
        from playout.ui.colour_grid import show_colour_grid

        def picked(hx: str) -> None:
            self.base_hex = hx
            self.swatch.set_hex(hx)
            self._sync()

        self._colour_popover = show_colour_grid(self.swatch, self.base_hex, [], picked)

    def _sync(self, *_) -> None:
        wells = self.editor.xy_fill_wells(self.spec)
        names = xy_names(len(wells))
        ramp = palette.ramp(len(names), self.base_hex) if names else []
        shown = list(zip(names[:PREVIEW_CHIPS], ramp[:PREVIEW_CHIPS]))
        trailing = f"→ {names[-1]}" if len(names) > PREVIEW_CHIPS else ""
        self.preview.set_items(shown, "No plate to number.", trailing)
        self.fill_button.setEnabled(bool(names))

    def apply(self) -> None:
        if not self.editor.xy_fill_wells(self.spec):
            return
        self.editor.apply_xy_fill(self.spec)
        self.accept()
