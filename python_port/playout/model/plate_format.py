"""PlateFormat and WellNaming — mirrors `Sources/PLayout/Model/PlateFormat.swift`.

Pure Python, no Qt. A `PlateFormat` is pure geometry (rows × cols); custom *names* live on
plate templates (`templates.py`), because every "did the format change" guard compares
dimensions alone.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

ROW_RANGE = (1, 64)
COLUMN_RANGE = (1, 96)


def _clamp(value: int, bounds: tuple[int, int]) -> int:
    lo, hi = bounds
    return min(max(int(value), lo), hi)


@dataclass(frozen=True, slots=True)
class PlateFormat:
    """Physical shape of a microplate. Clamped on construction *and* on decode, so a
    hand-edited document can never produce a zero-sized plate."""

    rows: int
    cols: int

    def __post_init__(self) -> None:
        object.__setattr__(self, "rows", _clamp(self.rows, ROW_RANGE))
        object.__setattr__(self, "cols", _clamp(self.cols, COLUMN_RANGE))

    # -- identity / names -------------------------------------------------------
    @property
    def id(self) -> str:
        return f"{self.rows}x{self.cols}"

    @property
    def well_count(self) -> int:
        return self.rows * self.cols

    @property
    def name(self) -> str:
        return f"{self.well_count}-well"

    @property
    def detailed_name(self) -> str:
        return f"{self.well_count}-well  ({self.rows}×{self.cols})"

    @property
    def is_standard(self) -> bool:
        return self in STANDARD

    @classmethod
    def standard_matching(cls, rows: int, cols: int) -> "PlateFormat | None":
        fmt = cls(rows, cols)
        return fmt if fmt in STANDARD else None

    # -- indexing (row-major everywhere, exports included) -----------------------
    def index(self, row: int, col: int) -> int:
        return row * self.cols + col

    def row_of(self, index: int) -> int:
        return index // self.cols

    def col_of(self, index: int) -> int:
        return index % self.cols

    def contains(self, row: int, col: int) -> bool:
        return 0 <= row < self.rows and 0 <= col < self.cols

    # -- codec -------------------------------------------------------------------
    def to_json(self) -> dict[str, Any]:
        return {"rows": self.rows, "cols": self.cols}

    @classmethod
    def from_json(cls, data: Any) -> "PlateFormat":
        """Both keys are required (a missing one is a decode error), values are clamped."""
        from playout.model.layout import LayoutDecodeError, require_int

        if not isinstance(data, dict):
            raise LayoutDecodeError("PlateFormat must be an object")
        return cls(require_int(data, "rows", "PlateFormat"), require_int(data, "cols", "PlateFormat"))


WELL6 = PlateFormat(2, 3)
WELL12 = PlateFormat(3, 4)
WELL24 = PlateFormat(4, 6)
WELL48 = PlateFormat(6, 8)
WELL96 = PlateFormat(8, 12)
WELL384 = PlateFormat(16, 24)
WELL1536 = PlateFormat(32, 48)

STANDARD: tuple[PlateFormat, ...] = (WELL6, WELL12, WELL24, WELL48, WELL96, WELL384, WELL1536)

# Class-level aliases so callers can write `PlateFormat.WELL96` / `PlateFormat.STANDARD`.
PlateFormat.WELL6 = WELL6  # type: ignore[attr-defined]
PlateFormat.WELL12 = WELL12  # type: ignore[attr-defined]
PlateFormat.WELL24 = WELL24  # type: ignore[attr-defined]
PlateFormat.WELL48 = WELL48  # type: ignore[attr-defined]
PlateFormat.WELL96 = WELL96  # type: ignore[attr-defined]
PlateFormat.WELL384 = WELL384  # type: ignore[attr-defined]
PlateFormat.WELL1536 = WELL1536  # type: ignore[attr-defined]
PlateFormat.STANDARD = STANDARD  # type: ignore[attr-defined]


def is_standard(rows: int, cols: int) -> bool:
    return PlateFormat(rows, cols) in STANDARD


PlateFormat.is_standard_shape = staticmethod(is_standard)  # type: ignore[attr-defined]


class WellNaming:
    """A1-style well names. Rows are bijective base-26 (A…Z, AA…), columns 1-based."""

    @staticmethod
    def row_label(row: int) -> str:
        """0 → "A", 25 → "Z", 26 → "AA" (a 1536-well plate runs A…AF)."""
        if row < 0:
            return "?"
        out = ""
        n = row
        while True:
            out = chr(65 + n % 26) + out
            n = n // 26 - 1
            if n < 0:
                break
        return out

    @staticmethod
    def row_index(label: str) -> int | None:
        """Inverse of `row_label`; None for anything that is not pure ASCII letters."""
        s = label.strip().upper()
        if not s or not all("A" <= ch <= "Z" for ch in s):
            return None
        n = 0
        for ch in s:
            n = n * 26 + (ord(ch) - 64)
        return n - 1

    @staticmethod
    def col_label(col: int, padded: bool) -> str:
        return f"{col + 1:02d}" if padded else str(col + 1)

    @staticmethod
    def well_label(row: int, col: int, padded: bool) -> str:
        return WellNaming.row_label(row) + WellNaming.col_label(col, padded)

    @staticmethod
    def parse_well(text: str) -> tuple[int, int] | None:
        """Parses "A1", "a01", " H12 " into (row, col); rejects letter-only and digit-only."""
        s = text.strip()
        if not s:
            return None
        i = 0
        while i < len(s) and s[i].isalpha():
            i += 1
        letters, digits = s[:i], s[i:]
        if not letters or not digits or not digits.lstrip("+").isdigit() or digits.count("+") > 1:
            return None
        row = WellNaming.row_index(letters)
        if row is None:
            return None
        num = int(digits)
        if num < 1:
            return None
        return (row, num - 1)
