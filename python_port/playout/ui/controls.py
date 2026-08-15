"""Small widgets shared by the sidebar (mirrors `Sources/PLayout/Views/Controls.swift`):
the key cap, the click-to-select / second-click-to-rename name field, the commit-on-enter
line edit, and the colour swatch button."""
from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QIcon, QKeySequence, QPainter, QPixmap
from PySide6.QtWidgets import QLabel, QLineEdit, QSizePolicy, QStackedWidget, QToolButton, QWidget

from playout.ui import fonts


def key_name(sequence: str) -> str:
    """"Ctrl+1" → "⌘1" on a Mac, "Ctrl+1" elsewhere."""
    return QKeySequence(sequence).toString(QKeySequence.SequenceFormat.NativeText)


class KeyCap(QLabel):
    """The little rounded key on a sidebar row (⌘1 / 1 / ·)."""

    def __init__(self, text: str = "", parent: QWidget | None = None):
        super().__init__(text, parent)
        self._highlighted = False
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMinimumWidth(30)
        self.setFixedHeight(18)
        f = self.font()
        f.setPointSizeF(max(8.0, f.pointSizeF() - 2))
        self.setFont(f)
        self._restyle()

    def set_highlighted(self, on: bool) -> None:
        if on != self._highlighted:
            self._highlighted = on
            self._restyle()

    def _restyle(self) -> None:
        if self._highlighted:
            self.setStyleSheet("QLabel { background: palette(highlight); color: palette(highlighted-text); border-radius: 4px; padding: 0 4px; }")
        else:
            self.setStyleSheet("QLabel { background: palette(alternate-base); color: palette(text); border-radius: 4px; padding: 0 4px; }")


class _RenameEdit(QLineEdit):
    cancelled = Signal()

    def keyPressEvent(self, e) -> None:
        if e.key() == Qt.Key.Key_Escape:
            self.cancelled.emit()
            return
        super().keyPressEvent(e)


class EditableName(QStackedWidget):
    """A label that becomes a line edit on demand. Enter or focus-out commits (trimmed,
    blank/unchanged ignored); Escape abandons. `on_commit(text)` and `on_done()` are the
    hooks; the sidebar hands focus back to the canvas in `on_done`."""

    def __init__(self, text: str, on_commit: Callable[[str], None], on_done: Callable[[], None] | None = None,
                 parent: QWidget | None = None):
        super().__init__(parent)
        self.on_commit = on_commit
        self.on_done = on_done or (lambda: None)
        self.label = QLabel(text)
        self.label.setTextInteractionFlags(Qt.TextInteractionFlag.NoTextInteraction)
        self.edit = _RenameEdit()
        self.edit.setFrame(True)
        self.addWidget(self.label)
        self.addWidget(self.edit)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._committing = False
        self.edit.editingFinished.connect(self._commit)
        self.edit.cancelled.connect(self.cancel)

    @property
    def is_renaming(self) -> bool:
        return self.currentWidget() is self.edit

    def set_text(self, text: str) -> None:
        if not self.is_renaming:
            self.label.setText(text)

    def begin_rename(self) -> None:
        self.edit.setText(self.label.text())
        self.setCurrentWidget(self.edit)
        self.edit.selectAll()
        self.edit.setFocus(Qt.FocusReason.OtherFocusReason)

    def cancel(self) -> None:
        if not self.is_renaming:
            return
        self._committing = True
        self.setCurrentWidget(self.label)
        self._committing = False
        self.on_done()

    def _commit(self) -> None:
        if self._committing or not self.is_renaming:
            return
        self._committing = True
        text = self.edit.text().strip(" \t")
        self.setCurrentWidget(self.label)
        self._committing = False
        if text and text != self.label.text():
            self.label.setText(text)
            self.on_commit(text)
        self.on_done()


class CommitLineEdit(QLineEdit):
    """A field that reports its text on Enter/focus-out; blank is reported as "" (the
    factor unit uses it, where blank means "no unit")."""

    def __init__(self, text: str, on_commit: Callable[[str], None], parent: QWidget | None = None):
        super().__init__(text, parent)
        self.on_commit = on_commit
        self._last = text
        self.editingFinished.connect(self._commit)

    def _commit(self) -> None:
        text = self.text().strip(" \t")
        if text != self._last:
            self._last = text
            self.on_commit(text)


def swatch_icon(hex_text: str, size: int = 14) -> QIcon:
    pm = QPixmap(size * 2, size * 2)
    pm.setDevicePixelRatio(2.0)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    colour = fonts.qcolor(hex_text) or QColor(128, 128, 128)
    p.setBrush(colour)
    p.setPen(QColor(0, 0, 0, 60))
    p.drawEllipse(QRectF(0.5, 0.5, size - 1, size - 1))
    p.end()
    return QIcon(pm)


class SwatchButton(QToolButton):
    """The 14 pt colour circle on a condition row. M3: opens the system colour dialog;
    the colour grid popover (M6) replaces the click handler."""

    def __init__(self, hex_text: str, parent: QWidget | None = None):
        super().__init__(parent)
        self.hex_text = hex_text
        self.setAutoRaise(True)
        self.setIconSize(QSize(14, 14))
        self.setFixedSize(20, 20)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip("Change colour")
        self.set_hex(hex_text)

    def set_hex(self, hex_text: str) -> None:
        self.hex_text = hex_text
        self.setIcon(swatch_icon(hex_text))
