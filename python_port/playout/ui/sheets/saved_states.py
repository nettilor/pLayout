"""The saved-states list — mirrors `Sources/PLayout/Views/SavedStatesPopover.swift`
(PORT.md §A4). A popover under the toolbar button: the active plate's states newest first,
each with a bookmark that fills when the plate matches it, an editable name, the subtitle,
a revert button (closes the popover) and a delete button. Every action is one undo step."""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QFrame, QHBoxLayout, QLabel, QScrollArea, QSizePolicy, QToolButton, QVBoxLayout, QWidget,
)

from playout.editor.plate_editor import PlateEditor
from playout.ui import fonts
from playout.ui import icons
from playout.ui.controls import CommitLineEdit, key_name


class StateRow(QWidget):
    def __init__(self, popover: "SavedStatesPopover", state):
        super().__init__()
        self.popover = popover
        self.state = state
        ed = popover.editor
        current = state.id == ed.matching_saved_state_id
        lay = QHBoxLayout(self)
        lay.setContentsMargins(8, 4, 8, 4)
        lay.setSpacing(8)
        c = self.palette().color(self.palette().ColorRole.WindowText)
        self.bookmark = QLabel()
        self.bookmark.setPixmap(icons.glyph_icon("bookmark.fill" if current else "bookmark", c).pixmap(14, 14))
        self.bookmark.setToolTip("The plate matches this state right now" if current else "")
        lay.addWidget(self.bookmark)
        text = QVBoxLayout()
        text.setSpacing(1)
        self.name = CommitLineEdit(state.name, lambda t, sid=state.id: ed.rename_state(sid, t))
        self.name.setFrame(False)
        self.name.setPlaceholderText("Name")
        self.name.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        text.addWidget(self.name)
        self.subtitle = QLabel(ed.subtitle_for(state))
        self.subtitle.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.subtitle.setStyleSheet(fonts.secondary_css(self))
        f = self.subtitle.font()
        f.setPointSizeF(max(8.0, f.pointSizeF() - 2))
        self.subtitle.setFont(f)
        text.addWidget(self.subtitle)
        lay.addLayout(text, 1)
        self.revert = QToolButton()
        self.revert.setText("↶")
        self.revert.setAutoRaise(True)
        self.revert.setFixedSize(26, 24)
        self.revert.setEnabled(not current)
        self.revert.setToolTip("Already showing this state" if current else "Revert the plate to this state")
        self.revert.clicked.connect(lambda: popover.revert_to(state.id))
        lay.addWidget(self.revert)
        self.delete = QToolButton()
        self.delete.setText("✕")
        self.delete.setAutoRaise(True)
        self.delete.setFixedSize(26, 24)
        self.delete.setToolTip(f"Delete this state — {key_name('Ctrl+Z')} brings it back")
        self.delete.clicked.connect(lambda: ed.delete_state(state.id))
        lay.addWidget(self.delete)
        if current:
            self.setAutoFillBackground(True)
            pal = self.palette()
            tint = pal.color(pal.ColorRole.Highlight)
            tint.setAlphaF(0.10)
            pal.setColor(pal.ColorRole.Window, tint)
            self.setPalette(pal)


class SavedStatesPopover(QDialog):
    def __init__(self, editor: PlateEditor, parent: QWidget | None = None):
        super().__init__(parent, Qt.WindowType.Popup)
        self.editor = editor
        self.setFixedWidth(330)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(12, 12, 12, 12)
        head = QHBoxLayout()
        title = QLabel("Saved states")
        f = title.font()
        f.setBold(True)
        title.setFont(f)
        head.addWidget(title)
        self.plate_label = QLabel()
        self.plate_label.setStyleSheet(fonts.secondary_css(self))
        head.addWidget(self.plate_label)
        head.addStretch(1)
        hint = QLabel(f"{key_name('Ctrl+Alt+S')} saves · {key_name('Ctrl+Z')} undoes")
        hint.setStyleSheet(fonts.secondary_css(self))
        hf = hint.font()
        hf.setPointSizeF(max(8.0, hf.pointSizeF() - 2))
        hint.setFont(hf)
        head.addWidget(hint)
        outer.addLayout(head)
        self.empty_title = QLabel()
        self.empty_body = QLabel("States belong to one plate. Save one before trying a new combination, and you can always come back to it.")
        self.empty_body.setWordWrap(True)
        self.empty_body.setStyleSheet(fonts.secondary_css(self))
        outer.addWidget(self.empty_title)
        outer.addWidget(self.empty_body)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll.setMaximumHeight(260)
        self.list_widget = QWidget()
        self.list_layout = QVBoxLayout(self.list_widget)
        self.list_layout.setContentsMargins(0, 0, 0, 0)
        self.list_layout.setSpacing(2)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(self.list_widget)
        outer.addWidget(self.scroll)
        self.rows: list[StateRow] = []
        editor.layout_changed.connect(self.refresh)
        editor.state_changed.connect(self.refresh)
        self.refresh()

    def refresh(self, *_) -> None:
        ed = self.editor
        plate = ed.plate
        self.plate_label.setText(plate.name if plate else "")
        for r in self.rows:
            self.list_layout.removeWidget(r)
            r.deleteLater()
        self.rows = []
        states = ed.saved_states_newest_first
        empty = not states
        self.empty_title.setText(f"Nothing saved for {plate.name if plate else 'this plate'} yet.")
        self.empty_title.setVisible(empty)
        self.empty_body.setVisible(empty)
        self.scroll.setVisible(not empty)
        for state in states:
            row = StateRow(self, state)
            self.list_layout.insertWidget(self.list_layout.count() - 1, row)
            self.rows.append(row)
        self.adjustSize()

    def revert_to(self, state_id: str) -> None:
        self.editor.revert_to_state(state_id)
        self.close()
