"""The sidebar: Factors, the active factor's conditions, and the Display section.

Mirrors `Sources/PLayout/Views/Sidebar.swift` (+ the row behaviour of `Controls.swift`),
PORT.md §A3. Row rules kept from the Mac: a single click selects/arms and hands focus back
to the canvas; a second click on the same row within the double-click interval renames it
(Qt delivers that as a double-click); Ctrl-click toggles the row into the multi-selection
(no arming); drag reorders (a real, undoable edit); resting the mouse on a condition row
spotlights it on the plate; context menus per row.

Every list rebuilds from the editor's signals — never from its own clicks — and never in
the middle of a rename or a drag.
"""
from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QEvent, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QColor, QPalette
from PySide6.QtWidgets import (
    QAbstractItemView, QButtonGroup, QCheckBox, QColorDialog, QFrame, QHBoxLayout, QLabel,
    QListWidget, QListWidgetItem, QMenu, QScrollArea, QSizePolicy, QToolButton, QVBoxLayout, QWidget,
)

from playout.editor.plate_editor import PlateEditor
from playout.model.layout import Factor, FactorKind, Level, WellLabelMode
from playout.ui import fonts
from playout.ui.controls import CommitLineEdit, EditableName, KeyCap, SwatchButton, key_name

MIN_WIDTH = 232


def _tint(widget: QWidget) -> QColor:
    return fonts.with_alpha(widget.palette().color(QPalette.ColorRole.Highlight), 0.12)


def reorder_target(old_ids: list[str], new_ids: list[str], dragged: str) -> tuple[int, int] | None:
    """From the list order before and after an internal move, the (from, to) pair for
    `editor.move_*` — `to` in pre-move indices (moving down = target + 1), the Swift
    `RowReorder.offset` rule."""
    if dragged not in old_ids or dragged not in new_ids:
        return None
    frm = old_ids.index(dragged)
    row = new_ids.index(dragged)
    if frm == row:
        return None
    return frm, (row + 1 if row > frm else row)


class RowWidget(QWidget):
    """One list row: keycap · [swatch] · editable name · [glyph] · trailing count."""

    def __init__(self, row_id: str, cap: str, name: str, on_rename: Callable[[str], None], on_done: Callable[[], None],
                 swatch_hex: str | None = None, glyph: str = "", trailing: str = ""):
        super().__init__()
        self.row_id = row_id
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, False)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(6, 1, 6, 1)
        lay.setSpacing(6)
        self.cap = KeyCap(cap)
        lay.addWidget(self.cap)
        self.swatch: SwatchButton | None = None
        if swatch_hex is not None:
            self.swatch = SwatchButton(swatch_hex)
            lay.addWidget(self.swatch)
        self.name = EditableName(name, on_rename, on_done)
        lay.addWidget(self.name, 1)
        self.glyph = QLabel(glyph)
        self.glyph.setStyleSheet(fonts.secondary_css(self))
        lay.addWidget(self.glyph)
        self.trailing = QLabel(trailing)
        self.trailing.setStyleSheet(fonts.secondary_css(self))
        lay.addWidget(self.trailing)
        for w in (self.cap, self.glyph, self.trailing, self.name.label):
            w.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        # The row must never be wider than the list: an item widget otherwise takes its
        # own size hint (the line-edit page inflates it) and the count falls off the edge.
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.name.edit.setMinimumWidth(40)


