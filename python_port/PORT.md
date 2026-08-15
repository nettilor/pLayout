# pLayout — Python/PySide6 port: the port document

This is the working document for `python_port/`: what the port has to do, how it stays
byte-compatible with the Mac app's `.plate` files, how it is built, and where we are.
**Read this before touching anything in `python_port/`.** `PARITY.md` next to it is the
feature-by-feature checklist; `README.md` is for people who just want to run or build it.

The Mac app in `Sources/` stays the primary line of development. This port follows it;
every module names the Swift file it mirrors so a Mac change maps mechanically onto a
port change. Sections 4–11 below are the specification and were derived from the Swift
sources and their tests on Aug 14 2026 (Mac version 1.4, 1.5 in progress).

## Progress log

| Date | Milestone | State |
|---|---|---|
| 2026-08-14 | M0 — documents, scaffold, venv, fixtures | ✅ |
| 2026-08-15 | M1 — model layer + codec + palette + preferences/templates | ✅ 3 Mac fixtures round-trip; palette bit-exact vs AppKit; Mac `LayoutCompatibilityTests` decodes the port-written fixtures |
| 2026-08-15 | M2 — editor core (PlateDocument, PlateEditor, WellRange, PlateGeometry, TSV/CSV) | ✅ 424 tests green (`pytest -q`) |
| 2026-08-15 | M3 — usable app: window, canvas (paint/select/keys/zoom/rotate), sidebar, plate tabs, status row, full menu tree + toolbar, open/save/save-as/recent/autosave, Custom Plate Size dialog, all four display modes drawn | ✅ 529 tests green; `python -m playout file.plate` runs |
| 2026-08-15 | M4 — exports: Excel workbook (openpyxl; both arrangements, scope, one-cell map, Legend with plate notes, light text on dark fills), tidy CSV, PNG, vector PDF, print (fit one page) + workbook options dialog | ✅ 545 tests green |
| 2026-08-15 | M5 — Series Fill sheet, XY Position Fill sheet, Saved States popover (note dialog + layout-template menus were already wired in M3) | ✅ 551 tests green |
| 2026-08-15 | M6 — colour grid popover (three families, shades, current outline, already-used dot, Custom…) on every swatch; Settings dialog (Display / Colours / Plate Text tabs, live preview, Restore Defaults) | ✅ 555 tests green |
| 2026-08-15 | Visual pass — compact unified toolbar (18 px glyphs at 1×/2×/3×), grey sidebar panel vs white workspace, segmented controls, chip plate tabs, darker secondary text, sheets sized to content (flow-wrapped previews), Settings tabs scroll instead of clipping | ✅ |
| 2026-08-15 | M7 — Windows packaging: `packaging/playout.spec` (onedir, windowed, own icon, essentials-only Qt), `launcher.py`, `build_windows.md`, `inno.iss` (per-user installer + `.plate` association), `.ico`/`.png` from the Mac icon, crash log + taskbar identity + window icon in `app.py`; spec validated by a macOS PyInstaller build (81 MB, runs) | ✅ — the Windows build itself is done by Lorenzo on a Windows machine |

### State of play after M2 (read this before starting M3)

What exists and is tested (`python_port/tests`, 424 tests):
- `playout/model/`: `plate_format.py` (formats, `WellNaming`), `layout.py` (all types, codec, every Layout/Plate mutation as pure functions), `palette.py` (bit-exact vs AppKit, incl. its own HSV to match `NSColor`), `preferences.py` (QSettings Ini, `Preferences.shared()`), `templates.py` (plate-size + layout templates).
- `playout/editor/`: `well_range.py`, `document.py` (`PlateDocument`: `mutate`, `QUndoStack`, save/open/autosave/`QSaveFile`), `plate_editor.py` (**every** operation of PORT.md §C0–C20; headless — UI hooks are `editor.confirm`, `editor.clipboard`, `editor.window_title_provider`, and the signals `state_changed`, `layout_changed`, `flash_message`, `zoom_requested/zoom_changed`, `focus_canvas_requested`, `sheet_requested("series"|"xy")`, `note_sheet_requested(NoteTarget)`, `error_presented`).
- `playout/ui/plate_geometry.py` (Qt-free `PlateGeometry.fit(fmt, Rect, turns)`, matches the pinned cell sizes; hit-testing, rotation mapping).
- `playout/io/table_io.py` (TSV/CSV parse/serialize, plate-header stripping). Tidy grid + workbook are M4.
- Cross-compat: `tests/fixtures/*.plate` (Mac-written) round-trip in the port; `tests/fixtures/port_written/*.plate` (port-written) are decoded by the Mac suite (`swift test --filter LayoutCompatibilityTests`, test added in `Tests/PLayoutTests/NewFeatureTests.swift`).

Deviations / decisions taken while implementing (all deliberate; revisit if wrong):
- `Preferences.reset_to_defaults()` resets the nine display keys only (as Swift), leaving the remembered workbook-export choices.
- Plate-size templates keep insertion order (Swift does not sort them either); one malformed stored template is skipped instead of losing the whole list.
- The flash strings say `⌘Z` on macOS and `Ctrl+Z` elsewhere (`plate_editor.UNDO_KEY`); everything else is the Mac string verbatim.
- `PlateEditor.delete_plate` / `delete_factor`: as on the Mac, the reconcile pass (which runs synchronously inside the edit) is what picks the new active plate/factor (the first one); the trailing fallback code in Swift is effectively dead and is mirrored as such.
- A correctly sized all-null assignment column found in a file is kept on decode (Swift only prunes columns it had to resize); it is pruned on the first write to it.
- Wrong-typed values for optional Layout keys are decode errors (Swift `decodeIfPresent` throws on type mismatch); absent or `null` take the default.
- `LayoutSnapshot.saved_at` is stored as the file's own Apple-epoch float, never converted, so round trips cannot move it.

State after M3 (Aug 15 2026): `ui/` is complete for the window shell — `plate_renderer.py`
(one `render_scene()` for screen/export, every mode incl. the factor stack, stripe, line key,
corner arrow), `plate_canvas.py` (`PlateCanvas` + `PlateScrollArea` owning zoom), `sidebar.py`
+ `controls.py`, `plate_tabs.py`, `status_bar.py`, `main_window.py` (menus A1, toolbar A2 with
`icons.py` glyphs, open/save/save-as/recent, "— Edited" title, close prompts), `sheets/
custom_format.py`, `sheets/shortcuts_card.py`; `app.py` (`App`: windows, recent files,
FileOpen events, argv). Series Fill / XY / Saved States / exports / Print / Preferences flash
"… arrives in a later build." M3 deviations: the swatch opens `QColorDialog` until the colour
grid arrives (M6); a "Rename…" item was added to the row context menus (Qt has no timed
second-click; double-click also renames). Screenshotting the port on this Mac:
the local screenshot harness takes the window owner from an environment variable (the venv process shows as `python`) — see HANDOFF.md §6.

M7 notes: `packaging/build_windows.bat` (double-click) → `build_windows.ps1` does the whole Windows build (Python check → venv → install → tests → PyInstaller → zip → Inno installer if ISCC.exe is present; `-SkipTests`, `-Clean`); build/dist go under `python_port/build` and `python_port/dist` (both gitignored); `playout.resources` is package data (pyproject) and PyInstaller `datas`; `app.resource_path()` resolves both from source and frozen; the crash log lands in the AppData folder. M6 notes: `ui/colour_grid.py` (`ColourGridPopover`, `show_colour_grid(anchor, current, used, on_pick)`; the sidebar scopes `used` to the factor, or the document under never-repeat), `ui/sheets/preferences_dialog.py` (`PreferencesDialog`, one instance per `App`; `WellPreview` paints the five sample wells). No placeholders remain in the window. M5 notes: `ui/sheets/series_fill.py` (`SeriesFillDialog`, live chip preview from `editor.series_values` + `palette.ramp`; number fields parse C-locale like Swift), `ui/sheets/xy_fill.py` (`XYFillDialog`; gradient swatch opens the system colour dialog until M6), `ui/sheets/saved_states.py` (`SavedStatesPopover`, a Popup under the toolbar clock button; rows rebuild on every editor signal). Remaining placeholder: Preferences… (M6). M4 notes: `io/table_io.py` holds `tidy_grid`, `workbook_sheets`/`build_workbook`/`workbook_bytes` (openpyxl; the sheet model `Cell`/`Sheet` mirrors the Swift `XLSX.Cell/Sheet`; strings are forced to `data_type="s"` so a name starting with "=" is never a formula), `io/plate_image.py` renders the export scene to PNG (`QImage` × device pixel ratio), vector PDF (`QPdfWriter`, page = plate size in points) and a `QPrinter` page (landscape iff wider, 24 pt margins, scaled to fit); `ui/sheets/workbook_options.py` asks arrangement / one-cell map / scope *before* the save dialog and remembers them in Preferences. Originally planned as: `io/table_io.py` gains `tidy_grid` + `Exporter.workbook` (openpyxl, PORT.md
§A6), `io/plate_image.py` renders `canvas.export_scene()` through `render_scene` into a
`QImage`/`QPdfWriter`/`QPrinter`; replace the `_later(...)` placeholders in `main_window.py`
with save dialogs. How to start M3 (kept for reference): build `ui/main_window.py` around one `PlateEditor` per window; connect widgets only to editor signals; the canvas takes a `PlateGeometry.fit(format, Rect(0,0,w/zoom,h/zoom), editor.quarter_turns)`; every mouse/key branch is already specified in §C18/§D3 and its editor call exists.

Commands (from `python_port/`):

```sh
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"   # once
.venv/bin/pytest -q                                          # all tests, headless
.venv/bin/python -m playout [file.plate]                     # run the app
```

---


## Context

pLayout is a native macOS (Swift/SwiftUI/AppKit) editor for microplate layouts. Windows
users have asked for it. Mac stays the primary line of development; a Python/PySide6
port in `python_port/` will give Windows users a local desktop app with **functional
parity** (same commands, buttons in similar positions, same shortcuts where the platform
allows, same `.plate` files and identical export outputs). Visual polish (toolbar
islands, exact typography) is explicitly *not* required to match.

The immediate deliverable is **a full, execution-ready port document** in the repo —
feature inventory, `.plate` compatibility contract, architecture, milestones, tests,
packaging — foolproof enough that future sessions (and Lorenzo on a Windows machine)
can execute from it without rediscovering anything. Code scaffolding follows the doc.

## Decisions already agreed with Lorenzo (this session)

- Python + **PySide6 (Qt 6)**; Tkinter ruled out (no proper canvas/undo/menus feel).
- Lives in **`python_port/`** in this same repo (shared `.plate` fixtures, one format
  contract); Mac development continues; the port is re-synced periodically.
- Lorenzo compiles/distributes the Windows build himself on a Windows machine
  (PyInstaller cannot cross-compile; that is accepted). Dev + tests happen on this Mac
  (PySide6 runs on macOS; Qt is cross-platform).
- Parity = **functionality**, not looks. Same buttons in similar positions is enough.
- All hard rules in CLAUDE.md apply unchanged: never push, no AI attribution, don't
  commit HANDOFF/CLAUDE/.claude/feature_list/Tools/ship_release.sh, run the
  personal-info scan before staging.

## Decisions from this planning round (Lorenzo, Aug 14 2026)
- **First execution session delivers M0 + M1 + M2**: PORT.md/PARITY.md/README + scaffold + venv + fixtures, the Qt-free model layer (codec, formats, palette, preferences, templates) with round-trip tests green, and the editor core (PlateDocument + PlateEditor with all C0–C20 operations) with the ported logic tests green — no UI yet.
- **One `QMainWindow` per document** (Mac parity); quit when the last window closes.
- **No update checker in v1** (⛔ in PARITY.md; may return in M7 against a Windows asset).
- Settled by me (state in PORT.md, no need to re-ask): "Revert to Saved" is dropped (meaningless with autosave-in-place, ⛔); the C20 quirks (paste ignores custom wells etc.) are **reproduced verbatim** and listed in PARITY.md "Known quirks — fix on the Mac first, then port"; Preferences on Windows under Edit → Preferences… (Ctrl+,); the Qt build on this Mac uses Qt's default AppData paths (`~/.config/nettilor/pLayout.ini`, `…/nettilor/pLayout/Templates`), not the native app's folders; ids are `str`; deps `PySide6-Essentials`.

