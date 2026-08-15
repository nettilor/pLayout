"""Layout / Plate / Factor / Level / LayoutSnapshot and the `.plate` JSON codec.

Mirrors `Sources/PLayout/Model/Layout.swift`. Pure Python, no Qt.

Every type here is a *frozen* dataclass: what Swift gets from value semantics we get from
immutability. Every Swift `mutating func` keeps its name (snake_case) but **returns a new
value** — `plate.set_level_id(...)` gives you a new Plate — so a Layout held by the undo
stack can never be changed under it, and untouched sub-objects are shared, which is what
keeps equality (`new == old`, the no-op guard in `PlateDocument.mutate`) cheap.

Identity is an upper-case UUID string everywhere (Swift renders `UUID.uuidString` in upper
case; `Plate.assignments` is keyed by that raw string, so case is load-bearing there).
Assignment *values* and keys are kept exactly as found in the file, like the Swift model.

Compatibility contract (see PORT.md §"Compatibility contract"): every key at Layout and
LayoutSnapshot level is optional on read; Factor, Level, PlateFormat require all their keys;
Plate requires id/name/format; unknown keys are ignored (and not preserved); `savedAt` is
seconds since 2001-01-01T00:00:00Z (Apple epoch); `orientation` is strict, `wellLabelMode`
lenient; assignment columns are normalised to rows*cols on decode and all-null columns dropped.
"""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any, Iterable, Mapping

from playout.model.plate_format import WELL96, PlateFormat

# 2001-01-01T00:00:00Z as a Unix timestamp. Swift's default JSON date is seconds since then.
APPLE_EPOCH = 978307200.0
APPLE_EPOCH_DATETIME = datetime(2001, 1, 1, tzinfo=timezone.utc)


class LayoutDecodeError(ValueError):
    """A `.plate` document is missing a required key or carries an unusable value.

    Raised for exactly the cases where the Mac app refuses to open the file (Swift
    `keyNotFound` / `dataCorrupted`); everything the Mac tolerates, we tolerate."""


# --------------------------------------------------------------------------------------
# Identity helpers


def new_id() -> str:
    """A fresh id in the form the Mac app writes: upper-case canonical UUID."""
    return str(uuid.uuid4()).upper()


def parse_id(text: Any, what: str = "id") -> str:
    """Validate a UUID string and return it upper-cased (Swift's `UUID(uuidString:)` is
    case-insensitive on read and re-encodes upper-case)."""
    if not isinstance(text, str):
        raise LayoutDecodeError(f"{what} must be a UUID string")
    try:
        return str(uuid.UUID(text.strip())).upper()
    except (ValueError, AttributeError) as exc:
        raise LayoutDecodeError(f"{what} is not a UUID: {text!r}") from exc


def is_uuid(text: Any) -> bool:
    if not isinstance(text, str):
        return False
    try:
        uuid.UUID(text)
        return True
    except ValueError:
        return False


# --------------------------------------------------------------------------------------
# JSON key helpers (the port's `decode` / `decodeIfPresent`)


def require(data: Mapping[str, Any], key: str, what: str) -> Any:
    if key not in data:
        raise LayoutDecodeError(f"{what} is missing required key {key!r}")
    return data[key]


def require_str(data: Mapping[str, Any], key: str, what: str) -> str:
    value = require(data, key, what)
    if not isinstance(value, str):
        raise LayoutDecodeError(f"{what}.{key} must be a string")
    return value


def require_int(data: Mapping[str, Any], key: str, what: str) -> int:
    value = require(data, key, what)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LayoutDecodeError(f"{what}.{key} must be a number")
    if isinstance(value, float) and not value.is_integer():
        raise LayoutDecodeError(f"{what}.{key} must be an integer")
    return int(value)


def _present(data: Mapping[str, Any], key: str) -> bool:
    """Swift `decodeIfPresent`: an absent key *or* a JSON null both mean "use the default";
    a value of the wrong type is a decode error, exactly as on the Mac."""
    return key in data and data[key] is not None


def optional_str(data: Mapping[str, Any], key: str, default: str, what: str = "Layout") -> str:
    if not _present(data, key):
        return default
    value = data[key]
    if not isinstance(value, str):
        raise LayoutDecodeError(f"{what}.{key} must be a string")
    return value