class RowList(QListWidget):
    """A section list. Subclasses supply `ids()`, `on_click`, `on_toggle`, `on_reorder`,
    `menu_for(id)` and `build_row(id)`."""

    def __init__(self, sidebar: "Sidebar"):
        super().__init__()
        self.sidebar = sidebar
        self.editor = sidebar.editor
        self.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove)
        self.setDefaultDropAction(Qt.DropAction.MoveAction)
        self.setDragEnabled(True)
        self.setAcceptDrops(True)
        self.setDropIndicatorShown(True)
        self.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.setUniformItemSizes(True)
        pal = self.palette()
        pal.setColor(QPalette.ColorRole.Highlight, _tint(self))
        pal.setColor(QPalette.ColorRole.HighlightedText, pal.color(QPalette.ColorRole.WindowText))
        self.setPalette(pal)
        self.viewport().setAutoFillBackground(False)
        self._press_id: str | None = None
        self._ids: list[str] = []
        self.rows: dict[str, RowWidget] = {}

    # -- to override --------------------------------------------------------
    def ids(self) -> list[str]:
        raise NotImplementedError

    def build_row(self, row_id: str) -> RowWidget:
        raise NotImplementedError

    def on_click(self, row_id: str) -> None: ...

    def on_toggle(self, row_id: str) -> None: ...

    def on_reorder(self, frm: int, to: int) -> None: ...

    def menu_for(self, row_id: str) -> QMenu | None:
        return None

    def is_current(self, row_id: str) -> bool:
        return False

    def is_multi(self, row_id: str) -> bool:
        return False

    def refresh_row(self, row_id: str, row: RowWidget) -> None: ...

    # -- helpers ------------------------------------------------------------
    def id_at(self, pos) -> str | None:
        item = self.itemAt(pos)
        return item.data(Qt.ItemDataRole.UserRole) if item is not None else None

    @property
    def is_renaming(self) -> bool:
        return any(r.name.is_renaming for r in self.rows.values())

    def rebuild(self) -> None:
        ids = self.ids()
        if ids != self._ids:
            self._ids = ids
            self.clear()
            self.rows = {}
            for row_id in ids:
                item = QListWidgetItem()
                item.setData(Qt.ItemDataRole.UserRole, row_id)
                widget = self.build_row(row_id)
                item.setSizeHint(QSize(max(1, self.viewport().width()), 24))
                self.addItem(item)
                self.setItemWidget(item, widget)
                self.rows[row_id] = widget
        for i, row_id in enumerate(ids):
            row = self.rows[row_id]
            self.refresh_row(row_id, row)
            item = self.item(i)
            item.setBackground(_tint(self) if self.is_multi(row_id) else Qt.GlobalColor.transparent)
            if self.is_current(row_id):
                self.setCurrentRow(i)
            row.cap.set_highlighted(self.is_current(row_id) or self.is_multi(row_id))
        if not any(self.is_current(i) for i in ids):
            self.setCurrentRow(-1)
        self.setFixedHeight(len(ids) * 24 + 4 if ids else 4)

    # -- events -------------------------------------------------------------
    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        w = max(1, self.viewport().width())
        for i in range(self.count()):
            self.item(i).setSizeHint(QSize(w, 24))
        for row in self.rows.values():
            row.setFixedWidth(w)

    def mousePressEvent(self, e) -> None:
        row_id = self.id_at(e.position().toPoint())
        if e.button() == Qt.MouseButton.LeftButton and row_id is not None and e.modifiers() & Qt.KeyboardModifier.ControlModifier:
            self.on_toggle(row_id)
            e.accept()
            return
        self._press_id = row_id
        super().mousePressEvent(e)
        if e.button() == Qt.MouseButton.LeftButton and row_id is not None:
            self.on_click(row_id)

    def mouseDoubleClickEvent(self, e) -> None:
        row_id = self.id_at(e.position().toPoint())
        if e.button() == Qt.MouseButton.LeftButton and row_id is not None and not e.modifiers():
            row = self.rows.get(row_id)
            if row is not None:
                self.on_click(row_id)
                row.name.begin_rename()
                return
        super().mouseDoubleClickEvent(e)

    def dropEvent(self, e) -> None:
        old_ids = list(self._ids)
        dragged = self._press_id
        super().dropEvent(e)
        new_ids = [self.item(i).data(Qt.ItemDataRole.UserRole) for i in range(self.count())]
        target = reorder_target(old_ids, new_ids, dragged) if dragged else None
        # The move destroyed the dragged row's widget; the editor edit below makes the
        # layout signal rebuild every row from the model, which is what makes this survive.
        self._ids = []
        if target is not None:
            frm, to = target
            QTimer.singleShot(0, lambda: self.on_reorder(frm, to))
        else:
            QTimer.singleShot(0, self.sidebar.schedule_refresh)

    def contextMenuEvent(self, e) -> None:
        row_id = self.id_at(e.pos())
        if row_id is None:
            return
        menu = self.menu_for(row_id)
        if menu is not None:
            menu.exec(e.globalPos())


