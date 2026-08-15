"""Plate-size templates (QSettings) and whole-layout templates (.plate files) —
mirrors `Sources/PLayout/Model/PlateTemplate.swift` and `LayoutTemplateStore.swift`. M1.

Two unrelated kinds of "template", both app-wide and shared by every open window:

* `PlateTemplateStore` — named plate *sizes* the user saved for reuse. The name lives
  here rather than on `PlateFormat` so that formats stay pure geometry: every "did the
  format change" guard in the app compares them by dimensions alone. Kept as a JSON
  string under one QSettings key (`customPlateTemplates`, same as the Mac's
  UserDefaults key).
* `LayoutTemplateStore` — whole-layout starting points: complete `.plate` files kept
  in the app-data folder, one per template. A new document "from template" is an
  untitled duplicate of that file, so the template itself can never be edited by
  accident.

QtCore only. `playout.model.layout` is imported lazily inside the methods that need the
codec, so this module imports even while that one is still being written.
"""
from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QSettings, QStandardPaths, Signal

from playout.model.plate_format import PlateFormat

# --------------------------------------------------------------------------------------
# Plate-size templates
# --------------------------------------------------------------------------------------

ROW_RANGE = (1, 64)
COLUMN_RANGE = (1, 96)


def _new_id() -> str:
    return str(uuid.uuid4()).upper()


def _parse_id(raw: Any) -> str | None:
    try:
        return str(uuid.UUID(str(raw))).upper()
    except (ValueError, TypeError, AttributeError):
        return None


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _in_range(rows: int, cols: int) -> bool:
    return ROW_RANGE[0] <= rows <= ROW_RANGE[1] and COLUMN_RANGE[0] <= cols <= COLUMN_RANGE[1]


def _is_standard_shape(rows: int, cols: int) -> bool:
    """Compared on dimensions, never through `PlateFormat(...)` — that clamps, and an
    out-of-range shape must not be mistaken for the standard plate it clamps to."""
    return any(f.rows == rows and f.cols == cols for f in PlateFormat.STANDARD)


def _shape(rows_or_format: Any, cols: int | None) -> tuple[int, int]:
    """Every lookup takes `(rows, cols)` or a single object with `.rows/.cols`."""
    if cols is None:
        return int(rows_or_format.rows), int(rows_or_format.cols)
    return int(rows_or_format), int(cols)


@dataclass(frozen=True)
class PlateTemplate:
    """A named plate size the user saved for reuse."""

    id: str
    name: str
    rows: int
    cols: int

    @property
    def format(self) -> PlateFormat:
        return PlateFormat(self.rows, self.cols)

    @property
    def well_count(self) -> int:
        return self.rows * self.cols

    @property
    def subtitle(self) -> str:
        return f"{self.well_count} wells · {self.rows}×{self.cols}"

    def to_json(self) -> dict[str, Any]:
        return {"id": self.id, "name": self.name, "rows": self.rows, "cols": self.cols}

    @classmethod
    def from_json(cls, data: Any) -> "PlateTemplate | None":
        """None for anything malformed — a rogue entry is dropped, not a crash."""
        if not isinstance(data, dict):
            return None
        template_id = _parse_id(data.get("id"))
        name, rows, cols = data.get("name"), data.get("rows"), data.get("cols")
        if template_id is None or not isinstance(name, str) or not _is_int(rows) or not _is_int(cols):
            return None
        return cls(template_id, name, rows, cols)