def optional_bool(data: Mapping[str, Any], key: str, default: bool, what: str = "Layout") -> bool:
    if not _present(data, key):
        return default
    value = data[key]
    if not isinstance(value, bool):
        raise LayoutDecodeError(f"{what}.{key} must be a boolean")
    return value


def optional_int(data: Mapping[str, Any], key: str, default: int, what: str = "Layout") -> int:
    if not _present(data, key):
        return default
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or (
        isinstance(value, float) and not value.is_integer()
    ):
        raise LayoutDecodeError(f"{what}.{key} must be an integer")
    return int(value)


def optional_list(data: Mapping[str, Any], key: str, what: str = "Layout") -> list:
    if not _present(data, key):
        return []
    value = data[key]
    if not isinstance(value, list):
        raise LayoutDecodeError(f"{what}.{key} must be an array")
    return value


def optional_number(data: Mapping[str, Any], key: str, default: float, what: str) -> float:
    if not _present(data, key):
        return default
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LayoutDecodeError(f"{what}.{key} must be a number")
    return float(value)


# --------------------------------------------------------------------------------------
# Enums


class FactorKind(str, Enum):
    categorical = "categorical"
    numeric = "numeric"

    @classmethod
    def from_raw(cls, raw: Any) -> "FactorKind":
        try:
            return cls(raw)
        except ValueError as exc:
            raise LayoutDecodeError(f"unknown factor kind {raw!r}") from exc


class WellLabelMode(str, Enum):
    """How much text each well carries. `overview` is the stacked mode with nothing armed."""

    none = "none"
    activeFactor = "activeFactor"
    allFactors = "allFactors"
    overview = "overview"

    @property
    def label(self) -> str:
        return {
            WellLabelMode.none: "None",
            WellLabelMode.activeFactor: "Active factor",
            WellLabelMode.allFactors: "All factors",
            WellLabelMode.overview: "Overview",
        }[self]

    @property
    def short_label(self) -> str:
        return {
            WellLabelMode.none: "None",
            WellLabelMode.activeFactor: "Active",
            WellLabelMode.allFactors: "All",
            WellLabelMode.overview: "Overview",
        }[self]

    @property
    def shows_text(self) -> bool:
        return self is not WellLabelMode.none

    @property
    def stacks_every_factor(self) -> bool:
        return self in (WellLabelMode.allFactors, WellLabelMode.overview)

    @property
    def is_overview(self) -> bool:
        return self is WellLabelMode.overview

    @classmethod
    def lenient(cls, raw: Any) -> "WellLabelMode":
        """Unknown values fall back to `activeFactor` — a file from a newer build still opens."""
        try:
            return cls(raw)
        except ValueError:
            return cls.activeFactor


class PlateOrientation(str, Enum):
    """Which way round a plate is drawn — a rotation of the picture, never of the data.
    Three-valued on purpose: "not yet decided" must be tellable from "deliberately upright"."""

    automatic = "automatic"
    upright = "upright"
    turned = "turned"

    def quarter_turns(self, fmt: PlateFormat) -> int:
        if self is PlateOrientation.automatic:
            return 1 if fmt.rows > fmt.cols else 0
        if self is PlateOrientation.upright:
            return 0
        return 1

    @classmethod
    def from_raw(cls, raw: Any) -> "PlateOrientation":
        try:
            return cls(raw)
        except ValueError as exc:
            raise LayoutDecodeError(f"unknown orientation {raw!r}") from exc


# --------------------------------------------------------------------------------------
# Level / Factor


@dataclass(frozen=True, slots=True)
class Level:
    """One value a factor can take, e.g. "10 µM" or "HeLa"."""

    name: str
    color_hex: str
    id: str = field(default_factory=new_id)

    def to_json(self) -> dict[str, Any]:
        return {"colorHex": self.color_hex, "id": self.id, "name": self.name}

    @classmethod
    def from_json(cls, data: Any) -> "Level":
        if not isinstance(data, dict):
            raise LayoutDecodeError("Level must be an object")
        return cls(
            id=parse_id(require(data, "id", "Level"), "Level.id"),
            name=require_str(data, "name", "Level"),
            color_hex=require_str(data, "colorHex", "Level"),
        )