class FactorList(RowList):
    def ids(self) -> list[str]:
        return [f.id for f in self.editor.layout.factors]

    def build_row(self, row_id: str) -> RowWidget:
        f = self.editor.layout.factor(row_id)
        index = self.editor.layout.factor_index(row_id) or 0
        cap = key_name(f"Ctrl+{index + 1}") if index < 9 else "·"
        return RowWidget(row_id, cap, f.name if f else "",
                         on_rename=lambda text, i=row_id: self.editor.rename_factor(i, text),
                         on_done=self.editor.focus_canvas)

    def refresh_row(self, row_id: str, row: RowWidget) -> None:
        f = self.editor.layout.factor(row_id)
        if f is None:
            return
        index = self.editor.layout.factor_index(row_id) or 0
        row.cap.setText(key_name(f"Ctrl+{index + 1}") if index < 9 else "·")
        row.name.set_text(f.name)
        row.glyph.setText("#" if f.kind is FactorKind.numeric else "")
        show_counts = self.editor.preferences.show_factor_condition_counts
        row.trailing.setText(("—" if not f.levels else str(len(f.levels))) if show_counts else "")

    def is_current(self, row_id: str) -> bool:
        return row_id == self.editor.active_factor_id

    def is_multi(self, row_id: str) -> bool:
        return row_id in self.editor.multi_selected_factor_ids

    def on_click(self, row_id: str) -> None:
        self.editor.set_active_factor(row_id)
        self.editor.focus_canvas()

    def on_toggle(self, row_id: str) -> None:
        self.editor.toggle_factor_in_multi_selection(row_id)

    def on_reorder(self, frm: int, to: int) -> None:
        self.editor.move_factors([frm], to)

    def menu_for(self, row_id: str) -> QMenu:
        ed = self.editor
        menu = QMenu(self)
        if row_id in ed.multi_selected_factor_ids:
            n = len(ed.multi_selected_factor_ids)
            menu.addAction(f"Delete {n} Factors", lambda: ed.delete_factors(ed.multi_selected_factor_ids))
            return menu
        f = ed.layout.factor(row_id)
        numeric = f is not None and f.kind is FactorKind.numeric
        menu.addAction("Treat as Categorical" if numeric else "Treat as Numeric",
                       lambda: ed.set_factor_kind(row_id, FactorKind.categorical if numeric else FactorKind.numeric))
        menu.addAction("Rename…", lambda: self.rows[row_id].name.begin_rename() if row_id in self.rows else None)
        menu.addSeparator()
        delete = menu.addAction("Delete Factor", lambda: ed.delete_factor(row_id))
        delete.setEnabled(len(ed.layout.factors) > 1)
        return menu


