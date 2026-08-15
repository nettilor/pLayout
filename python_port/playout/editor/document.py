"""PlateDocument: layout + path + QUndoStack + `mutate()` + save/load/autosave.

Mirrors `Sources/PLayout/Model/PlateDocument.swift` plus the bits of the macOS document
machinery (`DocumentGroup`) the port has to supply itself: autosave in place, the dirty
flag, atomic writes.

The one rule that matters: **every model edit goes through `mutate`.** It builds the new
`Layout`, returns early when nothing changed (no undo entry, no signal), and otherwise
pushes one `QUndoCommand` holding (previous, new). Undo and redo swap whole layouts and
emit the same `layout_changed` as an edit — which is what lets `PlateEditor` reconcile
its state from that one signal instead of from every action.

Views must never connect to `layout_changed` directly; they listen to `PlateEditor`,
which re-emits only after it has reconciled (PORT.md §Architecture).
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QCoreApplication, QObject, QSaveFile, QTimer, Signal
from PySide6.QtGui import QUndoCommand, QUndoStack

from playout.model.layout import Layout, LayoutDecodeError, dumps, loads

AUTOSAVE_DELAY_MS = 2000


class _LayoutCommand(QUndoCommand):
    """One user action: swap the document between two whole layouts."""

    def __init__(self, document: "PlateDocument", previous: Layout, new: Layout, name: str):
        super().__init__(name)
        self._document = document
        self._previous = previous
        self._new = new

    def redo(self) -> None:  # called by QUndoStack.push() as well — that installs the edit
        self._document._install(self._new)

    def undo(self) -> None:
        self._document._install(self._previous)


class PlateDocument(QObject):
    """A `.plate` file in memory."""

    #: The new layout, after it has been assigned. Emitted for edits, undo and redo alike.
    layout_changed = Signal(object)
    #: The path changed (Save As, first save of an untitled document).
    path_changed = Signal(object)
    #: True when the document matches what is on disk (QUndoStack clean state).
    clean_changed = Signal(bool)
    #: A save failed (autosave or explicit). Payload: (path, error message).
    save_failed = Signal(object, str)

    def __init__(self, layout: Layout | None = None, path: str | os.PathLike | None = None, parent=None):
        super().__init__(parent)
        self._layout = layout if layout is not None else Layout.starter()
        self._path: Path | None = Path(path) if path is not None else None
        self.undo_stack = QUndoStack(self)
        self.undo_stack.cleanChanged.connect(self.clean_changed)
        self.undo_stack.cleanChanged.connect(self._on_clean_changed)
        self._autosave_timer: QTimer | None = None
        self.autosave_enabled = True
        self._save_warned = False

    # ------------------------------------------------------------------ construction
    @classmethod
    def open(cls, path: str | os.PathLike, parent=None) -> "PlateDocument":
        """Reads a `.plate` file. Raises `LayoutDecodeError` (or OSError) exactly where the
        Mac app would refuse to open it."""
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        return cls(loads(text), path, parent)

    # ------------------------------------------------------------------ state
    @property
    def layout(self) -> Layout:
        return self._layout

    @property
    def path(self) -> Path | None:
        return self._path

    @path.setter
    def path(self, value: str | os.PathLike | None) -> None:
        new = Path(value) if value is not None else None
        if new != self._path:
            self._path = new
            self.path_changed.emit(new)

    @property
    def is_untitled(self) -> bool:
        return self._path is None

    @property
    def is_dirty(self) -> bool:
        return not self.undo_stack.isClean()

    @property
    def display_name(self) -> str:
        """The window title base: the file's stem, or "Untitled"."""
        return self._path.stem if self._path is not None else "Untitled"

    # ------------------------------------------------------------------ mutation
    def mutate(self, action_name: str, change: Callable[[Layout], Layout]) -> bool:
        """The single funnel for every edit. `change` receives the current layout and
        returns the new one; an unchanged layout is a no-op — no undo entry, no signal.
        Returns whether anything changed."""
        updated = change(self._layout)
        if updated is None or updated == self._layout:
            return False
        self.undo_stack.push(_LayoutCommand(self, self._layout, updated, action_name))
        return True

    def replace_layout(self, layout: Layout, action_name: str = "Replace Layout") -> bool:
        """`mutate` with a ready-made layout."""
        return self.mutate(action_name, lambda _current: layout)

    def _install(self, layout: Layout) -> None:
        # Assign first, then emit — there is no `willSet` trap to recreate here.
        self._layout = layout
        self.layout_changed.emit(layout)
        self.schedule_autosave()

    # ------------------------------------------------------------------ files
    def save(self, path: str | os.PathLike | None = None) -> bool:
        """Writes atomically (QSaveFile) to `path` or the document's own path. Marks the
        undo stack clean on success. Returns False (and emits `save_failed`) on error."""
        target = Path(path) if path is not None else self._path
        if target is None:
            return False
        text = dumps(self._layout)
        ok, error = _atomic_write(target, text)
        if not ok:
            self.save_failed.emit(target, error)
            return False
        self._save_warned = False
        if path is not None:
            self.path = target
        self.undo_stack.setClean()
        return True

    def save_now(self) -> bool:
        """Flush a pending autosave immediately (window deactivate, close, quit)."""
        if self._autosave_timer is not None:
            self._autosave_timer.stop()
        if self._path is None or not self.is_dirty:
            return True
        return self.save()

    def schedule_autosave(self) -> None:
        """Debounced save-in-place, like the Mac's autosave: only once the document has a
        path, ~2 s after the last change. Silently does nothing without an event loop."""
        if not self.autosave_enabled or self._path is None:
            return
        if QCoreApplication.instance() is None:
            return
        if self._autosave_timer is None:
            self._autosave_timer = QTimer(self)
            self._autosave_timer.setSingleShot(True)
            self._autosave_timer.timeout.connect(self._autosave)
        self._autosave_timer.start(AUTOSAVE_DELAY_MS)

    def _autosave(self) -> None:
        if self._path is not None and self.is_dirty:
            self.save()

    def revert_to_saved(self) -> bool:
        """Reloads the file from disk (mostly meaningless with autosave — kept for the
        rare failed-save case). Clears the undo stack."""
        if self._path is None:
            return False
        try:
            layout = loads(Path(self._path).read_text(encoding="utf-8"))
        except (OSError, LayoutDecodeError):
            return False
        self.undo_stack.clear()
        self._install(layout)
        self.undo_stack.setClean()
        return True

    def _on_clean_changed(self, clean: bool) -> None:
        pass  # placeholder for hooks (window title is driven straight from clean_changed)


def _atomic_write(target: Path, text: str) -> tuple[bool, str]:
    target.parent.mkdir(parents=True, exist_ok=True)
    f = QSaveFile(str(target))
    if not f.open(QSaveFile.OpenModeFlag.WriteOnly):
        return False, f.errorString()
    f.write(text.encode("utf-8"))
    if not f.commit():
        return False, f.errorString()
    return True, ""
