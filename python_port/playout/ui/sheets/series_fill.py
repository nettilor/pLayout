"""Series Fill — mirrors `Sources/PLayout/Views/SeriesFillSheet.swift` (PORT.md §A4).
Writes a value series across the selection: fold dilutions or linear steps, across columns
or down rows, an optional vehicle zero last; the live preview shows the values in the ramp
they will be coloured with. The maths lives in `PlateEditor.series_values`."""
from __future__ import annotations

from PySide6.QtCore import QLocale, QPoint, QRect, QSize, Qt
from PySide6.QtGui import QDoubleValidator
from PySide6.QtWidgets import (
    QLayout,
    QButtonGroup, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QGridLayout, QHBoxLayout, QLabel,
    QLineEdit, QSpinBox, QToolButton, QVBoxLayout, QWidget,
)

from playout.editor.plate_editor import PlateEditor, SeriesDirection, SeriesMode, SeriesSpec
from playout.model import palette
from playout.ui import fonts


def _segmented(options: list[tuple[str, object]], parent) -> tuple[QHBoxLayout, QButtonGroup, dict]:
    lay = QHBoxLayout()
    lay.setSpacing(0)
    group = QButtonGroup(parent)
    group.setExclusive(True)
    buttons = {}
    for i, (label, value) in enumerate(options):
        b = QToolButton()
        b.setText(label)
        b.setCheckable(True)
        b.setSizePolicy(b.sizePolicy().horizontalPolicy().Expanding, b.sizePolicy().verticalPolicy())
        b.setProperty("segmented", True)
        b.setProperty("first", i == 0)
        b.setProperty("last", i == len(options) - 1)
        group.addButton(b, i)
        buttons[value] = b
        lay.addWidget(b)
    return lay, group, buttons


class _NumberEdit(QLineEdit):
    """A number field that parses like Swift's `format: .number` (C locale)."""

    def __init__(self, value: float, parent=None):
        super().__init__(parent)
        v = QDoubleValidator(-1e12, 1e12, 10, self)
        v.setLocale(QLocale.c())
        v.setNotation(QDoubleValidator.Notation.StandardNotation)
        self.setValidator(v)
        self.set_value(value)

    def value(self) -> float:
        try:
            return float(self.text().replace(",", "."))
        except ValueError:
            return 0.0

    def set_value(self, value: float) -> None:
        text = f"{value:.10g}"
        self.setText(text)


class FlowLayout(QLayout):
    """A left-to-right layout that wraps to the next line — Qt's flow-layout example, so
    a preview of many chips grows down instead of pushing the sheet wider."""

    def __init__(self, parent=None, margin: int = 0, spacing: int = 4):
        super().__init__(parent)
        self.setContentsMargins(margin, margin, margin, margin)
        self._spacing = spacing
        self._items: list = []

    def addItem(self, item) -> None:
        self._items.append(item)

    def count(self) -> int:
        return len(self._items)

    def itemAt(self, index: int):
        return self._items[index] if 0 <= index < len(self._items) else None

    def takeAt(self, index: int):
        return self._items.pop(index) if 0 <= index < len(self._items) else None

    def expandingDirections(self):
        return Qt.Orientation(0)

    def hasHeightForWidth(self) -> bool:
        return True

    def heightForWidth(self, width: int) -> int:
        return self._do_layout(QRect(0, 0, width, 0), test_only=True)

    def setGeometry(self, rect: QRect) -> None:
        super().setGeometry(rect)
        self._do_layout(rect, test_only=False)

    def sizeHint(self) -> QSize:
        return self.minimumSize()

    def minimumSize(self) -> QSize:
        size = QSize()
        for item in self._items:
            size = size.expandedTo(item.minimumSize())
        m = self.contentsMargins()
        return size + QSize(m.left() + m.right(), m.top() + m.bottom())

    def _do_layout(self, rect: QRect, test_only: bool) -> int:
        m = self.contentsMargins()
        x = rect.x() + m.left()
        y = rect.y() + m.top()
        line_height = 0
        right = rect.right() - m.right()
        for item in self._items:
            hint = item.sizeHint()
            next_x = x + hint.width() + self._spacing
            if next_x - self._spacing > right and line_height > 0:
                x = rect.x() + m.left()
                y = y + line_height + self._spacing
                next_x = x + hint.width() + self._spacing
                line_height = 0
            if not test_only:
                item.setGeometry(QRect(QPoint(x, y), hint))
            x = next_x
            line_height = max(line_height, hint.height())
        return y + line_height - rect.y() + m.bottom()


