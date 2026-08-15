"""PNG / PDF / print of the plate — mirrors `pngData`, `pdfData` and `printPlate` in
`Sources/PLayout/Views/PlateCanvasView.swift` (PORT.md §D5).

All three draw the same `RenderScene` (export mode: light colours, white page, no
selection/hover/spotlight/notes/corner; the line key still drawn) through the one
`render_scene()`; only the paint device differs. The size is the canvas's *unmagnified*
size — what the user sees at fit, whatever the zoom.
"""
from __future__ import annotations

from PySide6.QtCore import QBuffer, QIODevice, QMarginsF, QSizeF, Qt
from PySide6.QtGui import QColor, QImage, QPageLayout, QPageSize, QPainter, QPdfWriter

from playout.editor.plate_editor import PlateEditor
from playout.ui.plate_geometry import Rect
from playout.ui.plate_renderer import Colors, RenderScene, render_scene


def export_scene(editor: PlateEditor) -> RenderScene | None:
    return RenderScene.from_editor(editor, Colors.light(), export_mode=True)


def render_png(editor: PlateEditor, width: float, height: float, device_pixel_ratio: float = 2.0) -> bytes | None:
    """The plate as it is shown, at the canvas's unmagnified size × the device pixel ratio."""
    scene = export_scene(editor)
    if scene is None or width < 4 or height < 4:
        return None
    dpr = max(1.0, float(device_pixel_ratio))
    img = QImage(int(round(width * dpr)), int(round(height * dpr)), QImage.Format.Format_ARGB32_Premultiplied)
    img.setDevicePixelRatio(dpr)
    img.fill(QColor(255, 255, 255))
    p = QPainter(img)
    render_scene(scene, p, Rect(0, 0, width, height))
    p.end()
    buf = QBuffer()
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    img.save(buf, "PNG")
    buf.close()
    return bytes(buf.data())


def write_pdf(editor: PlateEditor, path: str, width: float, height: float) -> bool:
    """A vector PDF whose page is exactly the plate's unmagnified size in points."""
    scene = export_scene(editor)
    if scene is None or width < 4 or height < 4:
        return False
    writer = QPdfWriter(path)
    writer.setResolution(72)
    writer.setPageSize(QPageSize(QSizeF(width, height), QPageSize.Unit.Point))
    writer.setPageMargins(QMarginsF(0, 0, 0, 0))
    writer.setTitle("Plate layout")
    p = QPainter(writer)
    if not p.isActive():
        return False
    render_scene(scene, p, Rect(0, 0, width, height))
    p.end()
    return True


def paint_for_print(editor: PlateEditor, printer, width: float, height: float, margin_pt: float = 24.0) -> bool:
    """Draw the plate onto a QPrinter page: landscape when wider than tall, scaled to fill
    one page inside `margin_pt` margins, centred."""
    from PySide6.QtPrintSupport import QPrinter  # local import: QtPrintSupport is optional at import time

    scene = export_scene(editor)
    if scene is None:
        return False
    layout = printer.pageLayout()
    layout.setOrientation(QPageLayout.Orientation.Landscape if width >= height else QPageLayout.Orientation.Portrait)
    layout.setUnits(QPageLayout.Unit.Point)
    layout.setMargins(QMarginsF(margin_pt, margin_pt, margin_pt, margin_pt))
    printer.setPageLayout(layout)
    p = QPainter(printer)
    if not p.isActive():
        return False
    page = printer.pageRect(QPrinter.Unit.DevicePixel)
    scale = min(page.width() / width, page.height() / height)
    p.translate(page.x() + (page.width() - width * scale) / 2, page.y() + (page.height() - height * scale) / 2)
    p.scale(scale, scale)
    render_scene(scene, p, Rect(0, 0, width, height))
    p.end()
    return True