def _clean_name(name: str) -> str:
    """Swift `trimmingCharacters(in: .whitespaces)` — spaces and tabs, not newlines."""
    return name.strip(" \t")


@dataclass(frozen=True, slots=True)
class Factor:
    """An independent variable painted onto the plate."""

    name: str
    kind: FactorKind = FactorKind.categorical
    unit: str = ""
    levels: tuple[Level, ...] = ()
    id: str = field(default_factory=new_id)

    def __post_init__(self) -> None:
        if not isinstance(self.levels, tuple):
            object.__setattr__(self, "levels", tuple(self.levels))
        if not isinstance(self.kind, FactorKind):
            object.__setattr__(self, "kind", FactorKind(self.kind))

    @property
    def display_name(self) -> str:
        return self.name if not self.unit else f"{self.name} ({self.unit})"

    def level(self, level_id: str | None) -> Level | None:
        if level_id is None:
            return None
        for lv in self.levels:
            if lv.id == level_id:
                return lv
        return None

    def level_named(self, name: str) -> Level | None:
        key = _clean_name(name).lower()
        for lv in self.levels:
            if _clean_name(lv.name).lower() == key:
                return lv
        return None

    def index_of(self, level_id: str) -> int | None:
        for i, lv in enumerate(self.levels):
            if lv.id == level_id:
                return i
        return None

    def ensure_level(self, name: str, color_hex: str | None = None) -> tuple["Factor", str]:
        """Adds a level with the given name if absent; returns (factor, level id) either way.
        The colour override exists for the never-repeat setting, whose choice depends on the
        whole document — which a single factor cannot see."""
        clean = _clean_name(name)
        existing = self.level_named(clean)
        if existing is not None:
            return self, existing.id
        if color_hex is None:
            from playout.model.palette import color_at

            color_hex = color_at(len(self.levels))
        level = Level(name=clean, color_hex=color_hex)
        return replace(self, levels=self.levels + (level,)), level.id

    def with_levels(self, levels: Iterable[Level]) -> "Factor":
        return replace(self, levels=tuple(levels))

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind.value,
            "levels": [lv.to_json() for lv in self.levels],
            "name": self.name,
            "unit": self.unit,
        }

    @classmethod
    def from_json(cls, data: Any) -> "Factor":
        if not isinstance(data, dict):
            raise LayoutDecodeError("Factor must be an object")
        levels = require(data, "levels", "Factor")
        if not isinstance(levels, list):
            raise LayoutDecodeError("Factor.levels must be an array")
        return cls(
            id=parse_id(require(data, "id", "Factor"), "Factor.id"),
            name=require_str(data, "name", "Factor"),
            kind=FactorKind.from_raw(require(data, "kind", "Factor")),
            unit=require_str(data, "unit", "Factor"),
            levels=tuple(Level.from_json(lv) for lv in levels),
        )


# --------------------------------------------------------------------------------------
# Plate

Column = tuple  # tuple[str | None, ...]


def _resized(column: tuple, count: int) -> tuple:
    if len(column) == count:
        return column
    if len(column) > count:
        return column[:count]
    return column + (None,) * (count - len(column))


def _has_value(column: Iterable[str | None]) -> bool:
    return any(v is not None for v in column)


