"""PlateEditor: every mutation and the active plate/factor/level/selection state.

Mirrors `Sources/PLayout/Editor/PlateEditor.swift`, in the same section order, so a Mac
change maps onto a port change by section name. See PORT.md §C0–C20 for the rules and the
exact strings; the tests in `tests/test_editor_*.py` pin them.

Two rules that make everything else work:

* **Every edit goes through `_edit` → `PlateDocument.mutate`.** An unchanged layout is a
  no-op (no undo step, no signal); anything else is exactly one undo step.
* **The editor reconciles its state from the document's `layout_changed` signal, not per
  action** — undo and redo can delete the active plate/factor/level just as easily as an
  edit can. Views connect to *this* object's signals, never to the document's, so they only
  ever see reconciled state.

Anything that needs a window (a modal confirm, the clipboard, an error alert, a sheet)
goes through an injectable hook or a signal so this class runs headless under pytest.
"""
from __future__ import annotations

import math
import random
import sys
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from enum import Enum
from typing import Callable, Iterable

from PySide6.QtCore import QCoreApplication, QDateTime, QLocale, QObject, QTimer, Signal

from playout.editor.document import PlateDocument
from playout.editor.well_range import WellPos, WellRange
from playout.io.table_io import CSV, TSV, Grid
from playout.model import palette
from playout.model.layout import (
    Factor,
    FactorKind,
    Layout,
    LayoutSnapshot,
    Level,
    Plate,
    PlateOrientation,
    WellLabelMode,
    new_id,
)
from playout.model.plate_format import WELL96, PlateFormat, WellNaming
from playout.model.preferences import NewConditionColors, Preferences
from playout.model.templates import PlateTemplateStore

FLASH_SECONDS = 3.0
XY_FACTOR_NAME = "XY"
#: How the flash messages name the undo key: the Mac strings say ⌘Z, Windows says Ctrl+Z.
UNDO_KEY = "⌘Z" if sys.platform == "darwin" else "Ctrl+Z"


# --------------------------------------------------------------------------------------
# Small value types


@dataclass(frozen=True)
class NoteTarget:
    """`well(index)` or `plate` — what the note sheet edits."""

    well: int | None = None  # None means the plate

    @property
    def is_plate(self) -> bool:
        return self.well is None

    @property
    def id(self) -> str:
        return "plate" if self.well is None else f"well-{self.well}"

    @classmethod
    def for_well(cls, well: int) -> "NoteTarget":
        return cls(well)

    @classmethod
    def for_plate(cls) -> "NoteTarget":
        return cls(None)


class SeriesDirection(str, Enum):
    acrossColumns = "acrossColumns"
    downRows = "downRows"

    @property
    def label(self) -> str:
        return "Across columns →" if self is SeriesDirection.acrossColumns else "Down rows ↓"


class SeriesMode(str, Enum):
    fold = "fold"
    linear = "linear"

    @property
    def label(self) -> str:
        return "Fold dilution" if self is SeriesMode.fold else "Linear step"


@dataclass(frozen=True)
class SeriesSpec:
    direction: SeriesDirection = SeriesDirection.acrossColumns
    mode: SeriesMode = SeriesMode.fold
    start: float = 10.0
    fold_factor: float = 3.0
    dilute: bool = True
    step: float = -1.0
    significant_digits: int = 3
    last_is_zero: bool = False


class XYPattern(str, Enum):
    acrossColumns = "acrossColumns"
    downRows = "downRows"
    serpentine = "serpentine"

    @property
    def label(self) -> str:
        return {
            XYPattern.acrossColumns: "Across columns →",
            XYPattern.downRows: "Down rows ↓",
            XYPattern.serpentine: "Serpentine ⇄",
        }[self]


@dataclass(frozen=True)
class XYFillSpec:
    pattern: XYPattern = XYPattern.acrossColumns
    #: Base hue for the position ramp. None = the hue the XY factor already has, else the
    #: next colour the palette would hand out.
    base_hex: str | None = None


class MemoryClipboard:
    """Headless clipboard; the window swaps in one backed by `QApplication.clipboard()`."""

    def __init__(self) -> None:
        self._text = ""

    def text(self) -> str:
        return self._text

    def set_text(self, text: str) -> None:
        self._text = text


def format_value(value: float, significant_digits: int) -> str:
    """`%.{n}g` with trailing zeros (and a trailing dot) stripped, unless exponential."""
    if value == 0:
        return "0"
    digits = max(1, min(int(significant_digits), 12))
    text = f"{value:.{digits}g}"
    if "." in text and "e" not in text.lower():
        text = text.rstrip("0")
        if text.endswith("."):
            text = text[:-1]
    return text


def xy_names(count: int) -> list[str]:
    """XY01, XY02, … — two digits like the instrument, widening only when the count
    outgrows them (XY001… on a 384)."""
    if count <= 0:
        return []
    width = max(2, len(str(count)))
    return [f"XY{i:0{width}d}" for i in range(1, count + 1)]


def _double(text: str) -> float | None:
    """Swift `Double(String)`: strict decimal/exponent parse, no whitespace tolerance."""
    if not text or text != text.strip():
        return None
    try:
        v = float(text)
    except ValueError:
        return None
    if math.isnan(v) and text.lower() not in ("nan", "-nan", "+nan"):
        return None
    return v


# --------------------------------------------------------------------------------------
# The editor


