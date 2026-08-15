"""Custom Plate Size — mirrors `Sources/PLayout/Views/CustomFormatSheet.swift` (PORT.md §A4).
Any layout from 1×1 up to 64×96, previewed as you type; optionally saved as a named
template; the size is applied through `editor.apply_custom_format`, which only saves the
template once the size has actually been applied (backing out of the data-loss warning
leaves nothing behind)."""
from __future__ import annotations

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QPainter, QPalette
from PySide6.QtWidgets import (
    QLayout,
    QCheckBox, QDialog, QDialogButtonBox, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit,
    QListWidget, QListWidgetItem, QPushButton, QSpinBox, QToolButton, QVBoxLayout, QWidget,
)

from playout.editor.plate_editor import PlateEditor
from playout.model.plate_format import COLUMN_RANGE, ROW_RANGE, PlateFormat, WellNaming
from playout.ui import fonts
from playout.ui.controls import CommitLineEdit


class PlatePreview(QWidget):
    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.rows, self.cols = 8, 12
        self.setFixedSize(210, 148)

    def set_shape(self, rows: int, cols: int) -> None:
        self.rows, self.cols = rows, cols
        self.update()

    def paintEvent(self, e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        w, h = self.width(), self.height()
        cell = min((w - 8) / self.cols, (h - 8) / self.rows)
        ox = (w - cell * self.cols) / 2
        oy = (h - cell * self.rows) / 2
        dot = max(1.0, cell * 0.72)
        p.setBrush(fonts.with_alpha(self.palette().color(QPalette.ColorRole.Highlight), 0.55))
        p.setPen(Qt.PenStyle.NoPen)
        for r in range(self.rows):
            for c in range(self.cols):
                p.drawEllipse(QRectF(ox + c * cell + (cell - dot) / 2, oy + r * cell + (cell - dot) / 2, dot, dot))
        p.end()


class CustomFormatDialog(QDialog):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.store = editor.template_store
        self.setWindowTitle("Custom Plate Size")
        self.setModal(True)
        self.setMinimumWidth(520)
        current = editor.format

        outer = QVBoxLayout(self)
        outer.setSizeConstraint(QLayout.SizeConstraint.SetFixedSize)
        title = QLabel("Custom Plate Size")
        f = title.font()
        f.setBold(True)
        f.setPointSizeF(f.pointSizeF() + 2)
        title.setFont(f)
        outer.addWidget(title)
        sub = QLabel("Any layout from 1×1 up to 64×96 wells.")
        sub.setStyleSheet(fonts.secondary_css(self))
        outer.addWidget(sub)

        body = QHBoxLayout()
        left = QGridLayout()
        left.setColumnMinimumWidth(1, 90)
        self.rows = QSpinBox()
        self.rows.setRange(*ROW_RANGE)
        self.rows.setValue(current.rows)
        self.cols = QSpinBox()
        self.cols.setRange(*COLUMN_RANGE)
        self.cols.setValue(current.cols)
        self.rows_hint = QLabel()
        self.cols_hint = QLabel()
        for lab in (self.rows_hint, self.cols_hint):
            lab.setStyleSheet(fonts.secondary_css(self))
        left.addWidget(QLabel("Rows"), 0, 0)
        left.addWidget(self.rows, 0, 1)
        left.addWidget(self.rows_hint, 0, 2)
        left.addWidget(QLabel("Columns"), 1, 0)
        left.addWidget(self.cols, 1, 1)
        left.addWidget(self.cols_hint, 1, 2)
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        left.addWidget(line, 2, 0, 1, 3)
        self.save_box = QCheckBox("Save as a template")
        self.save_box.setChecked(True)
        left.addWidget(self.save_box, 3, 0, 1, 3)
        self.status = QLabel()
        self.status.setWordWrap(True)
        self.status.setStyleSheet(fonts.secondary_css(self))
        left.addWidget(self.status, 4, 0, 1, 3)
        self.name_edit = QLineEdit()
        left.addWidget(QLabel("Name"), 5, 0)
        left.addWidget(self.name_edit, 5, 1, 1, 2)
        left.setRowStretch(6, 1)
        body.addLayout(left, 1)

        right = QVBoxLayout()
        self.count_label = QLabel()
        right.addWidget(self.count_label)
        self.preview = PlatePreview()
        right.addWidget(self.preview)
        self.wells_label = QLabel()
        self.wells_label.setStyleSheet(fonts.secondary_css(self))
        right.addWidget(self.wells_label)
        right.addStretch(1)
        body.addLayout(right)
        outer.addLayout(body)

        self.templates_header = QLabel("Saved templates")
        self.templates_header.setStyleSheet(fonts.secondary_css(self) + " margin-top: 6px;")
        outer.addWidget(self.templates_header)
        self.templates = QListWidget()
        self.templates.setMaximumHeight(108)
        outer.addWidget(self.templates)

        self.warning = QLabel("Some assigned wells fall outside this size")
        self.warning.setStyleSheet("color: #C25A00;")
        outer.addWidget(self.warning)
        buttons = QDialogButtonBox()
        self.use_button = QPushButton("Use Size")
        self.use_button.setDefault(True)
        buttons.addButton(self.use_button, QDialogButtonBox.ButtonRole.AcceptRole)
        buttons.addButton(QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.apply)
        buttons.rejected.connect(self.reject)
        outer.addWidget(buttons)

        self.rows.valueChanged.connect(self._sync)
        self.cols.valueChanged.connect(self._sync)
        self.save_box.toggled.connect(self._sync)
        self.store.changed.connect(self._sync)
        self._sync()

    # ------------------------------------------------------------------ state
    @property
    def fmt(self) -> PlateFormat:
        return PlateFormat(self.rows.value(), self.cols.value())

    def _sync(self, *_) -> None:
        fmt = self.fmt
        r, c = fmt.rows, fmt.cols
        self.rows_hint.setText(f"A–{WellNaming.row_label(r - 1)}")
        self.cols_hint.setText(f"1–{c}")
        self.count_label.setText(f"{fmt.well_count} wells")
        self.preview.set_shape(r, c)
        self.wells_label.setText(f"Wells A1 – {WellNaming.well_label(r - 1, c - 1, self.editor.layout.pad_well_labels)}")
        can_save = self.store.can_save(r, c)
        self.save_box.setEnabled(can_save)
        match = self.store.template_matching(r, c)
        if match is not None:
            self.status.setText(f'Already saved as "{match.name}".')
        elif fmt.is_standard:
            self.status.setText(f"{fmt.name} is a standard plate — it is already in the menu.")
        else:
            self.status.setText("")
        show_name = can_save and self.save_box.isChecked()
        self.name_edit.setVisible(show_name)
        self.name_edit.setPlaceholderText(f"{r}×{c} plate")
        self.status.setVisible(not show_name and bool(self.status.text()))
        plate = self.editor.plate
        self.warning.setVisible(plate is not None and plate.format_change_would_lose_data(fmt))
        self._fill_templates(fmt)

    def _fill_templates(self, fmt: PlateFormat) -> None:
        templates = self.store.templates
        self.templates_header.setVisible(bool(templates))
        self.templates.setVisible(bool(templates))
        self.templates.clear()
        for t in templates:
            item = QListWidgetItem()
            row = QWidget()
            lay = QHBoxLayout(row)
            lay.setContentsMargins(4, 0, 4, 0)
            name = CommitLineEdit(t.name, lambda text, tid=t.id: self.store.rename(tid, text))
            name.setFrame(False)
            lay.addWidget(name, 1)
            sub = QLabel(f"{t.rows * t.cols} wells · {t.rows}×{t.cols}")
            sub.setStyleSheet(fonts.secondary_css(self))
            lay.addWidget(sub)
            use = QToolButton()
            use.setText("Use")
            use.clicked.connect(lambda _=False, r=t.rows, c=t.cols: (self.rows.setValue(r), self.cols.setValue(c)))
            lay.addWidget(use)
            trash = QToolButton()
            trash.setText("✕")
            trash.setToolTip("Delete this template")
            trash.clicked.connect(lambda _=False, tid=t.id: self.store.remove(tid))
            lay.addWidget(trash)
            if PlateFormat(t.rows, t.cols) == fmt:
                row.setAutoFillBackground(True)
                pal = row.palette()
                pal.setColor(QPalette.ColorRole.Window, fonts.with_alpha(pal.color(QPalette.ColorRole.Highlight), 0.12))
                row.setPalette(pal)
            item.setSizeHint(row.sizeHint())
            self.templates.addItem(item)
            self.templates.setItemWidget(item, row)

    # ------------------------------------------------------------------ apply
    def apply(self) -> None:
        fmt = self.fmt
        template_name = None
        if self.save_box.isEnabled() and self.save_box.isChecked():
            template_name = self.name_edit.text().strip() or self.name_edit.placeholderText()
        if self.editor.apply_custom_format(fmt.rows, fmt.cols, template_name):
            self.accept()
        # else: the user backed out of the data-loss warning — the sheet stays open
