"""The document window: menus, toolbar, sidebar | plate tabs / canvas / status row.

Mirrors `Sources/PLayout/Views/ContentView.swift` and the menus in `App.swift`
(PORT.md §A1–§A3). One window per document; the window owns a `PlateEditor` and wires the
handful of hooks the editor needs from a UI (clipboard, the data-loss confirm, alerts,
sheets). Nothing in the toolbar or menus is hidden or disabled while the app is in use —
things that are not built yet say so in the status bar (the Mac rule).
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import TYPE_CHECKING

from PySide6.QtCore import QEvent, QSize, Qt
from PySide6.QtGui import QAction, QActionGroup, QKeySequence, QPalette
from PySide6.QtWidgets import (
    QApplication, QDialog, QFileDialog, QInputDialog, QMainWindow, QMenu, QMessageBox, QSplitter, QToolBar,
    QToolButton, QVBoxLayout, QWidget, QWidgetAction,
)

from playout.editor.document import PlateDocument
from playout.editor.plate_editor import NoteTarget, PlateEditor
from playout.model.layout import LayoutDecodeError, WellLabelMode
from playout.model.plate_format import STANDARD, PlateFormat
from playout.ui import icons
from playout.ui.plate_canvas import PlateScrollArea
from playout.ui.plate_tabs import PlateTabBar
from playout.ui.sidebar import Sidebar
from playout.ui.status_bar import StatusRow

if TYPE_CHECKING:
    from playout.app import App

PLATE_FILTER = "Plate layout (*.plate)"


class MenuToolButton(QToolButton):
    """A toolbar button that opens a menu: the glyph at full size, a small chevron painted
    to its right by us (Qt's own menu arrow is oversized and overlaps the icon)."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setStyleSheet("QToolButton::menu-indicator { image: none; }")

    def paintEvent(self, e) -> None:
        super().paintEvent(e)
        from PySide6.QtCore import QPointF
        from PySide6.QtGui import QPainter, QPen

        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        pen = QPen(self.palette().color(QPalette.ColorRole.WindowText), 1.4)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
        p.setPen(pen)
        cx = self.width() - 7.0
        cy = self.height() / 2 + 0.5
        p.drawPolyline([QPointF(cx - 2.4, cy - 1.2), QPointF(cx, cy + 1.2), QPointF(cx + 2.4, cy - 1.2)])
        p.end()


class QtClipboard:
    def text(self) -> str:
        return QApplication.clipboard().text()

    def set_text(self, text: str) -> None:
        QApplication.clipboard().setText(text)


class DocumentWindow(QMainWindow):
    def __init__(self, document: PlateDocument, app: "App"):
        super().__init__()
        self.app = app
        self.document = document
        self.editor = PlateEditor(document, app.preferences, app.template_store, parent=self)
        ed = self.editor
        ed.clipboard = QtClipboard()
        ed.confirm = self._confirm
        ed.window_title_provider = self.windowTitle
        ed.error_presented.connect(lambda title, msg: QMessageBox.warning(self, title, msg))
        ed.sheet_requested.connect(self._on_sheet)
        ed.note_sheet_requested.connect(self._on_note)

        self.setWindowTitle(document.display_name)
        self.resize(1240, 800)
        self.setMinimumSize(720, 480)

        # ---- central layout ----
        self.sidebar = Sidebar(ed)
        self.plate_tabs = PlateTabBar(ed)
        self.scroll = PlateScrollArea(ed)
        self.canvas = self.scroll.canvas
        self.status = StatusRow(ed)
        right = QWidget()
        right.setAutoFillBackground(True)
        rp = right.palette()
        rp.setColor(QPalette.ColorRole.Window, rp.color(QPalette.ColorRole.Base))
        right.setPalette(rp)
        rl = QVBoxLayout(right)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.setSpacing(0)
        rl.addWidget(self.plate_tabs)
        rl.addWidget(self.scroll, 1)
        rl.addWidget(self.status)
        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.addWidget(self.sidebar)
        splitter.addWidget(right)
        splitter.setCollapsible(0, False)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([260, 980])
        splitter.setHandleWidth(1)
        splitter.setStyleSheet("QSplitter::handle { background: palette(mid); }")
        self.setCentralWidget(splitter)
        ed.focus_canvas_requested.connect(lambda: self.canvas.setFocus(Qt.FocusReason.OtherFocusReason))

        self.actions_by_text: dict[str, QAction] = {}
        self._build_menus()
        self._build_toolbar()

        document.clean_changed.connect(self._update_title)
        document.path_changed.connect(self._update_title)
        document.save_failed.connect(self._save_failed)
        ed.state_changed.connect(self._refresh_actions)
        ed.layout_changed.connect(self._rebuild_factor_menu)
        ed.layout_changed.connect(self._refresh_actions)
        self._rebuild_factor_menu()
        self._refresh_actions()
        self._update_title()
        self.canvas.setFocus()

    # ================================================================== hooks
    def _confirm(self, title: str, message: str) -> bool:
        box = QMessageBox(QMessageBox.Icon.Warning, title, message, parent=QApplication.activeModalWidget() or self)
        switch = box.addButton("Switch", QMessageBox.ButtonRole.AcceptRole)
        box.addButton("Cancel", QMessageBox.ButtonRole.RejectRole)
        box.setDefaultButton(switch)
        box.exec()
        return box.clickedButton() is switch

    def _on_sheet(self, which: str) -> None:
        if which == "customFormat":
            self.show_custom_format()
        elif which == "series":
            from playout.ui.sheets.series_fill import SeriesFillDialog

            SeriesFillDialog(self.editor, self).exec()
        elif which == "xy":
            from playout.ui.sheets.xy_fill import XYFillDialog

            XYFillDialog(self.editor, self).exec()

    def show_saved_states(self) -> None:
        from playout.ui.sheets.saved_states import SavedStatesPopover

        popover = SavedStatesPopover(self.editor, self)
        anchor = getattr(self, "states_button", None)
        if anchor is not None:
            popover.move(anchor.mapToGlobal(anchor.rect().bottomLeft()))
        popover.show()

    def _on_note(self, target: NoteTarget) -> None:
        ed = self.editor
        text, ok = QInputDialog.getMultiLineText(
            self, ed.note_title(target),
            "Shown in the status bar, and exported with the Wells sheet. Leave empty to remove.",
            ed.note_text(target),
        )
        if ok:
            ed.save_note(text, target)

    def _later(self, feature: str):
        return lambda: self.editor.flash(f"{feature} arrives in a later build.")

    # ================================================================== menus
    def _act(self, menu: QMenu, text: str, slot=None, shortcut=None, checkable=False, role=None) -> QAction:
        a = QAction(text, self)
        if slot is not None:
            a.triggered.connect(lambda checked=False, s=slot: s())
        if shortcut is not None:
            if isinstance(shortcut, (list, tuple)):
                a.setShortcuts([QKeySequence(s) if isinstance(s, str) else QKeySequence(s) for s in shortcut])
            else:
                a.setShortcut(QKeySequence(shortcut) if isinstance(shortcut, str) else QKeySequence(shortcut))
        a.setCheckable(checkable)
        if role is not None:
            a.setMenuRole(role)
        menu.addAction(a)
        self.actions_by_text[text] = a
        return a

    def _build_menus(self) -> None:
        ed = self.editor
        app = self.app
        bar = self.menuBar()
        SK = QKeySequence.StandardKey

        file = bar.addMenu("&File")
        self._act(file, "New", lambda: app.new_document(), SK.New)
        self._act(file, "Open…", app.open_dialog, SK.Open)
        self.recent_menu = file.addMenu("Open Recent")
        self.recent_menu.aboutToShow.connect(self._fill_recent)
        self.template_menu = file.addMenu("New from Template")
        self.template_menu.aboutToShow.connect(self._fill_templates)
        self._act(file, "Save as Template…", self.save_as_template)
        file.addSeparator()
        self._act(file, "Close", self.close, SK.Close)
        self._act(file, "Save", self.save, SK.Save)
        self._act(file, "Save As…", self.save_as, SK.SaveAs)
        self._act(file, "Duplicate", lambda: app.new_document(layout=ed.layout))
        file.addSeparator()
        self._act(file, "Print Plate…", self.print_plate, SK.Print)
        self._act(file, "Export Excel Workbook…", self.export_workbook, "Ctrl+E")
        self._act(file, "Export Tidy CSV…", self.export_csv, "Ctrl+Shift+E")
        file.addSeparator()
        self._act(file, "Export Plate Image (PNG)…", self.export_png)
        self._act(file, "Export Plate Image (PDF)…", self.export_pdf)
        file.addSeparator()
        self._act(file, "Import Table…", self.import_table, "Ctrl+Shift+I")
        file.addSeparator()
        self._act(file, "Quit" if sys.platform == "darwin" else "Exit", QApplication.instance().closeAllWindows,
                  SK.Quit, role=QAction.MenuRole.QuitRole)

        edit = bar.addMenu("&Edit")
        undo = self.document.undo_stack.createUndoAction(self, "Undo")
        undo.setShortcuts([QKeySequence(SK.Undo)])
        redo = self.document.undo_stack.createRedoAction(self, "Redo")
        redo.setShortcuts([QKeySequence("Ctrl+Shift+Z"), QKeySequence("Ctrl+Y")])
        edit.addAction(undo)
        edit.addAction(redo)
        self.actions_by_text["Undo"] = undo
        self.actions_by_text["Redo"] = redo
        edit.addSeparator()
        self._act(edit, "Cut", ed.cut_selection, SK.Cut)
        self._act(edit, "Copy", lambda: ed.copy_selection(False), SK.Copy)
        self._act(edit, "Copy with Headers", lambda: ed.copy_selection(True), "Ctrl+Shift+C")
        self._act(edit, "Paste", ed.paste_from_clipboard, SK.Paste)
        self._act(edit, "Delete", ed.clear_selection)
        self._act(edit, "Select All", ed.select_all_wells, SK.SelectAll)
        edit.addSeparator()
        prefs = self._act(edit, "Preferences…", self.app.show_preferences, role=QAction.MenuRole.PreferencesRole)
        prefs.setShortcuts([QKeySequence(SK.Preferences), QKeySequence("Ctrl+,")])

        view = bar.addMenu("&View")
        self._act(view, "Zoom In", self.scroll.zoom_in, [QKeySequence(SK.ZoomIn), QKeySequence("Ctrl+=")])
        self._act(view, "Zoom Out", self.scroll.zoom_out, SK.ZoomOut)
        self._act(view, "Fit Plate to Window", self.scroll.zoom_to_fit, "Ctrl+0")
        view.addSeparator()
        self.overview_action = self._act(view, "Overview", ed.toggle_overview, "Ctrl+Shift+O", checkable=True)
        self.turn_action = self._act(view, "Turn Plate 90°", ed.rotate_plate, "Ctrl+Shift+L", checkable=True)

        plate = bar.addMenu("&Plate")
        self._act(plate, "Fill Selection", ed.paint_selection, ["Ctrl+Return", "Ctrl+Enter"])
        self._act(plate, "Clear Selection", ed.clear_selection)
        self._act(plate, "Clear All Factors in Selection", ed.clear_selection_all_factors, "Ctrl+Backspace")
        self._act(plate, "Select All Wells", ed.select_all_wells)
        self._act(plate, "Well Note…", ed.open_well_note_sheet, "Ctrl+Alt+N")
        plate.addSeparator()
        self._act(plate, "Save State", ed.save_state, "Ctrl+Alt+S")
        self._act(plate, "Revert to Last Saved State", ed.revert_to_latest_state, "Ctrl+Alt+R")
        plate.addSeparator()
        self._act(plate, "Series Fill…", ed.open_series_sheet, "Ctrl+Shift+D")
        self._act(plate, "XY Position Fill…", ed.open_xy_fill_sheet, "Ctrl+Shift+Y")
        self._act(plate, "Randomise Selection", ed.randomize_selection, "Ctrl+Shift+R")
        plate.addSeparator()
        self._act(plate, "Next Condition", lambda: ed.cycle_level(1), "Ctrl+]")
        self._act(plate, "Previous Condition", lambda: ed.cycle_level(-1), "Ctrl+[")
        self._act(plate, "Add Condition", ed.add_level, "Ctrl+Shift+N")
        plate.addSeparator()
        self.factor_menu = plate.addMenu("Factor")
        plate.addSeparator()
        self.format_menu = plate.addMenu("Plate Format")
        self.format_menu.aboutToShow.connect(lambda: self._fill_format_menu(self.format_menu))
        self._act(plate, "Custom Plate Size…", self.show_custom_format)
        self._act(plate, "Add Plate", ed.add_plate)
        self._act(plate, "Duplicate Plate", ed.duplicate_plate)
        plate.addSeparator()
        text_menu = plate.addMenu("Text in Wells")
        self.mode_group = QActionGroup(self)
        self.mode_group.setExclusive(True)
        self.mode_actions: dict[WellLabelMode, QAction] = {}
        for mode in WellLabelMode:
            a = QAction(mode.label, self)
            a.setCheckable(True)
            a.triggered.connect(lambda checked=False, m=mode: ed.set_well_label_mode(m))
            self.mode_group.addAction(a)
            text_menu.addAction(a)
            self.mode_actions[mode] = a
            self.actions_by_text[f"Text in Wells: {mode.label}"] = a

        help_menu = bar.addMenu("&Help")
        self._act(help_menu, "Keyboard Shortcuts", self.show_shortcuts)
        self._act(help_menu, "About pLayout", self.show_about, role=QAction.MenuRole.AboutRole)

    def _rebuild_factor_menu(self, *_):
        ed = self.editor
        menu = self.factor_menu
        menu.clear()
        for i, f in enumerate(ed.layout.factors):
            a = QAction(f.name, self)
            if i < 9:
                a.setShortcut(QKeySequence(f"Ctrl+{i + 1}"))
            a.triggered.connect(lambda checked=False, idx=i: ed.set_active_factor_at_index(idx))
            a.setCheckable(True)
            a.setChecked(f.id == ed.active_factor_id)
            menu.addAction(a)
        menu.addSeparator()
        menu.addAction("Next Factor", lambda: ed.cycle_factor(1))
        menu.addAction("Add Factor", ed.add_factor)

    def _fill_format_menu(self, menu: QMenu) -> None:
        ed = self.editor
        menu.clear()
        current = ed.format
        for fmt in STANDARD:
            a = menu.addAction(fmt.detailed_name, lambda checked=False, f=fmt: ed.set_format(f))
            a.setCheckable(True)
            a.setChecked(fmt == current)
        templates = ed.template_store.templates
        if templates:
            menu.addSeparator()
            head = menu.addAction("Custom")
            head.setEnabled(False)
            for t in templates:
                a = menu.addAction(f"{t.name}  ({t.rows}×{t.cols})", lambda checked=False, r=t.rows, c=t.cols: ed.set_format(PlateFormat(r, c)))
                a.setCheckable(True)
                a.setChecked(PlateFormat(t.rows, t.cols) == current)
        menu.addSeparator()
        menu.addAction("Custom Size…", self.show_custom_format)

    def _fill_recent(self) -> None:
        menu = self.recent_menu
        menu.clear()
        paths = self.app.recent_paths()
        for p in paths:
            menu.addAction(Path(p).name, lambda checked=False, path=p: self.app.open_path(path))
        if paths:
            menu.addSeparator()
        clear = menu.addAction("Clear Menu", self.app.clear_recent)
        clear.setEnabled(bool(paths))

    def _fill_templates(self) -> None:
        menu = self.template_menu
        menu.clear()
        store = self.app.layout_templates
        store.refresh()
        templates = store.templates
        if not templates:
            empty = menu.addAction("No templates yet — save one below.")
            empty.setEnabled(False)
        for t in templates:
            menu.addAction(t.name, lambda checked=False, tt=t: self.app.new_document(layout=store.load(tt)))
        menu.addSeparator()
        remove = menu.addMenu("Remove Template")
        remove.setEnabled(bool(templates))
        for t in templates:
            remove.addAction(t.name, lambda checked=False, tt=t: store.delete(tt))

    def _refresh_actions(self, *_):
        ed = self.editor
        for a, on in ((self.overview_action, ed.is_overview), (self.turn_action, ed.is_turned)):
            a.blockSignals(True)
            a.setChecked(on)
            a.blockSignals(False)
        for mode, a in self.mode_actions.items():
            a.blockSignals(True)
            a.setChecked(mode is ed.layout.well_label_mode)
            a.blockSignals(False)
        for i, a in enumerate(self.factor_menu.actions()):
            if a.isCheckable() and i < len(ed.layout.factors):
                a.setChecked(ed.layout.factors[i].id == ed.active_factor_id)
        if hasattr(self, "save_state_button"):
            saved = ed.current_design_is_saved
            self.save_state_button.setIcon(icons.glyph_icon("bookmark.fill" if saved else "bookmark", self._icon_color()))
            self.save_state_button.setToolTip(
                "This layout is already saved as a state" if saved
                else f"Bookmark the layout as it is now — every factor and plate ({QKeySequence('Ctrl+Alt+S').toString(QKeySequence.SequenceFormat.NativeText)})")
            self.format_button.setToolTip(f"Plate format — currently {ed.format_display_name(ed.format)}")

    # ================================================================== toolbar
    def _icon_color(self):
        return self.palette().color(QPalette.ColorRole.WindowText)

    def _build_toolbar(self) -> None:
        ed = self.editor
        tb = QToolBar("Main")
        tb.setMovable(False)
        tb.setFloatable(False)
        tb.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonIconOnly)
        tb.setIconSize(QSize(18, 18))
        tb.setContentsMargins(6, 2, 6, 2)
        self.addToolBar(tb)
        self.setUnifiedTitleAndToolBarOnMac(True)
        self.toolbar = tb
        c = self._icon_color()

        self.format_button = MenuToolButton()
        self.format_button.setIcon(icons.glyph_icon("grid", c))
        self.format_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        fm = QMenu(self.format_button)
        fm.aboutToShow.connect(lambda: self._fill_format_menu(fm))
        self.format_button.setMenu(fm)
        tb.addWidget(self.format_button)

        self.save_state_button = QToolButton()
        self.save_state_button.setIcon(icons.glyph_icon("bookmark", c))
        self.save_state_button.clicked.connect(ed.save_state)
        tb.addWidget(self.save_state_button)

        states = QToolButton()
        states.setIcon(icons.glyph_icon("clock.arrow", c))
        states.setToolTip(f"Revert to, rename or delete a saved state ({QKeySequence('Ctrl+Alt+R').toString(QKeySequence.SequenceFormat.NativeText)} reverts to the latest)")
        states.clicked.connect(self.show_saved_states)
        tb.addWidget(states)
        self.states_button = states

        tb.addSeparator()
        series = QToolButton()
        series.setIcon(icons.glyph_icon("trend", c))
        series.setToolTip(f"Fill the selection with a dilution or step series ({QKeySequence('Ctrl+Shift+D').toString(QKeySequence.SequenceFormat.NativeText)})")
        series.clicked.connect(ed.open_series_sheet)
        tb.addWidget(series)
        xy = QToolButton()
        xy.setIcon(icons.glyph_icon("xy", c))
        xy.setToolTip(f"Number wells as imaging positions ({QKeySequence('Ctrl+Shift+Y').toString(QKeySequence.SequenceFormat.NativeText)})")
        xy.clicked.connect(ed.open_xy_fill_sheet)
        tb.addWidget(xy)
        rnd = QToolButton()
        rnd.setIcon(icons.glyph_icon("shuffle", c))
        rnd.setToolTip("Shuffle the assigned values within the selection")
        rnd.clicked.connect(ed.randomize_selection)
        tb.addWidget(rnd)

        spacer = QWidget()
        spacer.setSizePolicy(spacer.sizePolicy().horizontalPolicy().Expanding, spacer.sizePolicy().verticalPolicy())
        tb.addWidget(spacer)

        export = MenuToolButton()
        export.setIcon(icons.glyph_icon("share", c))
        export.setToolTip("Export or import plate data")
        export.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        em = QMenu(export)
        em.addAction("Excel Workbook…", self.export_workbook)
        em.addAction("Tidy CSV…", self.export_csv)
        em.addSeparator()
        em.addAction("Plate Image (PNG)…", self.export_png)
        em.addAction("Plate Image (PDF)…", self.export_pdf)
        em.addSeparator()
        em.addAction("Import Table…", self.import_table)
        export.setMenu(em)
        tb.addWidget(export)

        keys = QToolButton()
        keys.setIcon(icons.glyph_icon("keyboard", c))
        keys.setToolTip("Keyboard & mouse shortcuts")
        keys.clicked.connect(self.show_shortcuts)
        tb.addWidget(keys)
        self.shortcuts_button = keys
        self._toolbar_buttons = [self.format_button, self.save_state_button, states, series, xy, rnd, export, keys]
        self._toolbar_glyphs = ["grid", "bookmark", "clock.arrow", "trend", "xy", "shuffle", "share", "keyboard"]
        self._menu_buttons = {self.format_button, export}
        for b in self._toolbar_buttons:
            b.setAutoRaise(True)
            b.setIconSize(QSize(18, 18))
            if b in self._menu_buttons:
                b.setFixedSize(46, 28)
                b.setStyleSheet("QToolButton::menu-indicator { image: none; } QToolButton { padding-right: 12px; }")
            else:
                b.setFixedSize(34, 28)

    def changeEvent(self, e) -> None:
        if e.type() == QEvent.Type.PaletteChange and hasattr(self, "_toolbar_buttons"):
            c = self._icon_color()
            for b, g in zip(self._toolbar_buttons, self._toolbar_glyphs):
                b.setIcon(icons.glyph_icon(g, c))
            self._refresh_actions()
        super().changeEvent(e)

    # ================================================================== dialogs
    def show_shortcuts(self) -> None:
        from playout.ui.sheets.shortcuts_card import ShortcutsCard

        card = ShortcutsCard(self)
        anchor = getattr(self, "shortcuts_button", None)
        if anchor is not None:
            card.move(anchor.mapToGlobal(anchor.rect().bottomLeft()))
        card.show()

    def show_about(self) -> None:
        from playout import MAC_VERSION, __version__

        QMessageBox.about(self, "About pLayout", f"pLayout {__version__}\nPython/PySide6 port of pLayout {MAC_VERSION} for macOS.\n\nA microplate layout editor.")

    def show_custom_format(self) -> None:
        from playout.ui.sheets.custom_format import CustomFormatDialog

        CustomFormatDialog(self.editor, self).exec()

    def save_as_template(self) -> None:
        name, ok = QInputDialog.getText(
            self, "Save as Template",
            "Keeps this whole layout — factors, conditions, plates and their painting — as a starting point.\nTemplate name:",
        )
        if ok and name.strip():
            self.app.layout_templates.save(self.editor.layout, name)
            self.editor.flash(f"Saved template {self.app.layout_templates.sanitized(name)}.")

    def import_table(self) -> None:
        if self.editor.active_factor_id is None:
            return
        path, _ = QFileDialog.getOpenFileName(
            self, "Choose a CSV or TSV file laid out like the plate.", "",
            "Tables (*.csv *.tsv *.txt);;All files (*)",
        )
        if path:
            self.editor.import_table_file(path)

    # ================================================================== exports
    def _ask_save_path(self, ext: str, filter_text: str) -> str | None:
        suggested = f"{self.editor.suggested_base_name}.{ext}"
        start = str((self.document.path.parent if self.document.path else Path.home()) / suggested)
        path, _ = QFileDialog.getSaveFileName(self, "Export", start, filter_text)
        if not path:
            return None
        if not path.lower().endswith(f".{ext}"):
            path += f".{ext}"
        return path

    def _write_bytes(self, path: str, data: bytes) -> None:
        try:
            tmp = f"{path}.tmp"
            with open(tmp, "wb") as fh:
                fh.write(data)
            import os

            os.replace(tmp, path)
        except OSError as exc:
            QMessageBox.warning(self, "Could not export", str(exc))
            return
        self.editor.flash(f"Exported {Path(path).name}")

    def export_workbook(self) -> None:
        from playout.io.table_io import WorkbookScope, resolved_separator, workbook_bytes
        from playout.ui.sheets.workbook_options import WorkbookOptionsDialog

        ed = self.editor
        active = ed.plate
        dlg = WorkbookOptionsDialog(ed.preferences, len(ed.layout.plates), active.name if active else "this plate", self)
        if dlg.exec() != QDialog.DialogCode.Accepted:
            return
        dlg.remember()
        path = self._ask_save_path("xlsx", "Excel workbook (*.xlsx)")
        if path is None:
            return
        only = ed.active_plate_id if dlg.selected_scope is WorkbookScope.activePlate else None
        joint = resolved_separator(dlg.joint_separator_typed) if dlg.joint_enabled else None
        self._write_bytes(path, workbook_bytes(ed.layout, dlg.selected_layout, only, joint))

    def export_csv(self) -> None:
        from playout.io.table_io import tidy_csv

        path = self._ask_save_path("csv", "CSV (*.csv)")
        if path is not None:
            self._write_bytes(path, tidy_csv(self.editor.layout).encode("utf-8"))

    def _export_size(self) -> tuple[float, float]:
        b = self.canvas.unmagnified_bounds()
        return b.width, b.height

    def export_png(self) -> None:
        from playout.io.plate_image import render_png

        path = self._ask_save_path("png", "PNG image (*.png)")
        if path is None:
            return
        w, h = self._export_size()
        data = render_png(self.editor, w, h, self.devicePixelRatioF())
        if data is None:
            QMessageBox.warning(self, "Could not export", "The plate is too small to draw.")
            return
        self._write_bytes(path, data)

    def export_pdf(self) -> None:
        from playout.io.plate_image import write_pdf

        path = self._ask_save_path("pdf", "PDF (*.pdf)")
        if path is None:
            return
        w, h = self._export_size()
        if write_pdf(self.editor, path, w, h):
            self.editor.flash(f"Exported {Path(path).name}")
        else:
            QMessageBox.warning(self, "Could not export", "The PDF could not be written.")

    def print_plate(self) -> None:
        from PySide6.QtPrintSupport import QPrintDialog, QPrinter

        from playout.io.plate_image import paint_for_print

        printer = QPrinter(QPrinter.PrinterMode.HighResolution)
        printer.setDocName(self.editor.suggested_base_name)
        dialog = QPrintDialog(printer, self)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        w, h = self._export_size()
        if not paint_for_print(self.editor, printer, w, h):
            QMessageBox.warning(self, "Could not print", "The plate could not be sent to the printer.")

    # ================================================================== files
    def _update_title(self, *_) -> None:
        doc = self.document
        self.setWindowTitle(f"{doc.display_name} — Edited" if doc.is_dirty else doc.display_name)
        # (setWindowModified needs a "[*]" placeholder in the title; the "— Edited" suffix is the Mac convention)

    def save(self) -> bool:
        if self.document.path is None:
            return self.save_as()
        ok = self.document.save()
        if ok:
            self.app.remember_recent(self.document.path)
        return ok

    def save_as(self) -> bool:
        suggested = f"{self.editor.suggested_base_name}.plate"
        start = str(self.document.path or Path.home() / suggested)
        path, _ = QFileDialog.getSaveFileName(self, "Save", start, PLATE_FILTER)
        if not path:
            return False
        if not path.lower().endswith(".plate"):
            path += ".plate"
        ok = self.document.save(path)
        if ok:
            self.app.remember_recent(path)
        return ok

    def _save_failed(self, path, message: str) -> None:
        QMessageBox.warning(self, "Could not save", f"{path}\n\n{message}")

    def event(self, e) -> bool:
        if e.type() == QEvent.Type.WindowDeactivate:
            self.document.save_now()
        return super().event(e)

    def closeEvent(self, e) -> None:
        doc = self.document
        if doc.is_untitled and doc.is_dirty:
            box = QMessageBox(QMessageBox.Icon.Question, "Save changes?",
                              "Save changes to Untitled?", parent=self)
            save = box.addButton("Save", QMessageBox.ButtonRole.AcceptRole)
            box.addButton("Don't Save", QMessageBox.ButtonRole.DestructiveRole)
            cancel = box.addButton("Cancel", QMessageBox.ButtonRole.RejectRole)
            box.setDefaultButton(save)
            box.exec()
            if box.clickedButton() is cancel:
                e.ignore()
                return
            if box.clickedButton() is save and not self.save_as():
                e.ignore()
                return
        elif not doc.is_untitled and doc.is_dirty:
            if not doc.save_now():
                box = QMessageBox(QMessageBox.Icon.Warning, "Could not save",
                                  "The document could not be saved. Close anyway?", parent=self)
                anyway = box.addButton("Close Anyway", QMessageBox.ButtonRole.DestructiveRole)
                box.addButton("Cancel", QMessageBox.ButtonRole.RejectRole)
                box.exec()
                if box.clickedButton() is not anyway:
                    e.ignore()
                    return
        self.app.window_closed(self)
        e.accept()