class PlateEditor(QObject):
    #: Anything a view might draw changed (active/armed/selection/hover/spotlight/message…).
    state_changed = Signal()
    #: The document's layout changed and the editor has already reconciled itself to it.
    layout_changed = Signal(object)
    #: The transient status-bar message changed ("" when cleared).
    flash_message = Signal(str)
    #: The editor wants the canvas to zoom to this level (the scroll area owns the clamp).
    zoom_requested = Signal(float)
    zoom_changed = Signal(float)
    focus_canvas_requested = Signal()
    #: "series" | "xy" | "customFormat" — the window presents the sheet.
    sheet_requested = Signal(str)
    #: A NoteTarget — the window presents the note sheet.
    note_sheet_requested = Signal(object)
    #: (title, message) for a modal alert the window shows.
    error_presented = Signal(str, str)

    def __init__(
        self,
        document: PlateDocument,
        preferences: Preferences | None = None,
        template_store: PlateTemplateStore | None = None,
        parent: QObject | None = None,
    ):
        super().__init__(parent)
        self.document = document
        self.preferences = preferences if preferences is not None else Preferences.shared()
        self.template_store = template_store if template_store is not None else PlateTemplateStore()

        # ---- injectable UI hooks (the window replaces these) ----
        self.clipboard = MemoryClipboard()
        #: (title, message) -> bool. Headless default says yes; the window shows a QMessageBox.
        self.confirm: Callable[[str, str], bool] = lambda title, message: True
        #: Supplies the window title for export file names.
        self.window_title_provider: Callable[[], str] = lambda: ""

        # ---- state outside the Layout (see PORT.md §C1) ----
        layout = document.layout
        self.active_plate_id: str | None = layout.plates[0].id if layout.plates else None
        self.active_factor_id: str | None = None
        self.armed_level_id: str | None = None
        if not layout.well_label_mode.is_overview:
            if layout.factors:
                self.active_factor_id = layout.factors[0].id
                self.armed_level_id = layout.factors[0].levels[0].id if layout.factors[0].levels else None
        self.selection: WellRange | None = WellRange.at(0, 0)
        self.custom_wells: frozenset[WellPos] | None = None
        self.custom_focus: WellPos | None = None
        self.multi_selected_factor_ids: frozenset[str] = frozenset()
        self.multi_selected_level_ids: frozenset[str] = frozenset()
        self.spotlight_level_id: str | None = None
        self.hovered: WellPos | None = None
        self.show_secondary_factors: bool = True
        self.round_wells: bool = self.preferences.new_document_well_shape.is_round
        self.transient_message: str = ""
        self.zoom_level: float = 1.0
        self.matching_saved_state_id: str | None = None
        self._overview_return: tuple[WellLabelMode, str | None] | None = None
        self._flash_timer: QTimer | None = None
        self.rng = random.Random()

        self.refresh_saved_state_match(layout)
        document.layout_changed.connect(self._on_layout_changed)
        self.preferences.changed.connect(self.state_changed)
        self.template_store.changed.connect(self.state_changed)

    # ================================================================== derived state
    @property
    def layout(self) -> Layout:
        return self.document.layout

    @property
    def plate_index(self) -> int:
        idx = self.layout.plate_index(self.active_plate_id)
        if idx is not None:
            return idx
        return 0 if self.layout.plates else -1

    @property
    def plate(self) -> Plate | None:
        i = self.plate_index
        return self.layout.plates[i] if 0 <= i < len(self.layout.plates) else None

    @property
    def format(self) -> PlateFormat:
        p = self.plate
        return p.format if p is not None else WELL96

    @property
    def active_factor(self) -> Factor | None:
        return self.layout.factor(self.active_factor_id)

    @property
    def armed_level(self) -> Level | None:
        f = self.active_factor
        return f.level(self.armed_level_id) if f else None

    @property
    def is_overview(self) -> bool:
        return self.layout.well_label_mode.is_overview

    @property
    def secondary_factors(self) -> list[Factor]:
        return [f for f in self.layout.factors if f.id != self.active_factor_id]

    def well_count_of_level(self, level: Level) -> int:
        p = self.plate
        if self.active_factor_id is None or p is None:
            return 0
        return p.assigned_well_count(self.active_factor_id, level.id)

    def summary(self, row: int, col: int) -> str:
        """"B7  ·  Condition: Treated  ·  Dose: 10" for the status bar."""
        p = self.plate
        if p is None or not p.format.contains(row, col):
            return ""
        well = p.format.index(row, col)
        label = WellNaming.well_label(row, col, self.layout.pad_well_labels)
        parts = []
        for factor in self.layout.factors:
            lid = p.level_id(factor.id, well)
            level = factor.level(lid) if lid else None
            if level is not None:
                parts.append(f"{factor.name}: {level.name}")
        text = f"{label} — empty" if not parts else f"{label}  ·  " + "  ·  ".join(parts)
        note = p.note_for(well)
        if note:
            text += f"  ·  ✎ {note}"
        return text

    # ================================================================== notes
    def open_well_note_sheet(self) -> None:
        p = self.plate
        if p is None:
            return
        focus = self.selection.focus if self.selection is not None else self.custom_focus
        if focus is None or not p.format.contains(focus.row, focus.col):
            self.flash("Select a well first.")
            return
        self.note_sheet_requested.emit(NoteTarget.for_well(p.format.index(focus.row, focus.col)))

    def open_plate_note_sheet(self) -> None:
        self.note_sheet_requested.emit(NoteTarget.for_plate())

    def note_title(self, target: NoteTarget) -> str:
        if target.is_plate:
            p = self.plate
            return f"Note for {p.name}" if p is not None else "Note for this plate"
        p = self.plate
        if p is None or p.format.cols <= 0:
            return "Note"
        label = WellNaming.well_label(target.well // p.format.cols, target.well % p.format.cols, self.layout.pad_well_labels)
        return f"Note for {label}"

    def note_text(self, target: NoteTarget) -> str:
        p = self.plate
        if p is None:
            return ""
        return p.note if target.is_plate else (p.note_for(target.well) or "")

    def save_note(self, text: str, target: NoteTarget) -> None:
        if target.is_plate:
            self._edit_plate("Edit Plate Note", lambda p: p.with_note(text.strip()))
        else:
            self._edit_plate("Edit Well Note", lambda p: p.set_note(text, target.well))

    # ================================================================== mutation plumbing
    def _edit(self, name: str, change: Callable[[Layout], Layout]) -> bool:
        return self.document.mutate(name, change)

    def _edit_plate(self, name: str, change: Callable[[Plate], Plate]) -> bool:
        index = self.plate_index
        if index < 0:
            return False

        def apply(layout: Layout) -> Layout:
            if not 0 <= index < len(layout.plates):
                return layout
            return layout.with_plate(index, change(layout.plates[index]))

        return self._edit(name, apply)

    def focus_canvas(self) -> None:
        self.focus_canvas_requested.emit()

    def flash(self, message: str) -> None:
        self.transient_message = message
        self.flash_message.emit(message)
        self.state_changed.emit()
        if QCoreApplication.instance() is None:
            return
        if self._flash_timer is None:
            self._flash_timer = QTimer(self)
            self._flash_timer.setSingleShot(True)
            self._flash_timer.timeout.connect(self._clear_flash)
        self._flash_timer.start(int(FLASH_SECONDS * 1000))

    def _clear_flash(self) -> None:
        if self.transient_message:
            self.transient_message = ""
            self.flash_message.emit("")
            self.state_changed.emit()

    def _flash_overview_is_read_only(self) -> None:
        self.flash("Overview is read-only — click a factor to start painting again.")

    def _emit_state(self) -> None:
        self.state_changed.emit()

    # ================================================================== painting
    def paint(self, wells: Iterable[int], level: str | None, action_name: str | None = None) -> None:
        wells = list(wells)
        factor_id = self.active_factor_id
        if factor_id is None or not wells or self.layout.factor(factor_id) is None:
            return
        if self.is_multi_selecting:
            self.flash("Painting is off while several rows are selected — click a single row to continue.")
            return
        name = action_name or ("Clear Wells" if level is None else "Paint Wells")
        self._edit_plate(name, lambda p: p.set_level_ids(factor_id, {w: level for w in wells}))

    def paint_selection(self) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        if self.armed_level_id is None:
            return self.flash("Pick a condition first — press 1–9 or click one in the sidebar.")
        if not self.has_selection:
            return self.flash("Select some wells first.")
        self.paint(self.selected_wells, self.armed_level_id, "Fill Selection")

    def clear_selection(self) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        self.paint(self.selected_wells, None, "Clear Selection")

    def clear_selection_all_factors(self) -> None:
        """Removes every factor's value from the selected wells. Deliberately not
        Overview-guarded and needs no active factor (Mac behaviour)."""
        wells = self.selected_wells
        factor_ids = [f.id for f in self.layout.factors]

        def apply(p: Plate) -> Plate:
            for fid in factor_ids:
                p = p.set_level_ids(fid, {w: None for w in wells})
            return p

        self._edit_plate("Clear All Factors", apply)

    # ================================================================== selection & navigation
    @property
    def has_selection(self) -> bool:
        return bool(self.custom_wells) or self.selection is not None

    @property
    def selected_wells(self) -> list[int]:
        """The wells an action applies to; a discontiguous selection overrides the rectangle."""
        if self.custom_wells is not None:
            f = self.format
            return sorted(f.index(p.row, p.col) for p in self.custom_wells)
        return self.selection.indices(self.format) if self.selection is not None else []

    @property
    def selection_as_positions(self) -> frozenset[WellPos]:
        if self.custom_wells is not None:
            return self.custom_wells
        if self.selection is None:
            return frozenset()
        return frozenset(self.selection.positions(self.format))

    def toggle_well(self, pos: WellPos) -> None:
        """Ctrl-click: add an unselected well, remove a selected one. Dissolves the
        rectangle into a set; any plain click/drag/arrow/select-all restores it."""
        if not self.format.contains(pos.row, pos.col):
            return
        current = set(self.selection_as_positions)
        if pos in current:
            current.remove(pos)
        else:
            current.add(pos)
        self.custom_focus = pos
        self.selection = None
        self.custom_wells = frozenset(current) if current else None
        self._emit_state()

    def add_to_selection(self, base: Iterable[WellPos], rect: WellRange) -> None:
        """Ctrl-drag with nothing armed: `base` (the set at mouse-down) plus a rectangle."""
        clamped = rect.clamped(self.format)
        out = set(base)
        out.update(clamped.positions(self.format))
        self.custom_focus = clamped.focus
        self.selection = None
        self.custom_wells = frozenset(out)
        self._emit_state()

    def select(self, rng: WellRange) -> None:
        self.custom_wells = None
        self.selection = rng.clamped(self.format)
        self._emit_state()

    def select_all_wells(self) -> None:
        self.custom_wells = None
        self.selection = WellRange.whole_plate(self.format)
        self._emit_state()

    def clear_selection_marquee(self) -> None:
        self.custom_wells = None
        self.selection = None
        self._emit_state()

    def move_cursor(self, d_row: int, d_col: int, extend: bool = False) -> None:
        f = self.format
        if self.custom_wells is not None:
            start = self.custom_focus or WellPos(0, 0)
            self.custom_wells = None
            self.selection = WellRange.at(
                min(max(start.row + d_row, 0), f.rows - 1), min(max(start.col + d_col, 0), f.cols - 1)
            )
            self._emit_state()
            return
        if self.selection is None:
            self.selection = WellRange.at(0, 0)
            self._emit_state()
            return
        cur = self.selection
        nxt = WellPos(min(max(cur.focus.row + d_row, 0), f.rows - 1), min(max(cur.focus.col + d_col, 0), f.cols - 1))
        self.selection = WellRange(cur.anchor, nxt) if extend else WellRange.single(nxt)
        self._emit_state()

    def set_hovered(self, pos: WellPos | None) -> None:
        if pos != self.hovered:
            self.hovered = pos
            self._emit_state()

    def set_spotlight(self, level_id: str | None) -> None:
        if level_id != self.spotlight_level_id:
            self.spotlight_level_id = level_id
            self._emit_state()

    def set_show_secondary_factors(self, on: bool) -> None:
        if on != self.show_secondary_factors:
            self.show_secondary_factors = on
            self._emit_state()

    def set_round_wells(self, on: bool) -> None:
        if on != self.round_wells:
            self.round_wells = on
            self._emit_state()

    # ================================================================== sidebar multi-selection
    @property
    def is_multi_selecting(self) -> bool:
        return bool(self.multi_selected_factor_ids) or bool(self.multi_selected_level_ids)

    def toggle_factor_in_multi_selection(self, factor_id: str) -> None:
        if self.layout.factor(factor_id) is None:
            return
        chosen = set(self.multi_selected_factor_ids)
        if not chosen and self.active_factor_id is not None and self.active_factor_id != factor_id:
            chosen.add(self.active_factor_id)
        if factor_id in chosen:
            chosen.remove(factor_id)
        else:
            chosen.add(factor_id)
        if len(chosen) <= 1:
            self.multi_selected_factor_ids = frozenset()
            if chosen:
                self.set_active_factor(next(iter(chosen)))
            else:
                self._emit_state()
            return
        self.multi_selected_level_ids = frozenset()
        self.multi_selected_factor_ids = frozenset(chosen)
        self.armed_level_id = None
        self._emit_state()

    def toggle_level_in_multi_selection(self, level_id: str) -> None:
        f = self.active_factor
        if f is None or f.level(level_id) is None:
            return
        chosen = set(self.multi_selected_level_ids)
        if not chosen and self.armed_level_id is not None and self.armed_level_id != level_id:
            chosen.add(self.armed_level_id)
        if level_id in chosen:
            chosen.remove(level_id)
        else:
            chosen.add(level_id)
        if len(chosen) <= 1:
            self.multi_selected_level_ids = frozenset()
            if chosen:
                self.arm_level(next(iter(chosen)))
            else:
                self._emit_state()
            return
        self.multi_selected_factor_ids = frozenset()
        self.multi_selected_level_ids = frozenset(chosen)
        self.armed_level_id = None
        self._emit_state()

    def arm_level(self, level_id: str) -> None:
        """A plain sidebar click on a condition row: arm it and leave multi-selection."""
        self._exit_multi_selection()
        self.armed_level_id = level_id
        self._emit_state()

    def _exit_multi_selection(self) -> None:
        self.multi_selected_factor_ids = frozenset()
        self.multi_selected_level_ids = frozenset()

    def delete_levels(self, ids: Iterable[str]) -> None:
        ids = set(ids)
        factor_id = self.active_factor_id
        if factor_id is None or not ids:
            return

        def apply(layout: Layout) -> Layout:
            for lid in ids:
                layout = layout.remove_level(lid, factor_id)
            return layout

        self._edit("Delete Conditions", apply)
        self._exit_multi_selection()
        if self.armed_level_id is None:
            f = self.active_factor
            self.armed_level_id = f.levels[0].id if f and f.levels else None
        self._emit_state()

    def delete_factors(self, ids: Iterable[str]) -> None:
        doomed = set(ids)
        if not doomed:
            return
        factors = self.layout.factors
        if factors and all(f.id in doomed for f in factors):
            spare = factors[0]
            doomed.discard(spare.id)
            self.flash(f"A layout needs at least one factor — {spare.name} stays.")
        if not doomed:
            return

        def apply(layout: Layout) -> Layout:
            for fid in doomed:
                layout = layout.remove_factor(fid)
            return layout

        self._edit("Delete Factors", apply)
        self._exit_multi_selection()
        if self.armed_level_id is None and not self.is_overview:
            f = self.active_factor
            self.armed_level_id = f.levels[0].id if f and f.levels else None
        self._emit_state()

    # ================================================================== level & factor hotkeys
    def arm_level_at_index(self, index: int) -> None:
        f = self.active_factor
        if f is None or not 0 <= index < len(f.levels):
            return
        self._exit_multi_selection()
        self.armed_level_id = f.levels[index].id
        self._emit_state()

    def cycle_level(self, delta: int) -> None:
        f = self.active_factor
        if f is None or not f.levels:
            return
        self._exit_multi_selection()
        current = f.index_of(self.armed_level_id) if self.armed_level_id else None
        if current is None:
            current = -1
        count = len(f.levels)
        self.armed_level_id = f.levels[((current + delta) % count + count) % count].id
        self._emit_state()

    def disarm_level(self) -> None:
        self._exit_multi_selection()
        self.armed_level_id = None
        self._emit_state()

    def set_active_factor(self, factor_id: str) -> None:
        self._leave_overview()
        self._exit_multi_selection()
        self.spotlight_level_id = None
        self.active_factor_id = factor_id
        f = self.layout.factor(factor_id)
        self.armed_level_id = f.levels[0].id if f and f.levels else None
        self._emit_state()

    def cycle_factor(self, delta: int) -> None:
        factors = self.layout.factors
        if not factors:
            return
        current = self.layout.factor_index(self.active_factor_id)
        if current is None:
            self.set_active_factor(factors[-1 if delta < 0 else 0].id)
            return
        count = len(factors)
        self.set_active_factor(factors[((current + delta) % count + count) % count].id)

    def set_active_factor_at_index(self, index: int) -> None:
        if 0 <= index < len(self.layout.factors):
            self.set_active_factor(self.layout.factors[index].id)

    # ================================================================== level editing
    def new_level_color(self, layout: Layout, fallback_index: int) -> str:
        """The colour for a condition about to be created, honouring the Settings choice.
        Takes the layout the level is joining, because during a paste the set of used
        colours grows with every new value."""
        if self.preferences.new_condition_colors is NewConditionColors.neverRepeat:
            return palette.first_color_avoiding(layout.used_level_colors(), fallback_index)
        return palette.color_at(fallback_index)

    def add_level(self, name: str | None = None) -> None:
        factor_id = self.active_factor_id
        f = self.active_factor
        if factor_id is None or f is None:
            return
        count = len(f.levels)
        level = Level(name=name if name is not None else f"Condition {count + 1}", color_hex=self.new_level_color(self.layout, count))

        def apply(layout: Layout) -> Layout:
            i = layout.factor_index(factor_id)
            if i is None:
                return layout
            fac = layout.factors[i]
            return layout.with_factor(i, fac.with_levels(fac.levels + (level,)))

        self._edit("Add Level", apply)
        self.armed_level_id = level.id
        self._emit_state()

    def rename_level(self, level_id: str, new_name: str) -> None:
        factor_id = self.active_factor_id
        trimmed = new_name.strip(" \t")
        if factor_id is None or not trimmed:
            return
        self._edit("Rename Level", lambda layout: _update_level(layout, factor_id, level_id, lambda lv: replace(lv, name=trimmed)))

    def set_level_color(self, level_id: str, hex_text: str) -> None:
        factor_id = self.active_factor_id
        if factor_id is None:
            return
        self._edit("Change Colour", lambda layout: _update_level(layout, factor_id, level_id, lambda lv: replace(lv, color_hex=hex_text)))

    def delete_level(self, level_id: str) -> None:
        factor_id = self.active_factor_id
        if factor_id is None:
            return
        self._edit("Delete Level", lambda layout: layout.remove_level(level_id, factor_id))
        if self.armed_level_id == level_id:
            f = self.active_factor
            self.armed_level_id = f.levels[0].id if f and f.levels else None
        self._emit_state()

    def move_levels(self, from_offsets: Iterable[int], to_offset: int) -> None:
        """Swift `move(fromOffsets:toOffset:)`: `to_offset` is an insertion point counted
        in the *pre-move* list (moving down passes the target index + 1)."""
        factor_id = self.active_factor_id
        if factor_id is None:
            return
        offsets = sorted(set(from_offsets))

        def apply(layout: Layout) -> Layout:
            i = layout.factor_index(factor_id)
            if i is None:
                return layout
            fac = layout.factors[i]
            return layout.with_factor(i, fac.with_levels(_moved(list(fac.levels), offsets, to_offset)))

        self._edit("Reorder Levels", apply)

    def recolor_levels_from_palette(self) -> None:
        factor_id = self.active_factor_id
        f = self.active_factor
        if factor_id is None or f is None:
            return
        n = len(f.levels)
        if f.kind is FactorKind.numeric:
            hexes = palette.ramp(n, palette.color_at(0))
        elif self.preferences.new_condition_colors is NewConditionColors.neverRepeat:
            used = set(self.layout.used_level_colors(excluding=factor_id))
            hexes = []
            for i in range(n):
                hx = palette.first_color_avoiding(used, i)
                used.add(palette.normalized(hx))
                hexes.append(hx)
        else:
            hexes = [palette.color_at(i) for i in range(n)]

        def apply(layout: Layout) -> Layout:
            i = layout.factor_index(factor_id)
            if i is None:
                return layout
            fac = layout.factors[i]
            levels = [replace(lv, color_hex=hexes[k]) if k < len(hexes) else lv for k, lv in enumerate(fac.levels)]
            return layout.with_factor(i, fac.with_levels(levels))

        self._edit("Recolour Levels", apply)

    def remove_unused_levels(self) -> None:
        factor_id = self.active_factor_id
        if factor_id is None:
            return
        before = len(self.active_factor.levels) if self.active_factor else 0
        self._edit("Remove Unused Levels", lambda layout: layout.prune_unused_levels(factor_id))
        after = len(self.active_factor.levels) if self.active_factor else 0
        self.flash("No unused conditions." if before == after else f"Removed {before - after} unused condition(s).")
        f = self.active_factor
        if f is None or f.level(self.armed_level_id) is None:
            self.armed_level_id = f.levels[0].id if f and f.levels else None
        self._emit_state()

    # ================================================================== factor editing
    def add_factor(self) -> None:
        factor = Factor(
            name=self.layout.unique_factor_name("Factor"),
            levels=(Level(name="Level 1", color_hex=self.new_level_color(self.layout, 0)),),
        )
        self._edit("Add Factor", lambda layout: replace(layout, factors=layout.factors + (factor,)))
        self.set_active_factor(factor.id)

    def rename_factor(self, factor_id: str, new_name: str) -> None:
        trimmed = new_name.strip(" \t")
        if not trimmed:
            return
        self._edit("Rename Factor", lambda layout: _update_factor(layout, factor_id, lambda f: replace(f, name=trimmed)))

    def set_factor_unit(self, factor_id: str, unit: str) -> None:
        clean = unit.strip(" \t")
        self._edit("Set Unit", lambda layout: _update_factor(layout, factor_id, lambda f: replace(f, unit=clean)))

    def set_factor_kind(self, factor_id: str, kind: FactorKind | str) -> None:
        k = FactorKind(kind)
        self._edit("Change Factor Type", lambda layout: _update_factor(layout, factor_id, lambda f: replace(f, kind=k)))

    def move_factors(self, from_offsets: Iterable[int], to_offset: int) -> None:
        offsets = sorted(set(from_offsets))
        self._edit("Reorder Factors", lambda layout: replace(layout, factors=tuple(_moved(list(layout.factors), offsets, to_offset))))

    def delete_factor(self, factor_id: str) -> None:
        if len(self.layout.factors) <= 1:
            return self.flash("A layout needs at least one factor.")
        self._edit("Delete Factor", lambda layout: layout.remove_factor(factor_id))
        if self.active_factor_id == factor_id and self.layout.factors:
            self.set_active_factor(self.layout.factors[0].id)
        else:
            self._emit_state()

    # ================================================================== plates
    def add_plate(self) -> None:
        plate = Plate(name=self.layout.unique_plate_name("Plate"), format=self.format)
        self._edit("Add Plate", lambda layout: replace(layout, plates=layout.plates + (plate,)))
        self.active_plate_id = plate.id
        self.custom_wells = None
        self.selection = WellRange.at(0, 0)
        self._after_plate_switch()

    def duplicate_plate(self) -> None:
        current = self.plate
        if current is None:
            return
        copy = replace(current, id=new_id(), name=self.layout.unique_plate_name(current.name + " copy"))
        self._edit("Duplicate Plate", lambda layout: replace(layout, plates=layout.plates + (copy,)))
        self.active_plate_id = copy.id
        self._after_plate_switch()

    def delete_plate(self, plate_id: str) -> None:
        if len(self.layout.plates) <= 1:
            return self.flash("A layout needs at least one plate.")
        index = self.layout.plate_index(plate_id)
        self._edit("Delete Plate", lambda layout: replace(layout, plates=tuple(p for p in layout.plates if p.id != plate_id)))
        if self.active_plate_id == plate_id:
            plates = self.layout.plates
            fallback = min(index if index is not None else 0, len(plates) - 1)
            self.active_plate_id = plates[fallback].id if 0 <= fallback < len(plates) else (plates[0].id if plates else None)
            self._after_plate_switch()
        else:
            self._emit_state()

    def set_active_plate(self, plate_id: str) -> None:
        """A tab click: make the plate active and put the selection back on A1."""
        if self.layout.plate(plate_id) is None:
            return
        self.active_plate_id = plate_id
        self.custom_wells = None
        self.selection = WellRange.at(0, 0)
        self._after_plate_switch()

    def _after_plate_switch(self) -> None:
        self.refresh_saved_state_match(self.layout, self.active_plate_id)
        self._emit_state()

    def rename_plate(self, plate_id: str, new_name: str) -> None:
        trimmed = new_name.strip(" \t")
        if not trimmed:
            return
        self._edit("Rename Plate", lambda layout: _update_plate(layout, plate_id, lambda p: replace(p, name=trimmed)))

    def set_format(self, new_format: PlateFormat) -> bool:
        """False when the user backed out of the data-loss warning (no side effects)."""
        current = self.plate
        if current is None:
            return False
        if current.format == new_format:
            return True
        if current.format_change_would_lose_data(new_format):
            ok = self.confirm(
                f"Switch to a {self.format_display_name(new_format)} plate?",
                "Wells outside the smaller plate already have values assigned. Those assignments will be discarded. You can undo this.",
            )
            if not ok:
                return False
        self._edit_plate("Change Plate Format", lambda p: p.change_format(new_format))
        self.selection = self.selection.clamped(new_format) if self.selection is not None else None
        self.custom_wells = self._clipping_custom_wells(new_format)
        self._emit_state()
        return True

    # ================================================================== rotation & labels
    def rotate_plate(self) -> None:
        was_turned = self.is_turned
        target = PlateOrientation.upright if was_turned else PlateOrientation.turned
        self._edit("Turn Plate", lambda layout: replace(layout, orientation=target))
        self.flash("Upright. A1 is top left." if was_turned else "Turned 90°. A1 is now top right.")

    @property
    def quarter_turns(self) -> int:
        return self.layout.orientation.quarter_turns(self.format)

    @property
    def is_turned(self) -> bool:
        return self.quarter_turns != 0

    def set_pad_well_labels(self, padded: bool) -> None:
        self._edit("Well Label Style", lambda layout: replace(layout, pad_well_labels=bool(padded)))

    def set_well_label_mode(self, mode: WellLabelMode | str) -> None:
        mode = WellLabelMode(mode)
        entering = mode.is_overview and not self.is_overview
        resume = (self.layout.well_label_mode, self.active_factor_id) if entering else self._overview_return
        self._edit("Well Labels", lambda layout: replace(layout, well_label_mode=mode))
        if mode.is_overview:
            self._overview_return = resume
            self._emit_state()
        else:
            if resume is not None and resume[1] is not None and self.layout.factor(resume[1]) is not None:
                self.set_active_factor(resume[1])
            self._overview_return = None
            self._emit_state()

    def toggle_overview(self) -> None:
        if self.is_overview:
            self.set_well_label_mode(self._overview_return[0] if self._overview_return else WellLabelMode.allFactors)
        else:
            self.set_well_label_mode(WellLabelMode.overview)

    def _leave_overview(self) -> None:
        if not self.is_overview:
            return
        resume = self._overview_return[0] if self._overview_return else WellLabelMode.allFactors
        target = WellLabelMode.allFactors if resume.is_overview else resume
        self._edit("Well Labels", lambda layout: replace(layout, well_label_mode=target))
        self._overview_return = None

    # ================================================================== saved states
    @property
    def saved_states(self) -> tuple[LayoutSnapshot, ...]:
        return self.layout.snapshots_for(self.active_plate_id)

    @property
    def has_saved_states(self) -> bool:
        return bool(self.saved_states)

    @property
    def saved_states_newest_first(self) -> list[LayoutSnapshot]:
        return list(reversed(self.saved_states))

    @staticmethod
    def _short_time(state: LayoutSnapshot) -> str:
        when = state.saved_at_datetime().astimezone()
        qdt = QDateTime(when.year, when.month, when.day, when.hour, when.minute, when.second)
        return QLocale.system().toString(qdt.time(), QLocale.FormatType.ShortFormat)

    def title_for(self, state: LayoutSnapshot) -> str:
        return f"{state.name}  ·  {self._short_time(state)}"

    def subtitle_for(self, state: LayoutSnapshot) -> str:
        parts = [f"Saved {self._short_time(state)}"]
        if state.plates:
            plate = state.plates[0]
            parts.append(self.template_store.display_name(plate.format))
            filled = sum(
                1
                for well in range(plate.format.well_count)
                if any(plate.level_id(f.id, well) is not None for f in state.factors)
            )
            parts.append(f"{filled} well{'' if filled == 1 else 's'} filled")
        if state.plate_id is None and len(state.plates) > 1:
            parts.append(f"whole document, {len(state.plates)} plates")
        return "  ·  ".join(parts)

    def save_state(self) -> None:
        plate_id = self.active_plate_id
        plate = self.plate
        if plate_id is None or plate is None:
            return self.flash("No plate to save.")
        existing = self.layout.snapshot_matching(plate_id)
        if existing is not None:
            return self.flash(f"{plate.name} is already saved as {existing.name}.")
        now = LayoutSnapshot.apple_seconds(datetime.now(timezone.utc))
        dropped = [0]

        def apply(layout: Layout) -> Layout:
            new, dropped[0] = layout.capture_snapshot(now, plate_id)
            return new

        self._edit("Save State", apply)
        if dropped[0] > 0:
            self.flash(f"Saved. Keeping the {len(self.layout.snapshots)} most recent states.")
        else:
            name = self.layout.snapshots[-1].name if self.layout.snapshots else "state"
            self.flash(f"Saved {name} for {plate.name}. {UNDO_KEY} undoes this.")

    def rename_state(self, state_id: str, new_name: str) -> None:
        self._edit("Rename State", lambda layout: layout.rename_snapshot(state_id, new_name))

    def delete_state(self, state_id: str) -> None:
        doomed = next((s for s in self.layout.snapshots if s.id == state_id), None)
        if doomed is None:
            return
        self._edit("Delete State", lambda layout: layout.remove_snapshot(state_id))
        self.flash(f"Deleted {doomed.name}. {UNDO_KEY} restores it.")

    def revert_to_latest_state(self) -> None:
        states = self.saved_states
        if not states:
            p = self.plate
            return self.flash(f"No saved states for {p.name if p else 'this plate'} yet — use the bookmark button first.")
        self.revert_to_state(states[-1].id)

    def revert_to_state(self, state_id: str) -> None:
        target = next((s for s in self.layout.snapshots if s.id == state_id), None)
        if target is None:
            return
        before = self.layout
        self._edit(f"Revert to {target.name}", lambda layout: layout.restore_snapshot(state_id)[0])
        if self.layout == before:
            self.flash(f"Already matches {target.name}.")
        else:
            self.flash(f"Reverted to {target.name}. {UNDO_KEY} puts it back.")

    def refresh_saved_state_match(self, layout: Layout, plate_id: str | None = None) -> None:
        match = layout.snapshot_matching(plate_id if plate_id is not None else self.active_plate_id)
        match_id = match.id if match else None
        if match_id != self.matching_saved_state_id:
            self.matching_saved_state_id = match_id

    @property
    def current_design_is_saved(self) -> bool:
        return self.matching_saved_state_id is not None

    # ================================================================== reconcile (the sink)
    def _on_layout_changed(self, layout: Layout) -> None:
        # Swift refreshes the match, reconciles, and then refreshes again through the
        # `$activePlateID` sink when reconciling moved the active plate; the end state is
        # "the match for whatever plate is active now", which one refresh after gives.
        self.reconcile_targets(layout)
        self.refresh_saved_state_match(layout)
        self.layout_changed.emit(layout)
        self.state_changed.emit()

    def reconcile_targets(self, layout: Layout) -> None:
        """Keeps what the editor points at valid for the layout that just arrived —
        driven from the layout signal, because undo/redo can delete anything."""
        if self.active_plate_id is None or layout.plate(self.active_plate_id) is None:
            self.active_plate_id = layout.plates[0].id if layout.plates else None
        if layout.well_label_mode.is_overview:
            self.active_factor_id = None
        elif self.active_factor_id is None or layout.factor(self.active_factor_id) is None:
            self.active_factor_id = layout.factors[0].id if layout.factors else None
        factor = layout.factor(self.active_factor_id)
        if self.armed_level_id is not None and (factor is None or factor.level(self.armed_level_id) is None):
            self.armed_level_id = factor.levels[0].id if factor and factor.levels else None
        plate = layout.plate(self.active_plate_id)
        if plate is not None:
            if self.selection is not None:
                self.selection = self.selection.clamped(plate.format)
            self.custom_wells = self._clipping_custom_wells(plate.format)
        if self.spotlight_level_id is not None and (factor is None or factor.level(self.spotlight_level_id) is None):
            self.spotlight_level_id = None
        factor_ids = {f.id for f in layout.factors}
        pruned_f = self.multi_selected_factor_ids & factor_ids
        if pruned_f != self.multi_selected_factor_ids:
            self.multi_selected_factor_ids = pruned_f if len(pruned_f) > 1 else frozenset()
        level_ids = {lv.id for lv in factor.levels} if factor else set()
        pruned_l = self.multi_selected_level_ids & level_ids
        if pruned_l != self.multi_selected_level_ids:
            self.multi_selected_level_ids = pruned_l if len(pruned_l) > 1 else frozenset()

    def _clipping_custom_wells(self, fmt: PlateFormat) -> frozenset[WellPos] | None:
        """A discontiguous well cannot be clamped without landing on a well the user never
        chose — out-of-range wells are dropped instead."""
        if self.custom_wells is None:
            return None
        kept = frozenset(p for p in self.custom_wells if fmt.contains(p.row, p.col))
        return kept or None

    # ================================================================== custom plate sizes
    def apply_custom_format(self, rows: int, cols: int, template_name: str | None) -> bool:
        fmt = PlateFormat(rows, cols)
        if not self.set_format(fmt):
            return False
        if template_name is not None:
            self.template_store.add(template_name, fmt.rows, fmt.cols)
        return True

    def format_display_name(self, fmt: PlateFormat) -> str:
        return self.template_store.display_name(fmt)

    def format_detailed_name(self, fmt: PlateFormat) -> str:
        return self.template_store.detailed_name(fmt)

    # ================================================================== clipboard
    def copy_selection(self, include_headers: bool = False) -> None:
        if self.custom_wells is not None:
            return self.flash("Copy needs a rectangular selection.")
        plate = self.plate
        if plate is None or self.selection is None:
            return
        factor = self.active_factor
        if factor is None:
            return self.flash("No factor selected — click one in the sidebar to copy its values.")
        rng = self.selection.clamped(plate.format)
        grid: Grid = []
        if include_headers:
            grid.append([""] + [str(c + 1) for c in range(rng.min_col, rng.max_col + 1)])
        for r in range(rng.min_row, rng.max_row + 1):
            row = [WellNaming.row_label(r)] if include_headers else []
            for c in range(rng.min_col, rng.max_col + 1):
                lid = plate.level_id(factor.id, plate.format.index(r, c))
                level = factor.level(lid) if lid else None
                row.append(level.name if level else "")
            grid.append(row)
        self.clipboard.set_text(TSV.serialize(grid))
        n = rng.well_count
        self.flash(f"Copied {n} well{'' if n == 1 else 's'} as {factor.name}.")

    def cut_selection(self) -> None:
        if self.custom_wells is not None:
            return self.flash("Cut needs a rectangular selection.")
        self.copy_selection()
        self.clear_selection()

    def paste_from_clipboard(self) -> None:
        text = self.clipboard.text()
        if not text:
            return
        if self.is_overview:
            return self._flash_overview_is_read_only()
        factor_id = self.active_factor_id
        if factor_id is None:
            return
        grid = TSV.parse(text)
        if len(grid) == 1 and len(grid[0]) == 1 and "," in text:
            grid = CSV.parse(text)
        grid = TSV.stripping_plate_headers(grid)
        if not grid:
            return
        origin_row = self.selection.min_row if self.selection is not None else 0
        origin_col = self.selection.min_col if self.selection is not None else 0
        self._apply_grid(grid, factor_id, origin_row, origin_col, "Paste")
        rows = len(grid)
        cols = max((len(r) for r in grid), default=0)
        self.selection = WellRange(WellPos(origin_row, origin_col), WellPos(origin_row + rows - 1, origin_col + cols - 1)).clamped(self.format)
        self._emit_state()

    def _apply_grid(self, grid: Grid, factor_id: str, origin_row: int, origin_col: int, action_name: str) -> None:
        index = self.plate_index
        if index < 0:
            return
        created = [0]

        def apply(layout: Layout) -> Layout:
            fi = layout.factor_index(factor_id)
            if not 0 <= index < len(layout.plates) or fi is None:
                return layout
            fmt = layout.plates[index].format
            factor = layout.factors[fi]
            writes: dict[int, str | None] = {}
            for dr, row in enumerate(grid):
                r = origin_row + dr
                if not 0 <= r < fmt.rows:
                    continue
                for dc, raw in enumerate(row):
                    c = origin_col + dc
                    if not 0 <= c < fmt.cols:
                        continue
                    value = raw.strip(" \t")
                    well = fmt.index(r, c)
                    if not value:
                        writes[well] = None
                        continue
                    existed = factor.level_named(value) is not None
                    color = None if existed else self.new_level_color(layout.with_factor(fi, factor), len(factor.levels))
                    factor, level_id = factor.ensure_level(value, color)
                    if not existed:
                        created[0] += 1
                    writes[well] = level_id
            layout = layout.with_factor(fi, factor)
            return layout.with_plate(index, layout.plates[index].set_level_ids(factor_id, writes))

        self._edit(action_name, apply)
        if created[0] > 0:
            self.flash(f"Added {created[0]} new condition{'' if created[0] == 1 else 's'} from pasted values.")
        f = self.active_factor
        if f is None or f.level(self.armed_level_id) is None:
            self.armed_level_id = f.levels[0].id if f and f.levels else None
        self._emit_state()

    def import_table_text(self, text: str, is_csv: bool) -> bool:
        """The pure half of File → Import Table: parse (by extension, then a CSV retry
        for a 1×1 result), strip plate headers, apply at A1 into the active factor."""
        factor_id = self.active_factor_id
        if factor_id is None:
            return False
        grid = CSV.parse(text) if is_csv else TSV.parse(text)
        if len(grid) == 1 and len(grid[0]) == 1:
            grid = CSV.parse(text)
        grid = TSV.stripping_plate_headers(grid)
        if not grid:
            self.flash("That file did not contain a readable table.")
            return False
        self._apply_grid(grid, factor_id, 0, 0, "Import Table")
        f = self.active_factor
        self.flash(f"Imported {len(grid)} × {len(grid[0])} values into {f.name if f else 'factor'}.")
        return True

    def import_table_file(self, path) -> bool:
        if self.active_factor_id is None:
            return False
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError) as exc:
            self.error_presented.emit("Could not read that file", str(exc))
            return False
        return self.import_table_text(text, str(path).lower().endswith(".csv"))

    # ================================================================== generators: series
    def open_series_sheet(self) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        self.sheet_requested.emit("series")

    def series_values(self, spec: SeriesSpec) -> list[str]:
        plate = self.plate
        if plate is None or self.selection is None:
            return []
        rng = self.selection.clamped(plate.format)
        steps = rng.col_count if spec.direction is SeriesDirection.acrossColumns else rng.row_count
        if steps <= 0:
            return []
        out = []
        for k in range(steps):
            if spec.last_is_zero and k == steps - 1:
                out.append("0")
                continue
            if spec.mode is SeriesMode.linear:
                raw = spec.start + spec.step * k
            else:
                f = 1.0 if spec.fold_factor <= 0 else spec.fold_factor
                raw = spec.start / (f ** k) if spec.dilute else spec.start * (f ** k)
            out.append(format_value(raw, spec.significant_digits))
        return out

    def apply_series(self, spec: SeriesSpec) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        factor_id = self.active_factor_id
        plate = self.plate
        if factor_id is None or plate is None or self.selection is None:
            return
        rng = self.selection.clamped(plate.format)
        values = self.series_values(spec)
        steps = len(values)
        if steps == 0:
            return
        f = self.active_factor
        base = f.levels[0].color_hex if f and f.levels else palette.color_at(0)
        ramp = palette.ramp(steps, base)
        index = self.plate_index

        def apply(layout: Layout) -> Layout:
            fi = layout.factor_index(factor_id)
            if not 0 <= index < len(layout.plates) or fi is None:
                return layout
            factor = replace(layout.factors[fi], kind=FactorKind.numeric)
            id_for_step: list[str] = []
            for k, value in enumerate(values):
                factor, lid = factor.ensure_level(value)
                factor = factor.with_levels(replace(lv, color_hex=ramp[k]) if lv.id == lid else lv for lv in factor.levels)
                id_for_step.append(lid)
            factor = factor.with_levels(sorted(factor.levels, key=_series_sort_key))
            layout = layout.with_factor(fi, factor)
            fmt = layout.plates[index].format
            writes: dict[int, str | None] = {}
            for r in range(rng.min_row, rng.max_row + 1):
                for c in range(rng.min_col, rng.max_col + 1):
                    if not fmt.contains(r, c):
                        continue
                    k = c - rng.min_col if spec.direction is SeriesDirection.acrossColumns else r - rng.min_row
                    if 0 <= k < len(id_for_step):
                        writes[fmt.index(r, c)] = id_for_step[k]
            return layout.with_plate(index, layout.plates[index].set_level_ids(factor_id, writes))

        self._edit("Series Fill", apply)
        f = self.active_factor
        self.armed_level_id = f.levels[0].id if f and f.levels else None
        self.flash(f"Filled {steps}-point series: {values[0]} → {values[-1]}")

    # ================================================================== generators: XY
    def xy_fill_wells(self, spec: XYFillSpec) -> list[int]:
        """The wells an XY fill would number, in pattern order, walking the plate as
        *displayed* (the geometry owns the rotation). No selection or a single well means
        the whole plate; a discontiguous set is numbered as it stands."""
        from playout.ui.plate_geometry import PlateGeometry, Rect

        plate = self.plate
        if plate is None:
            return []
        fmt = plate.format
        geo = PlateGeometry.fit(fmt, Rect(0, 0, 1000, 1000), self.quarter_turns)
        shown: list[WellPos] = []
        if self.custom_wells:
            for p in self.custom_wells:
                if fmt.contains(p.row, p.col):
                    dr, dc = geo.display_position(p.row, p.col)
                    shown.append(WellPos(dr, dc))
        elif self.selection is not None and not self.selection.is_single_well:
            rng = self.selection.clamped(fmt)
            a = geo.display_position(rng.min_row, rng.min_col)
            b = geo.display_position(rng.max_row, rng.max_col)
            for row in range(min(a[0], b[0]), max(a[0], b[0]) + 1):
                for col in range(min(a[1], b[1]), max(a[1], b[1]) + 1):
                    shown.append(WellPos(row, col))
        else:
            for row in range(geo.display_rows):
                for col in range(geo.display_cols):
                    shown.append(WellPos(row, col))

        if spec.pattern is XYPattern.acrossColumns:
            ordered = sorted(shown, key=lambda p: (p.row, p.col))
        elif spec.pattern is XYPattern.downRows:
            ordered = sorted(shown, key=lambda p: (p.col, p.row))
        else:
            by_row: dict[int, list[WellPos]] = {}
            for p in shown:
                by_row.setdefault(p.row, []).append(p)
            ordered = []
            for rank, row in enumerate(sorted(by_row)):
                cols = sorted(by_row[row], key=lambda p: p.col)
                ordered.extend(cols if rank % 2 == 0 else list(reversed(cols)))
        out = []
        for p in ordered:
            m = geo.model_position(p.row, p.col)
            out.append(fmt.index(m.row, m.col))
        return out

    def open_xy_fill_sheet(self) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        self.sheet_requested.emit("xy")

    def existing_xy_factor(self) -> Factor | None:
        for f in self.layout.factors:
            if f.name.strip(" \t").lower() == XY_FACTOR_NAME.lower():
                return f
        return None

    def apply_xy_fill(self, spec: XYFillSpec) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        wells = self.xy_fill_wells(spec)
        index = self.plate_index
        if not wells or index < 0:
            return
        names = xy_names(len(wells))
        existing = self.existing_xy_factor()
        factor_id = existing.id if existing else new_id()
        base_hex = spec.base_hex
        if base_hex is None and existing is not None and existing.levels:
            base_hex = existing.levels[0].color_hex
        if base_hex is None:
            base_hex = self.new_level_color(self.layout, len(self.layout.factors))
        ramp = palette.ramp(len(wells), base_hex)

        def apply(layout: Layout) -> Layout:
            fi = layout.factor_index(factor_id)
            if fi is None:
                layout = replace(layout, factors=layout.factors + (Factor(name=XY_FACTOR_NAME, id=factor_id),))
                fi = len(layout.factors) - 1
            if not 0 <= index < len(layout.plates):
                return layout
            factor = layout.factors[fi]
            writes: dict[int, str | None] = {}
            for k, name in enumerate(names):
                factor, lid = factor.ensure_level(name)
                factor = factor.with_levels(replace(lv, color_hex=ramp[k]) if lv.id == lid else lv for lv in factor.levels)
                writes[wells[k]] = lid
            layout = layout.with_factor(fi, factor)
            return layout.with_plate(index, layout.plates[index].set_level_ids(factor_id, writes))

        self._edit("XY Position Fill", apply)
        self.set_active_factor(factor_id)
        self.flash(f"Numbered {len(wells)} positions: {names[0]} → {names[-1]}")

    # ================================================================== randomise
    def randomize_selection(self) -> None:
        if self.is_overview:
            return self._flash_overview_is_read_only()
        factor_id = self.active_factor_id
        plate = self.plate
        if factor_id is None or plate is None:
            return
        wells = self.selected_wells
        if len(wells) <= 1:
            return
        values = [plate.level_id(factor_id, w) for w in wells]
        self.rng.shuffle(values)
        self._edit_plate("Randomise Selection", lambda p: p.set_level_ids(factor_id, dict(zip(wells, values))))
        self.flash(f"Randomised {len(wells)} wells.")

    # ================================================================== export naming
    @property
    def suggested_base_name(self) -> str:
        title = self.window_title_provider() or ""
        cleaned = title.replace(" — Edited", "").replace(".plate", "").strip(" \t")
        return "Plate Layout" if not cleaned or cleaned == "Untitled" else cleaned

    # ================================================================== zoom
    @property
    def can_zoom_out(self) -> bool:
        return self.zoom_level > 1.001

    def zoom_in(self) -> None:
        self.zoom_requested.emit(self.zoom_level * 1.4)

    def zoom_out(self) -> None:
        self.zoom_requested.emit(self.zoom_level / 1.4)

    def zoom_to_fit(self) -> None:
        self.zoom_requested.emit(1.0)

    def note_zoom_changed(self, value: float) -> None:
        if abs(value - self.zoom_level) <= 0.001:
            return
        self.zoom_level = value
        self.zoom_changed.emit(value)
        self._emit_state()