class ChipRow(QWidget):
    """The preview: coloured value chips, wrapping onto further lines as needed."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.lay = FlowLayout(self, 0, 4)
        self.empty = QLabel("")
        self.empty.setStyleSheet(fonts.secondary_css(self))
        self.lay.addWidget(self.empty)
        self.chips: list[QLabel] = []
        self.setMinimumWidth(300)

    def set_items(self, items: list[tuple[str, str | None]], empty_text: str, trailing: str = "") -> None:
        for c in self.chips:
            self.lay.removeWidget(c)
            c.deleteLater()
        self.chips = []
        if not items:
            self.empty.setText(empty_text)
            self.empty.show()
            self.updateGeometry()
            return
        self.empty.hide()
        for text, hex_text in items:
            chip = QLabel(text)
            chip.setAlignment(Qt.AlignmentFlag.AlignCenter)
            if hex_text:
                ink = "white" if palette.label_is_white(hex_text) else "black"
                chip.setStyleSheet(f"background: {hex_text}; color: {ink}; border-radius: 4px; padding: 2px 6px;")
            else:
                chip.setStyleSheet("padding: 2px 6px;")
            self.lay.addWidget(chip)
            self.chips.append(chip)
        if trailing:
            tail = QLabel(trailing)
            tail.setStyleSheet(fonts.secondary_css(self) + " padding: 2px 4px;")
            self.lay.addWidget(tail)
            self.chips.append(tail)
        self.updateGeometry()


class SeriesFillDialog(QDialog):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.setWindowTitle("Series Fill")
        self.setModal(True)
        self.setMinimumWidth(460)
        outer = QVBoxLayout(self)
        outer.setSizeConstraint(QLayout.SizeConstraint.SetFixedSize)
        title = QLabel("Series Fill")
        f = title.font()
        f.setBold(True)
        f.setPointSizeF(f.pointSizeF() + 2)
        title.setFont(f)
        outer.addWidget(title)
        sub = QLabel(f"Writes a value series into {self._selection_description()} of {editor.active_factor.name if editor.active_factor else 'the active factor'}.")
        sub.setWordWrap(True)
        sub.setStyleSheet(fonts.secondary_css(self))
        outer.addWidget(sub)

        grid = QGridLayout()
        grid.setColumnMinimumWidth(0, 120)
        row = 0
        grid.addWidget(QLabel("Direction"), row, 0)
        dir_lay, self.dir_group, self.dir_buttons = _segmented([(d.label, d) for d in SeriesDirection], self)
        grid.addLayout(dir_lay, row, 1)
        row += 1
        grid.addWidget(QLabel("Series"), row, 0)
        mode_lay, self.mode_group, self.mode_buttons = _segmented([(m.label, m) for m in SeriesMode], self)
        grid.addLayout(mode_lay, row, 1)
        row += 1
        grid.addWidget(QLabel("Top value"), row, 0)
        self.start = _NumberEdit(10)
        grid.addWidget(self.start, row, 1)
        row += 1
        self.fold_label = QLabel("Fold")
        self.step_label = QLabel("Step")
        grid.addWidget(self.fold_label, row, 0)
        grid.addWidget(self.step_label, row, 0)
        fold_row = QHBoxLayout()
        fold_row.setContentsMargins(0, 0, 0, 0)
        self.fold = _NumberEdit(3)
        self.fold.setFixedWidth(70)
        self.dilute = QComboBox()
        self.dilute.addItem("dilution (÷)", True)
        self.dilute.addItem("increase (×)", False)
        fold_row.addWidget(self.fold)
        fold_row.addWidget(self.dilute)
        fold_row.addStretch(1)
        self.fold_container = QWidget()
        self.fold_container.setLayout(fold_row)
        self.step = _NumberEdit(-1)
        grid.addWidget(self.fold_container, row, 1)
        grid.addWidget(self.step, row, 1)
        row += 1
        self.digits_label = QLabel("Significant digits")
        grid.addWidget(self.digits_label, row, 0)
        digits_row = QHBoxLayout()
        digits_row.setContentsMargins(0, 0, 0, 0)
        self.digits = QSpinBox()
        self.digits.setRange(1, 6)
        self.digits.setValue(3)
        self.digits.setFixedWidth(70)
        digits_row.addWidget(self.digits)
        digits_row.addStretch(1)
        grid.addLayout(digits_row, row, 1)
        row += 1
        self.last_zero = QCheckBox("Last position is 0 (vehicle control)")
        grid.addWidget(self.last_zero, row, 1)
        outer.addLayout(grid)

        preview_head = QLabel("Preview")
        preview_head.setStyleSheet(fonts.secondary_css(self) + " margin-top: 8px;")
        outer.addWidget(preview_head)
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

        self.dir_buttons[SeriesDirection.acrossColumns].setChecked(True)
        self.mode_buttons[SeriesMode.fold].setChecked(True)
        for w in (self.dir_group, self.mode_group):
            w.idClicked.connect(self._sync)
        for w in (self.start, self.fold, self.step):
            w.textChanged.connect(self._sync)
        self.dilute.currentIndexChanged.connect(self._sync)
        self.digits.valueChanged.connect(self._sync)
        self.last_zero.toggled.connect(self._sync)
        self._sync()

    def _selection_description(self) -> str:
        sel = self.editor.selection
        return f"{sel.row_count}×{sel.col_count} wells" if sel is not None else "the selection"

    @property
    def spec(self) -> SeriesSpec:
        direction = next(d for d, b in self.dir_buttons.items() if b.isChecked())
        mode = next(m for m, b in self.mode_buttons.items() if b.isChecked())
        return SeriesSpec(
            direction=direction, mode=mode, start=self.start.value(), fold_factor=self.fold.value(),
            dilute=bool(self.dilute.currentData()), step=self.step.value(),
            significant_digits=self.digits.value(), last_is_zero=self.last_zero.isChecked(),
        )

    def _sync(self, *_) -> None:
        spec = self.spec
        fold = spec.mode is SeriesMode.fold
        self.fold_label.setVisible(fold)
        self.fold_container.setVisible(fold)
        self.step_label.setVisible(not fold)
        self.step.setVisible(not fold)
        values = self.editor.series_values(spec)
        f = self.editor.active_factor
        base = f.levels[0].color_hex if f and f.levels else palette.color_at(0)
        ramp = palette.ramp(max(len(values), 1), base)
        self.preview.set_items(list(zip(values, ramp)), "Select some wells first.")
        self.fill_button.setEnabled(bool(values))

    def apply(self) -> None:
        if not self.editor.series_values(self.spec):
            return
        self.editor.apply_series(self.spec)
        self.accept()