class PlateTemplateStore(QObject):
    """App-wide list of custom plate sizes, shared by every open document. Insertion
    order is kept (the Mac list can be reordered by hand); `changed` fires after every
    write that altered the list."""

    changed = Signal()

    STORAGE_KEY = "customPlateTemplates"

    def __init__(self, settings: QSettings | None = None, parent: QObject | None = None) -> None:
        super().__init__(parent)
        if settings is None:
            from playout.model.preferences import default_settings

            settings = default_settings()
        self._settings = settings
        self._templates: list[PlateTemplate] = []
        self._load()

    # -- reading ---------------------------------------------------------------------

    @property
    def templates(self) -> list[PlateTemplate]:
        return list(self._templates)

    def template_matching(self, rows: Any, cols: int | None = None) -> PlateTemplate | None:
        r, c = _shape(rows, cols)
        for template in self._templates:
            if template.rows == r and template.cols == c:
                return template
        return None

    def display_name(self, rows: Any, cols: int | None = None) -> str:
        """The name to show for a shape: a matching template's name, else the well
        count. Standard plates keep their standard name whatever the store says."""
        r, c = _shape(rows, cols)
        if _is_standard_shape(r, c):
            return f"{r * c}-well"
        match = self.template_matching(r, c)
        return match.name if match is not None else f"{r * c}-well"

    def detailed_name(self, rows: Any, cols: int | None = None) -> str:
        r, c = _shape(rows, cols)
        name = self.display_name(r, c)
        return f"{name}  ({r}×{c})"

    def can_save(self, rows: Any, cols: int | None = None) -> bool:
        r, c = _shape(rows, cols)
        return not _is_standard_shape(r, c) and self.template_matching(r, c) is None

    # -- writing ---------------------------------------------------------------------

    def add(self, name: str, rows: Any, cols: int | None = None) -> PlateTemplate | None:
        """None when the shape is not worth saving: standard plates already have a name
        of their own, and a duplicate would show up twice in the format menu."""
        r, c = _shape(rows, cols)
        if not self.can_save(r, c):
            return None
        template = PlateTemplate(_new_id(), self._unique_name(name, r, c), r, c)
        self._templates.append(template)
        self._save()
        self.changed.emit()
        return template

    def rename(self, template_id: str, new_name: str) -> None:
        trimmed = new_name.strip()
        if not trimmed:
            return
        for index, template in enumerate(self._templates):
            if template.id == template_id:
                if template.name == trimmed:
                    return
                self._templates[index] = replace(template, name=trimmed)
                self._save()
                self.changed.emit()
                return

    def remove(self, template_id: str) -> None:
        kept = [t for t in self._templates if t.id != template_id]
        if len(kept) == len(self._templates):
            return
        self._templates = kept
        self._save()
        self.changed.emit()

    def _unique_name(self, proposed: str, rows: int, cols: int) -> str:
        """Falls back to a descriptive name, and disambiguates against what is saved."""
        base = proposed.strip()
        if not base:
            base = f"{rows}×{cols} plate"
        existing = {t.name.lower() for t in self._templates}
        if base.lower() not in existing:
            return base
        n = 2
        while f"{base} {n}".lower() in existing:
            n += 1
        return f"{base} {n}"

    # -- persistence -----------------------------------------------------------------

    def _load(self) -> None:
        raw = self._settings.value(self.STORAGE_KEY)
        if raw is None:
            return
        if isinstance(raw, (list, tuple)):  # an unquoted Ini value with commas
            raw = ",".join(str(part) for part in raw)
        elif isinstance(raw, (bytes, bytearray)):
            raw = bytes(raw).decode("utf-8", "replace")
        try:
            decoded = json.loads(str(raw))
        except ValueError:
            return
        if not isinstance(decoded, list):
            return
        # Drop anything out of bounds, any shape that is really a standard plate, and
        # any duplicate shape — all three would produce confusing format menus.
        seen: set[tuple[int, int]] = set()
        kept: list[PlateTemplate] = []
        for entry in decoded:
            template = PlateTemplate.from_json(entry)
            if template is None:
                continue
            shape = (template.rows, template.cols)
            if not _in_range(*shape) or _is_standard_shape(*shape) or shape in seen:
                continue
            seen.add(shape)
            kept.append(template)
        self._templates = kept

    def _save(self) -> None:
        payload = json.dumps([t.to_json() for t in self._templates], ensure_ascii=False)
        self._settings.setValue(self.STORAGE_KEY, payload)
        self._settings.sync()


# --------------------------------------------------------------------------------------
# Whole-layout templates
# --------------------------------------------------------------------------------------

_NATURAL_SPLIT = re.compile(r"(\d+)")


def _natural_key(name: str) -> tuple:
    """Finder-style ordering (`localizedStandardCompare`): case-insensitive, with digit
    runs compared as numbers so "Plate 2" sorts before "Plate 10"."""
    parts = _NATURAL_SPLIT.split(name)
    key: list[tuple[int, Any]] = []
    for part in parts:
        if part.isdigit():
            key.append((0, int(part)))
        elif part:
            key.append((1, part.casefold()))
    return (tuple(key), name.casefold(), name)


def _layout_module():
    """The `.plate` codec, resolved at call time (see the module docstring)."""
    from playout.model import layout

    return layout


class LayoutTemplateStore(QObject):
    """App-wide list of whole-layout starting points: complete `.plate` files kept in
    the app-data folder, one per template. `changed` fires after every refresh."""

    changed = Signal()

    @dataclass(frozen=True)
    class Template:
        name: str
        path: Path

    def __init__(self, directory: Path | str | None = None, parent: QObject | None = None) -> None:
        super().__init__(parent)
        if directory is None:
            base = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation)
            directory = Path(base) / "Templates"
        self._directory = Path(directory)
        self._templates: list[LayoutTemplateStore.Template] = []
        self.refresh()

    @property
    def directory(self) -> Path:
        return self._directory

    @property
    def templates(self) -> list["LayoutTemplateStore.Template"]:
        return list(self._templates)

    def refresh(self) -> None:
        found: list[LayoutTemplateStore.Template] = []
        try:
            entries = list(self._directory.iterdir())
        except OSError:
            entries = []
        for entry in entries:
            if entry.suffix == ".plate" and entry.is_file():
                found.append(self.Template(name=entry.stem, path=entry))
        found.sort(key=lambda t: _natural_key(t.name))
        self._templates = found
        self.changed.emit()

    def path_for(self, name: str) -> Path | None:
        clean = self.sanitized(name)
        return self._directory / f"{clean}.plate" if clean else None

    def save(self, layout: Any, name: str) -> "LayoutTemplateStore.Template | None":
        """Saves the layout as a template, overwriting one of the same name — saving
        again under a name *is* updating that template. A name that sanitises to
        nothing is a no-op."""
        path = self.path_for(name)
        if path is None:
            return None
        self._directory.mkdir(parents=True, exist_ok=True)
        path.write_text(_layout_module().dumps(layout), encoding="utf-8")
        self.refresh()
        return self.Template(name=path.stem, path=path)

    def load(self, template: "LayoutTemplateStore.Template") -> Any:
        """The template's layout, decoded — the caller seeds a new untitled document
        with it so the file itself stays untouched."""
        return _layout_module().loads(Path(template.path).read_text(encoding="utf-8"))

    def delete(self, template: "LayoutTemplateStore.Template") -> None:
        try:
            Path(template.path).unlink()
        except OSError:
            pass
        self.refresh()

    @staticmethod
    def sanitized(name: str) -> str:
        """A file name, not a path: separators and leading dots have no business in one."""
        return name.strip().replace("/", "-").replace(":", "-").strip(".")
