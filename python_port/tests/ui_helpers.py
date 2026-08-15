"""Helpers for the widget tests: editors on temp settings, an App on temp settings, and
synthetic mouse events (7-arg QMouseEvent + sendEvent — QTest.mouseMove does not reliably
carry the pressed buttons)."""
from __future__ import annotations

from PySide6.QtCore import QEvent, QPointF, QSettings, Qt
from PySide6.QtGui import QMouseEvent
from PySide6.QtWidgets import QApplication

from playout.editor.document import PlateDocument
from playout.editor.plate_editor import PlateEditor
from playout.model.preferences import Preferences
from playout.model.templates import LayoutTemplateStore, PlateTemplateStore


def temp_settings(tmp_path) -> QSettings:
    return QSettings(str(tmp_path / "prefs.ini"), QSettings.Format.IniFormat)


def make_editor(tmp_path, layout=None):
    settings = temp_settings(tmp_path)
    return PlateEditor(PlateDocument(layout), Preferences(settings), PlateTemplateStore(settings))


def make_app(tmp_path):
    from playout.app import App

    settings = temp_settings(tmp_path)
    return App(
        preferences=Preferences(settings),
        template_store=PlateTemplateStore(settings),
        layout_templates=LayoutTemplateStore(tmp_path / "Templates"),
        settings=settings,
    )


NO_MOD = Qt.KeyboardModifier.NoModifier
CTRL = Qt.KeyboardModifier.ControlModifier
SHIFT = Qt.KeyboardModifier.ShiftModifier
ALT = Qt.KeyboardModifier.AltModifier


def mouse_event(widget, kind, pos, button=Qt.MouseButton.LeftButton, buttons=None, mods=NO_MOD):
    p = QPointF(*pos) if isinstance(pos, tuple) else QPointF(pos)
    if buttons is None:
        buttons = button if kind != QEvent.Type.MouseButtonRelease else Qt.MouseButton.NoButton
        if kind == QEvent.Type.MouseMove and button == Qt.MouseButton.NoButton:
            buttons = Qt.MouseButton.NoButton
    ev = QMouseEvent(kind, p, p, QPointF(widget.mapToGlobal(p.toPoint())), button, buttons, mods)
    QApplication.sendEvent(widget, ev)
    return ev


def press(widget, pos, mods=NO_MOD):
    mouse_event(widget, QEvent.Type.MouseButtonPress, pos, mods=mods)


def move(widget, pos, mods=NO_MOD, pressed=True):
    mouse_event(widget, QEvent.Type.MouseMove, pos, button=Qt.MouseButton.NoButton,
                buttons=Qt.MouseButton.LeftButton if pressed else Qt.MouseButton.NoButton, mods=mods)


def release(widget, pos, mods=NO_MOD):
    mouse_event(widget, QEvent.Type.MouseButtonRelease, pos, mods=mods)


def click(widget, pos, mods=NO_MOD):
    press(widget, pos, mods)
    release(widget, pos, mods)


def drag(widget, p0, p1, mods=NO_MOD, via=()):
    """A realistic drag: press, a first move still inside the pressed spot (as every real
    drag reports), the waypoints, the end point, release."""
    press(widget, p0, mods)
    move(widget, (p0[0] + 1, p0[1] + 1), mods)
    for p in via:
        move(widget, p, mods)
    move(widget, p1, mods)
    release(widget, p1, mods)


def hover(widget, pos):
    move(widget, pos, pressed=False)


# ---- canvas geometry helpers (positions in canvas widget coordinates, unmagnified) ----


def cell_centre(canvas, row, col):
    r = canvas.plate_geometry().cell_rect(row, col)
    z = canvas.zoom
    return (r.mid_x * z, r.mid_y * z)


def column_header_centre(canvas, col):
    r = canvas.plate_geometry().column_header_rect(col)
    z = canvas.zoom
    return (r.mid_x * z, r.mid_y * z)


def row_header_centre(canvas, row):
    r = canvas.plate_geometry().row_header_rect(row)
    z = canvas.zoom
    return (r.mid_x * z, r.mid_y * z)


def corner_centre(canvas):
    r = canvas.plate_geometry().corner_rect
    z = canvas.zoom
    return (r.mid_x * z, r.mid_y * z)


def outside_point(canvas):
    return (2.0, 2.0)