# --------------------------------------------------------------------------------------
# helpers


def _update_factor(layout: Layout, factor_id: str, fn: Callable[[Factor], Factor]) -> Layout:
    i = layout.factor_index(factor_id)
    return layout if i is None else layout.with_factor(i, fn(layout.factors[i]))


def _update_level(layout: Layout, factor_id: str, level_id: str, fn: Callable[[Level], Level]) -> Layout:
    def on_factor(f: Factor) -> Factor:
        if f.index_of(level_id) is None:
            return f
        return f.with_levels(fn(lv) if lv.id == level_id else lv for lv in f.levels)

    return _update_factor(layout, factor_id, on_factor)


def _update_plate(layout: Layout, plate_id: str, fn: Callable[[Plate], Plate]) -> Layout:
    i = layout.plate_index(plate_id)
    return layout if i is None else layout.with_plate(i, fn(layout.plates[i]))


def _moved(items: list, offsets: list[int], to_offset: int) -> list:
    """Swift `Array.move(fromOffsets:toOffset:)`: pull the picked items out and insert them
    at `to_offset` as counted in the original list (adjusted for the removals before it)."""
    picked = [items[i] for i in offsets if 0 <= i < len(items)]
    remaining = [x for i, x in enumerate(items) if i not in set(offsets)]
    insert_at = to_offset - sum(1 for i in offsets if i < to_offset)
    insert_at = min(max(insert_at, 0), len(remaining))
    return remaining[:insert_at] + picked + remaining[insert_at:]


def _series_sort_key(level: Level):
    """Numeric names descending, numeric before non-numeric, non-numeric ascending by name."""
    v = _double(level.name)
    if v is not None:
        return (0, -v, "")
    return (1, 0.0, level.name)
