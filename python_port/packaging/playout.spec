# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for pLayout (Windows and, for a smoke test, macOS).
#
#   pyinstaller packaging/playout.spec        (run from python_port/)
#
# One-directory build (faster start-up and fewer antivirus false positives than one-file),
# windowed (no console), our own icon, only the Qt modules the app imports.

import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files

ROOT = Path(SPECPATH).parent            # python_port/
ICON = ROOT / "playout" / "resources" / ("icon.ico" if sys.platform == "win32" else "icon.png")

datas = [(str(ROOT / "playout" / "resources"), "playout/resources")]

a = Analysis(
    [str(ROOT / "packaging" / "launcher.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=[
        "PySide6.QtPrintSupport",
        "openpyxl",
        "openpyxl.cell._writer",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # PySide6-Essentials has none of these, but a full PySide6 install would drag them in.
        "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets", "PySide6.QtWebEngineQuick",
        "PySide6.QtQml", "PySide6.QtQuick", "PySide6.QtQuick3D", "PySide6.QtMultimedia",
        "PySide6.QtBluetooth", "PySide6.QtNfc", "PySide6.QtSensors", "PySide6.QtSerialPort",
        "PySide6.QtCharts", "PySide6.QtDataVisualization", "PySide6.Qt3DCore", "PySide6.Qt3DRender",
        "PySide6.QtRemoteObjects", "PySide6.QtLocation", "PySide6.QtPositioning", "PySide6.QtWebSockets",
        "PySide6.QtWebChannel", "PySide6.QtPdf", "PySide6.QtPdfWidgets", "PySide6.QtHttpServer",
        "PySide6.QtTest", "PySide6.QtDesigner", "PySide6.QtHelp", "PySide6.QtUiTools",
        "tkinter", "unittest", "pydoc",
    ],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="pLayout",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=str(ICON) if ICON.exists() else None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="pLayout",
)
if sys.platform == "darwin":
    app = BUNDLE(coll, name="pLayout.app", icon=None, bundle_identifier="com.nettilor.playout.py")