@dataclass(frozen=True, slots=True)
class Plate:
    """One plate: a format plus, per factor, one level id per well (row-major)."""

    name: str
    format: PlateFormat = WELL96
    #: factor id (raw string, upper-case when written by either app) -> per-well level id
    #: (raw string) or None, indexed row-major, length == format.well_count.
    assignments: Mapping[str, tuple] = field(default_factory=dict, hash=False)
    #: well index as decimal string -> note (string keys: an Int-keyed Swift dictionary
    #: would encode as a flat array).
    well_notes: Mapping[str, str] = field(default_factory=dict, hash=False)
    note: str = ""
    id: str = field(default_factory=new_id)

    def __post_init__(self) -> None:
        # Freeze the mappings' contents as tuples so nothing downstream can alias into them.
        fixed = {k: tuple(v) for k, v in self.assignments.items()}
        object.__setattr__(self, "assignments", fixed)
        object.__setattr__(self, "well_notes", dict(self.well_notes))

    # -- notes ------------------------------------------------------------------------
    def note_for(self, well: int) -> str | None:
        text = self.well_notes.get(str(well))
        return text if text else None

    def set_note(self, text: str | None, well: int) -> "Plate":
        if well < 0 or well >= self.format.well_count:
            return self
        clean = (text or "").strip()
        notes = dict(self.well_notes)
        if clean:
            notes[str(well)] = clean
        else:
            notes.pop(str(well), None)
        return replace(self, well_notes=notes)

    def with_note(self, text: str) -> "Plate":
        return replace(self, note=text)

    # -- assignments ------------------------------------------------------------------
    def level_id(self, factor_id: str, well: int) -> str | None:
        """The level at a well, or None. Like Swift's `UUID(uuidString:)` this is
        case-insensitive on the stored value and returns the canonical (upper) form."""
        column = self.assignments.get(factor_id)
        if column is None or well < 0 or well >= len(column):
            return None
        raw = column[well]
        if raw is None or not is_uuid(raw):
            return None
        return raw.upper()

    def set_level_id(self, level_id: str | None, factor_id: str, well: int) -> "Plate":
        return self.set_level_ids(factor_id, {well: level_id})

    def set_level_ids(self, factor_id: str, values: Mapping[int, str | None]) -> "Plate":
        """Batch form of `set_level_id`: one copy of the column for any number of wells.
        Out-of-range wells are ignored; a column left all-None is removed entirely."""
        count = self.format.well_count
        column = list(_resized(self.assignments.get(factor_id, ()), count))
        touched = False
        for well, level_id in values.items():
            if 0 <= well < count:
                column[well] = level_id
                touched = True
        if not touched:
            return self
        assignments = dict(self.assignments)
        if _has_value(column):
            assignments[factor_id] = tuple(column)
        else:
            assignments.pop(factor_id, None)
        return replace(self, assignments=assignments)

    def without_factor(self, factor_id: str) -> "Plate":
        if factor_id not in self.assignments:
            return self
        assignments = dict(self.assignments)
        del assignments[factor_id]
        return replace(self, assignments=assignments)

    def assigned_well_count(self, factor_id: str, level_id: str) -> int:
        column = self.assignments.get(factor_id)
        if column is None:
            return 0
        return sum(1 for v in column if v == level_id)

    def change_format(self, new_format: PlateFormat) -> "Plate":
        """Changes the plate size, keeping each well's values (and notes) at the same
        row/column; wells the smaller plate no longer has are dropped."""
        if new_format == self.format:
            return self
        old = self.format
        rows = min(old.rows, new_format.rows)
        cols = min(old.cols, new_format.cols)
        remapped: dict[str, tuple] = {}
        for key, column in self.assignments.items():
            fresh: list[str | None] = [None] * new_format.well_count
            for row in range(rows):
                for col in range(cols):
                    o = old.index(row, col)
                    if o < len(column):
                        fresh[new_format.index(row, col)] = column[o]
            if _has_value(fresh):
                remapped[key] = tuple(fresh)
        kept_notes: dict[str, str] = {}
        for row in range(rows):
            for col in range(cols):
                text = self.well_notes.get(str(old.index(row, col)))
                if text is not None:
                    kept_notes[str(new_format.index(row, col))] = text
        return replace(self, format=new_format, assignments=remapped, well_notes=kept_notes)

    def format_change_would_lose_data(self, new_format: PlateFormat) -> bool:
        """True when shrinking to `new_format` would drop wells that currently hold a value."""
        old = self.format
        if not (new_format.rows < old.rows or new_format.cols < old.cols):
            return False
        for column in self.assignments.values():
            for row in range(old.rows):
                for col in range(old.cols):
                    if row >= new_format.rows or col >= new_format.cols:
                        idx = old.index(row, col)
                        if idx < len(column) and column[idx] is not None:
                            return True
        return False

    def normalize_assignments(self) -> "Plate":
        """Forces every factor's column to match this plate's well count (pad/truncate),
        dropping a *resized* column that ends up all-None. Applied once on decode. A
        correctly sized all-None column is left alone, exactly as the Mac leaves it."""
        count = self.format.well_count
        if all(len(c) == count for c in self.assignments.values()):
            return self
        fixed: dict[str, tuple] = {}
        for key, column in self.assignments.items():
            column = _resized(column, count)
            if _has_value(column):
                fixed[key] = column
        return replace(self, assignments=fixed)

    def to_json(self) -> dict[str, Any]:
        return {
            "assignments": {k: list(v) for k, v in self.assignments.items()},
            "format": self.format.to_json(),
            "id": self.id,
            "name": self.name,
            "note": self.note,
            "wellNotes": dict(self.well_notes),
        }

    @classmethod
    def from_json(cls, data: Any) -> "Plate":
        if not isinstance(data, dict):
            raise LayoutDecodeError("Plate must be an object")
        raw_assignments = data.get("assignments") if _present(data, "assignments") else {}
        if not isinstance(raw_assignments, dict):
            raise LayoutDecodeError("Plate.assignments must be an object")
        assignments: dict[str, tuple] = {}
        for key, column in raw_assignments.items():
            if not isinstance(key, str) or not isinstance(column, list):
                raise LayoutDecodeError("Plate.assignments must map factor ids to arrays")
            for v in column:
                if v is not None and not isinstance(v, str):
                    raise LayoutDecodeError("Plate.assignments values must be strings or null")
            assignments[key] = tuple(column)
        raw_notes = data.get("wellNotes") if _present(data, "wellNotes") else {}
        if not isinstance(raw_notes, dict):
            raise LayoutDecodeError("Plate.wellNotes must be an object")
        for k, v in raw_notes.items():
            if not isinstance(k, str) or not isinstance(v, str):
                raise LayoutDecodeError("Plate.wellNotes must map strings to strings")
        return cls(
            id=parse_id(require(data, "id", "Plate"), "Plate.id"),
            name=require_str(data, "name", "Plate"),
            format=PlateFormat.from_json(require(data, "format", "Plate")),
            assignments=assignments,
            well_notes=dict(raw_notes),
            note=optional_str(data, "note", "", "Plate"),
        )


