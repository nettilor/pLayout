"""Settings — mirrors `Sources/PLayout/Views/PreferencesView.swift` (PORT.md §A5): three
tabs (Display / Colours / Plate Text), a live preview of five sample wells beneath the tabs
(every tab changes something it shows), and Restore Defaults. Preferences are app-local
(QSettings) and reach every open canvas through `Preferences.changed`."""
from __future__ import annotations

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QFontDatabase, QPainter, QPainterPath
from PySide6.QtWidgets import (
    QButtonGroup, QCheckBox, QColorDialog, QComboBox, QDialog, QFrame, QGroupBox, QHBoxLayout, QLabel,
    QPushButton, QRadioButton, QScrollArea, QSlider, QTabWidget, QVBoxLayout, QWidget,
)

from playout.model import palette
from playout.model.preferences import (
    FONT_SCALE_RANGE, ActiveMarkerStyle, NewConditionColors, Preferences, WellShape, WellTextStyle,
)
from playout.ui import fonts

SAMPLES = (("#F1CE63", "Vehicle"), ("#8CD17D", "Low"), ("#F28E2B", "Mid"), ("#5889BC", "High"))


class WellPreview(QWidget):
    """Five sample wells drawn marker-then-label the way the canvas does; the fifth is
    Overview's neutral tile."""

    def __init__(self, prefs: Preferences, parent: QWidget | None = None):
        super().__init__(parent)
        self.prefs = prefs
        self.setFixedHeight(34)
        prefs.changed.connect(self.update)

    def paintEvent(self, e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        prefs = self.prefs
        style = prefs.well_text_style
        marker_style = prefs.active_marker_style
        n = len(SAMPLES) + 1
        gap = 6
        w = (self.width() - gap * (n - 1)) / n
        font = fonts.canvas_font(prefs, 11 * prefs.canvas_font_scale, "medium")
        p.setFont(font)
        custom = prefs.empty_well_color_hex
        for i in range(n):
            x = i * (w + gap)
            rect = QRectF(x, 2, w, self.height() - 4)
            path = QPainterPath()
            path.addRoundedRect(rect, 5, 5)
            if i < len(SAMPLES):
                hex_text, name = SAMPLES[i]
                fill = fonts.qcolor(hex_text)
                ink = fonts.label_ink(hex_text, style)
                marker = fonts.qcolor(palette.contrasting_shade(hex_text)) if marker_style is ActiveMarkerStyle.deeperShade else QColor(ink)
            else:
                name = "Overview"
                if custom:
                    fill = fonts.qcolor(custom)
                    ink = fonts.label_ink(custom, style)
                elif style is WellTextStyle.alwaysWhite:
                    fill = QColor.fromRgbF(0.32, 0.32, 0.32)
                    ink = QColor(fonts.WHITE)
                else:
                    label = self.palette().color(self.palette().ColorRole.WindowText)
                    fill = fonts.with_alpha(label, 0.18)
                    ink = QColor(fonts.BLACK85) if style is WellTextStyle.alwaysBlack else label
                marker = None
            p.fillPath(path, fill)
            if marker is not None:
                cap = QPainterPath()
                cap.addRoundedRect(QRectF(x + 5, rect.center().y() - 6.5, 6, 13), 3, 3)
                p.fillPath(cap, marker)
            p.setPen(ink)
            m = fonts.font_metrics(font)
            text = m.elidedText(name, Qt.TextElideMode.ElideRight, int(w - 20))
            p.drawText(QRectF(x + 15, rect.top(), w - 18, rect.height()), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, text)
        p.end()


class _Choice(QWidget):
    """A titled radio group bound to an enum preference."""

    def __init__(self, title: str, enum_cls, get, set_, parent=None):
        super().__init__(parent)
        self.enum_cls = enum_cls
        self.get = get
        self.set_ = set_
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(2)
        head = QLabel(title)
        head.setStyleSheet(fonts.secondary_css(self))
        lay.addWidget(head)
        self.group = QButtonGroup(self)
        self.buttons = {}
        for i, member in enumerate(enum_cls):
            b = QRadioButton(member.label)
            self.group.addButton(b, i)
            self.buttons[member] = b
            lay.addWidget(b)
        self.note = QLabel()
        self.note.setWordWrap(True)
        self.note.setStyleSheet(fonts.secondary_css(self))
        lay.addWidget(self.note)
        self.group.idClicked.connect(lambda i: set_(list(enum_cls)[i]))
        self.refresh()

    def refresh(self) -> None:
        current = self.get()
        for member, b in self.buttons.items():
            b.blockSignals(True)
            b.setChecked(member is current)
            b.blockSignals(False)
        self.note.setText(current.note)


def _section(title: str, *widgets) -> QGroupBox:
    box = QGroupBox(title)
    lay = QVBoxLayout(box)
    lay.setSpacing(4)
    for w in widgets:
        lay.addWidget(w)
    return box


def _scrolling(page: QWidget) -> QScrollArea:
    """Every tab scrolls rather than clipping — the notes are full sentences."""
    area = QScrollArea()
    area.setWidgetResizable(True)
    area.setFrameShape(QFrame.Shape.NoFrame)
    area.setWidget(page)
    return area


class PreferencesDialog(QDialog):
    def __init__(self, prefs: Preferences, parent: QWidget | None = None):
        super().__init__(parent)
        self.prefs = prefs
        self.setWindowTitle("Settings")
        self.setMinimumWidth(480)
        self.resize(480, 720)
        outer = QVBoxLayout(self)
        self.tabs = QTabWidget()
        outer.addWidget(self.tabs, 1)

        # ---- Display ----
        display = QWidget()
        dl = QVBoxLayout(display)
        self.text_choice = _Choice("Text colour", WellTextStyle, lambda: prefs.well_text_style, lambda v: setattr(prefs, "well_text_style", v))
        self.marker_choice = _Choice("Active marker", ActiveMarkerStyle, lambda: prefs.active_marker_style, lambda v: setattr(prefs, "active_marker_style", v))
        self.shape_choice = _Choice("Well shape", WellShape, lambda: prefs.new_document_well_shape, lambda v: setattr(prefs, "new_document_well_shape", v))
        self.counts_box = QCheckBox("Show each factor's number of conditions")
        self.counts_box.toggled.connect(lambda on: setattr(prefs, "show_factor_condition_counts", on))
        counts_note = QLabel("A count at the end of every factor row, the way conditions show how many wells they cover.")
        counts_note.setWordWrap(True)
        counts_note.setStyleSheet(fonts.secondary_css(self))
        dl.addWidget(_section("Well labels", self.text_choice))
        dl.addWidget(_section("Factor being painted", self.marker_choice))
        dl.addWidget(_section("New documents", self.shape_choice))
        dl.addWidget(_section("Sidebar", self.counts_box, counts_note))
        dl.addStretch(1)
        self.tabs.addTab(_scrolling(display), "Display")

        # ---- Colours ----
        colours = QWidget()
        cl = QVBoxLayout(colours)
        self.new_colours_choice = _Choice("Colours", NewConditionColors, lambda: prefs.new_condition_colors, lambda v: setattr(prefs, "new_condition_colors", v))
        empty_row = QWidget()
        er = QHBoxLayout(empty_row)
        er.setContentsMargins(0, 0, 0, 0)
        self.empty_button = QPushButton()
        self.empty_button.setFixedSize(44, 24)
        self.empty_button.clicked.connect(self._pick_empty)
        er.addWidget(self.empty_button)
        cap = QLabel("Background of wells with no value")
        cap.setStyleSheet(fonts.secondary_css(self))
        er.addWidget(cap)
        er.addStretch(1)
        self.reset_empty = QPushButton("Reset to Default")
        self.reset_empty.clicked.connect(lambda: setattr(prefs, "empty_well_color_hex", None))
        er.addWidget(self.reset_empty)
        self.empty_note = QLabel()
        self.empty_note.setWordWrap(True)
        self.empty_note.setStyleSheet(fonts.secondary_css(self))
        cl.addWidget(_section("New conditions", self.new_colours_choice))
        cl.addWidget(_section("Empty wells", empty_row, self.empty_note))
        cl.addStretch(1)
        self.tabs.addTab(_scrolling(colours), "Colours")

        # ---- Plate Text ----
        text = QWidget()
        tl = QVBoxLayout(text)
        font_row = QWidget()
        fr = QHBoxLayout(font_row)
        fr.setContentsMargins(0, 0, 0, 0)
        fr.addWidget(QLabel("Font"))
        self.font_box = QComboBox()
        self.font_box.addItem("System", None)
        self.font_box.insertSeparator(1)
        for family in sorted(f for f in QFontDatabase.families() if not f.startswith((".", "@"))):
            self.font_box.addItem(family, family)
        self.font_box.currentIndexChanged.connect(lambda _: setattr(prefs, "canvas_font_family", self.font_box.currentData()))
        fr.addWidget(self.font_box, 1)
        size_row = QWidget()
        sr = QHBoxLayout(size_row)
        sr.setContentsMargins(0, 0, 0, 0)
        sr.addWidget(QLabel("Size"))
        self.size_slider = QSlider(Qt.Orientation.Horizontal)
        lo, hi = FONT_SCALE_RANGE
        self.size_slider.setRange(int(round(lo * 100)), int(round(hi * 100)))
        self.size_slider.setSingleStep(5)
        self.size_slider.setPageStep(5)
        self.size_slider.valueChanged.connect(self._slider_changed)
        sr.addWidget(self.size_slider, 1)
        self.size_label = QLabel()
        self.size_label.setFixedWidth(44)
        self.size_label.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        sr.addWidget(self.size_label)
        text_note = QLabel("Applies to the plate — wells, headers and the line key — and travels into exports and print. The window's own controls keep the system font.")
        text_note.setWordWrap(True)
        text_note.setStyleSheet(fonts.secondary_css(self))
        tl.addWidget(_section("Plate text", font_row, size_row, text_note))
        tl.addStretch(1)
        self.tabs.addTab(_scrolling(text), "Plate Text")

        # ---- preview + footer ----
        self.preview = WellPreview(prefs)
        outer.addWidget(_section("Preview", self.preview))
        footer = QHBoxLayout()
        self.restore = QPushButton("Restore Defaults")
        self.restore.clicked.connect(prefs.reset_to_defaults)
        footer.addWidget(self.restore)
        footer.addStretch(1)
        close = QPushButton("Close")
        close.setDefault(True)
        close.clicked.connect(self.accept)
        footer.addWidget(close)
        outer.addLayout(footer)

        prefs.changed.connect(self.refresh)
        self.refresh()

    # ------------------------------------------------------------------ sync
    def _slider_changed(self, value: int) -> None:
        scale = round(value / 100.0 / 0.05) * 0.05
        if abs(self.prefs.canvas_font_scale - scale) > 1e-9:
            self.prefs.canvas_font_scale = scale

    def _pick_empty(self) -> None:
        current = fonts.qcolor(self.prefs.empty_well_color_hex) or QColor(222, 222, 222)
        colour = QColorDialog.getColor(current, self, "Empty wells")
        if colour.isValid():
            self.prefs.empty_well_color_hex = colour.name(QColor.NameFormat.HexRgb).upper()

    def refresh(self) -> None:
        prefs = self.prefs
        for c in (self.text_choice, self.marker_choice, self.shape_choice, self.new_colours_choice):
            c.refresh()
        self.counts_box.blockSignals(True)
        self.counts_box.setChecked(prefs.show_factor_condition_counts)
        self.counts_box.blockSignals(False)
        custom = prefs.empty_well_color_hex
        self.reset_empty.setEnabled(custom is not None)
        swatch = custom or "#DEDEDE"
        self.empty_button.setStyleSheet(f"background: {swatch}; border: 1px solid palette(mid); border-radius: 4px;")
        self.empty_note.setText(
            "The default follows light and dark mode." if custom is None
            else "A chosen colour is used as it is, everywhere — light mode, dark mode, Overview's backdrop, exports and print."
        )
        family = prefs.canvas_font_family
        idx = self.font_box.findData(family) if family else 0
        self.font_box.blockSignals(True)
        self.font_box.setCurrentIndex(idx if idx >= 0 else 0)
        self.font_box.blockSignals(False)
        self.size_slider.blockSignals(True)
        self.size_slider.setValue(int(round(prefs.canvas_font_scale * 100)))
        self.size_slider.blockSignals(False)
        self.size_label.setText(f"{int(round(prefs.canvas_font_scale * 100))} %")
        self.preview.update()
