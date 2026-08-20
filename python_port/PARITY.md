# Feature parity — Mac pLayout ⇄ Python port

Checked against Mac version **1.4** (1.5 in progress); last updated 2026-08-19 with the pipetting prep sheet. Port version `1.4.0` (`playout.__version__`).
Legend: ✅ ported and tested · 🚧 partial · ⏳ not started · ⛔ deliberately not on Windows.
"Port keys" use Ctrl/Alt/Shift for ⌘/⌥/⇧; on a Mac running the port, Ctrl-sequences render as ⌘.

Rules: a Mac release bump means every row gets re-checked; a new Mac shortcut updates the
Mac `ShortcutsCard`, the README table, the menu item **and this file** in the same commit.

## Model and editing

| Feature | Mac keys | Port keys | Status | Milestone | Notes |
|---|---|---|---|---|---|
| Multi-factor model: factors with colour-coded levels; every well keeps a value per factor | | | ✅ | M1 | model + editor; drawn in M3 |
| `.plate` JSON documents, byte-compatible both ways | | | ✅ | M1 | contract in PORT.md; Mac suite decodes port-written files |
| Plate formats 6–1536 + custom sizes up to 64×96, savable as named templates | | | ✅ | M3 | Plate Format menu + Custom Plate Size dialog |
| Painting: drag rectangle, ⌘-drag brush, ⌥-drag erase, header click paints row/column, fill/clear selection | drag, ⌘drag, ⌥drag, space/F, ⌫ | drag, Ctrl-drag, Alt-drag, Space/F, Backspace | ✅ | M3 | canvas interaction tests port PaintingInteractionTests |
| Keyboard-first: 1–0 arm, `[`/`]` step, ⌘1–9 factors, arrows move/extend | | Ctrl+1–9 | ✅ | M3 | |
| Well display modes None / Active / All / Overview | ⇧⌘O | Ctrl+Shift+O | ✅ | M3 | renderer draws all four incl. rails, active emphasis, stripe, line key |
| Uniform undo — every edit incl. saved-state ops is one step | ⌘Z | Ctrl+Z, Ctrl+Shift+Z / Ctrl+Y | ✅ | M2/M3 | Edit menu shows the action name |
| Zoom: in, ⌘0 fit, never below fit | pinch, ⌘+/-/0 | Ctrl+wheel (pinch on Mac), Ctrl++/-/0 | ✅ | M3 | status-bar % button |
| Plate rotation (true 90°), corner button, saved in document | ⇧⌘L | Ctrl+Shift+L | ✅ | M3 | |
| Multiple plates per document; tabs with rename/duplicate/delete; per-plate formats | | | ✅ | M3 | QTabBar chips; double-click renames |
| Per-plate saved states: bookmark, revert, rename, delete; 20 kept | ⌥⌘S / ⌥⌘R | Ctrl+Alt+S / Ctrl+Alt+R | ✅ | M5 | popover under the toolbar button |
| Dose series fill: fold/linear, vehicle zero, high-to-low ramp | ⇧⌘D | Ctrl+Shift+D | ✅ | M5 | |
| Randomise assigned values within a selection | ⇧⌘R | Ctrl+Shift+R | ✅ | M3 | |
| XY Position Fill (Keyence imaging positions), display-order walk, re-run renumbers | ⇧⌘Y | Ctrl+Shift+Y | ✅ | M5 | |
| Mac-standard well selection: ⌘-click toggle, disarmed ⌘-drag adds rectangle, ⇧-click extends | | Ctrl/Shift | ✅ | M3 | |
| Sidebar multi-select (⌘-click rows) → Delete N as one undo step; painting pauses | | Ctrl-click | ✅ | M3 | |
| ⌘⌫ empties wells completely; ⌫ clears the active factor | ⌘⌫ | Ctrl+Backspace | ✅ | M3 | |
| Spotlight a condition on sidebar hover | | | ✅ | M3 | 1.5 feature |
| Layout templates: Save as Template… / New from Template / Remove | | | ✅ | M3 | File menu |
| Per-well and per-plate notes; corner mark; status bar; Note column in exports | ⌥⌘N | Ctrl+Alt+N | ✅ | M4 | |
| Overview block outlines: "Group identical wells" + All factors / one factor picker | | | ⏳ | — | 1.5; runs of identical wells, not bounding boxes; walked in display space |
| Unit field on every factor, not only numeric ones; clearable | | | ⏳ | — | 1.5; the model field already exists both sides |
| Pipetting prep sheet: serial/individual dilutions, compound × dose, totals from the well counts | ⌥⌘P | Ctrl+Alt+P | ⏳ | — | 1.5; own window, not a dialog. `Level.stock` and `Layout.prep` are new in the file format — **the port must decode both leniently before it can open a 1.5 file** |
| Stock concentration on a condition row in the sidebar | | | ⏳ | — | 1.5; only on the prep sheet's compound factor, only when set |
| Canvas board: plates, prep table and notes as cards; active card editable in place | ⇧⌘K | Ctrl+Shift+K | ⏳ | — | 1.5; `Layout.canvas` is a new optional key — an ordered `items` array, **not** a dict, since draw order is z-order. Placement is computed at display time and only written when a card is moved |