# --------------------------------------------------------------------------------------
# Saved states


@dataclass(frozen=True, slots=True)
class LayoutSnapshot:
    """A bookmark of one plate's design (factors travel with it). Same fields as Layout
    minus the snapshot list, which is what keeps it from nesting.

    `saved_at` is kept as the file's own number — seconds since 2001-01-01T00:00:00Z —
    so a round trip cannot move it by a rounding error. Use `saved_at_datetime()`."""

    name: str = "State"
    saved_at: float = -APPLE_EPOCH  # the Unix epoch, expressed in Apple seconds
    plate_id: str | None = None
    factors: tuple[Factor, ...] = ()
    plates: tuple[Plate, ...] = ()
    id: str = field(default_factory=new_id)

    def __post_init__(self) -> None:
        if not isinstance(self.factors, tuple):
            object.__setattr__(self, "factors", tuple(self.factors))
        if not isinstance(self.plates, tuple):
            object.__setattr__(self, "plates", tuple(self.plates))

    @staticmethod
    def apple_seconds(when: datetime) -> float:
        if when.tzinfo is None:
            when = when.astimezone()
        return (when - APPLE_EPOCH_DATETIME).total_seconds()

    def saved_at_datetime(self) -> datetime:
        return APPLE_EPOCH_DATETIME + timedelta(seconds=self.saved_at)

    def belongs_to(self, plate_id: str | None) -> bool:
        """True for the given plate, or for every plate when the state predates per-plate states."""
        return self.plate_id is None or self.plate_id == plate_id

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "factors": [f.to_json() for f in self.factors],
            "id": self.id,
            "name": self.name,
            "plates": [p.to_json() for p in self.plates],
            "savedAt": self.saved_at,
        }
        if self.plate_id is not None:  # Swift `encodeIfPresent`
            out["plateID"] = self.plate_id
        return out

    @classmethod
    def from_json(cls, data: Any) -> "LayoutSnapshot":
        if not isinstance(data, dict):
            raise LayoutDecodeError("LayoutSnapshot must be an object")
        what = "LayoutSnapshot"
        raw_id = data.get("id") if _present(data, "id") else None
        factors = tuple(Factor.from_json(f) for f in optional_list(data, "factors", what))
        plates = tuple(Plate.from_json(p) for p in optional_list(data, "plates", what))
        saved = optional_number(data, "savedAt", -APPLE_EPOCH, what)
        raw_plate_id = data.get("plateID") if _present(data, "plateID") else None
        if raw_plate_id is not None:
            plate_id: str | None = parse_id(raw_plate_id, "LayoutSnapshot.plateID")
        else:
            # A state from before per-plate states that holds exactly one plate is adopted by it.
            plate_id = plates[0].id if len(plates) == 1 else None
        return cls(
            id=parse_id(raw_id, "LayoutSnapshot.id") if raw_id is not None else new_id(),
            name=optional_str(data, "name", "State", what),
            saved_at=saved,
            plate_id=plate_id,
            factors=factors,
            plates=plates,
        )


