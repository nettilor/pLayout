"""Workbook export options — mirrors `WorkbookLayoutAccessory.swift` (PORT.md §A4). The Mac
puts these in the save panel; the port asks *before* the file dialog. Every choice is
remembered in Preferences and re-read next time."""
from __future__ import annotations

from PySide6.QtWidgets import (
    QLayout,
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QGridLayout, QHBoxLayout, QLabel, QLineEdit, QVBoxLayout, QWidget,
)

from playout.io.table_io import WorkbookLayout, WorkbookScope
from playout.ui import fonts
from playout.model.preferences import Preferences


def _elide(name: str, limit: int = 25) -> str:
    return name if len(name) <= limit else name[:limit] + "…"


class WorkbookOptionsDialog(QDialog):
    def __init__(self, prefs: Preferences, plate_count: int, active_plate_name: str, parent: QWidget | None = None):
        super().__init__(parent)
        self.prefs = prefs
        self.setWindowTitle("Export Excel Workbook")
        self.setModal(True)
        self.setMinimumWidth(470)
        outer = QVBoxLayout(self)
        outer.setSizeConstraint(QLayout.SizeConstraint.SetFixedSize)
        grid = QGridLayout()
        grid.setColumnMinimumWidth(0, 100)

        grid.addWidget(QLabel("Plate maps:"), 0, 0)
        self.arrangement = QComboBox()
        for layout in WorkbookLayout:
            self.arrangement.addItem(layout.label, layout.value)
        self.arrangement.setCurrentIndex(list(WorkbookLayout).index(WorkbookLayout.lenient(prefs.workbook_sheet_layout)))
        grid.addWidget(self.arrangement, 0, 1)
        self.detail = QLabel()
        self.detail.setStyleSheet(fonts.secondary_css(self))
        self.detail.setWordWrap(True)
        grid.addWidget(self.detail, 1, 1)

        grid.addWidget(QLabel("One-cell map:"), 2, 0)
        joint_row = QHBoxLayout()
        self.joint = QCheckBox("All factors in one cell, joined by")
        self.joint.setChecked(prefs.workbook_joint_map_enabled)
        self.separator = QLineEdit(prefs.workbook_joint_map_separator)
        self.separator.setPlaceholderText("+")
        self.separator.setFixedWidth(44)
        self.separator.setAlignment(__import__("PySide6.QtCore", fromlist=["Qt"]).Qt.AlignmentFlag.AlignCenter)
        joint_row.addWidget(self.joint)
        joint_row.addWidget(self.separator)
        joint_row.addStretch(1)
        grid.addLayout(joint_row, 2, 1)

        self.scope_label = QLabel("Plates:")
        self.scope = QComboBox()
        self.scope.addItem("All plates", WorkbookScope.allPlates.value)
        self.scope.addItem(f'Just "{_elide(active_plate_name)}"', WorkbookScope.activePlate.value)
        self.scope.setCurrentIndex(0 if WorkbookScope.lenient(prefs.workbook_scope) is WorkbookScope.allPlates else 1)
        grid.addWidget(self.scope_label, 3, 0)
        grid.addWidget(self.scope, 3, 1)
        show_scope = plate_count > 1
        self.scope_label.setVisible(show_scope)
        self.scope.setVisible(show_scope)
        self._show_scope = show_scope
        outer.addLayout(grid)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("Export…")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        outer.addWidget(buttons)
        self.arrangement.currentIndexChanged.connect(self._sync)
        self._sync()

    def _sync(self, *_):
        self.detail.setText(self.selected_layout.detail)

    @property
    def selected_layout(self) -> WorkbookLayout:
        return WorkbookLayout(self.arrangement.currentData())

    @property
    def selected_scope(self) -> WorkbookScope:
        return WorkbookScope(self.scope.currentData()) if self._show_scope else WorkbookScope.allPlates

    @property
    def joint_enabled(self) -> bool:
        return self.joint.isChecked()

    @property
    def joint_separator_typed(self) -> str:
        return self.separator.text()

    def remember(self) -> None:
        self.prefs.workbook_sheet_layout = self.selected_layout.value
        if self._show_scope:
            self.prefs.workbook_scope = self.selected_scope.value
        self.prefs.workbook_joint_map_enabled = self.joint_enabled
        self.prefs.workbook_joint_map_separator = self.joint_separator_typed
