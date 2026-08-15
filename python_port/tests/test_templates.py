"""Templates — port of `PlateTemplateStoreTests` (NewFeatureTests.swift) and
`LayoutTemplateTests.swift`. QSettings on a temp Ini file, layout templates in
`tmp_path`; the real user profile is never touched."""
from __future__ import annotations

import dataclasses
import json
import shutil
import uuid
from pathlib import Path

import pytest
from PySide6.QtCore import QSettings

from playout.model.plate_format import PlateFormat
from playout.model.templates import LayoutTemplateStore, PlateTemplate, PlateTemplateStore

STORAGE_KEY = "customPlateTemplates"


@pytest.fixture
def ini(tmp_path: Path) -> Path:
    return tmp_path / "templates.ini"


@pytest.fixture
def settings(ini: Path) -> QSettings:
    return QSettings(str(ini), QSettings.Format.IniFormat)


@pytest.fixture
def store(settings: QSettings) -> PlateTemplateStore:
    return PlateTemplateStore(settings)


def _fresh_id() -> str:
    return str(uuid.uuid4()).upper()


def rogue(name: str, rows: int, cols: int) -> dict:
    """A stored entry as the Mac would write it — used to seed the settings by hand."""
    return PlateTemplate(_fresh_id(), name, rows, cols).to_json()


class Counter:
    def __init__(self, signal) -> None:
        self.count = 0
        signal.connect(self._bump)

    def _bump(self) -> None:
        self.count += 1


# -- PlateTemplate ----------------------------------------------------------------------


def test_plate_template_json_round_trip_and_leniency():
    template = PlateTemplate(_fresh_id(), "Chamber slide", 2, 4)
    data = template.to_json()
    assert set(data) == {"id", "name", "rows", "cols"}
    assert PlateTemplate.from_json(data) == template
    assert PlateTemplate.from_json(json.loads(json.dumps(data))) == template

    lower = dict(data, id=data["id"].lower())
    assert PlateTemplate.from_json(lower).id == data["id"], "ids are upper-case on read"

    assert PlateTemplate.from_json({"id": "not-a-uuid", "name": "x", "rows": 2, "cols": 4}) is None
    assert PlateTemplate.from_json({"id": data["id"], "name": "x", "rows": "2", "cols": 4}) is None
    assert PlateTemplate.from_json({"id": data["id"], "rows": 2, "cols": 4}) is None
    assert PlateTemplate.from_json("nonsense") is None

    assert template.format == PlateFormat(2, 4)
    assert template.subtitle == "8 wells · 2×4"


# -- PlateTemplateStore -----------------------------------------------------------------


def test_a_standard_shape_is_not_saved_as_a_template(store: PlateTemplateStore):
    assert store.add("My 96", 8, 12) is None
    assert store.add("My 96", PlateFormat(8, 12)) is None
    assert not store.can_save(8, 12)
    assert store.templates == []


def test_the_same_shape_is_not_saved_twice(store: PlateTemplateStore):
    assert store.add("First", 5, 7) is not None
    assert store.add("Second", 5, 7) is None
    assert len(store.templates) == 1


def test_standard_and_duplicate_shapes_are_dropped_when_loaded(settings: QSettings):
    settings.setValue(
        STORAGE_KEY,
        json.dumps([rogue("Sneaky 96", 8, 12), rogue("Custom", 5, 7), rogue("Custom again", 5, 7)]),
    )
    reloaded = PlateTemplateStore(settings)
    assert [t.name for t in reloaded.templates] == ["Custom"]


def test_out_of_bounds_templates_are_dropped_on_load(settings: QSettings):
    settings.setValue(STORAGE_KEY, json.dumps([rogue("Huge", 5000, 5000), rogue("Nothing", 0, 4)]))
    assert PlateTemplateStore(settings).templates == []


def test_malformed_storage_is_treated_as_empty(settings: QSettings):
    settings.setValue(STORAGE_KEY, "this is not json")
    assert PlateTemplateStore(settings).templates == []
    settings.setValue(STORAGE_KEY, json.dumps({"id": "x"}))
    assert PlateTemplateStore(settings).templates == []
    # One rogue entry costs itself, not the whole list.
    settings.setValue(STORAGE_KEY, json.dumps([{"broken": True}, rogue("Fine", 5, 7)]))
    assert [t.name for t in PlateTemplateStore(settings).templates] == ["Fine"]


def test_add_and_look_up_by_shape(store: PlateTemplateStore):
    added = store.add("Chamber slide", 2, 4)
    assert added is not None and added.name == "Chamber slide"
    assert store.display_name(2, 4) == "Chamber slide"
    assert store.display_name(PlateFormat(2, 4)) == "Chamber slide"
    assert store.template_matching(2, 4).name == "Chamber slide"
    assert store.template_matching(PlateFormat(2, 4)) == added
    assert store.template_matching(4, 2) is None
    assert store.detailed_name(2, 4) == "Chamber slide  (2×4)"


