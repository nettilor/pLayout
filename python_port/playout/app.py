"""Application entry point — mirrors `Sources/PLayout/App.swift` and the DocumentGroup
plumbing: one window per document, recent files, files opened from the command line or
the Finder/Explorer, and the shared stores every window uses.

`App` takes every store injected so tests never touch the real user settings.
"""
from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path

from PySide6.QtCore import QCoreApplication, QEvent, QObject, QSettings
from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox

from playout.model.layout import Layout, LayoutDecodeError
from playout.model.preferences import Preferences, default_settings
from playout.model.templates import LayoutTemplateStore, PlateTemplateStore

RECENT_KEY = "recentFiles"
RECENT_CAP = 10


def resource_path(name: str) -> Path:
    """A file under `playout/resources`, both from source and inside a PyInstaller bundle
    (where the package is unpacked next to the executable / in `sys._MEIPASS`)."""
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidate = Path(base) / "playout" / "resources" / name
        if candidate.exists():
            return candidate
    return Path(__file__).parent / "resources" / name


def crash_log_path() -> Path:
    from PySide6.QtCore import QStandardPaths

    folder = Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation) or Path.home())
    folder.mkdir(parents=True, exist_ok=True)
    return folder / "pLayout-crash.log"


def _install_excepthook() -> None:
    """A windowed build has no console, so an uncaught error goes to a log file next to
    the settings and into a dialog — never silently into the void."""

    def hook(exc_type, exc, tb):
        text = "".join(traceback.format_exception(exc_type, exc, tb))
        sys.stderr.write(text)
        where = ""
        try:
            path = crash_log_path()
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(text + "\n")
            where = f"\n\nLogged to {path}"
        except Exception:  # pragma: no cover - the log is best effort
            pass
        try:
            if QApplication.instance() is not None:
                QMessageBox.critical(None, "pLayout — unexpected error", text[-3000:] + where)
        except Exception:  # pragma: no cover - last resort
            pass

    sys.excepthook = hook


def make_application(argv: list[str] | None = None) -> QApplication:
    """Create the QApplication with the names every QSettings/QStandardPaths call relies on."""
    app = QApplication.instance()
    if app is None:
        app = QApplication(argv if argv is not None else sys.argv)
    QCoreApplication.setOrganizationName("nettilor")
    QCoreApplication.setApplicationName("pLayout")
    QApplication.setApplicationDisplayName("pLayout")
    app.setStyleSheet(APP_STYLE)
    icon_file = resource_path("icon.png")
    if icon_file.exists():
        from PySide6.QtGui import QIcon

        app.setWindowIcon(QIcon(str(icon_file)))
    if sys.platform == "win32":
        # Group the taskbar button under our own identity rather than "python".
        try:
            import ctypes

            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("nettilor.pLayout")
        except Exception:  # pragma: no cover
            pass
    return app


#: A light touch on top of the platform style: rounded, compact tool buttons and the
#: segmented controls the Mac app uses everywhere. Colours come from the palette so the
#: sheet works in light and dark mode alike.
APP_STYLE = """
QToolButton { border: 1px solid transparent; border-radius: 6px; padding: 3px; }
QToolButton:hover { background: palette(midlight); }
QToolButton:pressed { background: palette(mid); }
QToolButton[segmented="true"] {
    border: 1px solid palette(mid); border-radius: 0; padding: 3px 10px; background: palette(base);
}
QToolButton[segmented="true"][first="true"] { border-top-left-radius: 6px; border-bottom-left-radius: 6px; }
QToolButton[segmented="true"][last="true"] { border-top-right-radius: 6px; border-bottom-right-radius: 6px; }
QToolButton[segmented="true"]:checked { background: palette(highlight); color: palette(highlighted-text); }
QToolButton[segmented="true"]:!first { margin-left: -1px; }
QToolButton[flat="true"] { border: none; }
"""


