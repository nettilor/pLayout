"""The plate tab bar — mirrors the tab bar in `Sources/PLayout/Views/ContentView.swift`
(PORT.md §A3): one chip per plate ("name  ·  format"), a "+" to add another; a click
activates (and puts the selection back on A1), a second click renames in place, and the
context menu offers Rename / Duplicate / Plate Note… / Delete."""
from __future__ import annotations

from PySide6.QtCore import QEvent, Qt, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import QHBoxLayout, QLineEdit, QMenu, QTabBar, QToolButton, QWidget

from playout.editor.plate_editor import PlateEditor

HEIGHT = 34


class _InlineEdit(QLineEdit):
    cancelled = Signal()

    def keyPressEvent(self, e) -> None:
        if e.key() == Qt.Key.Key_Escape:
            self.cancelled.emit()
            return
        super().keyPressEvent(e)


class PlateTabBar(QWidget):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.setFixedHeight(HEIGHT)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(6, 2, 6, 0)
        lay.setSpacing(4)
        self.tabs = QTabBar()
        self.tabs.setTabsClosable(False)
        self.tabs.setMovable(False)
        self.tabs.setExpanding(False)
        self.tabs.setUsesScrollButtons(True)
        self.tabs.setDocumentMode(True)
        self.tabs.setDrawBase(False)
        self.tabs.setElideMode(Qt.TextElideMode.ElideNone)
        self.tabs.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self._style_chips()
        self.tabs.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tabs.customContextMenuRequested.connect(self._context_menu)
        self.tabs.tabBarClicked.connect(self._clicked)
        self.tabs.tabBarDoubleClicked.connect(self._double_clicked)
        lay.addWidget(self.tabs)
        self.add_button = QToolButton()
        self.add_button.setText("+")
        self.add_button.setAutoRaise(True)
        self.add_button.setToolTip("Add another plate to this layout")
        self.add_button.clicked.connect(editor.add_plate)
        lay.addWidget(self.add_button)
        lay.addStretch(1)
        self._rebuilding = False
        self._rename_edit: _InlineEdit | None = None
        editor.layout_changed.connect(self.refresh)
        editor.state_changed.connect(self.refresh)
        self.refresh()

    def _style_chips(self) -> None:
        """Rounded chips like the Mac's plate tabs: accent-tinted when active."""
        pal = self.palette()
        accent = pal.color(pal.ColorRole.Highlight)
        tint = QColor(accent)
        tint.setAlphaF(0.14)
        border = QColor(accent)
        border.setAlphaF(0.55)
        text = pal.color(pal.ColorRole.WindowText).name()
        mid = QColor(pal.color(pal.ColorRole.Mid))
        mid.setAlphaF(0.6)
        self.tabs.setStyleSheet(
            "QTabBar { background: transparent; }"
            "QTabBar::tab { border: 1px solid " + mid.name(QColor.NameFormat.HexArgb) + "; border-radius: 7px;"
            " padding: 3px 10px; margin: 2px 3px; background: transparent; color: " + text + "; }"
            "QTabBar::tab:selected { background: " + tint.name(QColor.NameFormat.HexArgb) + ";"
            " border-color: " + border.name(QColor.NameFormat.HexArgb) + "; font-weight: 600; }"
            "QTabBar::tab:hover:!selected { background: " + QColor(0, 0, 0, 12).name(QColor.NameFormat.HexArgb) + "; }"
        )

    def changeEvent(self, e) -> None:
        if e.type() == QEvent.Type.PaletteChange:
            self._style_chips()
        super().changeEvent(e)

    # ------------------------------------------------------------------ model → tabs
    def refresh(self) -> None:
        if self._rename_edit is not None:
            return
        ed = self.editor
        plates = ed.layout.plates
        self._rebuilding = True
        self.tabs.blockSignals(True)
        while self.tabs.count() > len(plates):
            self.tabs.removeTab(self.tabs.count() - 1)
        while self.tabs.count() < len(plates):
            self.tabs.addTab("")
        for i, plate in enumerate(plates):
            self.tabs.setTabText(i, f"{plate.name}  ·  {ed.format_display_name(plate.format)}")
            self.tabs.setTabData(i, plate.id)
            self.tabs.setTabToolTip(i, "Double-click to rename")
        idx = ed.plate_index
        if 0 <= idx < self.tabs.count():
            self.tabs.setCurrentIndex(idx)
        self.tabs.blockSignals(False)
        self._rebuilding = False

    # ------------------------------------------------------------------ tabs → editor
    def _plate_id(self, index: int) -> str | None:
        return self.tabs.tabData(index) if 0 <= index < self.tabs.count() else None

    def _clicked(self, index: int) -> None:
        if self._rebuilding:
            return
        pid = self._plate_id(index)
        if pid is not None:
            self.editor.set_active_plate(pid)
            self.editor.focus_canvas()

    def _double_clicked(self, index: int) -> None:
        pid = self._plate_id(index)
        if pid is not None:
            self.editor.set_active_plate(pid)
            self.begin_rename(index)

    def begin_rename(self, index: int) -> None:
        pid = self._plate_id(index)
        plate = self.editor.layout.plate(pid) if pid else None
        if plate is None:
            return
        edit = _InlineEdit(self.tabs)
        edit.setText(plate.name)
        edit.setGeometry(self.tabs.tabRect(index))
        edit.selectAll()
        edit.show()
        edit.setFocus()
        self._rename_edit = edit

        def finish(commit: bool):
            if self._rename_edit is not edit:
                return
            self._rename_edit = None
            text = edit.text()
            edit.deleteLater()
            if commit:
                self.editor.rename_plate(pid, text)
            self.refresh()
            self.editor.focus_canvas()

        edit.editingFinished.connect(lambda: finish(True))
        edit.cancelled.connect(lambda: finish(False))

    def _context_menu(self, pos) -> None:
        index = self.tabs.tabAt(pos)
        pid = self._plate_id(index)
        if pid is None:
            return
        menu = self.menu_for(index)
        menu.exec(self.tabs.mapToGlobal(pos))

    def menu_for(self, index: int) -> QMenu:
        ed = self.editor
        pid = self._plate_id(index)
        menu = QMenu(self)
        menu.addAction("Rename Plate", lambda: (ed.set_active_plate(pid), self.begin_rename(index)))
        menu.addAction("Duplicate Plate", lambda: (ed.set_active_plate(pid), ed.duplicate_plate()))
        menu.addAction("Plate Note…", lambda: (ed.set_active_plate(pid), ed.open_plate_note_sheet()))
        menu.addSeparator()
        delete = menu.addAction("Delete Plate", lambda: ed.delete_plate(pid))
        delete.setEnabled(len(ed.layout.plates) > 1)
        return menu