def test_standard_formats_are_never_renamed_by_a_template(store: PlateTemplateStore):
    store.add("My 96", 8, 12)
    assert store.display_name(8, 12) == "96-well", "a standard plate should keep its standard name"
    assert store.detailed_name(8, 12) == "96-well  (8×12)"


def test_unknown_shape_falls_back_to_the_well_count(store: PlateTemplateStore):
    assert store.display_name(5, 7) == "35-well"
    assert store.detailed_name(5, 7) == "35-well  (5×7)"
    assert store.detailed_name(5, 7) == PlateFormat(5, 7).detailed_name


def test_names_are_made_unique(store: PlateTemplateStore):
    # Two different non-standard shapes, so both are saved.
    store.add("Slide", 2, 4)
    store.add("Slide", 2, 5)
    store.add("slide", 2, 6)
    store.add("Slide 2", 2, 7)
    assert [t.name for t in store.templates] == ["Slide", "Slide 2", "slide 3", "Slide 2 2"]


def test_empty_name_gets_a_descriptive_fallback(store: PlateTemplateStore):
    store.add("   ", 5, 7)
    assert store.templates[0].name == "5×7 plate"
    store.add("", 5, 8)
    assert store.templates[1].name == "5×8 plate"


def test_rename_remove_and_persistence(store: PlateTemplateStore, settings: QSettings, ini: Path):
    template = store.add("Strip", 1, 8)
    assert template is not None
    store.rename(template.id, "8-strip")
    assert store.templates[0].name == "8-strip"
    assert store.templates[0].id == template.id

    # A second store over the same settings must see the saved list.
    reloaded = PlateTemplateStore(settings)
    assert reloaded.templates[0].name == "8-strip"

    # And so must one parsed from the file on disk (Qt's in-process cache bypassed).
    copy = ini.with_name("templates-copy.ini")
    shutil.copy(ini, copy)
    from_disk = PlateTemplateStore(QSettings(str(copy), QSettings.Format.IniFormat))
    assert [(t.name, t.rows, t.cols) for t in from_disk.templates] == [("8-strip", 1, 8)]

    store.remove(template.id)
    assert store.templates == []
    assert PlateTemplateStore(settings).templates == []


def test_rename_ignores_blank_names_and_unknown_ids(store: PlateTemplateStore):
    template = store.add("Strip", 1, 8)
    counter = Counter(store.changed)
    store.rename(template.id, "  ")
    store.rename(template.id, "\t")
    store.rename(_fresh_id(), "Ghost")
    assert store.templates[0].name == "Strip"
    assert counter.count == 0
    store.rename(template.id, "  Trimmed  ")
    assert store.templates[0].name == "Trimmed"
    assert counter.count == 1


def test_changed_fires_on_real_writes_only(store: PlateTemplateStore):
    counter = Counter(store.changed)
    assert store.add("My 96", 8, 12) is None
    assert counter.count == 0
    template = store.add("Slide", 2, 4)
    assert counter.count == 1
    store.add("Again", 2, 4)
    assert counter.count == 1
    store.rename(template.id, "Slide")  # same name
    assert counter.count == 1
    store.remove(_fresh_id())
    assert counter.count == 1
    store.remove(template.id)
    assert counter.count == 2


def test_insertion_order_is_kept(store: PlateTemplateStore, settings: QSettings):
    store.add("Zebra", 2, 4)
    store.add("Apple", 2, 5)
    store.add("Mango", 2, 6)
    assert [t.name for t in store.templates] == ["Zebra", "Apple", "Mango"]
    assert [t.name for t in PlateTemplateStore(settings).templates] == ["Zebra", "Apple", "Mango"]


# -- LayoutTemplateStore ----------------------------------------------------------------


def _layout_api():
    """The real codec when it exists; otherwise a tiny duck-typed stand-in so these
    tests still exercise the store's file handling."""
    try:
        from playout.model import layout as mod

        if all(hasattr(mod, n) for n in ("Layout", "dumps", "loads")) and hasattr(mod.Layout, "starter"):
            return mod, True
    except ImportError:
        pass

    class _FakeLayout:
        def __init__(self, tag: str = "starter") -> None:
            self.tag = tag

        def __eq__(self, other) -> bool:
            return isinstance(other, _FakeLayout) and other.tag == self.tag

    class _FakeModule:
        Layout = _FakeLayout

        @staticmethod
        def dumps(layout) -> str:
            return json.dumps({"tag": layout.tag})

        @staticmethod
        def loads(text: str):
            return _FakeLayout(json.loads(text)["tag"])

    _FakeLayout.starter = classmethod(lambda cls: cls("starter"))
    return _FakeModule, False