class App(QObject):
    """The document controller: windows, stores, recent files."""

    def __init__(self, preferences: Preferences | None = None, template_store: PlateTemplateStore | None = None,
                 layout_templates: LayoutTemplateStore | None = None, settings: QSettings | None = None,
                 parent: QObject | None = None):
        super().__init__(parent)
        self.settings = settings if settings is not None else default_settings()
        self.preferences = preferences if preferences is not None else Preferences.shared()
        self.template_store = template_store if template_store is not None else PlateTemplateStore(self.settings)
        self.layout_templates = layout_templates if layout_templates is not None else LayoutTemplateStore()
        self.windows: list = []
        qapp = QApplication.instance()
        if qapp is not None:
            qapp.installEventFilter(self)
            qapp.aboutToQuit.connect(self.save_all_now)

    # ------------------------------------------------------------------ windows
    def new_document(self, layout: Layout | None = None, path=None, show: bool = True):
        from playout.editor.document import PlateDocument
        from playout.ui.main_window import DocumentWindow

        document = PlateDocument(layout, path)
        window = DocumentWindow(document, self)
        self.windows.append(window)
        if show:
            window.show()
            window.raise_()
            window.activateWindow()
        return window

    def open_path(self, path, show: bool = True):
        """Open a `.plate` file in a new window; a lone untitled, clean window is replaced."""
        from playout.editor.document import PlateDocument
        from playout.ui.main_window import DocumentWindow

        path = Path(path)
        for w in self.windows:
            if w.document.path is not None and Path(w.document.path) == path:
                w.raise_()
                w.activateWindow()
                return w
        try:
            document = PlateDocument.open(path)
        except (OSError, LayoutDecodeError, UnicodeDecodeError) as exc:
            QMessageBox.warning(self.front_window(), "Could not open", f"{path}\n\n{exc}")
            return None
        window = DocumentWindow(document, self)
        self.windows.append(window)
        self.remember_recent(path)
        front = self.front_window(exclude=window)
        if show:
            window.show()
            window.raise_()
            window.activateWindow()
        if front is not None and front.document.is_untitled and not front.document.is_dirty and len(self.windows) == 2:
            front.close()
        return window

    def open_dialog(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self.front_window(), "Open", "", "Plate layout (*.plate)")
        if path:
            self.open_path(path)

    def front_window(self, exclude=None):
        active = QApplication.activeWindow()
        for w in self.windows:
            if w is active and w is not exclude:
                return w
        for w in self.windows:
            if w is not exclude:
                return w
        return None

    def window_closed(self, window) -> None:
        if window in self.windows:
            self.windows.remove(window)

    def save_all_now(self) -> None:
        for w in list(self.windows):
            w.document.save_now()

    def show_preferences(self) -> None:
        """One Settings window for the app, like the Mac's `Settings` scene."""
        from playout.ui.sheets.preferences_dialog import PreferencesDialog

        dlg = getattr(self, "_preferences_dialog", None)
        if dlg is None:
            dlg = PreferencesDialog(self.preferences)
            self._preferences_dialog = dlg
        dlg.show()
        dlg.raise_()
        dlg.activateWindow()

    # ------------------------------------------------------------------ recent files
    def recent_paths(self) -> list[str]:
        raw = self.settings.value(RECENT_KEY, "[]")
        try:
            paths = json.loads(raw) if isinstance(raw, str) else list(raw or [])
        except (TypeError, ValueError):
            paths = []
        return [p for p in paths if isinstance(p, str)]

    def remember_recent(self, path) -> None:
        p = str(path)
        paths = [x for x in self.recent_paths() if x != p]
        paths.insert(0, p)
        self.settings.setValue(RECENT_KEY, json.dumps(paths[:RECENT_CAP]))
        self.settings.sync()

    def clear_recent(self) -> None:
        self.settings.setValue(RECENT_KEY, "[]")
        self.settings.sync()

    # ------------------------------------------------------------------ platform
    def eventFilter(self, obj, e) -> bool:
        if e.type() == QEvent.Type.FileOpen:  # macOS: double-clicked file / "Open With"
            path = e.file()
            if path and path.lower().endswith(".plate"):
                self.open_path(path)
            return True
        return super().eventFilter(obj, e)


def main(argv: list[str] | None = None) -> int:
    """Run the app. Files given on the command line are opened, one window each."""
    _install_excepthook()
    args = list(sys.argv[1:] if argv is None else argv[1:])
    qapp = make_application(argv)
    qapp.setQuitOnLastWindowClosed(True)
    app = App()
    opened = 0
    for a in args:
        if a.startswith("-"):
            continue
        if app.open_path(a) is not None:
            opened += 1
    if opened == 0:
        app.new_document()
    return qapp.exec()
