"""WellPos / WellRange — mirrors `Sources/PLayout/Editor/WellRange.swift`. Pure Python."""
from __future__ import annotations

from dataclasses import dataclass

from playout.model.plate_format import PlateFormat


@dataclass(frozen=True, slots=True, order=True)
class WellPos:
    row: int
    col: int


@dataclass(frozen=True, slots=True)
class WellRange:
    """A rectangular block of wells, Excel-style: an anchor plus a moving focus corner."""

    anchor: WellPos
    focus: WellPos

    @classmethod
    def single(cls, pos: WellPos) -> "WellRange":
        return cls(pos, pos)

    @classmethod
    def at(cls, row: int, col: int) -> "WellRange":
        return cls.single(WellPos(row, col))

    @property
    def min_row(self) -> int:
        return min(self.anchor.row, self.focus.row)

    @property
    def max_row(self) -> int:
        return max(self.anchor.row, self.focus.row)

    @property
    def min_col(self) -> int:
        return min(self.anchor.col, self.focus.col)

    @property
    def max_col(self) -> int:
        return max(self.anchor.col, self.focus.col)

    @property
    def row_count(self) -> int:
        return self.max_row - self.min_row + 1

    @property
    def col_count(self) -> int:
        return self.max_col - self.min_col + 1

    @property
    def well_count(self) -> int:
        return self.row_count * self.col_count

    @property
    def is_single_well(self) -> bool:
        return self.well_count == 1

    def contains(self, row: int, col: int) -> bool:
        return self.min_row <= row <= self.max_row and self.min_col <= col <= self.max_col

    def contains_row(self, row: int) -> bool:
        return self.min_row <= row <= self.max_row

    def contains_col(self, col: int) -> bool:
        return self.min_col <= col <= self.max_col

    def indices(self, fmt: PlateFormat) -> list[int]:
        """Row-major well indices for a plate shape, clipped to the plate. A range that
        lies wholly outside still yields the clamped corner — never an empty list."""
        if fmt.rows <= 0 or fmt.cols <= 0:
            return []
        first_row = max(0, min(self.min_row, fmt.rows - 1))
        last_row = max(0, min(self.max_row, fmt.rows - 1))
        first_col = max(0, min(self.min_col, fmt.cols - 1))
        last_col = max(0, min(self.max_col, fmt.cols - 1))
        if first_row > last_row or first_col > last_col:
            return []
        return [fmt.index(r, c) for r in range(first_row, last_row + 1) for c in range(first_col, last_col + 1)]

    def positions(self, fmt: PlateFormat) -> list[WellPos]:
        r = self.clamped(fmt)
        return [WellPos(row, col) for row in range(r.min_row, r.max_row + 1) for col in range(r.min_col, r.max_col + 1)]

    def clamped(self, fmt: PlateFormat) -> "WellRange":
        """Clamps both corners independently into the plate."""
        return WellRange(
            WellPos(min(max(self.anchor.row, 0), fmt.rows - 1), min(max(self.anchor.col, 0), fmt.cols - 1)),
            WellPos(min(max(self.focus.row, 0), fmt.rows - 1), min(max(self.focus.col, 0), fmt.cols - 1)),
        )

    @staticmethod
    def whole_plate(fmt: PlateFormat) -> "WellRange":
        return WellRange(WellPos(0, 0), WellPos(fmt.rows - 1, fmt.cols - 1))

    @staticmethod
    def whole_row(row: int, fmt: PlateFormat) -> "WellRange":
        return WellRange(WellPos(row, 0), WellPos(row, fmt.cols - 1))

    @staticmethod
    def whole_column(col: int, fmt: PlateFormat) -> "WellRange":
        return WellRange(WellPos(0, col), WellPos(fmt.rows - 1, col))