@pytest.fixture
def layout_api(monkeypatch):
    mod, real = _layout_api()
    if not real:
        monkeypatch.setattr("playout.model.templates._layout_module", lambda: mod)
    return mod, real


def _renamed_first_factor(api, layout, name: str):
    mod, real = api
    if not real:
        return type(layout)(name)
    factor = dataclasses.replace(layout.factors[0], name=name)
    return dataclasses.replace(layout, factors=(factor,) + tuple(layout.factors[1:]))


def _first_factor_name(api, layout) -> str:
    mod, real = api
    return layout.factors[0].name if real else layout.tag


@pytest.fixture
def directory(tmp_path: Path) -> Path:
    return tmp_path / "Templates"


@pytest.fixture
def layout_store(directory: Path) -> LayoutTemplateStore:
    return LayoutTemplateStore(directory)


def test_a_missing_directory_is_simply_empty(layout_store: LayoutTemplateStore, directory: Path):
    assert not directory.exists()
    assert layout_store.templates == []
    assert layout_store.directory == directory


def test_saving_lists_and_reading_back(layout_store: LayoutTemplateStore, layout_api, directory: Path):
    mod, _ = layout_api
    layout = _renamed_first_factor(layout_api, mod.Layout.starter(), "Drug")
    saved = layout_store.save(layout, "IC50 setup")

    assert [t.name for t in layout_store.templates] == ["IC50 setup"]
    assert saved == layout_store.templates[0]
    assert layout_store.templates[0].path == directory / "IC50 setup.plate"
    decoded = mod.loads((directory / "IC50 setup.plate").read_text(encoding="utf-8"))
    assert _first_factor_name(layout_api, decoded) == "Drug"
    assert _first_factor_name(layout_api, layout_store.load(layout_store.templates[0])) == "Drug"


def test_saving_under_the_same_name_replaces(layout_store: LayoutTemplateStore, layout_api):
    mod, _ = layout_api
    layout_store.save(mod.Layout.starter(), "Base")
    second = _renamed_first_factor(layout_api, mod.Layout.starter(), "Replaced")
    layout_store.save(second, "Base")

    assert len(layout_store.templates) == 1
    assert _first_factor_name(layout_api, layout_store.load(layout_store.templates[0])) == "Replaced"


def test_a_name_that_sanitises_to_nothing_saves_nothing(layout_store: LayoutTemplateStore, layout_api, directory: Path):
    mod, _ = layout_api
    assert layout_store.save(mod.Layout.starter(), "...") is None
    assert layout_store.save(mod.Layout.starter(), "   ") is None
    assert layout_store.templates == []
    assert not directory.exists()


def test_the_file_name_is_the_sanitised_name(layout_store: LayoutTemplateStore, layout_api, directory: Path):
    mod, _ = layout_api
    saved = layout_store.save(mod.Layout.starter(), "  A/B: run 2  ")
    assert saved.name == "A-B- run 2"
    assert (directory / "A-B- run 2.plate").is_file()


def test_delete_removes_the_file(layout_store: LayoutTemplateStore, layout_api, directory: Path):
    mod, _ = layout_api
    layout_store.save(mod.Layout.starter(), "Doomed")
    counter = Counter(layout_store.changed)
    layout_store.delete(layout_store.templates[0])
    assert layout_store.templates == []
    assert not (directory / "Doomed.plate").exists()
    assert counter.count == 1
    # Deleting something already gone is quiet.
    layout_store.delete(LayoutTemplateStore.Template("Gone", directory / "Gone.plate"))


def test_listing_ignores_other_files_and_sorts_naturally(layout_store: LayoutTemplateStore, directory: Path):
    directory.mkdir(parents=True)
    for name in ("plate 10.plate", "Plate 2.plate", "apple.plate", "Banana.plate", "notes.txt", "x.plate.bak"):
        (directory / name).write_text("{}", encoding="utf-8")
    (directory / "sub.plate").mkdir()
    layout_store.refresh()
    assert [t.name for t in layout_store.templates] == ["apple", "Banana", "Plate 2", "plate 10"]


def test_names_are_sanitised_into_file_names():
    sanitized = LayoutTemplateStore.sanitized
    assert sanitized("  A/B: run 2  ") == "A-B- run 2"
    assert sanitized("a/b:c") == "a-b-c"
    assert sanitized("  x  ") == "x"
    assert sanitized("...") == ""
    assert sanitized("   ") == ""
    assert sanitized("\n .hidden. \n") == "hidden"
    assert sanitized("plain") == "plain"