class LevelRowWidget(RowWidget):
    """A condition row also spotlights on hover."""

    def __init__(self, editor: PlateEditor, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._editor = editor

    def enterEvent(self, e) -> None:
        self._editor.set_spotlight(self.row_id)
        # PySide6 6.8 rejects anything but a QEnterEvent here (6.11 is lenient); the base
        # implementation does nothing we need, so only forward the real thing.
        from PySide6.QtGui import QEnterEvent

        if isinstance(e, QEnterEvent):
            super().enterEvent(e)

    def leaveEvent(self, e) -> None:
        if self._editor.spotlight_level_id == self.row_id:
            self._editor.set_spotlight(None)
        super().leaveEvent(e)


class LevelList(RowList):
    def ids(self) -> list[str]:
        f = self.editor.active_factor
        return [lv.id for lv in f.levels] if f else []

    def build_row(self, row_id: str) -> RowWidget:
        f = self.editor.active_factor
        lv = f.level(row_id) if f else None
        index = f.index_of(row_id) if f else None
        row = LevelRowWidget(self.editor, row_id, self._cap(index), lv.name if lv else "",
                             on_rename=lambda text, i=row_id: self.editor.rename_level(i, text),
                             on_done=self.editor.focus_canvas, swatch_hex=lv.color_hex if lv else "#888888")
        row.swatch.clicked.connect(lambda _=False, i=row_id: self.pick_colour(i))
        return row

    @staticmethod
    def _cap(index: int | None) -> str:
        if index is None:
            return "·"
        if index < 9:
            return str(index + 1)
        return "0" if index == 9 else "·"

    def refresh_row(self, row_id: str, row: RowWidget) -> None:
        f = self.editor.active_factor
        lv = f.level(row_id) if f else None
        if lv is None:
            return
        row.cap.setText(self._cap(f.index_of(row_id)))
        row.name.set_text(lv.name)
        if row.swatch is not None and row.swatch.hex_text != lv.color_hex:
            row.swatch.set_hex(lv.color_hex)
        n = self.editor.well_count_of_level(lv)
        row.trailing.setText(str(n) if n else "—")

    def is_current(self, row_id: str) -> bool:
        return row_id == self.editor.armed_level_id

    def is_multi(self, row_id: str) -> bool:
        return row_id in self.editor.multi_selected_level_ids

    def on_click(self, row_id: str) -> None:
        self.editor.arm_level(row_id)
        self.editor.focus_canvas()

    def on_toggle(self, row_id: str) -> None:
        self.editor.toggle_level_in_multi_selection(row_id)

    def on_reorder(self, frm: int, to: int) -> None:
        self.editor.move_levels([frm], to)

    def used_colours(self, exclude_level: str) -> list[str]:
        """The other conditions' colours — of this factor, or of the whole document under
        the never-repeat setting, which redefines what counts as a duplicate."""
        from playout.model.preferences import NewConditionColors

        ed = self.editor
        f = ed.active_factor
        if f is None:
            return []
        if ed.preferences.new_condition_colors is NewConditionColors.neverRepeat:
            return [lv.color_hex for fac in ed.layout.factors for lv in fac.levels if lv.id != exclude_level]
        return [lv.color_hex for lv in f.levels if lv.id != exclude_level]

    def pick_colour(self, row_id: str) -> None:
        from playout.ui.colour_grid import show_colour_grid

        f = self.editor.active_factor
        lv = f.level(row_id) if f else None
        if lv is None:
            return
        anchor = self.rows[row_id].swatch if row_id in self.rows and self.rows[row_id].swatch else self
        self._colour_popover = show_colour_grid(anchor, lv.color_hex, self.used_colours(row_id),
                                                lambda hx, i=row_id: self.editor.set_level_color(i, hx))

    def menu_for(self, row_id: str) -> QMenu:
        ed = self.editor
        menu = QMenu(self)
        if row_id in ed.multi_selected_level_ids:
            n = len(ed.multi_selected_level_ids)
            menu.addAction(f"Delete {n} Conditions", lambda: ed.delete_levels(ed.multi_selected_level_ids))
            return menu
        f = ed.active_factor
        lv = f.level(row_id) if f else None
        name = lv.name if lv else ""

        def fill():
            ed.arm_level(row_id)
            ed.paint_selection()

        menu.addAction(f"Fill Selection with {name}", fill)
        menu.addAction("Rename…", lambda: self.rows[row_id].name.begin_rename() if row_id in self.rows else None)
        menu.addSeparator()
        menu.addAction("Delete Condition", lambda: ed.delete_level(row_id))
        return menu


def _header(text: str) -> QLabel:
    lab = QLabel(text)
    f = lab.font()
    f.setBold(True)
    lab.setFont(f)
    lab.setStyleSheet(fonts.secondary_css(lab) + " margin-top: 6px;")
    return lab


def _caption(text: str) -> QLabel:
    lab = QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet(fonts.secondary_css(lab))
    f = lab.font()
    f.setPointSizeF(max(8.0, f.pointSizeF() - 2))
    lab.setFont(f)
    return lab


class Sidebar(QScrollArea):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent)
        self.editor = editor
        self.setWidgetResizable(True)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setMinimumWidth(MIN_WIDTH)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        # The sidebar is a panel: window grey, against the workspace's white.
        self.setAutoFillBackground(True)
        self.viewport().setAutoFillBackground(True)
        inner = QWidget()
        inner.setAutoFillBackground(True)
        self.setWidget(inner)
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(14, 8, 10, 8)
        lay.setSpacing(4)

        lay.addWidget(_header("Factors"))
        self.factor_list = FactorList(self)
        lay.addWidget(self.factor_list)
        lay.addWidget(_caption("Each factor is painted separately. Wells keep a value for every factor."))
        add_factor = QToolButton()
        add_factor.setText("+ Add Factor")
        add_factor.setAutoRaise(True)
        add_factor.clicked.connect(editor.add_factor)
        lay.addWidget(add_factor)

        head = QHBoxLayout()
        self.conditions_header = _header("Conditions")
        head.addWidget(self.conditions_header, 1)
        self.more = QToolButton()
        self.more.setText("⋯")
        self.more.setAutoRaise(True)
        self.more.setFixedSize(24, 22)
        self.more.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        self.more.setStyleSheet("QToolButton::menu-indicator { image: none; }")
        self.more.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        more_menu = QMenu(self.more)
        self.recolour_action = more_menu.addAction("Recolour from Palette", editor.recolor_levels_from_palette)
        self.prune_action = more_menu.addAction("Remove Unused Conditions", editor.remove_unused_levels)
        self.more.setMenu(more_menu)
        head.addWidget(self.more)
        lay.addLayout(head)
        unit_row = QHBoxLayout()
        self.unit_label = QLabel("Unit")
        self.unit_edit = CommitLineEdit("", self._commit_unit)
        self.unit_edit.setPlaceholderText("µM, h, ng/mL…")
        unit_row.addWidget(self.unit_label)
        unit_row.addWidget(self.unit_edit, 1)
        self.unit_container = QWidget()
        self.unit_container.setLayout(unit_row)
        lay.addWidget(self.unit_container)
        self.level_list = LevelList(self)
        lay.addWidget(self.level_list)
        self.overview_note = _caption("No factor selected. Click a factor above to paint again.")
        lay.addWidget(self.overview_note)
        self.add_condition = QToolButton()
        self.add_condition.setText("+ Add Condition")
        self.add_condition.setAutoRaise(True)
        self.add_condition.clicked.connect(editor.add_level)
        lay.addWidget(self.add_condition)

        lay.addWidget(_header("Display"))
        lay.addWidget(_caption("Text in wells"))
        modes = QHBoxLayout()
        modes.setSpacing(0)
        self.mode_group = QButtonGroup(self)
        self.mode_group.setExclusive(True)
        self.mode_buttons: dict[WellLabelMode, QToolButton] = {}
        modes_list = list(WellLabelMode)
        for i, mode in enumerate(modes_list):
            b = QToolButton()
            b.setText(mode.short_label)
            b.setCheckable(True)
            b.setAutoRaise(False)
            b.setProperty("segmented", True)
            b.setProperty("first", i == 0)
            b.setProperty("last", i == len(modes_list) - 1)
            b.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
            self.mode_group.addButton(b, i)
            self.mode_buttons[mode] = b
            modes.addWidget(b)
        self.mode_group.idClicked.connect(lambda i: editor.set_well_label_mode(list(WellLabelMode)[i]))
        lay.addLayout(modes)
        self.mode_hint = _caption("")
        lay.addWidget(self.mode_hint)
        self.show_secondary = QCheckBox("Show other factors")
        self.show_secondary.setToolTip("Adds a colour strip along the bottom of each well for the factors you are not painting.")
        self.show_secondary.toggled.connect(editor.set_show_secondary_factors)
        lay.addWidget(self.show_secondary)
        self.round_wells = QCheckBox("Round wells")
        self.round_wells.setToolTip("Ignored while stacked labels are showing — they need the full width of the well, so those are drawn as squares.")
        self.round_wells.toggled.connect(editor.set_round_wells)
        lay.addWidget(self.round_wells)
        self.pad_labels = QCheckBox("Pad well IDs (A01)")
        self.pad_labels.toggled.connect(editor.set_pad_well_labels)
        lay.addWidget(self.pad_labels)
        lay.addStretch(1)

        self._refresh_pending = False
        editor.state_changed.connect(self.schedule_refresh)
        editor.layout_changed.connect(self.schedule_refresh)
        self.refresh()

    # ------------------------------------------------------------------ refresh
    def schedule_refresh(self) -> None:
        if self._refresh_pending:
            return
        self._refresh_pending = True
        QTimer.singleShot(0, self.refresh)

    @property
    def is_renaming(self) -> bool:
        return self.factor_list.is_renaming or self.level_list.is_renaming

    def refresh(self) -> None:
        self._refresh_pending = False
        ed = self.editor
        if self.is_renaming or self.factor_list.state() == QAbstractItemView.State.DraggingState \
                or self.level_list.state() == QAbstractItemView.State.DraggingState:
            QTimer.singleShot(150, self.schedule_refresh)
            return
        self.factor_list.rebuild()
        self.level_list.rebuild()
        f = ed.active_factor
        self.conditions_header.setText(f.name if f else "Conditions")
        self.more.setEnabled(f is not None)
        show_unit = f is not None and (bool(f.unit) or f.kind is FactorKind.numeric)
        self.unit_container.setVisible(show_unit)
        if f is not None and self.unit_edit.text().strip() != f.unit and not self.unit_edit.hasFocus():
            self.unit_edit.setText(f.unit)
            self.unit_edit._last = f.unit
        self.overview_note.setVisible(ed.is_overview)
        self.level_list.setVisible(not ed.is_overview)
        self.add_condition.setVisible(not ed.is_overview)
        mode = ed.layout.well_label_mode
        for m, b in self.mode_buttons.items():
            b.blockSignals(True)
            b.setChecked(m is mode)
            b.blockSignals(False)
        hint = self._mode_hint()
        self.mode_hint.setText(hint or "")
        self.mode_hint.setVisible(bool(hint))
        self.show_secondary.setVisible(not mode.stacks_every_factor)
        self.show_secondary.setEnabled(len(ed.layout.factors) >= 2)
        for box, value in ((self.show_secondary, ed.show_secondary_factors), (self.round_wells, ed.round_wells),
                           (self.pad_labels, ed.layout.pad_well_labels)):
            box.blockSignals(True)
            box.setChecked(value)
            box.blockSignals(False)

    def _mode_hint(self) -> str | None:
        ed = self.editor
        mode = ed.layout.well_label_mode
        if mode is WellLabelMode.allFactors:
            if len(ed.layout.factors) < 2:
                return "Add a second factor to see stacked labels."
            return "One line per factor, in the order listed above. Any that do not fit drop to a colour strip. A key appears under the plate."
        if mode is WellLabelMode.overview:
            return f"Every factor at the same size on a plain well, with nothing selected — the whole design at a glance ({key_name('Ctrl+Shift+O')})."
        return None

    def _commit_unit(self, text: str) -> None:
        f = self.editor.active_factor
        if f is not None:
            self.editor.set_factor_unit(f.id, text)