## First execution session — step by step (M0 → M1 → M2)
1. `.gitignore` additions (repo root) as listed under Repo structure; verify with `git status` that only intended files show.
2. Create `python_port/` skeleton: `pyproject.toml`, `playout/` packages with docstring-stubbed modules, `tests/conftest.py`, `tests/test_smoke.py`, copy the three fixtures with `git add -f` later (no commits unless Lorenzo asks — leave everything staged/unstaged as he prefers; commit locally only if he says so).
3. `python3 -m venv python_port/.venv && python_port/.venv/bin/pip install -e "python_port[dev]"` (network; PySide6-Essentials, openpyxl, pytest, pytest-qt). Confirm `QT_QPA_PLATFORM=offscreen pytest` runs the smoke test.
4. Write `python_port/PORT.md` from this plan (sections verbatim where marked) and `PARITY.md` (tables per README section, all ⏳ except what M1/M2 complete), `README.md`.
5. **M1**: `model/plate_format.py` → `model/palette.py` → `model/layout.py` (+codec) → `model/preferences.py` → `model/templates.py`; tests: `test_well_naming.py`, `test_palette.py` (shade table for all 28 hues, ramp samples, firstColor ladder, no-white-flip, families), `test_layout_codec.py` (three fixtures decode + re-encode value-equal, defaults, unknown keys at every level, retired keys, ragged columns, clamp, Apple epoch, UUID case, snapshot adoption, snapshots don't nest), `test_plate_model.py` (set/get, pruning, resize (row,col), lossy shrink, ensure_level, remove_level/factor, notes), `test_preferences.py`, `test_templates.py`. Also write 3–4 port-written fixtures into `tests/fixtures/port_written/` and open one in `build/pLayout.app` to confirm the Mac reads it (visual check + a Swift `LayoutCompatibilityTests` case decoding that folder — small Swift-side addition, run `swift test --filter LayoutCompatibilityTests`).
6. **M2**: `editor/well_range.py` → `editor/document.py` (QUndoStack, mutate, save/load, autosave timer, dirty) → `editor/plate_editor.py` in Swift section order; tests: `test_well_range.py`, `test_document.py` (no-op mutate, undo/redo, clean state, save/load), `test_editor_*.py` ported from CoreTests.EditorTests/SeriesTests, SavedStateTests, PerPlateStateTests, NotesTests, XYFillTests (model half incl. turned plate), OverviewModeTests (model half), OrientationTests (model half), SidebarMultiSelectTests, CustomFormatFlowTests, SelectionInteraction rules that are editor-level (toggle/add/collapse), clipboard copy/paste/header-strip via `io/table_io.py` (pure part; QClipboard behind an injectable interface).
7. Report: pytest count green, which PARITY rows moved to ✅, what is deferred to M3+ (all UI, IO exports, packaging), and the exact commands to re-run.

## Environment on this Mac (checked)

- `python3` = Anaconda 3.12.2 (`/opt/anaconda3/bin/python3`); `openpyxl 3.1.5` present;
  **PySide6 not installed** → execution creates `python_port/.venv` (from the Anaconda
  python is fine on this Mac; Windows builds use python.org 3.12) and installs
  `PySide6-Essentials`, `openpyxl`, `pytest`, `pytest-qt` (network install; one-time).
- `.gitignore` ignores `*.plate`, `*.csv`, `*.xlsx` globally and `build/` anywhere;
  port fixtures need `!python_port/tests/fixtures/**/*.plate` (and `.csv`) exceptions
  added to `.gitignore`, plus the venv/cache ignores listed under Repo structure.
- Real Mac-written fixtures already exist locally: `Tools/verify/{allfactors,big384,overview}.plate`
  (gitignored dir) — to be copied into `python_port/tests/fixtures/` (force-added).

## Repo structure (to create in M0)

```
python_port/
  PORT.md                 ← THE port document (this plan's spec sections verbatim + architecture), committed
  PARITY.md               ← feature-by-feature checklist Mac ⇄ port, updated on every sync
  README.md               ← run from source (venv, `python -m playout [file.plate]`), tests, pointer to packaging/
  pyproject.toml          ← setuptools; name "playout", version "1.4.0" (PEP 440; MAC_VERSION="1.4" in __init__),
                             requires-python >=3.11, deps PySide6-Essentials>=6.7,<7 + openpyxl>=3.1,<4;
                             dev = pytest>=8, pytest-qt>=4.4; [project.scripts] playout = "playout.app:main";
                             [tool.pytest.ini_options] testpaths=["tests"], qt_api="pyside6"
  playout/
    __init__.py (__version__, MAC_VERSION)   __main__.py   app.py (main(): names, HiDPI, excepthook, App = window registry, opens argv files)
    model/    layout.py  plate_format.py  palette.py  preferences.py  templates.py      ← Qt-free except preferences/templates (QtCore only)
    editor/   document.py (PlateDocument: layout, path, QUndoStack, mutate, save/load/autosave)
              plate_editor.py (ALL operations, reconcile)  well_range.py (WellPos, WellRange)
    io/       table_io.py  xlsx_writer.py (openpyxl)  plate_image.py (PNG/PDF/print)
    ui/       main_window.py  plate_geometry.py (Qt-free, tiny Rect namedtuple)  plate_renderer.py (one render() for screen/PNG/PDF/print)
              plate_canvas.py (QWidget + PlateScrollArea subclass owning zoom)  sidebar.py  plate_tabs.py  status_bar.py  colour_grid.py  fonts.py
              sheets/ custom_format.py series_fill.py xy_fill.py note.py saved_states.py workbook_options.py preferences_dialog.py shortcuts_card.py
    resources/ .gitkeep (icon.ico/png in M7)
  tests/     conftest.py  test_smoke.py  fixtures/{allfactors,big384,overview}.plate (force-added)  fixtures/port_written/.gitkeep
  packaging/ (M7) playout.spec (onedir, console=False), launcher.py, build_windows.md, optional inno.iss
```
Each module's docstring names the Swift file it mirrors (see Module map) so syncs are mechanical.
`.gitignore` additions (repo root): `python_port/.venv/`, `python_port/dist/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`, `*.egg-info/`, `!python_port/tests/fixtures/**/*.plate`, `!python_port/tests/fixtures/**/*.csv` (`build/` already covered).

## Architecture of the port (mirrors the Mac app; verdicts validated by the architecture review, measured where noted)

- **Model = frozen dataclasses** (`@dataclass(frozen=True, slots=True)`) for Level/Factor/Plate/PlateFormat/LayoutSnapshot/Layout/WellPos/WellRange; sequences as `tuple`; `assignments: dict[str, tuple[str|None, ...]]` (never mutated; `field(hash=False)`). Every Swift `mutating func` keeps its snake_case name but **returns a new value** (`plate.set_level_id(...) -> Plate`) — aliasing into undo snapshots impossible, sync grep-mechanical. Measured (1536×10 doc + 20 states): frozen one-well edit + equality **0.016 ms**; `copy.deepcopy` per edit **55 ms** → mutable+deepcopy rejected. Equality is cheap because untouched sub-objects are the *same objects*. IDs are upper-case `str` everywhere (`parse_id()` validates via `uuid.UUID`, uppercases on read). `saved_at` is an aware UTC `datetime`, converted to Apple epoch only in the codec. Batch `set_level_ids(factor_id, {well: level})` so a 300-well paint copies each column once. No numpy.
- **Codec** hand-written `layout_from_json/layout_to_json` with defaults for every absent key, tolerance of unknown keys, post-decode normalisation; `dumps(indent=2, sort_keys=True, ensure_ascii=False, separators=(',', ' : '))`.
- **Undo = `PySide6.QtGui.QUndoStack`** (Qt 6 location) of `_LayoutCommand(prev, new)`; unlimited (default `undoLimit()==0`, like the Mac); never override `mergeWith`/`id` (one command per action); `push()` calls `redo()` synchronously → that installs the new layout. `createUndoAction/createRedoAction` give live "Undo Paint Wells" text; `setClean/cleanChanged` drive the "— Edited" title. Memory: structural sharing → a paint step retains ~12 KB (one 1536 column) → 200 steps ≈ 2–5 MB.
- **Single mutation choke point:** `PlateDocument.mutate(name, fn: Layout -> Layout) -> bool`: `new == old` → no-op (no command, no signal); else push command. Document sets `_layout = new` **then** emits `layout_changed(new)` (no willSet trap possible).
- **`PlateEditor(QObject)`** with signals `state_changed`, `layout_changed`, `flash_message`, `zoom_changed`, `focus_canvas_requested`, `sheet_requested`. **Routing rule: views never connect to the document; only to the editor**, which emits after `reconcile_targets(new)` + `refresh_saved_state_match` — guarantees reconcile runs before any view reads. Reconcile writes fields silently, one `state_changed` at the end. `preferences.changed → editor.state_changed` so canvases repaint.
- **`PlateGeometry` (Qt-free) owns all geometry incl. rotation, unmagnified.** Zoom lives in the painter/scroll area, **not** in the geometry.
- **Canvas = custom `QWidget` inside a `PlateScrollArea(QScrollArea)` subclass that owns `zoom`** (not QGraphicsView: 1:1 port of render/mouse handling; tests send events to the widget itself). On `resizeEvent` scroll area sets `canvas.resize(viewport.size()*zoom)`; canvas paints with `painter.scale(zoom)` and builds geometry from `size()/zoom`; hit-testing divides by zoom; dirty-rect clip = `event.rect()/zoom`. Zoom about visible centre: compute centre/zoom before, set scrollbars after. Focus: canvas `StrongFocus`, scroll area `NoFocus` + `setFocusProxy(canvas)`; canvas handles Tab/Backtab in `event()`; `setMouseTracking(True)`; `leaveEvent` = mouseExited.
- **One renderer** `render(painter, scene: RenderScene, bounds)` in `ui/plate_renderer.py` (widget-free); `RenderScene` = layout/plate/mode/prefs snapshot/quarter_turns + screen-only state (selection, custom wells, hover, hovering corner, spotlight) + `export_mode` + a `Colors` struct (screen from `widget.palette()`, export = fixed light constants). PNG: `QImage(w*dpr,h*dpr, ARGB32_Premultiplied)`, `setDevicePixelRatio`, white fill, render at unmagnified viewport size. PDF: `QPdfWriter` resolution 72, page size = (w,h) Points, zero margins. Print: `QPrinter(HighResolution)`, `QPrintDialog`, landscape iff w≥h, 24 pt margins, scale to fit, centre; headless test via `setOutputFormat(PdfFormat)`.
- **Preferences = `QSettings(IniFormat, UserScope, "nettilor", "pLayout")`** (Windows `%APPDATA%\nettilor\pLayout.ini`; macOS `~/.config/nettilor/pLayout.ini`). NativeFormat rejected (registry on Windows; on this Mac would collide with the native app's `com.nettilor.playout` domain). `Preferences(QObject)` singleton with `changed` signal, injectable QSettings for tests; coercion helpers because Ini round-trips values as strings. Font factory / empty-well fill resolver live in `ui/fonts.py` & renderer.
- **Templates**: plate-size templates as JSON string in QSettings; layout templates as `.plate` files under `QStandardPaths.AppDataLocation/Templates` (injectable dir).
- **Autosave in place**: 2 s debounce restarted per `layout_changed`, only when `path` set; flush on `WindowDeactivate`, `closeEvent`, `aboutToQuit`; `QSaveFile` (commit failure → keep dirty, warn once); `setClean()` after each successful save; title `"{stem} — Edited"` from `cleanChanged` + `setWindowModified`; untitled → Save/Don't Save/Cancel on close.
- **Windows: one `QMainWindow` per document** (Mac parity; New from Template / Duplicate / side-by-side). `App` object holds window list, shared singletons (Preferences dialog, template stores, recent files); Open reuses the front window only if untitled & clean; `setQuitOnLastWindowClosed(True)` on both platforms.
- **XLSX via openpyxl 3.1** (probed): aRGB fills `"FF5889BC"`, `Font(bold, color)`, thin `Border(Side(color="FFD0D0D0"))`, `Alignment(center,center)`, `freeze_panes`, `column_dimensions[...].width`, styled blank cells written. We sanitise + 31-truncate + " (2)" de-dupe **before** openpyxl (its own de-dupe/warnings would differ); strings starting with `=` → set `cell.data_type = "s"`; integral floats as `int`; remove default "Sheet"; test by re-opening (bytes non-deterministic).
- **i18n none**; strings hard-coded exactly as Mac; shortcuts card renders via `QKeySequence.toString(NativeText)` (⌘ on Mac, Ctrl on Windows).

## Qt/Python pitfalls (go into PORT.md §12, each with its mitigation)
1. Signals + dataclasses: `Signal(object)`; QObject subclasses call `super().__init__()` first; keep slot owners long-lived; scoped enums; `event.position()`.
2. `QColorDialog.getColor(initial, parent, title)` default options (no alpha); `color.name(HexRgb).upper()`.
3. Keys: special keys by `event.key()`; printable `[ ] 0-9 f` by `event.text()` (layout-independent = Mac `charactersIgnoringModifiers`); mask KeypadModifier; bail on Ctrl **unless Alt also down** (AltGr).
4. Ctrl+wheel: `wheelEvent` on the scroll-area subclass (zoom by `1.4**(angleDelta.y()/120)`), inner canvas ignores wheels; `QNativeGestureEvent.ZoomNativeGesture` for trackpad pinch on Mac.
5. Undo menu text via `createUndoAction/createRedoAction`; Redo shortcuts explicitly `["Ctrl+Shift+Z","Ctrl+Y"]`; QLineEdit keeps its own Ctrl+Z/C/V/Backspace via ShortcutOverride.
6. QSettings Ini returns strings after reload → `_bool/_float/_str/_enum` coercion; structured values as JSON strings; test = write, `sync()`, reopen.
7. Fonts: `QFontDatabase.families()` static; filter `.`/`@` names; None → `QApplication.font().family()`; semibold = `QFont.Weight.DemiBold`; cache `QFontMetricsF`.
8. HiDPI: screen automatic; PNG needs `QImage(size*dpr)+setDevicePixelRatio`.
9. Dark mode: read `palette()` roles (`Accent` on ≥6.6 with `Highlight` fallback); `styleHints().colorScheme()` only for the Preferences preview; export uses fixed light Colors.
10. pytest-qt: `os.environ.setdefault("QT_QPA_PLATFORM","offscreen")` at top of conftest before PySide6 imports; `qt_api="pyside6"`; drags via a `drag(widget,p0,p1,modifiers)` helper sending explicit 7-arg `QMouseEvent`s (`QTest.mouseMove` doesn't reliably carry buttons); `QTest.keyClick` for `[`/`]`; `widget.grab()` for pixel assertions of fills/geometry only, never text pixels.
11. PyInstaller: no `--collect-all PySide6`; import only QtCore/QtGui/QtWidgets/QtPrintSupport(+QtSvg); `.spec` console=False onedir; `packaging/launcher.py` (entry points unusable); python.org 3.12 venv, never Anaconda; `sys.excepthook` → log under AppDataLocation + QMessageBox; `PySide6-Essentials` not full PySide6.
12. `.plate` association: Inno Setup HKCU only; app opens `sys.argv[1:]` and handles `QFileOpenEvent` on Mac; no single-instance (same file twice = two autosavers — accepted, or `QLockFile` later).
13. Names: `setOrganizationName("nettilor")`, `setApplicationName("pLayout")`, `setApplicationDisplayName("pLayout")` before any QSettings; explicit menu roles (Preferences/About/Quit) + `StandardKey.Preferences` **and** "Ctrl+,".
14. Screenshot harness on this Mac: Qt window owner will be `python`/`Python`/`python3.12` — check via `Quartz.CGWindowListCopyWindowInfo`; make `Tools/verify/shot.py` read the window owner name from an environment variable with fallback to `kCGWindowName` containing "pLayout" (Tools/verify is gitignored, edit is safe; record in HANDOFF).
15. On this Mac Ctrl-sequences mean ⌘ — good for parity testing.
16. Locale: `float()`/`"%.*g"` are C-locale (matches Swift); avoid `QDoubleSpinBox` for series values or `setLocale(QLocale.c())`.
17. Factor submenu rebuilt on every `layout_changed`; `menu.clear()` (else duplicate Ctrl+1 → ambiguous shortcut silently dead).
18. Model must be Qt-free (`model/layout.py`, `plate_format.py`, `palette.py`, `editor/well_range.py`, `ui/plate_geometry.py`) — fast pure pytest; `colorsys` for HSV.

## Module map (python ↔ Swift; names only)
- `model/layout.py` [Layout.swift]: `new_id`, `parse_id`, `APPLE_EPOCH`, `LayoutDecodeError`; `FactorKind`, `WellLabelMode` (`label`, `short_label`, `shows_text`, `stacks_every_factor`, `is_overview`, `lenient(raw)`), `PlateOrientation.quarter_turns(fmt)`; `Level`; `Factor` (`display_name`, `level`, `level_named`, `index_of`, `ensure_level -> (Factor, id)`); `Plate` (`note_for`, `set_note`, `level_id`, `set_level_id`, `set_level_ids`, `assigned_well_count`, `change_format`, `format_change_would_lose_data`, `normalise_assignments`); `LayoutSnapshot` (`belongs_to`); `Layout` (`MAX_SNAPSHOTS`, `starter`, `factor`, `factor_index`, `value_name`, `with_plate`, `with_factor`, `prune_unused_levels`, `remove_level`, `remove_factor`, `snapshots_for`, `capture_snapshot -> (Layout, dropped)`, `restore_snapshot`, `_reinstate_factors`, `rename_snapshot`, `remove_snapshot`, `snapshot_matching`, `unique_factor_name`, `unique_plate_name`, `used_level_colors`); codec `layout_from_json`, `layout_to_json`, `loads`, `dumps`.
- `model/plate_format.py` [PlateFormat.swift]: `PlateFormat` (clamp in `__post_init__`, `well_count`, `name`, `detailed_name`, `is_standard`, `index/row_of/col_of/contains`, `STANDARD`, `WELL6…WELL1536`, `to_json/from_json`); `WellNaming.row_label/row_index/col_label/well_label/parse_well`.
- `model/palette.py` [Palette.swift + NSColor ext]: `CATEGORICAL`, `color_at`, `normalized`, `first_color_avoiding`, `Family` (`label`, `note`, `hues`), `shades`, `WELL_TEXT_FLOOR`, `brightness_clearing`, `matches`, `ramp`, `parse_hex`, `hex_of`, `luminance`, `contrasting_label_color`, `contrasting_shade`, HSV wrappers.
- `model/preferences.py` [Preferences.swift]: enums with `label/note`, `Preferences(QObject)` (`changed`, all props incl. workbook options, `reset_to_defaults`, `shared()`, injectable settings), coercion helpers.
- `model/templates.py` [PlateTemplate.swift, LayoutTemplateStore.swift]: `PlateTemplate`, `PlateTemplateStore(QObject)` (`changed`, `templates`, `display_name`, `detailed_name`, `template_matching`, `add`, `rename`, `remove`); `LayoutTemplateStore(QObject)` (`Template`, `refresh`, `save`, `delete`, `sanitized`, injectable dir).
- `editor/well_range.py` [WellRange.swift]: `WellPos`, `WellRange`.
- `editor/document.py` [PlateDocument.swift + DocumentGroup]: `PlateDocument(QObject)` (`layout`, `path`, `undo_stack`, `layout_changed`, `path_changed`, `dirty_changed`, `mutate -> bool`, `_replace`, `_LayoutCommand`, `load`, `save`, `save_now`, `schedule_autosave`, `is_dirty`, `revert_to_saved`, `display_name`).
- `editor/plate_editor.py` [PlateEditor.swift, same section order C0–C20]: `NoteTarget`; `PlateEditor(QObject)`.
- `ui/plate_geometry.py` [PlateGeometry in PlateCanvasView.swift]; `ui/plate_renderer.py` [render()/draw* in PlateCanvasView.swift]; `ui/plate_canvas.py` [PlateCanvasView mouse/keys + PlateScrollView]; `ui/main_window.py` [ContentView.swift + App.swift menus]; `ui/sidebar.py` [Sidebar.swift + Controls.swift]; `ui/colour_grid.py` [SwatchPicker in Controls.swift]; `ui/sheets/*` [matching *Sheet.swift / SavedStatesPopover / WorkbookLayoutAccessory / PreferencesView]; `io/table_io.py` [TableIO.swift]; `io/xlsx_writer.py` [XLSXWriter.swift + Exporter in TableIO.swift]; `io/plate_image.py` [pngData/pdfData/printPlate].

## PORT.md table of contents
0 Purpose & how to use · 1 Ground rules (CLAUDE.md hard rules; parity = function) · 2 Environment & commands · 3 Architecture (verdicts above) · 4 `.plate` contract · 5 PlateFormat & naming · 6 Palette (full shade table for all 28 hues + ramp samples) · 7 Preferences & templates · 8 UI surface A1–A5 + key-mapping table · 9 IO formats A6 · 10 Editor operations C0–C20 · 11 Canvas D1–D6 · 12 Qt/Python pitfalls · 13 Module map · 14 Test plan + fixture matrix · 15 Milestones & definition of done · 16 Windows packaging · 17 Sync process · Appendix: exact strings, undo names, shortcut table.
Verbatim from this plan: contract, naming, palette, preferences/templates, A1–A6, C0–C20, D1–D6, test plan, milestones, packaging, sync. Rewritten: context, decisions, environment, architecture.
**PARITY.md**: header (Mac version checked = 1.4→1.5, port version, date, legend ✅/🚧/⛔/⏳); one table per Shipped subsection (paraphrased from README rather than copying the uncommitted `feature_list.md` lines), columns Feature | Mac keys | Port keys | Status | Milestone | Deviation note; then "Deliberate deviations" and "Not applicable on Windows".

## Feature parity inventory — A. UI surface & IO (from `App.swift`, `ContentView.swift`, `Sidebar.swift`, sheets, `TableIO.swift`, `XLSXWriter.swift`)

Key mapping for the port: ⌘→Ctrl, ⌥→Alt, ⇧→Shift, ⌫→Backspace, ⎋→Esc, ↩→Enter.
Where Windows conventions collide (Ctrl+, for Settings is unusual → use Edit → Preferences… with Ctrl+, kept as well), keep the Mac chord as a secondary shortcut so the shortcuts card stays truthful.

### A1. Menus (`App.swift:31-205`) — port as a `QMenuBar`
- **App menu items → relocate**: *About pLayout* (Help), *Check for Updates…* + *Check for Updates Automatically* toggle (Help; optional, M7), *Settings…* (Edit → Preferences… Ctrl+,), Quit (File → Exit).
- **File**: New (Ctrl+N, 96-well starter) · Open… (Ctrl+O) · Open Recent ▸ · **New from Template ▸** (alphabetical list of layout templates; empty row "No templates yet — save one below."; each opens an *untitled duplicate*; then divider + **Remove Template ▸** same names) · **Save as Template…** (modal: title "Save as Template", one text field placeholder "Template name", Save/Cancel; same-name overwrites) · Close · Save (Ctrl+S) · Save As… (Ctrl+Shift+S) · Duplicate · Revert to saved (Mac has versions; port offers plain "Revert to Saved") · **Print Plate…** (Ctrl+P) · **Export Excel Workbook…** (Ctrl+E) · **Export Tidy CSV…** (Ctrl+Shift+E) · — · **Export Plate Image (PNG)…** · **Export Plate Image (PDF)…** · — · **Import Table…** (Ctrl+Shift+I) · Exit.
- **Edit**: Undo (Ctrl+Z) / Redo (Ctrl+Shift+Z and Ctrl+Y) — every mutation is one named undo step; Cut/Copy/Paste/Delete/Select All routed to the canvas when it has focus (text fields keep them); **Copy with Headers** (Ctrl+Shift+C — on Mac canvas-only; the port may list it in Edit); Preferences… (Ctrl+,).
- **View**: Zoom In (Ctrl++, ×1.4) · Zoom Out (Ctrl+-, ÷1.4) · Fit Plate to Window (Ctrl+0) · — · **Overview** (checkable, Ctrl+Shift+O) · **Turn Plate 90°** (checkable, Ctrl+Shift+L) · (toolbar/sidebar visibility toggles as Qt offers).
- **Plate**: Fill Selection (Ctrl+Enter) · Clear Selection (no key) · Clear All Factors in Selection (Ctrl+Backspace) · Select All Wells (no key; Ctrl+A on canvas) · Well Note… (Ctrl+Alt+N) · — · Save State (Ctrl+Alt+S) · Revert to Last Saved State (Ctrl+Alt+R) · — · Series Fill… (Ctrl+Shift+D) · XY Position Fill… (Ctrl+Shift+Y) · Randomise Selection (Ctrl+Shift+R) · — · Next Condition (Ctrl+]) · Previous Condition (Ctrl+[) · Add Condition (Ctrl+Shift+N) · — · **Factor ▸** (one item per factor in document order, **Ctrl+1…Ctrl+9 by position — the submenu must be rebuilt on every layout change**, then divider, Next Factor, Add Factor) · — · **Plate Format ▸** (same items as toolbar menu) · Custom Plate Size… · Add Plate · Duplicate Plate · — · **Text in Wells ▸** (radio: None / Active factor / All factors / Overview).
- **Window / Help**: standard; Help gets About + (optionally) update items + Shortcuts.

### A2. Toolbar (`ContentView.swift:243-370`) — `QToolBar`, left group | spacer | right group
1. **Plate Format** (grid icon, icon-only) → menu: 7 standard formats as "96-well  (8×12)" with check on current; if custom templates: divider + section "Custom" listing "{name}  ({rows}×{cols})"; divider; **Custom Size…**. Tooltip "Plate format — currently {display name}".
2. **Save State** (bookmark / bookmark-filled when the plate matches a saved state); tooltip "This layout is already saved as a state" or "Bookmark the layout as it is now… (Ctrl+Alt+S)".
3. **Saved States** (clock-arrow) → popover `SavedStatesPopover`.
   ‖ (Mac puts 1–3 in their own island; port: a `QToolBar` separator)
4. **Series Fill** (chart icon) tooltip "Fill the selection with a dilution or step series (Ctrl+Shift+D)".
5. **XY Position Fill** ("XY" glyph) tooltip "Number wells as imaging positions (Ctrl+Shift+Y)".
6. **Randomise** (shuffle) tooltip "Shuffle the assigned values within the selection".
7. **Export** (share icon) → menu: Excel Workbook… / Tidy CSV… / — / Plate Image (PNG)… / Plate Image (PDF)… / — / Import Table….
8. **Shortcuts** (keyboard icon) → popover **Shortcuts card** ("Keyboard & Mouse", 2 columns; port copies the Mac rows verbatim with Windows key names: `1 – 9, 0` Arm condition 1–10 · `[ / ]` Previous/next condition · `drag` Paint a rectangle · `Ctrl drag` Free-hand brush / adds to selection when disarmed · `Alt drag` Erase · `click A / 1` Paint a whole row or column · `space / F` Fill selection · `Backspace` Clear active factor (Ctrl+Backspace clears all) · `Ctrl click` Add/remove one well · `Shift click` Extend selection, Shift+arrows too · `Ctrl+A` Select every well · `Esc` Disarm · `click away` Deselect · `Ctrl+Shift+D` Series Fill · `Ctrl+Shift+Y` XY Fill · `Ctrl+Shift+R` Randomise · `Ctrl+Alt+N` Note · `Ctrl+1…9` Switch factor · `Ctrl click row` multi-select sidebar rows · `rest on row` Spotlight a condition · `click ↻ corner` Turn plate (Ctrl+Shift+L) · `Ctrl+Shift+O` Overview · `Ctrl+wheel` Zoom, Ctrl+0 fits · `Ctrl+C / Ctrl+V` Copy/paste as Excel cells · `Ctrl+Shift+C` Copy incl. headers · `Ctrl+P` Print · `Ctrl+Alt+S` Save state · `Ctrl+Alt+R` Revert · `Ctrl+Z` Undo incl. states).
Rule kept from Mac: toolbar buttons are never hidden/disabled; they explain themselves in tooltips/flashes.

### A3. Window layout (`ContentView.swift`, `Sidebar.swift`) — `QMainWindow`: sidebar dock/left pane (min 232) | plate tab bar (h≈34) / canvas / status bar (h≈26)
**Sidebar — "Factors" section** (footer caption "Each factor is painted separately. Wells keep a value for every factor."): row = keycap `Ctrl+{n}` (n<9, filled when active, `·` beyond) · editable name · numeric glyph if kind is numeric · trailing condition count only if Preferences.showFactorConditionCounts. Row tinted when active or multi-selected. Click = select factor (also leaves Overview) & return focus to canvas; second click within double-click interval on the same row = inline rename (Esc abandons, Enter/click-away keeps); Ctrl-click = toggle multi-select; drag row = reorder. Context menu: multi → "Delete N Factors"; else "Treat as Numeric"/"Treat as Categorical", —, "Delete Factor" (disabled when only one). Footer button "Add Factor".
**Sidebar — "{active factor}" (conditions) section**: header ⋯ menu → "Recolour from Palette", "Remove Unused Conditions". Optional **Unit** row (label "Unit", placeholder "µM, h, ng/mL…") shown when unit non-empty or factor numeric. Row = keycap `1…9`, `0` for 10th, `·` beyond · **swatch button** (14 pt circle → colour grid popover) · editable name · trailing well count on the active plate. Hover row → spotlight (plate dims all other wells). Click = arm; double-click = rename; Ctrl-click = multi-select; drag = reorder. Context menu: multi → "Delete N Conditions"; else "Fill Selection with {name}", —, "Delete Condition". Button "Add Condition". In Overview the section shows "No factor selected. Click a factor above to paint again."
**Sidebar — "Display" section**: "Text in wells" 4-segment control None/Active/All/Overview + hint caption (All: "One line per factor, in the order listed above. Any that do not fit drop to a colour strip. A key appears under the plate." / "Add a second factor to see stacked labels." when <2 factors; Overview: "Every factor at the same size on a plain well, with nothing selected — the whole design at a glance (Ctrl+Shift+O)."); **Show other factors** checkbox (hidden in All/Overview, disabled <2 factors; help "Adds a colour strip along the bottom of each well for the factors you are not painting."); **Round wells** checkbox (help "Ignored while stacked labels are showing…"); **Pad well IDs (A01)** checkbox → `layout.padWellLabels`.
**Plate tab bar**: scrolling chips (name semibold when active + smaller format name; accent tint when active), trailing "+" (tooltip "Add another plate to this layout"). Click = activate **and reset selection to A1**; second click = rename; context menu: Rename Plate, Duplicate Plate, Plate Note…, —, Delete Plate (disabled when only one).
**Status bar**: [armed: colour dot + "{factor}: {condition}" | "Overview — click a factor to start painting" | "No condition armed — press 1–9 to pick one"] │ [hover/cursor summary "B7  ·  Factor: Level  ·  Factor2: Level2" or "B7 — empty", plus "  ·  ✎ {note}"; falls back to selection focus] … [transient flash message, accent colour, auto-clears after 3 s] [zoom "137%" button only when zoom > 1.001, click = fit] │ [selection: `A1` / `A1:D6  ·  4×6 = 24` / `N wells selected` / `No selection`].

### A4. Sheets / dialogs (fields, defaults, exact strings)
- **Custom Plate Size** (w 520): title "Custom Plate Size", sub "Any layout from 1×1 up to 64×96 wells." Rows spinbox 1…64 (hint "A–{last row letter}"), Columns 1…96 (hint "1–{cols}"); checkbox **Save as a template** (default on; disabled when standard or already saved) with either "Already saved as "{name}"." / "{n}-well is a standard plate — it is already in the menu." / Name field prompt "{rows}×{cols} plate". Right: "{n} wells", dot-grid preview, "Wells A1 – {last}". If templates exist: list with rename-in-place, "{n} wells · r×c", **Use** and trash buttons. Footer warning "Some assigned wells fall outside this size" when shrinking loses data; Cancel / **Use Size**. Shrink confirm alert: "Switch to a {name} plate?" / "Wells outside the smaller plate already have values assigned… You can undo this." Switch/Cancel; cancel keeps the sheet open. Template saved only when the size is applied.
- **Series Fill** (w 460): sub "Writes a value series into {r}×{c} wells of {factor}." Direction "Across columns →"/"Down rows ↓" (default across); Series "Fold dilution"/"Linear step" (default fold); Top value (default 10); fold: Fold (default 3) + "dilution (÷)"/"increase (×)" (default ÷); linear: Step (default -1); Significant digits stepper 1…6 (default 3); checkbox "Last position is 0 (vehicle control)" (off). Live preview chips coloured by `Palette.ramp`; empty state "Select some wells first." Cancel / **Fill**. Requires a rectangular selection.
- **XY Position Fill** (w 460): sub "Numbers {the whole plate | the N selected wells | r×c wells} as factor "XY", in the order the microscope visits them." Pattern "Across columns →"/"Down rows ↓"/"Serpentine ⇄" (default across); "Gradient colour" swatch picker (preset to existing XY factor colour else next palette colour). Preview first 16 names then "→ {last}"; empty "No plate to number." Cancel / **Fill**.
- **Note** (w 380): title "Note for A1" / "Note for {plate}"; sub "Shown in the status bar, and exported with the Wells sheet. Leave empty to remove."; multiline editor; Cancel / **Save**. Empty text deletes. No focused well → flash "Select a well first."
- **Saved States popover** (w 330): header "Saved states" + plate name, caption "Ctrl+Alt+S saves · Ctrl+Z undoes"; empty "Nothing saved for {plate} yet." + explanation; rows newest first: bookmark glyph (filled when the plate matches; tooltip "The plate matches this state right now"), editable name, subtitle "Saved 14:32  ·  96-well  ·  42 wells filled" (+ "whole document, N plates" for legacy states), revert button (disabled when current; closes popover), delete (tooltip "Delete this state — Ctrl+Z brings it back"). Auto-names "State N", cap 20 oldest-dropped, saving an unchanged design is refused with a flash.
- **Workbook export options** (Mac: save-panel accessory; port: a small dialog *before* the file dialog, or a custom QFileDialog widget): "Plate maps:" popup **One sheet per factor** / **All factors on one sheet** + detail line ("A separate tab for each factor, ready to paste elsewhere." / "One tab per plate, each map headed by its factor name."); "One-cell map:" checkbox **All factors in one cell, joined by** + separator field placeholder "+"; "Plates:" popup **All plates** / **Just "{active plate}"** — **only when >1 plate**. All remembered in QSettings keys `workbookSheetLayout`, `workbookScope`, `workbookJointMapEnabled`, `workbookJointMapSeparator`.
- **Image/CSV export**: plain save dialog, suggested name from the window title ("Plate Layout" when untitled), success flash "Exported {filename}".
- **Colour grid popover** (`Controls.swift:153-265`): family segmented **Standard / Colour-blind / Muted**; grid **8 columns × 5 rows** (column = hue, rows lightest→darkest, base hue in the middle row), swatches 22 pt; current outlined; **already-used dot** top-trailing (scope: other levels of this factor, or the whole document under never-repeat) tooltip "{hex} — already used by another condition"; family note ("Default hues for new conditions." / "Okabe–Ito: stays separable with red/green colour blindness." / "Softer tints, for a plate that is mostly full."); divider; **Custom…** → `QColorDialog` (no alpha). Family hues (`Palette.swift:75-90`): Standard `#5889BC #F28E2B #59A14F #E15759 #B07AA1 #76B7B2 #EDC948 #928785`; Colour-blind `#008AD7 #56B4E9 #009E73 #F0E442 #E69F00 #D86000 #CC79A7 #8B8B8B`; Muted `#A0CBE8 #FFBE7D #8CD17D #FF9DA7 #D4A6C8 #86BCB6 #F1CE63 #BAB0AC`.

### A5. Settings dialog (`PreferencesView.swift`; Mac 460×660, 3 tabs + live preview below + "Restore Defaults")
- **Display**: Text colour radio **Match the well** (default) / Always black / Always white; Active marker radio **Match the label** (default) / Darker shade of the well; Well shape (new documents) radio **Round** (default) / Square; Sidebar checkbox "Show each factor's number of conditions" (off).
- **Colours**: New conditions radio **Start the palette over per factor** (default) / Never repeat a colour; Empty wells colour button + caption "Background of wells with no value" + **Reset to Default** (nil = follow the app default; note text switches between "The default follows light and dark mode." and "A chosen colour is used as it is, everywhere…").
- **Plate Text**: Font popup "System" + installed families; Size slider 0.7…1.8 step 0.05 shown as % (a multiplier on computed sizes); note that it applies to wells, headers, line key, exports and print.
- Preview row: 5 sample wells (Vehicle/Low/Mid/High + an Overview tile) redrawn live. Defaults: automatic, matchLabel, round, perFactor, empty nil, font nil, scale 1.0, counts off, auto-update on.

### A6. IO formats (must match byte-for-byte where stated)
- **Copy** (`PlateEditor.swift:973-1006`): refuse discontiguous ("Copy needs a rectangular selection.") and no factor ("No factor selected — click one in the sidebar to copy its values."). Grid = active factor's level names, "" where unassigned. With headers: first row `["", "1", "2", …]` (unpadded), rows prefixed with the letter. TSV: `\t` between cells, `\n` between rows, **no trailing newline, no quoting**. Flash "Copied N wells as {factor}." **Cut** = copy (never headers) + clear active factor.
- **Paste** (`:1019-1042`): refused in Overview. `TSV.parse`: normalise `\r\n`/`\r`→`\n`, drop trailing empty lines, split `\t`, right-pad rows. If 1×1 and text contains a comma → CSV re-parse. **Header stripping** (`TableIO.swift:23-38`) only when ALL hold: corner blank; every other row-0 cell blank or == its 1-based column number; every later row's first cell blank or `row_index(cell)` == its 0-based offset (case-insensitive, AA-style ok). Applied at selection top-left (A1 if none), clipped; blank → clear; non-blank → find-or-create level (trimmed, case-insensitive), colour via `new_level_color`. Flash "Added N new conditions from pasted values." Selection := pasted block.
- **Import Table** (`:1447-1469`): file dialog (csv/tsv/txt), message "Choose a CSV or TSV file laid out like the plate."; `.csv` → CSV parser else TSV; 1×1 → retry CSV; header strip; apply at **A1** into the active factor. Empty → "That file did not contain a readable table."; read error → alert "Could not read that file"; success "Imported R × C values into {factor}."
- **CSV parser** RFC-4180-ish (quotes, `""`, ignore `\r`, drop trailing empty rows, right-pad). **CSV writer**: quote only when field has `,` `"` `\n` `\r`, double inner quotes, `\n` line ends **with trailing newline**, UTF-8 no BOM.
- **Tidy grid** (`TableIO.swift:331-364`): columns `Plate` (only if >1 plate) · `Well` (`B7`, or `B07` when padWellLabels) · `Row` · `Column` · one per factor headed by displayName (`name` or `name (unit)`) · `Note` (only if any well note exists in scope). One row per well of every plate (plate order, row-major), unassigned wells included. **Tidy CSV export = whole document, no scope choice.**
- **XLSX workbook** (`TableIO.swift:191-417`, `XLSXWriter.swift`), reproduce with openpyxl:
  - Scope filter first (id matching nothing → all plates).
  - Sheet order: per-factor arrangement → for each plate, for each factor **"{plate} · {factor name}"** (bare name); one-sheet arrangement → per plate **"{plate}"** with, per factor, a bold single-cell row with the factor **displayName**, then the map, then an empty row; then if one-cell map on → per plate **"{plate} · Combined"**; then **"Wells"**; then **"Legend"**.
  - Sheet-name sanitising: drop `[ ] : * ? / \`, empty→"Sheet", truncate 31, de-dupe case-insensitively with " (2)", " (3)"… trimming the base to fit.
  - Plate map: row 1 = blank header cell + column numbers as header cells; rows 2.. = row letter header + wells: **fill = level colorHex**, centred, value numeric if factor numeric and name parses as float, else text; unassigned = blank centred, no fill. Header style: fill `#EDEDED`, bold, centred. Column widths `[5, 11, 11…]`, freeze A2/B2 (1 row + 1 col; combined arrangement freezes 1 column only).
  - Combined map: same frame; cell = every factor's level name (document order, unassigned skipped) joined by separator (blank→"+"); no fill; centred; widths `[5, 24, 24…]`; freeze 1/1.
  - Wells sheet: tidy grid, header style, numbers for numeric-factor columns that parse; widths `max(9, min(24, len(header)+4))`; freeze 1 row.
  - Legend: header `Factor | Level | Colour | Wells`; one row per level: factor displayName, level name **filled with its colour** (not centred), hex text, well count over plates in scope; then if any plate note: empty row, bold "Plate notes", rows `plate | note`. Widths `[22,22,12,8]`, freeze 1 row.
  - Styles: Calibri 11; bold for headers; **white font when fill luminance ≤ 0.42** (WCAG relative luminance); filled cells get thin border `#D0D0D0` all sides; centred cells vertical+horizontal centre; General number format.
  - openpyxl differences are cosmetic (sharedStrings, docProps, theme) — do not chase byte equality; test by re-opening with openpyxl and asserting names/cells/fills.
- **UpdateChecker**: GET `https://api.github.com/repos/nettilor/pLayout/releases/latest`, ≤ once per 20 h, version compare numeric; port may omit or (M7) reimplement pointing at a Windows asset.

## Compatibility contract (.plate) — from `Model/Layout.swift`, `PlateFormat.swift`, `PlateDocument.swift`

### Container
- One JSON object = encoded `Layout`. Written `JSONEncoder` `.prettyPrinted, .sortedKeys` (2-space indent, `"key" : value`). Read with plain `JSONDecoder` — **unknown keys ignored at every level (and NOT preserved on re-save)**.
- Dates = **JSON number, seconds since 2001-01-01T00:00:00Z (Apple epoch)**; `apple = unix − 978307200.0`. ISO strings throw.
- UUIDs = **UPPER-CASE** canonical strings. `assignments` keys are compared as raw strings → must be upper-case; values/other ids parse case-insensitively. Port: write `str(uuid).upper()` everywhere; read keys case-insensitively by normalising to upper on load.
- Port writer: `json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False, separators=(',', ' : '))` (Swift also escapes `/` as `\/` — harmless either way).

### Schema (R = required on read; else default when absent; encoder always writes every key unless noted)
**Layout (root)** — hand-decoded, everything optional: `formatVersion` int (1, never validated) · `factors` [Factor] ([]) · `plates` [Plate] ([]) · `padWellLabels` bool (false) · `wellLabelMode` "none"|"activeFactor"|"allFactors"|"overview" (default activeFactor; **unknown → activeFactor, lenient**) · `orientation` "automatic"|"upright"|"turned" (**strict — unknown value throws**; absent → legacy rule) · `snapshots` [LayoutSnapshot] ([]; cap 20 oldest dropped) · `notes` string ("").
Retired keys honoured on read only: `transposedView` bool, `quarterTurns` int → if `orientation` absent and (transposedView == true or quarterTurns != 0) → "turned" else "automatic"; explicit `orientation` wins. Never written.
Post-decode normalisation: every assignment column resized to `rows*cols` (pad null / truncate); all-null columns deleted. Port must do the same (equality/undo-noop/bookmark match depend on it).
**Factor** — synthesized, **all R**: `id` UUID · `name` · `kind` "categorical"|"numeric" (unknown throws) · `unit` string (may be "") · `levels` [Level]. `displayName` derived (`name` or `name (unit)`).
**Level** — **all R**: `id` · `name` · `colorHex` "#RRGGBB" upper-case (reader: trim, strip one `#`, exactly 6 hex digits, else nil → drawn uncoloured).
**Plate** — `id` R · `name` R · `format` R · `assignments` {} · `wellNotes` {} · `note` "".
`assignments`: `{ "<FACTOR-UUID-UPPER>": [ "<LEVEL-UUID>" | null, … ] }`, length rows*cols, **row-major** (`index = row*cols + col`), null = unassigned; **an all-null column is removed from the dict**.
`wellNotes`: `{ "<well index decimal string>": "text" }` 0-based row-major; empty/whitespace notes deleted, never stored. `note`: plate note.
**PlateFormat** — `{ "rows": 8, "cols": 12 }` both R; clamped on decode rows 1…64, cols 1…96 (`{"rows":0,"cols":5000}` → 1×96).
**LayoutSnapshot** — hand-decoded, all optional: `id` (random) · `name` ("State") · `savedAt` number Apple-epoch (default −978307200 = 1970) · `plateID` UUID **omitted when nil** · `factors` [] · `plates` []. **plateID-absent rule**: exactly one plate → adopt that plate's id; else stays nil = whole-document state, belongs to every plate. Snapshots never nest (no `snapshots` inside).
Minimal useful example: see model inventory (agent) — a Layout with 1 factor/2 levels, 1 plate 2×3 with one assignment column and a `wellNotes {"1": "bubble"}`.

### PlateFormat & naming (`PlateFormat.swift`)
Standard: 6=2×3, 12=3×4, 24=4×6, 48=6×8, 96=8×12, 384=16×24, 1536=32×48. `name` "{n}-well", `detailedName` "{n}-well  ({rows}×{cols})" (two spaces, U+00D7). Custom rows 1…64, cols 1…96 clamped in init and decode. `index=row*cols+col`. `changeFormat` keeps (row,col) not linear index; notes same; `formatChangeWouldLoseData` only when a populated well falls outside.
`WellNaming.rowLabel(n)`: bijective base-26 (`do { out = chr(65+n%26)+out; n = n//26 − 1 } while n ≥ 0`): 0→A, 25→Z, 26→AA, 31→AF, 63→BL. `rowIndex(label)`: uppercase, pure ASCII letters only, `n = n*26 + (ord−64)`, return n−1. `colLabel(col, padded)`: 1-based, padded → `%02d` (100 stays "100"). `wellLabel = rowLabel+colLabel`. `parseWell("A1"|"a01"|" B07 ")` → (row,col); digits ≥ 1; rejects digit-only/letter-only.
Orientation `quarterTurns`: automatic → 1 iff rows > cols; upright 0; turned 1. Display-only.

### Palette (`Palette.swift`) — reproduce exactly
- `categorical` (20, `color(at: i) = categorical[((i%20)+20)%20]`): `#5889BC #F28E2B #59A14F #E15759 #B07AA1 #76B7B2 #EDC948 #FF9DA7 #A17962 #8CD17D #A0CBE8 #FFBE7D #D4A6C8 #499894 #D7B5A6 #B6992D #86BCB6 #FABFD2 #928785 #F1CE63`.
- Families (8 columns, last is neutral): standard/colourBlind/muted as listed in A4.
- `shades(of: base, count: 5)` (HSV in sRGB — Python `colorsys` reproduces AppKit exactly; clamp RGB to [0,1] after HSV→RGB; luminance on unquantised floats):
  ```
  h,s,v = rgb_to_hsv(base); ceiling = 0.80 if s<0.15 else 0.95
  anchor = min(max(v,0.12),0.94) if s<0.15 else max(v,0.12); middle=(count-1)//2; ms=0.03
  lightest = max(anchor + ms*max(middle,1), min(ceiling, max(0.88, anchor+0.22)))
  darkest  = min(anchor - ms*max(count-1-middle,1), max(min(0.42, anchor*0.62), brightness_clearing(h,s,0.19)))
  row i: i==middle → base verbatim if anchor==v else hsv(h,s,anchor)
         i<middle → u=(middle-i)/middle; hsv(h, s*(1-0.35*u), anchor+(lightest-anchor)*u)
         i>middle → u=(i-middle)/(count-1-middle); hsv(h, s, anchor-(anchor-darkest)*u)
  ```
  count ≤ 0 → []; unparseable → input repeated; count 1 → [base]. `brightness_clearing(h,s,L)`: if lum(h,s,1.0) ≤ L → 1.0; else 14-iteration bisection on [0,1], `lo=mid` when lum<L else `hi=mid`, **return hi**. `wellTextFloor = 0.19`. Luminance = WCAG (`lin(v) = v/12.92 if v ≤ 0.03928 else ((v+0.055)/1.055)^2.4`; 0.2126/0.7152/0.0722). Hex out `"#%02X%02X%02X"` of `round(c*255)`.
  Verified table (0 mismatches vs AppKit) to pin in tests, e.g. `#5889BC → #9EC8F2 #79A7D7 #5889BC #5482B3 #507CAA`; `#F28E2B → #FFBC78 #FAA550 #F28E2B #D17B25 #B0671F`; `#928785 → #CCC2C0 #AFA4A2 #928785 #897F7D #807775`; `#008AD7 → #55BAF2 #28A1E5 #008AD7 #0084CE #007EC5`; `#BAB0AC → #CCC5C2 #C3BAB7 #BAB0AC #9C9490 #7E7775` (full 28-hue table is in the model-inventory report; PORT.md carries it all).
- `firstColor(avoiding: used, fallbackIndex)`: 20 hues in order → `shades(hue)[row]` for row in [3,1,4,0] over the 20 hues → `color(at: fallback)`. `usedLevelColors(excluding:)` = set of `normalized(hex)` over all factors (`normalized` = parse→upper `#RRGGBB`, else raw upper).
- `ramp(count, baseHex)`: count ≤ 0 → []; base = parse or **"#4E79A7"** fallback; count 1 → [baseHex verbatim]; `deepest = max(min(v,0.92), 0.45, brightness_clearing(h, max(s,0.55), 0.19))`; `t=i/(count−1)`; `sat = 0.18+(max(s,0.55)−0.18)*t`; `bri = 0.98−(0.98−deepest)*t`. Verified: `ramp(5,"#5889BC") = #CDE3FA #ABCAEA #8BB2DB #6E9CCB #5587BC`; `ramp(3,"#F28E2B") = #FAE3CD #F2B579 #EB8A2A`.
- Contrast: `contrastingLabelColor` = white iff luminance ≤ 0.175 else black @ 85%; `contrastingShade`: luminance > 0.16 → sat×1.2 (≤1), bri = max(0.20, b×0.5); else sat×0.85, bri = min(1, max(b×1.9, b+0.4)).

### Preferences (`Preferences.swift`; QSettings in the port, same keys)
`wellTextStyle` "automatic"|"alwaysBlack"|"alwaysWhite" (automatic) · `activeMarkerStyle` "matchLabel"|"deeperShade" (matchLabel) · `newDocumentWellShape` "round"|"square" (round; seeds new docs only; live `roundWells` never persisted) · `newConditionColors` "perFactor"|"neverRepeat" (perFactor) · `emptyWellColorHex` string or absent (absent = app default; reset removes key) · `canvasFontFamily` string or absent · `canvasFontScale` double 1.0 clamped 0.7…1.8 on load · `showFactorConditionCounts` bool false · `checkForUpdatesAutomatically` bool true. Unknown enum strings → default. Also: `customPlateTemplates` (JSON array of {id,name,rows,cols}; standard/duplicate/out-of-range entries dropped on load; names deduped " 2"," 3"; blank → "{rows}×{cols} plate"), `workbookSheetLayout` "sheetPerFactor"|"allFactorsOneSheet", `workbookScope` "allPlates"|"activePlate", `workbookJointMapEnabled`, `workbookJointMapSeparator`, `lastUpdateCheckDate`, `skippedUpdateTag`.

### Templates
Plate-size templates: QSettings JSON. Layout templates: complete `.plate` files in `<AppData>/pLayout/Templates/<name>.plate` (Mac: `~/Library/Application Support/pLayout/Templates/`; port: `QStandardPaths.AppDataLocation`), listing = directory scan `*.plate`, name = stem, sorted natural-case-insensitive; save overwrites same name; `sanitized(name)`: trim, `/`→`-`, `:`→`-`, trim leading/trailing `.`; opening duplicates into an untitled document.

### Round-trip gotchas (all must be tests)
UUID case (keys upper) · `savedAt` Apple epoch · Factor/Level/Plate/PlateFormat required keys · `orientation` strict (omit rather than guess) · pad columns to rows*cols and prune all-null · row-major 0-based indices independent of orientation · extra keys are dropped by the Mac on re-save (never load-bearing) · `formatVersion` is not a gate · cap 20 snapshots · preferences never in file.

## Feature parity inventory — C. Editor operations (`Editor/PlateEditor.swift`, `Editor/WellRange.swift`; model rules in `Model/Layout.swift`)

### C0. Mutation plumbing & undo
- `edit(name, change)` → `document.mutate`: copy whole Layout, apply change, **if equal do nothing** (no undo entry, no notification); else assign + register an undo that restores the previous whole layout. Undo/redo = whole-document snapshot swap. `editPlate` captures `plateIndex` before and re-checks it inside.
- Every action incl. saving/renaming/deleting/reverting states = one undo step.
- **Reconcile from the layout signal on every layout value** (`:897-937`), in order: (1) `activePlateID` nil/missing → first plate; (2) if `wellLabelMode.isOverview` → `activeFactorID = nil` unconditionally, else nil/missing → first factor; (3) `armedLevelID` non-nil **and stale** → first level of the active factor (a deliberate nil is never re-armed); (4) `selection = selection.clamped(format)`, `customWells` re-clipped (drop out-of-range, empty→nil); (5) `spotlightLevelID` cleared if gone; (6) multi-select sets ∩ live ids, and if shrunk to ≤1 member → empty.
- Separate subscription on `activePlateID` recomputes only the saved-state match.
- `flash(msg)`: sets transient message, clears after 3.0 s (cancel pending).

### C1. Editor state outside `Layout` (view-model)
`activePlateID: UUID?` · `activeFactorID: UUID?` (**nil in Overview always**) · `armedLevelID: UUID?` (nil = select without painting) · `selection: WellRange?` (anchor+focus rectangle, Excel-style; **initial = single well (0,0)**; nil = none) · `customWells: set[WellPos] | None` (discontiguous; non-nil overrides `selection`, which is nil while it exists; never empty) · `customFocus: WellPos?` (last Ctrl-clicked well) · `multiSelectedFactorIDs`, `multiSelectedLevelIDs: set` (mutually exclusive; non-empty ⇒ painting off) · `spotlightLevelID` · `noteTarget` (`well(index)`/`plate`) · `hovered` · `showSecondaryFactors=True` (view-only) · `roundWells` (seeded once from Preferences well shape; sidebar owns it after) · `transientMessage` · sheet flags · `zoomLevel=1` (min) · `matchingSavedStateID` (recomputed on layout/plate change only) · `overviewReturn: (mode, factorID)?`.
Derived: `plateIndex` (index of active, else 0 if any plates, else −1), `plate`, `format` (default 96), `activeFactor`, `armedLevel`, `isOverview`, `secondaryFactors`, `wellCount(ofLevel)` (active factor, active plate).
**Init**: `activePlateID = first plate`; only if not Overview: `activeFactorID = first factor`, `armedLevelID = its first level`. A doc saved in Overview reopens with both nil.

### C2. Selection & navigation (`WellRange`: anchor, focus, min/max row/col, counts, isSingleWell, contains, clamped(to) clamps both corners independently, wholePlate/wholeRow/wholeColumn; `indices(in:)` clips edges, row-major; fully out-of-range still yields the clamped corner — 96-well → `[95]`)
- `hasSelection` = customWells non-empty or selection non-nil. `selectedWells`: custom → row-major indices **sorted**; else selection indices.
- `toggleWell(pos)` (Ctrl-click): ignore outside format; take current positions; insert-or-remove; `customFocus=pos`, `selection=nil`, `customWells = set or nil if empty`.
- `addToSelection(base, rect)` (Ctrl-drag disarmed): base ∪ clamped rect; `customFocus = rect.focus`; `selection=nil`.
- `select(range)`: `customWells=nil`, `selection = range.clamped`. `selectAllWells`: whole plate. `clearSelectionMarquee`: both nil.
- `moveCursor(dRow,dCol,extend)`: custom set → collapse to `single(clamp((customFocus or (0,0)) + delta))`, extend ignored; no selection → `single((0,0))` (delta NOT applied); else `next=clamp(focus+delta)`, extend ? `(anchor, next)` : `single(next)`.

### C3. Painting
- `paint(wells, level, actionName)` — single write path: needs `activeFactorID` present in layout and wells non-empty (else silent). If multi-selecting → flash "Painting is off while several rows are selected — click a single row to continue." Undo name = actionName or ("Clear Wells" if level nil else "Paint Wells"). Model `setLevelID` ignores out-of-range wells, resizes mismatched column, **removes the factor's column when all-nil**.
- `paintSelection()` guards in order: Overview → "Overview is read-only — click a factor to start painting again."; no armed → "Pick a condition first — press 1–9 or click one in the sidebar."; no selection → "Select some wells first."; then paint(selectedWells, armed, "Fill Selection") — works on discontiguous.
- `clearSelection()`: Overview-guarded; paint(nil, "Clear Selection") active factor only. `clearSelectionAllFactors()`: **no Overview guard, no factor needed**; one edit "Clear All Factors" over every factor.
- Erase (Alt-drag) = paint(nil, "Erase Wells"). Painting never moves the selection.

### C4. Sidebar multi-select
- `toggleFactorInMultiSelection(id)`: ignore unknown; if set empty, seed with `activeFactorID` (unless same); insert-or-remove; result ≤1 → clear set and if exactly one remains `setActiveFactor(it)`; else clear level set, store, `armedLevelID=nil`.
- `toggleLevelInMultiSelection(id)`: same shape for levels of the active factor; seeds from `armedLevelID`; collapse → `armLevel(only)`; growing clears factor set and disarms.
- `armLevel(id)` = exit multi-select + arm. `deleteLevels(ids)`: one edit "Delete Conditions"; exit; if nothing armed arm first survivor. `deleteFactors(ids)`: if it covers all factors, spare `factors.first` and flash "A layout needs at least one factor — {name} stays."; one edit "Delete Factors"; exit; if nothing armed and not Overview arm active's first level. `armLevel(atIndex)`, `cycleLevel`, `disarmLevel`, `setActiveFactor` all exit multi-select first.

### C5. Levels
- `newLevelColor(layout, fallbackIndex)`: never-repeat → `Palette.firstColor(avoiding: layout.usedLevelColors(), fallback)`; else `Palette.color(at: index)` (20-entry list mod 20). `firstColor`: first unused categorical hue; then `shades(of: hue)[row]` for rows **[3,1,4,0]** over every hue; then `color(at: fallback)`.
- `addLevel()`: name **"Condition {count+1}"**, colour `newLevelColor(fallback: count)`, appended, edit "Add Level", **armed := new**. Does not exit multi-select.
- `renameLevel` (trim, ignore blank, "Rename Level") · `setLevelColor` ("Change Colour") · `deleteLevel` ("Delete Level"; model nils wells everywhere, drops empty columns; re-arm first if the armed went) · `moveLevels(fromOffsets,toOffset)` ("Reorder Levels", Swift move semantics: insert before `toOffset` using pre-move indices; sidebar passes `to > from ? to+1 : to`).
- `recolorLevelsFromPalette()` ("Recolour Levels"): numeric → `Palette.ramp(count, base: color(at:0))`; never-repeat → sequential `firstColor(avoiding: used-excluding-this-factor)` adding each pick to used; else `color(at: i)`.
- `removeUnusedLevels()`: drop levels referenced by no plate; flash "No unused conditions." / "Removed {n} unused condition(s)."; re-arm if needed.
- Name lookups are trimmed + lowercased; `ensureLevel(named, colorHex?)` stores trimmed name, default colour `color(at: levels.count)`.

### C6. Factors
- `addFactor()`: `Factor(name: uniqueFactorName("Factor"), levels: [Level("Level 1", newLevelColor(fallback 0))])` — first level is **"Level 1"**; unique naming case-insensitive: base, "base 2", "base 3"… (starter doc has factor "Condition" so first added is "Factor", then "Factor 2"). Edit "Add Factor"; `setActiveFactor(new)`.
- `renameFactor` ("Rename Factor") · `setFactorUnit` (trim, "Set Unit"; displayName = name or "name (unit)") · `setFactorKind` ("Change Factor Type") · `moveFactors` ("Reorder Factors"; assignments keyed by id so nothing moves) · `deleteFactor`: refuse when ≤1 ("A layout needs at least one factor."); "Delete Factor" (drops its column everywhere); if it was active → `setActiveFactor(first)` (also leaves Overview).

### C7. Plates
- `addPlate()`: `Plate(uniquePlateName("Plate"), format: current plate's)` → on starter doc named **"Plate"**, then "Plate 2"; edit "Add Plate"; active := new; `customWells=nil`; `selection=single(0,0)`.
- `duplicatePlate()`: deep copy, new UUID, name `uniquePlateName(current.name + " copy")` → "Plate 1 copy", "Plate 1 copy 2"; appended; active. Selection untouched.
- `deletePlate(id)`: refuse ≤1 ("A layout needs at least one plate."); "Delete Plate"; if active deleted → `plates[min(deletedIndex, count-1)]`.
- `renamePlate` (trim, ignore blank, "Rename Plate").
- `setFormat(new) -> bool`: no plate → False; same → True **without edit**; if `formatChangeWouldLoseData` (only when shrinking either dimension) → modal "Switch to a {displayName} plate?" / "Wells outside the smaller plate already have values assigned. Those assignments will be discarded. You can undo this." Switch/Cancel; Cancel → False, no side effects; edit "Change Plate Format" — **assignments and well notes keep (row,col)**, outside cells dropped, empty columns removed; then clamp selection, clip customWells (drop, never clamp).
- `applyCustomFormat(rows, cols, templateName)`: PlateFormat clamped rows 1…64, cols 1…96; `setFormat`; **only if True** save the template.
- `formatDisplayName`/`formatDetailedName`: template name if a custom template matches, else "{n}-well" / "{n}-well  (rows×cols)"; standard formats never renamed by templates.

### C8. Rotation
- `rotatePlate()`: read `isTurned`, edit "Turn Plate" → `orientation = wasTurned ? upright : turned` (2-state). Flash "Upright. A1 is top left." / "Turned 90°. A1 is now top right."
- `quarterTurns`: automatic → 1 iff rows > cols else 0; upright → 0; turned → 1. Display-only: clockwise `display(r,c) = (c, rows-1-r)`; inverse `model(dr,dc) = (rows-1-dc, dr)`.
- `setPadWellLabels(bool)`: edit "Well Label Style".

### C9. Display mode / Overview
- `setWellLabelMode(mode)`: `entering = mode.isOverview and not isOverview`; `resume = entering ? (currentMode, activeFactorID) : overviewReturn` **captured before the edit**; edit "Well Labels"; if new mode Overview → `overviewReturn = resume`; else if `resume.factorID` exists → `setActiveFactor(it)`; clear overviewReturn.
- `toggleOverview()`: `setWellLabelMode(isOverview ? (overviewReturn.mode or allFactors) : overview)`.
- `leaveOverview()` (called by setActiveFactor): if Overview, edit "Well Labels" back to `overviewReturn.mode or allFactors` (overview→allFactors defensively), clear.
- Overview invariant enforced in reconcile. Read-only refusals via flash: paintSelection, clearSelection, paste, openSeriesSheet, applySeries, openXYFillSheet, applyXYFill, randomize. **clearSelectionAllFactors not guarded.**
- `cycleFactor(delta)`: no active (Overview) → `factors[delta<0 ? last : 0]`; else wrap; then setActiveFactor. `setActiveFactor(id)`: leaveOverview → exitMultiSelection → spotlight=nil → active=id → armed = its first level. `armLevel(atIndex)` bounds-checked. `cycleLevel(delta)` wraps; unarmed counts as −1 so +1 → index 0. `disarmLevel()`.
- `WellLabelMode` raw values `none`, `activeFactor`, `allFactors`, `overview`; labels "None"/"Active factor"/"All factors"/"Overview"; short "None"/"Active"/"All"/"Overview"; unknown decodes → activeFactor.

### C10. Saved states (per plate)
- `savedStates` = snapshots with `plateID == nil` (legacy: belongs to all) or `== activePlateID`, oldest first.
- `saveState()`: no plate → "No plate to save."; if `snapshotMatching(plate)` exists → "{plate} is already saved as {state}." and refuse; else edit "Save State" → snapshot(date, factors: all, plates: [this plate]). Name: `n = count(states for this plate)+1`, bump while "State n" taken within this plate. **Cap 20 across the whole document**, oldest dropped. Flash: dropped → "Saved. Keeping the {n} most recent states."; else "Saved {name} for {plate}. ⌘Z undoes this." (port: Ctrl+Z).
- `renameState` ("Rename State", model trims/ignores blank) · `deleteState` ("Delete State"; flash "Deleted {name}. ⌘Z restores it.") · `revertToLatestState()` uses this plate's last; none → "No saved states for {plate} yet — use the bookmark button first." · `revertToState(id)`: edit named **"Revert to {name}"**; unchanged → "Already matches {name}." else "Reverted to {name}. ⌘Z puts it back."
- `restoreSnapshot`: (1) **reinstateFactors — merge never remove**: append lost factors whole, else append only missing levels (at end); existing names/kinds/units/colours untouched; (2) `plateID nil` → `plates = snapshot.plates`; (3) else replace that plate in place, or append if deleted; (4) wellLabelMode/padWellLabels/orientation and the snapshot list are never restored.
- **Bookmark filled**: newest snapshot with `plateID == active` and `plates.first == live plate` (full Plate equality: id, name, format, assignments, wellNotes, note); factors NOT compared.
- Strings: title "{name}  ·  {short time}"; subtitle "Saved {time}  ·  {format display}  ·  {n} well(s) filled" (filled = any factor has a value) + "whole document, {n} plates" for legacy states with >1 plate.

### C11. Notes
- Storage: `wellNotes: {str(wellIndex): text}`, plate `note: str`. `setNote` ignores out-of-range, trims whitespace+newlines, empty removes key.
- `openWellNoteSheet()`: target = `selection.focus or customFocus`; nil/out of format → "Select a well first." `openPlateNoteSheet()`.
- Titles "Note for {wellLabel}" (padded per layout) / "Note for {plate}" / "Note for this plate". Edits "Edit Well Note" / "Edit Plate Note".
- `summary(row,col)`: "" if no plate/out of range; "{label}  ·  {Factor}: {Level}  ·  …" over all factors in order skipping unassigned, or "{label} — empty"; + "  ·  ✎ {note}".

### C12. Clipboard / import — see A6 for formats. Extra rules: `copySelection` exact outputs `"Untreated\t"` and `"\t1\t2\nA\tUntreated\t"`; `cutSelection` refuses discontiguous ("Cut needs a rectangular selection."), else copy then clearSelection; **paste origin ignores customWells (pastes at selection min or A1) and does not clear customWells** (reproduce, or consciously fix and note in PARITY.md); paste selection := pasted block clamped; `applyGrid` creates levels via `ensureLevel(named, colorHex: newLevelColor(in: layout-being-built, fallback: levels.count))`, flashes "Added {n} new condition(s) from pasted values.", re-arms first level if armed no longer resolves; `importTable` applies at (0,0), action "Import Table".

### C13. Series fill
- `SeriesSpec` defaults: acrossColumns, fold, start 10, foldFactor 3, dilute True, step −1, significantDigits 3 (sheet clamps 1…6), lastIsZero False.
- `seriesValues(spec)`: needs plate and **rectangular selection** (custom ⇒ []); steps = colCount or rowCount of clamped range; k-th: lastIsZero&&last → "0"; linear `start + step*k`; fold `f = factor<=0 ? 1 : factor`, dilute ? `start/f^k` : `start*f^k`.
- `formatValue(v, sig)`: 0 → "0"; digits clamp 1…12; `"%.{d}g"`; if contains "." and no e/E strip trailing zeros then trailing ".". Pinned: 10,÷3,6 → 10,3.33,1.11,0.37,0.123,0.0412; 100,÷10,lastZero,4 → 100,10,1,0; linear 24 step −6 ×4 → 24,18,12,6.
- `applySeries`: Overview-guarded; needs active factor, plate, selection; `ramp = Palette.ramp(steps, base: activeFactor.levels.first.colorHex or color(at:0))` before edit; one edit "Series Fill": kind := numeric; per value `ensureLevel(named)` and **overwrite colour with ramp[k]**; **sort all levels**: both numeric → descending; numeric before non-numeric; both non-numeric → ascending by name; write wells (k = c−minCol or r−minRow), skip k out of range. Then armed := first level; flash "Filled {steps}-point series: {first} → {last}". Selection unchanged.
- `Palette.ramp(count, baseHex)`: HSB of base; count 1 → [base]; `deepest = max(min(b,0.92), 0.45, brightness(hue h, sat max(s,0.55), clearing 0.19))`; for `t=i/(count−1)`: `sat = 0.18 + (max(s,0.55)−0.18)*t`, `bri = 0.98 − (0.98−deepest)*t`. `brightness(clearing:)` = 14-step bisection on WCAG relative luminance (sRGB linearisation, 0.2126/0.7152/0.0722); hex channels rounded.

### C14. XY position fill
- Patterns acrossColumns / downRows / serpentine; labels "Across columns →" / "Down rows ↓" / "Serpentine ⇄"; factor name "XY".
- `xyNames(count)`: width = max(2, len(str(count))) → `XY%0{w}d`.
- Wells, in **display space** (geometry with dummy bounds): custom set → those wells; else selection not single → full display rectangle between mapped corners; else whole plate. Order: across → sort (row,col); down → (col,row); serpentine → group by display row, reverse columns of every **odd-ranked row among rows present**. Map back to model indices.
- `applyXYFill`: Overview-guarded; existing = first factor whose trimmed name == "XY" case-insensitively (reuse id) else new; `baseHex = spec.baseHex or existing.levels.first.colorHex or newLevelColor(fallback: factors.count)`; ramp(count); one edit "XY Position Fill": create Factor(id, "XY") if absent; per k ensureLevel(names[k]), **overwrite colour ramp[k]**, assign. Stale levels/assignments from a larger run are NOT removed. Then setActiveFactor(XY); flash "Numbered {n} positions: {first} → {last}". Pinned: 96-well turned → XY01 = H1, XY08 = A1, XY09 = H2.

### C15. Randomise: Overview-guarded; needs active factor + plate; wells = selectedWells; count > 1 else silent; shuffle the level ids **including nils** and write back; edit "Randomise Selection"; flash "Randomised {n} wells."

### C16. Zoom: zoomIn ×1.4, zoomOut ÷1.4, fit = 1; clamp [1, 10]; zoom about visible centre; `canZoomOut = zoom > 1.001`; the canvas keeps its unmagnified size (magnification reveals part of the same layout).

### C17. Export naming: window title with " — Edited" and ".plate" stripped, "Plate Layout" when blank/Untitled; success "Exported {filename}"; failure alert "Could not export".

### C18. Canvas input contract (mouse-down: `freeformBrush = Ctrl`, `erase = Alt`, `pendingLevel = armed`, painting drag iff erase or armed):
| Hit | Plain | Shift | Ctrl |
|---|---|---|---|
| well | select single, anchor=pos | select(anchor: selection.anchor or customFocus, focus: pos) | customDragBase = positions; toggleWell; drag then paints freehand (armed) or addToSelection (disarmed) |
| column header | select whole column | anchor from selection.anchor.col | — |
| row header | select whole row | anchor from selection.anchor.row | — |
| corner | rotatePlate, no paint/selection change | | |
| outside | clearSelectionMarquee | | |
Paint commits **once on mouse-up** from accumulated pending wells ("Paint Wells"/"Erase Wells"); armed Ctrl-drag paints without touching customWells; drags clamp to nearest well. Keys without Ctrl: arrows moveCursor(extend: Shift); Backspace/Delete clearSelection (Shift → all factors); Esc disarm; Enter paintSelection; 1–9 armLevel(n−1); 0 armLevel(9); `[`/`]` cycleLevel; f/Space paintSelection; Tab/Shift+Tab cycleFactor. With Ctrl and canvas focused: C copy, Shift+C copy w/ headers, X cut, V paste, A select all. `focusCanvas()` after sidebar clicks.

### C19. Exact strings: defaults "Condition {n}", "Level 1", "Factor"/"Factor 2", "Plate"/"Plate 2", "{name} copy"/"{name} copy 2", "State {n}", "XY", XY01/XY001. **Starter document**: factor "Condition" with levels "Untreated", "Vehicle", "Treated" on palette colours 0/1/2; plate "Plate 1" 8×12. Undo names: Paint Wells, Clear Wells, Erase Wells, Fill Selection, Clear Selection, Clear All Factors, Add Level, Rename Level, Change Colour, Delete Level, Delete Conditions, Reorder Levels, Recolour Levels, Remove Unused Levels, Add Factor, Rename Factor, Set Unit, Change Factor Type, Reorder Factors, Delete Factor, Delete Factors, Add Plate, Duplicate Plate, Delete Plate, Rename Plate, Change Plate Format, Turn Plate, Well Label Style, Well Labels, Save State, Rename State, Delete State, Revert to {name}, Edit Well Note, Edit Plate Note, Paste, Import Table, Series Fill, XY Position Fill, Randomise Selection.

### C20. Edge cases to reproduce (pinned by tests): clearSelectionAllFactors works in Overview; paste ignores customWells; addPlate on starter → "Plate"; setFormat same-format returns True without edit; applySeries recolours+resorts all levels and forces numeric; applyXYFill leaves stale levels; snapshot cap global/naming per plate; moveCursor with nothing selected → A1 regardless of delta; formatChangeWouldLoseData only on shrink; plateIndex falls back to 0.

## Feature parity inventory — D. Canvas rendering & geometry (`Views/PlateCanvasView.swift`)
Y grows downward on Mac too (flipped view) — no inversion needed in Qt.

### D1. PlateGeometry — must match
Inputs: format, bounds, `turns = ((t%4)+4)%4`. `isTurnedOnEnd = turns%2==1`; `verticalStripOnRight = turns∈{1,2}`; `horizontalStripAtBottom = turns∈{2,3}`; displayRows/Cols swap when on end.
Cell solve:
```
pad=14; availW=max(w-28,1); availH=max(h-28,1); maxCell=96; minCell=0.01
headerWidth(c)=clamp(c*1.05,26,54); headerHeight(c)=clamp(c*0.80,18,34)
fit(hw,hh)=min((availW-hw)/gridCols, (availH-hh)/gridRows)
size=min(96, fit(26,18)); repeat 3×: size=min(size, fit(headerWidth(size),headerHeight(size)))
size=clamp(size,0.01,96); cell=size; headerW=headerWidth(size); headerH=headerHeight(size)
totalW=headerW+cell*gridCols; totalH=headerH+cell*gridRows
originX=14+max(0,(availW-totalW)/2)+(verticalStripOnRight?0:headerW)
originY=14+max(0,(availH-totalH)/2)+(horizontalStripAtBottom?0:headerH)
```
Only ever `min` → guaranteed to fit; **never add a readability floor**. Pinned at 940×560: 6/12/24 → 96, 48 → 83, 96 → 62.25, 384 → 31.644, 1536 → 16.0625; all standard ≥ 9.
Rects: `gridRect` (origin, cell×displayCols × cell×displayRows); `frameRect` (grid + one strip each axis); `cellRect(row,col)` via displayPosition; `rect(of: WellRange)` union of corner cells; `horizontalHeaderRect(i)`/`verticalHeaderRect(i)` display-indexed (strip y = bottom edge if at bottom else originY−headerH; x symmetric); `columnHeaderRect(col)`/`rowHeaderRect(row)` model-indexed (use these); `cornerRect = (verticalStripX, horizontalStripY, headerW, headerH)`.
Rotation: `display(r,c)`: 0→(r,c); 1→(c, rows−1−r); 2→(rows−1−r, cols−1−c); 3→(cols−1−c, r). `model(dr,dc)`: 0→(dr,dc); 1→(rows−1−dc, dr); 2→(rows−1−dr, cols−1−dc); 3→(dc, cols−1−dr). Rotation not transpose (handedness/cross-product test at all 4 turns; A1 walks corners clockwise).
Hit-testing: `line(offset,origin)=floor((offset−origin)/cell)` guarded (cell>0, finite, clamp ±1e6). `hit(point)`: inside grid → `.well(model(down,across))`; on-grid-x and y in horizontal strip → `.rowHeader(model row)` if on end else `.columnHeader`; on-grid-y and x in vertical strip → `.columnHeader` if on end else `.rowHeader`; corner → `.corner`; else `.outside`. Strips name the model axis. `nearestWell(point)` clamps in display space then maps back.

### D2. Label plan — continuity is behaviour
```
scale = canvasFontScale (0.7…1.8); primary=clamp(cell*0.30,7,13)*scale; secondary=max(6.5*scale, primary*0.80)
gap=max(0.5, secondary*0.16); lineHeight(size)=size*1.18; bodyInset(cell)=min(2,max(1,cell*0.1))
stackHeight(n, primary?) = (primary?primaryH:secondaryH) + (n-1)*(secondaryH+gap)
Overview: primarySize=secondary, uniform=true
if stacksEveryFactor and factorCount≥2: available=cell-2*bodyInset
   if primaryHeight>available: lines=0 else lines=1; while stackHeight(lines+1)≤available: lines+=1; lines=min(lines,factorCount); if <2 → 0
Overview regrow (lines≥2): reserved=(factorCount>lines)? max(3,cell*0.15)+2 : 0
   fitted=(available-reserved-(lines-1)*gap)/(lines*1.18); primary=secondary=clamp(fitted, secondary, primary)
wellFontSize=clamp(cell*0.30,7,13)*scale
```
No rounding/stepping anywhere (line count must be monotone non-decreasing in cell; Overview never fewer lines than All).
`drawFitted`: trim; bail width ≤ 8; padding = center ? max(2, w*0.12) : 1; bail available ≤ 2; floor = max(6, min(minFont or 7, maxFont)); linear first guess then ≤8 shrink iterations ×min(0.97, avail/width), then ellipsis; single line, never wrap.

### D3. Draw order & modes
Order: background (white in export, window bg on screen) → gridRect filled text-background, radius 3 → headers + corner → plan; `stacked = factors[:lineCount]` if ≥2, overflow rest → wells in model order → line key if stacking → **export guard** → screen-only overlays.
| Mode | showsText | stacks | fill | text |
|---|---|---|---|---|
| None | no | no | active level colour / empty | none (strip possible) |
| Active | yes | no | active level colour | name centred, only if cell ≥ 17 |
| All | yes | yes | active level colour | one line per factor (Active-style single text if lineCount<2) |
| Overview | yes | yes | **neutral tile always** | uniform stack; too dense → factor 1 as well text, rest to strip |
Per well: hairline when cell ≥ 4 (separator α0.6, inset 0.25, w 0.5); body = inset bodyInset, minus `stripeHeight+1` if strip; if not stacked and wider than tall → centre-crop square. Shape: circle iff `roundWells && stacked.isEmpty && width ≥ 8`, else rounded rect radius min(2.5, w/5) — **squares forced when stacked**. Painted: fill colour; stroke colour blended 25% black α0.55 w0.75. Empty fill: custom colour if set else quaternary label α0.13 screen / 0.10 export. Overview tile: custom colour if set, else white 0.32 under alwaysWhite, else quaternary α0.18 / 0.14 export. Notes mark (screen only): label α0.45 right-triangle in **top-right**, side clamp(w*0.16,4,7), inset 1.5.
Factor stack: `textColor = wellColour.labelInk(style) or (uniform ? neutralInk : neutralInk α0.75)`; `railWidth=clamp(bodyW*0.09,2.5,5.5)`, active ×1.45; `inset=max(2.5,bodyW*0.055)`; `textGap=max(2,railWidth*0.75)`; `textStart = minX+inset+activeRailWidth+textGap` (one x for all lines); `y0 = minY + (bodyH − reservedBottom − stackHeight)/2`. Slots = document factor order, unassigned keep their slot (empty capsule α0.16, no text). Active-line emphasis: band (when lineHeight ≥ 8 and bodyW ≥ 24; textColor α0.15, bleeding min(1.5, gap*0.6), radius min(3,h/3)); rail ×1.45; semibold at primary size. `primarySlot` = index of active factor among drawn lines, or nil if uniform or active didn't get a line (never fall back to slot 0). Rail capsule at x=minX+inset, y=lineY+h*0.14, h*0.72; when `isPrimary && levelColour == wellColour` → solid marker in `contrastingShade` (deeperShade) or textColor (matchLabel), **no outline**; else fill level colour + wall max(0.9, rail*0.19) primary / 0.75 secondary in textColor α1/α0.7. Text from textStart to maxX−inset, fitted at tier size (min tier×0.85), left, textColor (α0.86 for secondary).
Colour strip: not stacking → strip factors = secondaryFactors when showSecondaryFactors || Overview; `stripeHeight = cell ≥ (Overview?10:22) ? max(3, cell*0.15) : 0`; band bottom of cell inset 2. Stacking → overflow factors regardless of toggle; `leftover = cell−2*bodyInset−stackHeight(stacked)`; `stripeHeight = leftover ≥ 5 ? min(max(3,cell*0.15), leftover−2) : 0`; band flush with body bottom. stripeHeight 0 → factors hidden (counted). Segments equal width, shortened 0.75 when n>1, radius 1, unassigned = gap.
Line key (also exported): x=4, y=max(frameRect.maxY, bounds.maxY−14), width=bounds.w−8, height=min(14, max(0, bounds.maxY−frameRect.maxY)); skip if h<8 or w≤24; text `"Well lines:  "` + `"1 Name"`, `"2 Name"`… joined by 3 spaces + `"+N in stripe"` + `"+N not shown"`; 9.5→7 pt medium, secondary label colour.
Headers: `headerFontSize = max(7, min(headerH*0.55, cell*0.42, 12))*scale` semibold; row letters always; column numbers stride `cell≥15?1 : cell≥10?2 : 4` (draw when displayIndex%stride==0 or ==0); highlight (screen only) accent α0.16 fill + accent text for rows/cols in selection; else secondary label.
Text colour: automatic → white iff luminance ≤ 0.175 else black α0.85; alwaysBlack; alwaysWhite (Overview tile darkens to white 0.32). `neutralInk` = custom empty colour's labelInk if set, else fixed ink, else label colour.
Screen-only overlays: spotlight (text-background α0.8 over every well whose active-factor level ≠ spotlit); selection (discontiguous: per-well fill accent α0.10 + outline inset 1 w2; rectangle: one fill+outline + focus-cell outline accent α0.9 inset 1.5 w1.5 when >1 well); hover (label α0.35 inset 1 w1).

### D4. Interaction (see C18) + zoom: scroll area with min magnification 1 = fit, max 10; content keeps the unmagnified viewport size and zoom is a scale on top; zoomIn/Out ×/÷1.4; fit=1; centre on visible middle; pinch/Ctrl+wheel; publish zoom back for the status bar.

### D5. Export/print: PNG at on-screen size × device pixel ratio; PDF vector; both `exportMode` under light appearance: white bg, no header highlight, **no corner control, no note marks, no spotlight, no selection/cursor, no hover**, empty alpha 0.13→0.10, tile 0.18→0.14 (custom colour unchanged), **line key still drawn**. Print: landscape iff w ≥ h, fit to one page, centred, 24 pt margins, exportMode, unmagnified bounds (whole plate regardless of zoom).

### D6. Performance: whole-view repaint on model/hover/selection change; **clip the well loop to the dirty rect** (`event.rect()`); density ramps (hairlines off <4, strided numbers, text only ≥17, strips ≥22/10); cache `QFontMetrics` per (family,size,weight) and fitted size per (text, tier, width); one font factory (`Preferences.canvasFont`).
Taste (safe to approximate): exact stroke widths/alphas, radii, turn-arrow glyph (must reverse between states), ellipsis loop count, note-triangle size, key font ramp, `contrastingShade` push.

## Test plan (from the 18 Swift test files, 311 tests) — port as pytest / pytest-qt
**(a) Pure logic → pytest (M1/M2/M4/M5)**: `CoreTests` (WellNaming, PlateModel incl. column pruning & (row,col) resize & lossy shrink & ensureLevel case-insensitive & removeLevel & JSON round-trip; Selection incl. out-of-bounds→[95]; TableIO TSV/CSV/header strip/tidy grid/Plate column; Series maths incl. exact strings; Editor paint/undo, paste creates levels + moves selection, copy TSV exact, randomise counts, clear-all); `WorkbookTests` (via zipfile+openpyxl: sheet lists both arrangements, joint map on/off/blank→"+", scope incl. unmatched id keeps all, combined heading with unit, block pitch, cell refs AA1/AV1, remembered settings); `LayoutCompatibilityTests` (missing fields, unknown mode → activeFactor, ragged columns normalised, clamp 0×5000 → 1×96, custom formats round-trip); `PlateTemplateStoreTests`; `CustomFormatFlowTests` (all-or-nothing template save, same-format no-op, factor reorder undoable & keeps assignments); `SavedStateTests` + `PerPlateStateTests` (all rules in C10 incl. legacy adoption); `NotesTests`; `XYFillTests` (all C14 rules incl. turned plate H1=XY01, discontiguous, one undo step, Overview refusal); `PaletteGridTests` (base at index 2, strictly light→dark, no repeats, low-sat not paler than empty (lum<0.72), 8 columns ending neutral, first 8 auto colours in grid, colour-blind separation > 1.4× standard under deuteranope sim, **nothing the app hands out flips to white**, floor 0.19 with headroom, hex matching lenient, degenerate inputs); `PreferencesTests` (defaults, lenient decode, reset, empty-well hex verbatim in export, font scale clamp, firstColor ladder & fallback, default same blue per factor, neverRepeat across add/paste/recolour, font scale uniform); `LayoutTemplateTests`; `RowReorderTests` (pre-move index off-by-one); `OrientationTests` model half (automatic rule, three-valued, undoable+saved, 2-state toggle, absent → automatic, retired keys, no data change); `OverviewModeTests` model half (C9 rules).
**(b) UI → pytest-qt / offscreen (M3/M6)**: `PaintingInteractionTests` (drag paints rect only; disarmed drag selects; header click selects+paints; corner rotates & paints nothing; Alt erases; Shift extends; off-plate drag clamps; click off deselects; outside mousedown paints nothing; no-selection actions safe; arrow restarts at A1; paste at A1; hover summary; number keys/space/delete); `SelectionInteractionTests` (Ctrl-click never paints; toggle off; last toggle clears; armed Ctrl-drag = brush with customWells nil; disarmed adds rect; plain click restores rectangle; Shift-click extends from last toggled; arrow collapses; fill on discontiguous; copy refuses); `SidebarMultiSelectTests`; `LabelPlanTests`/`LabelLayoutRegressionTests`/`MultiFactorRenderTests` (monotone lines, fits, headline = active, none promoted when overflowed, ≥13.9 pt below plate for key, hit-test agrees with drawing when key shown, every mode × format renders); `OrientationTests` geometry half (rotation not reflection, corners, identity after 4, distinct cells, click centre hits at all turns, headers name model axis, strips/corner travel, clamp, selection rect same wells); `OverviewModeTests` render half; `RenderPreviewTests` (cell sizes table, custom empty colour pixel-identical, spotlight dims others, Overview tile takes custom colour, font settings change bytes, never overflow, hit-test bands, 1×1 canvas safe); `ZoomTests` intent.
**(c) Not ported**: `UpdateCheckerTests` (DMG-specific; version ordering reusable if M7 updater), `/usr/bin/unzip` harness, AppKit identity checks, `RowClickTracker` timing (Qt has doubleClicked; keep the product rule "second click on selected row = rename").
**Fixtures to create** (`python_port/tests/fixtures/`): copy `Tools/verify/{allfactors,overview,big384}.plate` (overview = genuine legacy no-orientation file; big384 = Python-written with non-palette hexes — don't assert palette membership on it). Generate via a Swift env-gated emitter (`PLATE_DOC_PATH` in `CoreTests:493` — extend `sampleLayout()` or add sibling tests) the matrix: multi-plate with data on both & differing formats & duplicate name; saved states (2 plates × 2 states; legacy 1-plate no plateID; legacy multi-plate no plateID; 20-cap); notes (doc `notes`, plate `note`, wellNotes keys "0", last, beyond-count, whitespace-only); orientation ×3 + tall plate upright; retired keys (`transposedView` t/f, `quarterTurns` 0/1/3, both keys with explicit orientation); custom formats 5×7, 1×8, 1×1, 64×96, hand-edited 0×5000, −4×7; all four label modes + "holographic" + absent; **unknown extra key at every level** (highest-value missing fixture — a naive `dataclass(**d)` explodes); ragged columns; padWellLabels + numeric factor with `µM`; all-null column present. Plus port-written files under `fixtures/port_written/` for the Mac-side decode test.
**37 non-obvious rules** the tests reveal are all captured in sections B–D above (Apple epoch, UUID case, pruning, lossy-normalising decode, Plate required keys, clamp-to-last-well, (row,col) resize incl. notes, note targets focus not anchor, Overview ⇒ nothing active re-derived on load/undo/redo/delete, leave-Overview restores previous mode, XY fill is the only orientation-dependent data op, single well = nothing for XY, revert merges, disarmed vs stale re-arm, saved-match ignores display settings & recomputed from layout, per-plate duplicate refusal, snapshots don't nest, legacy adoption, retired keys, three-valued orientation, rotation not transpose, Ctrl-drag dual meaning, Ctrl-click never paints, copy refuses/fill accepts discontiguous, headers paint/corner rotates, monotone label lines, headline = active, no colour flips to white, 8 columns ending neutral, same first blue per factor, custom empty colour verbatim in export, pngData omits transient state, unmatched onlyPlate = all, series 3-sig-fig strings + numeric kind, paste creates only missing levels, template refusal rules, starter = Condition/Untreated/Vehicle/Treated).

## Milestones (each ends green on `pytest`, runnable on this Mac; nothing skipped silently)

- **M0 — Document + scaffold (this session's execution):** write `python_port/PORT.md`
  (all spec sections below, expanded), `PARITY.md`, `README.md`, `pyproject.toml`,
  package skeleton, venv, `.gitignore` additions, copy the three Mac fixtures.
- **M1 — Model + codec + palette + formats:** `layout.py`, `plate_format.py`,
  `palette.py`, `preferences.py`, `templates.py`; pytest: round-trip every fixture
  byte-for-byte modulo key order/whitespace (compare parsed JSON), defaults for absent
  keys, unknown keys tolerated, retired keys mapped, well naming, resize semantics,
  palette hex tables + shade/ramp maths + next-colour rules (per-factor and never-repeat).
- **M2 — Editor core:** `plate_editor.py` with every operation in the inventory,
  `QUndoStack`-based `PlateDocument`, reconcile-from-layout, selection model
  (rectangle + custom set + anchor/cursor), multi-select rules; pytest ports of the Swift
  logic tests (undo one-step, saved states, XY fill, series maths, notes, paste…).
- **M3 — Usable app:** main window, canvas (None/Active modes, painting, drag select,
  header paint, keys, rotation, zoom), sidebar (factors/conditions, rename, reorder,
  ⌘-multi-select → Ctrl), plate tabs, menus + shortcuts (⌘→Ctrl, ⌥→Alt, ⇧→Shift),
  status bar, open/save/save-as/autosave/new/recent, Custom Size sheet + templates.
- **M4 — IO:** copy/cut/paste TSV (with/without headers, header detection), Import
  Table, Tidy CSV, XLSX workbook (both arrangements, scope, one-cell map, Legend, notes),
  PNG/PDF export, print. pytest opens the produced .xlsx with openpyxl and asserts
  sheet names/cells/fills.
- **M5 — Advanced editing:** Series Fill, XY Position Fill, Randomise, saved states
  (per-plate, bookmark filled, revert-merges rule, 20 cap), notes (well + plate),
  layout templates (Save as / New from / Remove), Factor menu ⌘1–9 → Ctrl+1–9.
- **M6 — Display parity:** All / Overview modes with rails, active-line emphasis,
  colour-strip fallback, key under the plate; spotlight on hover; colour grid popover
  (3 families, shades, used-dot, Custom…); Recolour ⋯ menu; Settings dialog with all
  tabs (text colour, active marker, well shape, new-condition colours, empty-well
  colour, plate font/size, sidebar counts) + live preview.
- **M7 — Windows packaging:** PyInstaller spec (onedir), `.ico`, `build_windows.md`
  (exact commands for a clean Windows machine), smoke checklist; optional update
  checker (GitHub releases API, Windows asset) last.

## Testing & verification (how each milestone is proven)

- `cd python_port && .venv/bin/pytest -q` — headless: `QT_QPA_PLATFORM=offscreen` set
  in `tests/conftest.py`; pytest-qt for canvas/sidebar interaction tests (synthesised
  QMouseEvent/QKeyEvent, mirroring `PaintingInteractionTests`/`SelectionInteractionTests`).
- **Cross-app compatibility, both directions:** (1) every Mac fixture opens in the port
  and re-saves to JSON that parses equal; (2) port-written files are opened by the Mac
  test-suite: add a `LayoutCompatibilityTests` case that decodes
  `python_port/tests/fixtures/port_written/*.plate` (Swift side; small, done in M1) —
  and manually `open build/pLayout.app` on one to eyeball.
- Run the real app on this Mac: `cd python_port && .venv/bin/python -m playout
  <fixture>`; screenshots via the existing `Tools/verify/shot.py` with `OWNER` overridden
  to the Python process name (Qt window owner is `python`/`Python` — verify with the
  window list first; note in HANDOFF).
- Never let a test hard-code a palette hex — read `palette.py` tables (same rule as Mac).
- Fixture UUID keys are upper-case; the port's `to_json` **must emit `str(uuid).upper()`**
  and `from_json` should read case-insensitively (Swift's `UUID(uuidString:)` does).

## Windows packaging (Lorenzo runs on Windows; documented in `packaging/build_windows.md`)

- Python 3.12 x64 from python.org; `py -3.12 -m venv .venv; .venv\Scripts\pip install -e .[dev] pyinstaller`.
- `pyinstaller packaging/playout.spec` → `dist/pLayout/pLayout.exe` (**onedir**, not
  onefile: faster start, fewer AV false positives); zip the folder for distribution;
  optional Inno Setup script for an installer + `.plate` file association.
- Icon: `.ico` generated from the existing 1024-px icon PNG (`Tools/make_icon.sh` output)
  with Pillow at build time or committed once under `playout/resources/`.
- Known Windows realities to write into the README: SmartScreen prompt on an unsigned
  exe ("More info → Run anyway"), signing is optional/later; per-user install path.
- Smoke checklist on Windows: open a Mac-written `.plate`, paint, undo, export xlsx and
  open in Excel, save, reopen in Mac app.

## Ongoing sync process (Mac ships → port catches up)

- `python_port/PARITY.md` lists every feature line of `feature_list.md`'s Shipped
  section with a status (`✅ ported / 🚧 partial / ⛔ n/a on Windows / ⏳ todo`) and the
  Mac version it was checked against. A Mac release bump = a row to review.
- Any Mac commit touching `Layout.swift`'s codec, `Palette.swift` tables, `TableIO`, or
  `XLSXWriter` must add/refresh a fixture in `python_port/tests/fixtures/` and get a
  matching `layout.py`/`palette.py`/… change; the cross-compat test is what catches drift.
- The HANDOFF rule "a new shortcut updates three places" gains a fourth: `PARITY.md`.
- Port version string tracks the Mac version it matches: package version PEP 440 (`1.4.0`, `1.5.0`) with `MAC_VERSION` in `playout/__init__.py`.