## Colours

| Feature | Status | Milestone | Notes |
|---|---|---|---|
| Colour grid: hues across, shades down; Standard / Colour-blind / Muted; already-used dot; Custom… | ✅ | M6 | |
| Recolour a whole factor: hue spread, or ramp when numeric | ✅ | M3 | sidebar ⋯ menu |
| Never-repeat mode (Settings) | ✅ | M6 | |

## Import and export

| Feature | Mac keys | Port keys | Status | Milestone | Notes |
|---|---|---|---|---|---|
| ⌘C / ⇧⌘C copy as cells, ⌘V paste back (new values → conditions), header detection | ⌘C ⇧⌘C ⌘V | Ctrl+C, Ctrl+Shift+C, Ctrl+V | ✅ | M3 | Edit menu; Copy with Headers listed there |
| Copy / paste wells with every factor, across documents | ⌥⌘C ⌥⌘V | Ctrl+Alt+C, Ctrl+Alt+V | ⏳ | — | 1.5; private pasteboard flavour `com.nettilor.playout.wells` (JSON) plus a joined-text grid; ⌘V routes to it when present |
| File → Import Table (CSV/TSV) | ⇧⌘I | Ctrl+Shift+I | ✅ | M3 | |
| Excel workbook export: maps, Wells, Legend; arrangements; scope; one-cell map | ⌘E | Ctrl+E | ✅ | M4 | openpyxl; options asked before the save dialog |
| Tidy CSV export | ⇧⌘E | Ctrl+Shift+E | ✅ | M4 | |
| Plate image PNG / PDF; print scaled to one page | ⌘P | Ctrl+P | ✅ | M4 | PNG at the on-screen size × DPR, vector PDF |
| Image export asks whether to include the Overview block outlines | | | ⏳ | — | 1.5; remembered like the workbook options |
| Prep tab in the Excel workbook | | | ⏳ | — | 1.5; appended after Legend, only when the document has a prep setup |
| ⌘P prints the prep sheet when its window is frontmost | ⌘P | Ctrl+P | ⏳ | — | 1.5; the menu item retitles to say which it will print |

## Settings

| Feature | Status | Milestone | Notes |
|---|---|---|---|
| Text colour, active marker, live preview | ✅ | M6 | |
| Default well shape for new documents | ✅ | M6 | |
| Empty-well background colour (Overview tiles, exports, print) | ✅ | M6 | |
| Plate typeface and text size | ✅ | M6 | |
| Sidebar: per-factor condition counts | ✅ | M6 | |
| Settings window in tabs | ✅ | M6 | |
| Canvas board background colour | ⏳ | — | 1.5; dot grid takes its contrast from it |
| Overview block outline colour and thickness | ⏳ | — | 1.5; default colour follows light/dark, thickness capped at a quarter of the cell |

## App and distribution

| Feature | Status | Milestone | Notes |
|---|---|---|---|
| Document windows (one per file), autosave in place | ✅ | M3 | recent files, argv, Finder open events |
| Windows build (PyInstaller onedir) + optional installer with `.plate` association | ✅ | M7 | spec + Inno script; built on Windows by Lorenzo |
| Release DMG | ⛔ | — | Mac only |
| Update checker (daily / on demand) | ⛔ | — | omitted from v1 by decision; may return in M7 against a Windows asset |
| macOS Versions / "Revert To" browser | ⛔ | — | no equivalent; autosave-in-place makes "Revert to Saved" a no-op — not offered |

## Deliberate deviations (functionally equivalent)

- Toolbar has no "islands"; groups are separated by plain separators.
- Settings live under **Edit → Preferences… (Ctrl+,)** instead of the app menu.
- **Copy with Headers** is listed in the Edit menu (on the Mac it is a canvas-only key equivalent).
- The workbook export options are a small dialog *before* the file dialog rather than a save-panel accessory.
- Row context menus carry an extra "Rename…" item (double-click also renames); the Mac renames on a timed second click.
- Toolbar icons are simple painted glyphs, not SF Symbols.
- Preferences are an Ini file (`%APPDATA%\nettilor\pLayout.ini`; `~/.config/nettilor/pLayout.ini` on a Mac), never shared with the native app's defaults.

## Known quirks reproduced on purpose (fix on the Mac first, then port — never in the port alone)

- Paste ignores a discontiguous (custom) selection for its origin and does not clear it.
- `Add Plate` on the starter document names the plate "Plate" (unique-name rule against "Plate 1").
- `Clear All Factors in Selection` works in Overview and without an active factor.
- Series fill recolours and re-sorts *all* levels of the factor and makes it numeric permanently.
- XY fill leaves stale levels/assignments from a previous, larger run.
- Snapshot cap (20) is document-wide while numbering is per plate.