# --------------------------------------------------------------------------------------
# Layout (the document's value)

MAX_SNAPSHOTS = 20


@dataclass(frozen=True, slots=True)
class Layout:
    factors: tuple[Factor, ...] = ()
    plates: tuple[Plate, ...] = ()
    pad_well_labels: bool = False
    well_label_mode: WellLabelMode = WellLabelMode.activeFactor
    orientation: PlateOrientation = PlateOrientation.automatic
    snapshots: tuple[LayoutSnapshot, ...] = ()
    notes: str = ""
    format_version: int = 1

    MAX_SNAPSHOTS = MAX_SNAPSHOTS

    def __post_init__(self) -> None:
        for name in ("factors", "plates", "snapshots"):
            value = getattr(self, name)
            if not isinstance(value, tuple):
                object.__setattr__(self, name, tuple(value))

    # -- construction -----------------------------------------------------------------
    @classmethod
    def starter(cls) -> "Layout":
        from playout.model.palette import color_at

        factor = Factor(
            name="Condition",
            levels=(
                Level(name="Untreated", color_hex=color_at(0)),
                Level(name="Vehicle", color_hex=color_at(1)),
                Level(name="Treated", color_hex=color_at(2)),
            ),
        )
        return cls(factors=(factor,), plates=(Plate(name="Plate 1", format=WELL96),))

    # -- lookups ----------------------------------------------------------------------
    def factor(self, factor_id: str | None) -> Factor | None:
        if factor_id is None:
            return None
        for f in self.factors:
            if f.id == factor_id:
                return f
        return None

    def factor_index(self, factor_id: str | None) -> int | None:
        if factor_id is None:
            return None
        for i, f in enumerate(self.factors):
            if f.id == factor_id:
                return i
        return None

    def plate(self, plate_id: str | None) -> Plate | None:
        if plate_id is None:
            return None
        for p in self.plates:
            if p.id == plate_id:
                return p
        return None

    def plate_index(self, plate_id: str | None) -> int | None:
        if plate_id is None:
            return None
        for i, p in enumerate(self.plates):
            if p.id == plate_id:
                return i
        return None

    def value_name(self, plate_index: int, factor: Factor, well: int) -> str | None:
        """Human-readable value of a factor at a well, or None when unassigned."""
        if not 0 <= plate_index < len(self.plates):
            return None
        level_id = self.plates[plate_index].level_id(factor.id, well)
        if level_id is None:
            return None
        level = factor.level(level_id)
        return level.name if level else None

    # -- structural helpers (return new layouts) -------------------------------------
    def with_plate(self, index: int, plate: Plate) -> "Layout":
        plates = list(self.plates)
        plates[index] = plate
        return replace(self, plates=tuple(plates))

    def with_plate_id(self, plate_id: str, plate: Plate) -> "Layout":
        index = self.plate_index(plate_id)
        if index is None:
            return self
        return self.with_plate(index, plate)

    def with_factor(self, index: int, factor: Factor) -> "Layout":
        factors = list(self.factors)
        factors[index] = factor
        return replace(self, factors=tuple(factors))

    def with_factor_id(self, factor_id: str, factor: Factor) -> "Layout":
        index = self.factor_index(factor_id)
        if index is None:
            return self
        return self.with_factor(index, factor)

    def prune_unused_levels(self, factor_id: str) -> "Layout":
        """Drops levels that no plate references any more (raw-string comparison, as Swift)."""
        fi = self.factor_index(factor_id)
        if fi is None:
            return self
        used: set[str] = set()
        for p in self.plates:
            for raw in p.assignments.get(factor_id, ()):
                if raw is not None:
                    used.add(raw)
        factor = self.factors[fi]
        kept = tuple(lv for lv in factor.levels if lv.id in used)
        if len(kept) == len(factor.levels):
            return self
        return self.with_factor(fi, factor.with_levels(kept))

    def remove_level(self, level_id: str, factor_id: str) -> "Layout":
        fi = self.factor_index(factor_id)
        if fi is None:
            return self
        factor = self.factors[fi]
        layout = self.with_factor(fi, factor.with_levels(lv for lv in factor.levels if lv.id != level_id))
        plates = []
        for p in layout.plates:
            column = p.assignments.get(factor_id)
            if column is None:
                plates.append(p)
                continue
            cleared = {i: None for i, v in enumerate(column) if v == level_id}
            plates.append(p.set_level_ids(factor_id, cleared) if cleared else p)
        return replace(layout, plates=tuple(plates))

    def remove_factor(self, factor_id: str) -> "Layout":
        return replace(
            self,
            factors=tuple(f for f in self.factors if f.id != factor_id),
            plates=tuple(p.without_factor(factor_id) for p in self.plates),
        )

    # -- saved states -----------------------------------------------------------------
    def snapshots_for(self, plate_id: str | None) -> tuple[LayoutSnapshot, ...]:
        """Every state saved for one plate, oldest first."""
        return tuple(s for s in self.snapshots if s.belongs_to(plate_id))

    def capture_snapshot(self, saved_at: float, plate_id: str) -> tuple["Layout", int]:
        """Bookmarks one plate as it stands (`saved_at` in Apple seconds). Returns the new
        layout and how many old states were dropped to stay inside MAX_SNAPSHOTS."""
        plate = self.plate(plate_id)
        if plate is None:
            return self, 0
        mine = self.snapshots_for(plate_id)
        used = {s.name for s in mine}
        n = len(mine) + 1
        while f"State {n}" in used:
            n += 1
        snapshot = LayoutSnapshot(
            name=f"State {n}", saved_at=saved_at, plate_id=plate_id,
            factors=self.factors, plates=(plate,),
        )
        snapshots = self.snapshots + (snapshot,)
        excess = max(0, len(snapshots) - MAX_SNAPSHOTS)
        if excess:
            snapshots = snapshots[excess:]
        return replace(self, snapshots=snapshots), excess

    def restore_snapshot(self, snapshot_id: str) -> tuple["Layout", bool]:
        """Puts one plate back to a saved state. Display settings and the state list are
        untouched; factors are merged in (never removed)."""
        snapshot = next((s for s in self.snapshots if s.id == snapshot_id), None)
        if snapshot is None:
            return self, False
        layout = self._reinstate_factors(snapshot)
        if snapshot.plate_id is None:
            return replace(layout, plates=snapshot.plates), True
        saved = next((p for p in snapshot.plates if p.id == snapshot.plate_id), None)
        if saved is None:
            return layout, False
        index = layout.plate_index(snapshot.plate_id)
        if index is not None:
            return layout.with_plate(index, saved), True
        return replace(layout, plates=layout.plates + (saved,)), True

    def _reinstate_factors(self, snapshot: LayoutSnapshot) -> "Layout":
        factors = list(self.factors)
        for saved in snapshot.factors:
            index = next((i for i, f in enumerate(factors) if f.id == saved.id), None)
            if index is None:
                factors.append(saved)
                continue
            have = {lv.id for lv in factors[index].levels}
            missing = tuple(lv for lv in saved.levels if lv.id not in have)
            if missing:
                factors[index] = factors[index].with_levels(factors[index].levels + missing)
        return replace(self, factors=tuple(factors))

    def rename_snapshot(self, snapshot_id: str, new_name: str) -> "Layout":
        trimmed = _clean_name(new_name)
        if not trimmed:
            return self
        snapshots = list(self.snapshots)
        for i, s in enumerate(snapshots):
            if s.id == snapshot_id:
                snapshots[i] = replace(s, name=trimmed)
                return replace(self, snapshots=tuple(snapshots))
        return self

    def remove_snapshot(self, snapshot_id: str) -> "Layout":
        kept = tuple(s for s in self.snapshots if s.id != snapshot_id)
        return self if len(kept) == len(self.snapshots) else replace(self, snapshots=kept)

    def snapshot_matching(self, plate_id: str | None) -> LayoutSnapshot | None:
        """The newest saved state this plate currently matches (full Plate equality;
        factors deliberately not compared)."""
        plate = self.plate(plate_id)
        if plate is None:
            return None
        for s in reversed(self.snapshots):
            if s.plate_id == plate_id and s.plates and s.plates[0] == plate:
                return s
        return None

    # -- naming -----------------------------------------------------------------------
    def unique_factor_name(self, base: str) -> str:
        return _unique_name(base, (f.name for f in self.factors))

    def unique_plate_name(self, base: str) -> str:
        return _unique_name(base, (p.name for p in self.plates))

    def used_level_colors(self, excluding: str | None = None) -> set[str]:
        """Every colour any condition uses, normalised for membership tests."""
        from playout.model.palette import normalized

        return {
            normalized(lv.color_hex)
            for f in self.factors
            if f.id != excluding
            for lv in f.levels
        }

    # -- codec ------------------------------------------------------------------------
    def to_json(self) -> dict[str, Any]:
        return {
            "factors": [f.to_json() for f in self.factors],
            "formatVersion": self.format_version,
            "notes": self.notes,
            "orientation": self.orientation.value,
            "padWellLabels": self.pad_well_labels,
            "plates": [p.to_json() for p in self.plates],
            "snapshots": [s.to_json() for s in self.snapshots],
            "wellLabelMode": self.well_label_mode.value,
        }

    @classmethod
    def from_json(cls, data: Any) -> "Layout":
        if not isinstance(data, dict):
            raise LayoutDecodeError("a .plate document must be a JSON object")
        factors = tuple(Factor.from_json(f) for f in optional_list(data, "factors"))
        plates = tuple(Plate.from_json(p).normalize_assignments() for p in optional_list(data, "plates"))
        snapshots = tuple(LayoutSnapshot.from_json(s) for s in optional_list(data, "snapshots"))

        if _present(data, "orientation"):
            orientation = PlateOrientation.from_raw(data["orientation"])
        else:
            # Two retired predecessors: `transposedView` (a mirror) and `quarterTurns`
            # (a four-way cycle). Either having been set means the plate had been turned.
            mirrored = data.get("transposedView")
            old_turns = data.get("quarterTurns")
            was_mirrored = mirrored is True
            turned = isinstance(old_turns, (int, float)) and not isinstance(old_turns, bool) and old_turns != 0
            orientation = PlateOrientation.turned if (was_mirrored or turned) else PlateOrientation.automatic

        return cls(
            factors=factors,
            plates=plates,
            pad_well_labels=optional_bool(data, "padWellLabels", False),
            well_label_mode=WellLabelMode.lenient(data.get("wellLabelMode")),
            orientation=orientation,
            snapshots=snapshots,
            notes=optional_str(data, "notes", ""),
            format_version=optional_int(data, "formatVersion", 1),
        )


def _unique_name(base: str, existing_names: Iterable[str]) -> str:
    existing = {n.lower() for n in existing_names}
    if base.lower() not in existing:
        return base
    n = 2
    while f"{base} {n}".lower() in existing:
        n += 1
    return f"{base} {n}"


# --------------------------------------------------------------------------------------
# File-level codec


def dumps(layout: Layout) -> str:
    """The Mac app's output shape: pretty-printed, sorted keys, `"key" : value`, raw UTF-8."""
    return json.dumps(layout.to_json(), indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : "))


def loads(text: str | bytes) -> Layout:
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise LayoutDecodeError(f"not valid JSON: {exc}") from exc
    return Layout.from_json(data)


def load_file(path) -> Layout:
    with open(path, "r", encoding="utf-8") as f:
        return loads(f.read())


def save_file(layout: Layout, path) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(layout))
