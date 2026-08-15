"""PlateGeometry (Qt-free): cell solve, rects, rotation mapping, hit-testing.

Mirrors `PlateGeometry` in `Sources/PLayout/Views/PlateCanvasView.swift`.

Owns *all* plate geometry including rotation. Everything above it works in model
coordinates (row, col as indexed in the file); `display_position` / `model_position` are
exact inverses and the only crossing point. Coordinates here are unmagnified: zoom is a
painter transform applied by the canvas, never part of the geometry.

`quarter_turns` is a **rotation**, not a transpose — A1 walks the corners clockwise. A
strip of headers names the *model* axis its cells belong to, wherever the turn has put it.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import NamedTuple

from playout.editor.well_range import WellPos, WellRange
from playout.model.plate_format import PlateFormat

MAX_CELL = 96.0
MIN_CELL = 0.01
PAD = 14.0
MIN_HEADER_W = 26.0
MIN_HEADER_H = 18.0


class Rect(NamedTuple):
    x: float
    y: float
    width: float
    height: float

    @property
    def max_x(self) -> float:
        return self.x + self.width

    @property
    def max_y(self) -> float:
        return self.y + self.height

    @property
    def mid_x(self) -> float:
        return self.x + self.width / 2

    @property
    def mid_y(self) -> float:
        return self.y + self.height / 2

    def contains(self, x: float, y: float) -> bool:
        return self.x <= x < self.max_x and self.y <= y < self.max_y

    def union(self, other: "Rect") -> "Rect":
        x0 = min(self.x, other.x)
        y0 = min(self.y, other.y)
        x1 = max(self.max_x, other.max_x)
        y1 = max(self.max_y, other.max_y)
        return Rect(x0, y0, x1 - x0, y1 - y0)

    def inset(self, dx: float, dy: float | None = None) -> "Rect":
        dy = dx if dy is None else dy
        return Rect(self.x + dx, self.y + dy, self.width - 2 * dx, self.height - 2 * dy)

    def intersects(self, other: "Rect") -> bool:
        return not (self.max_x <= other.x or other.max_x <= self.x or self.max_y <= other.y or other.max_y <= self.y)


class Hit:
    """Result of `PlateGeometry.hit`: which model thing a point lands on."""

    __slots__ = ("kind", "well", "index")

    WELL, COLUMN_HEADER, ROW_HEADER, CORNER, OUTSIDE = "well", "columnHeader", "rowHeader", "corner", "outside"

    def __init__(self, kind: str, well: WellPos | None = None, index: int | None = None):
        self.kind = kind
        self.well = well
        self.index = index

    def __eq__(self, other) -> bool:
        return isinstance(other, Hit) and (self.kind, self.well, self.index) == (other.kind, other.well, other.index)

    def __repr__(self) -> str:
        return f"Hit({self.kind}, well={self.well}, index={self.index})"

    @classmethod
    def well_at(cls, pos: WellPos) -> "Hit":
        return cls(cls.WELL, well=pos)

    @classmethod
    def column_header(cls, col: int) -> "Hit":
        return cls(cls.COLUMN_HEADER, index=col)

    @classmethod
    def row_header(cls, row: int) -> "Hit":
        return cls(cls.ROW_HEADER, index=row)

    @classmethod
    def corner(cls) -> "Hit":
        return cls(cls.CORNER)

    @classmethod
    def outside(cls) -> "Hit":
        return cls(cls.OUTSIDE)


def _header_width(cell: float) -> float:
    return max(MIN_HEADER_W, min(cell * 1.05, 54.0))


def _header_height(cell: float) -> float:
    return max(MIN_HEADER_H, min(cell * 0.8, 34.0))


@dataclass(frozen=True, slots=True)
class PlateGeometry:
    format: PlateFormat
    quarter_turns: int
    cell: float
    header_w: float
    header_h: float
    origin_x: float
    origin_y: float
    bounds: Rect

    # -------------------------------------------------------------- construction
    @classmethod
    def fit(cls, fmt: PlateFormat, bounds: Rect | tuple, quarter_turns: int = 0) -> "PlateGeometry":
        """Solve the cell size for a canvas of `bounds` (x, y, width, height). The headers
        grow with the cell, so this is solved, not computed: start from the most optimistic
        headers and only ever take `min`, which guarantees the result fits the bounds it was
        measured against. Never add a readability floor — an overflowing plate is invisible
        *and* unclickable."""
        b = Rect(*bounds)
        turns = ((quarter_turns % 4) + 4) % 4
        on_end = turns % 2 == 1
        grid_rows = fmt.cols if on_end else fmt.rows
        grid_cols = fmt.rows if on_end else fmt.cols
        avail_w = max(b.width - PAD * 2, 1.0)
        avail_h = max(b.height - PAD * 2, 1.0)

        def fits(hw: float, hh: float) -> float:
            return min((avail_w - hw) / grid_cols, (avail_h - hh) / grid_rows)

        size = min(MAX_CELL, fits(MIN_HEADER_W, MIN_HEADER_H))
        for _ in range(3):
            size = min(size, fits(_header_width(size), _header_height(size)))
        size = max(MIN_CELL, min(size, MAX_CELL))
        header_w = _header_width(size)
        header_h = _header_height(size)
        total_w = header_w + size * grid_cols
        total_h = header_h + size * grid_rows
        strip_on_right = turns in (1, 2)
        strip_at_bottom = turns in (2, 3)
        origin_x = b.x + PAD + max(0.0, (avail_w - total_w) / 2) + (0.0 if strip_on_right else header_w)
        origin_y = b.y + PAD + max(0.0, (avail_h - total_h) / 2) + (0.0 if strip_at_bottom else header_h)
        return cls(fmt, turns, size, header_w, header_h, origin_x, origin_y, b)

    # -------------------------------------------------------------- shape
    @property
    def is_turned_on_end(self) -> bool:
        return self.quarter_turns % 2 == 1

    @property
    def vertical_strip_on_right(self) -> bool:
        return self.quarter_turns in (1, 2)

    @property
    def horizontal_strip_at_bottom(self) -> bool:
        return self.quarter_turns in (2, 3)

    @property
    def display_rows(self) -> int:
        return self.format.cols if self.is_turned_on_end else self.format.rows

    @property
    def display_cols(self) -> int:
        return self.format.rows if self.is_turned_on_end else self.format.cols

    # -------------------------------------------------------------- rotation (the whole of it)
    def display_position(self, row: int, col: int) -> tuple[int, int]:
        """Where a *model* well is drawn, as (display_row, display_col). Clockwise: a model
        row becomes a display column counted from the right, a model column a display row."""
        t = self.quarter_turns
        rows, cols = self.format.rows, self.format.cols
        if t == 1:
            return (col, rows - 1 - row)
        if t == 2:
            return (rows - 1 - row, cols - 1 - col)
        if t == 3:
            return (cols - 1 - col, row)
        return (row, col)

    def model_position(self, display_row: int, display_col: int) -> WellPos:
        t = self.quarter_turns
        rows, cols = self.format.rows, self.format.cols
        if t == 1:
            return WellPos(rows - 1 - display_col, display_row)
        if t == 2:
            return WellPos(rows - 1 - display_row, cols - 1 - display_col)
        if t == 3:
            return WellPos(display_col, cols - 1 - display_row)
        return WellPos(display_row, display_col)

    # -------------------------------------------------------------- rects
    @property
    def grid_rect(self) -> Rect:
        return Rect(self.origin_x, self.origin_y, self.cell * self.display_cols, self.cell * self.display_rows)

    @property
    def frame_rect(self) -> Rect:
        return Rect(
            self.origin_x if self.vertical_strip_on_right else self.origin_x - self.header_w,
            self.origin_y if self.horizontal_strip_at_bottom else self.origin_y - self.header_h,
            self.header_w + self.cell * self.display_cols,
            self.header_h + self.cell * self.display_rows,
        )

    def cell_rect(self, row: int, col: int) -> Rect:
        drow, dcol = self.display_position(row, col)
        return Rect(self.origin_x + dcol * self.cell, self.origin_y + drow * self.cell, self.cell, self.cell)

    def rect_of(self, rng: WellRange) -> Rect:
        return self.cell_rect(rng.min_row, rng.min_col).union(self.cell_rect(rng.max_row, rng.max_col))

    @property
    def _horizontal_strip_y(self) -> float:
        return self.origin_y + self.cell * self.display_rows if self.horizontal_strip_at_bottom else self.origin_y - self.header_h

    @property
    def _vertical_strip_x(self) -> float:
        return self.origin_x + self.cell * self.display_cols if self.vertical_strip_on_right else self.origin_x - self.header_w

    def horizontal_header_rect(self, display_index: int) -> Rect:
        return Rect(self.origin_x + display_index * self.cell, self._horizontal_strip_y, self.cell, self.header_h)

    def vertical_header_rect(self, display_index: int) -> Rect:
        return Rect(self._vertical_strip_x, self.origin_y + display_index * self.cell, self.header_w, self.cell)

    def column_header_rect(self, col: int) -> Rect:
        """Model-indexed: the header cell for model column `col`, wherever the turn put it."""
        drow, dcol = self.display_position(0, col)
        return self.vertical_header_rect(drow) if self.is_turned_on_end else self.horizontal_header_rect(dcol)

    def row_header_rect(self, row: int) -> Rect:
        drow, dcol = self.display_position(row, 0)
        return self.horizontal_header_rect(dcol) if self.is_turned_on_end else self.vertical_header_rect(drow)

    @property
    def corner_rect(self) -> Rect:
        return Rect(self._vertical_strip_x, self._horizontal_strip_y, self.header_w, self.header_h)

    # -------------------------------------------------------------- hit-testing
    def _line(self, offset: float, origin: float) -> int:
        if self.cell <= 0 or not math.isfinite(offset) or not math.isfinite(origin):
            return 0
        raw = math.floor((offset - origin) / self.cell)
        if not math.isfinite(raw):
            return 0
        return int(min(max(raw, -1_000_000), 1_000_000))

    def hit(self, x: float, y: float) -> Hit:
        """Always answers in model space; a strip names the model axis its cells belong to."""
        across = self._line(x, self.origin_x)
        down = self._line(y, self.origin_y)
        on_grid_x = 0 <= across < self.display_cols
        on_grid_y = 0 <= down < self.display_rows
        if on_grid_x and on_grid_y:
            return Hit.well_at(self.model_position(down, across))
        hy = self._horizontal_strip_y
        if on_grid_x and hy <= y < hy + self.header_h:
            well = self.model_position(0, across)
            return Hit.row_header(well.row) if self.is_turned_on_end else Hit.column_header(well.col)
        vx = self._vertical_strip_x
        if on_grid_y and vx <= x < vx + self.header_w:
            well = self.model_position(down, 0)
            return Hit.column_header(well.col) if self.is_turned_on_end else Hit.row_header(well.row)
        if self.corner_rect.contains(x, y):
            return Hit.corner()
        return Hit.outside()

    def nearest_well(self, x: float, y: float) -> WellPos:
        """Clamps in *display* space first, so a drag running off the right edge keeps
        extending along whichever model axis that edge belongs to."""
        across = min(max(self._line(x, self.origin_x), 0), self.display_cols - 1)
        down = min(max(self._line(y, self.origin_y), 0), self.display_rows - 1)
        return self.model_position(down, across)

    def nearest_column(self, x: float, y: float) -> int:
        return self.nearest_well(x, y).col

    def nearest_row(self, x: float, y: float) -> int:
        return self.nearest_well(x, y).row
