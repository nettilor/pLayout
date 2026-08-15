"""Toolbar glyphs painted with QPainter — no icon files, no font dependency, and they
follow the palette (regenerated on a palette change). Rough equivalents of the SF
Symbols the Mac toolbar uses (PORT.md §A2)."""
from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QIcon, QPainter, QPainterPath, QPen, QPixmap

SIZE = 18


def _begin(color: QColor, dpr: float):
    pm = QPixmap(int(SIZE * dpr), int(SIZE * dpr))
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    pen = QPen(color, 1.5)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)
    return pm, p


MENU_WIDTH = SIZE  # menu icons stay square: the glyph shrinks a little to make room for a chevron


def glyph_icon(name: str, color: QColor, menu: bool = False) -> QIcon:
    """The glyph rendered once per device pixel ratio (1×, 2×, 3×) so Qt never scales a
    bitmap up or down — that scaling is what read as "grainy". `menu=True` appends a
    small chevron (the button then hides Qt's own, oversized menu arrow)."""
    icon = QIcon()
    for dpr in (1.0, 2.0, 3.0):
        icon.addPixmap(_glyph_pixmap(name, color, dpr, menu))
    return icon


def _glyph_pixmap(name: str, color: QColor, dpr: float, menu: bool = False) -> QPixmap:
    width = MENU_WIDTH if menu else SIZE
    pm = QPixmap(int(width * dpr), int(SIZE * dpr))
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    pen = QPen(color, 1.5)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)
    s = SIZE
    if name == "grid":
        pen2 = QPen(color, 1.7)
        pen2.setJoinStyle(Qt.PenJoinStyle.MiterJoin)
        p.setPen(pen2)
        for i in range(3):
            for j in range(3):
                p.drawRect(QRectF(1.8 + i * 5.2, 1.8 + j * 5.2, 4.0, 4.0))
    elif name in ("bookmark", "bookmark.fill"):
        path = QPainterPath()
        path.moveTo(4.5, 2.5)
        path.lineTo(13.5, 2.5)
        path.lineTo(13.5, 15.5)
        path.lineTo(9, 11.5)
        path.lineTo(4.5, 15.5)
        path.closeSubpath()
        if name.endswith("fill"):
            p.fillPath(path, color)
        p.drawPath(path)
    elif name == "clock.arrow":
        p.drawArc(QRectF(3, 3, 12, 12), 30 * 16, 300 * 16)
        p.drawLine(QPointF(9, 5.5), QPointF(9, 9))
        p.drawLine(QPointF(9, 9), QPointF(11.5, 10.5))
        head = QPainterPath()
        head.moveTo(15.2, 3.2)
        head.lineTo(15.4, 7.4)
        head.lineTo(11.4, 6.6)
        head.closeSubpath()
        p.fillPath(head, color)
    elif name == "trend":
        p.drawPolyline([QPointF(2.5, 4), QPointF(6, 8), QPointF(9.5, 6.5), QPointF(15.5, 14)])
        p.drawLine(QPointF(2.5, 15.5), QPointF(15.5, 15.5))
    elif name == "xy":
        f = QFont()
        f.setBold(True)
        f.setPointSizeF(9.5)
        p.setFont(f)
        p.drawText(QRectF(0, 0, s, s), Qt.AlignmentFlag.AlignCenter, "XY")
    elif name == "shuffle":
        p.drawLine(QPointF(2.5, 5), QPointF(6, 5))
        p.drawLine(QPointF(6, 5), QPointF(12, 13))
        p.drawLine(QPointF(12, 13), QPointF(15.5, 13))
        p.drawLine(QPointF(2.5, 13), QPointF(6, 13))
        p.drawLine(QPointF(6, 13), QPointF(12, 5))
        p.drawLine(QPointF(12, 5), QPointF(15.5, 5))
        for y in (5, 13):
            p.drawLine(QPointF(13.5, y - 2), QPointF(15.5, y))
            p.drawLine(QPointF(13.5, y + 2), QPointF(15.5, y))
    elif name == "share":
        p.drawRect(QRectF(3.5, 7.5, 11, 8))
        p.drawLine(QPointF(9, 2.5), QPointF(9, 11))
        p.drawLine(QPointF(6, 5.5), QPointF(9, 2.5))
        p.drawLine(QPointF(12, 5.5), QPointF(9, 2.5))
    elif name == "keyboard":
        p.drawRoundedRect(QRectF(2, 4.5, 14, 9), 1.5, 1.5)
        for x in (4.5, 7.5, 10.5, 13.5):
            p.drawPoint(QPointF(x, 7.5))
        p.drawLine(QPointF(5.5, 11), QPointF(12.5, 11))
    p.end()
    return pm
