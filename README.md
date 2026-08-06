# pLayout

A native macOS editor for microplate layouts. Pick a condition with a number key,
drag across wells to paint it, and export a spreadsheet that Excel, Prism, R or
pandas can read directly.

Supports 6, 12, 24, 48, 96, 384 and 1536-well plates, plus any custom size you
define.

![pLayout showing a 96-well plate with three factors labelled in each well](app_layout.png)

## Build

```sh
./build.sh
open "build/pLayout.app"
swift test          # 148 tests
```

Swift Package Manager, no third-party dependencies. Requires macOS 14 or later.

Like other document-based Mac apps, it opens a file picker at launch — `⌘N`, or
the **New Document** button in that panel, starts an empty 96-well plate.

## The model: factors, not just labels

Most plate maps have more than one variable. A document holds a list of **factors**
(Cell line, Drug, Dose, Timepoint…), each with its own colour-coded **levels**. You
paint one factor at a time, and every well keeps a value for each of them.

With a single factor it behaves exactly like a simple condition painter.

In the sidebar, a **single click** on a factor or condition selects it — anywhere on
the row, including the name — and a **double click** on the name renames it. Escape
abandons a rename, Return or clicking away keeps it.

### How much each well shows

**Display → Text in wells** in the sidebar has four settings:

| Setting | What a well shows |
| --- | --- |
| None | Colour only |
| Active | The active factor's value, filling the well (the default) |
| All | One labelled line per factor, stacked |
| Overview | Every factor at one size on a plain well, nothing selected |

In **All** the lines follow the order of the factor list — drag factors in
the sidebar to reorder them — each headed by a small rail in that level's colour,
with a key under the plate naming the order. The line for the factor you are
currently painting is called out three ways — a shaded band across the row, a wider
solid marker in place of its rail, and larger bold text — so every well says what a
click would change; switching factors moves the emphasis. Its rail becomes a plain
marker because in this mode the well is already flooded with that factor's colour,
which would leave a coloured rail invisible against it. If the active factor did not
fit as a line, no line is promoted rather than a different one being claimed. A
factor with no value in a well keeps
its slot, so line 2 means the same factor in every well and a blank reads as a blank
rather than a shifted line. Wells are drawn as rounded squares in this mode because
circles waste the width the text needs. Factors that do not fit at the current well
size fall back to the colour strip along the bottom, so nothing is silently dropped.

**Overview** (`⇧⌘O`) is the same stack with the design read rather than edited. The
well takes no colour from any factor — every one is a plain neutral tile, so the only
colour in the plate is the rails — and no line is treated as the headline, so all of
them share one size and weight. Choosing it also deselects the factor you were
painting: nothing is armed, clicking selects wells without changing them, and an edit
says so rather than quietly doing nothing. Click any factor, press `⇧⌘O` again, or
pick another setting to go back to exactly what you were doing.

Both stacking modes supersede the *Show other factors* checkbox, which is therefore
hidden while either is on — the stacked list already accounts for every factor. On a
plate too dense to stack, Overview keeps the first factor as the well's text and drops
the rest to the colour strip, so a 384- or 1536-well design still reads at a glance.

The setting is saved with the document, so a layout reopens — and exports — the
way you designed it.

## Custom plate sizes

**Plate format → Custom Size…** (in the toolbar or the Plate menu) takes any
layout from 1×1 up to 64×96 and previews it as you type. Tick *Save as a template*
to name it and have it appear in the format menu from then on; saved templates are
shared across documents and can be renamed or deleted from the same sheet.

Templates store only the name — a document records its plate as plain dimensions,
so deleting a template never affects a layout that used it.

## Painting

| Input | Action |
| --- | --- |
| `1`–`9`, `0` | Arm condition 1–10 of the active factor |
| `[` / `]` | Previous / next condition |
| `⌘1`–`⌘9` | Switch active factor |
| `⇧⌘O` | Overview — every factor at once, nothing armed; again to go back |
| drag | Paint a rectangle of wells |
| `⌘`-drag | Free-hand brush |
| `⌥`-drag | Erase |
| click `A` or `1` header | Paint a whole row or column |
| click the corner | Whole plate |
| `space` or `F` | Fill the current selection |
| `⌫` | Clear the active factor in the selection (`⇧⌫` clears every factor) |
| `⎋` | Disarm — drag then selects without painting |
| click off the plate | Deselect |
| arrows | Move the cursor; `⇧`-arrows extend the selection |
| pinch | Zoom in; `⌘0` fits the whole plate again |
| `⌘Z` | Undo (every edit is one step) |

Zoom never goes below "whole plate in view" — that is the resting state, and pinching
only ever moves in closer. The current level shows in the status bar; click it to fit.

## Choosing colours

Clicking a condition's swatch opens a grid that reads in two directions: **across** a
row to tell two conditions apart, **down** a column for the same hue lighter or darker.
The middle row is the colour itself, so a condition the app coloured for you shows up
selected rather than as "custom", and the last column is always a neutral for the
untreated arm.

Three families sit above the grid. **Standard** is the set new conditions are given.
**Colour-blind** is Okabe–Ito, which stays separable with red/green colour blindness —
worth reaching for on anything headed into a figure. **Muted** is softer tints, for a
plate crowded enough that full-strength colour is too loud.

A colour another condition of the same factor already uses is marked with a dot, so a
duplicate is visible before you pick it rather than after. Colours are only compared
within a factor: two factors sharing a blue is harmless, since they never occupy the
same line of a well.

**Custom…** at the bottom opens the system colour picker for anything else, and the
⋯ menu beside the condition list recolours every condition at once — as a spread of
hues, or as a light-to-dark ramp when the factor is numeric.

## Excel round-trip

`⌘C` puts the selection on the pasteboard as tab-separated text, which pastes
straight into Excel as cells. `⇧⌘C` includes the A–H / 1–12 headers.

`⌘V` pastes a block of cells back onto the plate at the selection's top-left
corner. Values it has not seen before become new conditions with colours assigned
from the palette, so you can build a layout in Excel and paste it in whole. If the
pasted block still has its row/column headers, they are detected and stripped.

**File → Import Table…** does the same from a CSV or TSV file.

## Export

- **Excel Workbook (`⌘E`)** — colour-coded plate maps, a `Wells` sheet with one row
  per well and one column per factor, and a `Legend` sheet. The maps keep the fill
  colours you painted with. The save panel offers two arrangements, and remembers
  which you picked:

  | Plate maps | What you get |
  | --- | --- |
  | One sheet per factor | A separate tab per factor — easiest to paste elsewhere |
  | All factors on one sheet | One tab per plate, each map headed by its factor name |
- **Tidy CSV (`⇧⌘E`)** — just the one-row-per-well table.
- **Plate image** — PNG or vector PDF of the plate for a lab notebook or figure.
- **Print (`⌘P`)** — the plate exactly as displayed, scaled to fill one page. The
  selection highlight is left out and colours are rendered light, so a dark-mode
  window still prints as a clean figure.

The `.xlsx` writer is built into the app (OOXML + a small ZIP writer), so exports
work offline with no Python or Excel involved.

## Saved states

Two buttons in their own toolbar island, at the left of the toolbar next to the
plate-format menu, for trying a combination out without committing to it:

| Button | Does |
| --- | --- |
| 🔖 Save State (`⌥⌘S`) | Bookmarks every factor and plate as they stand |
| ↺ Saved States | Opens the list: revert to, rename, or delete any state |

The bookmark **fills in** whenever the plate matches one of your saved states, so
you can tell at a glance whether what you are looking at is bookmarked or is an
experiment in progress. Saving an unchanged design is refused rather than adding a
duplicate. `⌥⌘R` reverts to the most recent state without opening the list.

Reverting restores the design only. Your saved states survive it, and so do the
display settings — going back to an earlier layout should not also change how you
are looking at the plate.

**Every one of these is an ordinary undo step.** Saving, reverting, renaming and
deleting each land in the undo stack, so a mis-clicked button costs one `⌘Z` and
never any work. States are stored in the `.plate` file, so they are still there next
time you open it; the twenty most recent are kept.

## Dose series

**Series Fill** (toolbar, or `⇧⌘D`) writes a value series across the selection —
fold dilutions or linear steps, across columns or down rows, with an optional
zero in the last position for a vehicle control. It creates the levels, orders
them high-to-low and colours them as a light-to-dark ramp.

**Randomise** shuffles the assigned values inside the selection, keeping the
counts, to guard against plate position effects.

## Multiple plates

A document can hold several plates that share one set of factors — useful for
replicate plates or a multi-plate screen. Plate tabs are above the grid; duplicate
or delete via right-click. Each plate can have its own format.

## File format

Documents are `.plate` files: plain JSON, one array of level IDs per factor per
plate. Autosave, versions and revert come from the standard document machinery.

## Layout

```
Sources/PLayout/
  App.swift              @main scene, menu bar commands
  Model/                 PlateFormat, Layout/Factor/Level/Plate, templates, document
  Editor/                PlateEditor (all mutations), WellRange
  Views/                 SwiftUI shell, sidebar, sheets, and the AppKit plate grid
  IO/                    TSV/CSV, ZIP writer, XLSX writer, workbook builder
Tests/PLayoutTests/      model, clipboard, workbook, painting, rendering, zoom
Tools/make_icon.swift    draws the app icon
```

Two invariants are worth knowing before changing the drawing code:

- **`PlateGeometry` must fit whatever rect it is handed.** Its cell size is solved,
  not computed, because the headers grow with it; the solve only ever shrinks, so
  the result is guaranteed to fit. A readability floor here would put wells outside
  the view, where they are invisible *and* unclickable.
- **Label sizes are continuous functions of the cell size.** Any step — even
  rounding — can make the number of label lines drop as the window grows, which
  reads as labels randomly disappearing. `LabelPlanTests` pins this down.
- **The plate view's document keeps its unmagnified size.** Zoom is `NSScrollView`
  magnification, so if the document view tracked the clip view's *bounds* it would
  re-fit the plate smaller and cancel the zoom exactly out. `PlateScrollView.tile()`
  pins it to `contentView.frame`; `ZoomTests` guards it.
- **Sidebar rows drive their own clicks and drags.** A row's tap gesture is what
  decides between select and rename (timed, not a double-tap recogniser), and that
  same gesture consumes the mouse movement that `List.onMove` needs — so reordering
  is an explicit `onDrag`/`onDrop` pair instead. `.onMove` was verified to be wired
  up correctly and still not to work, so do not "simplify" it back.
- **No toolbar item changes structure, enabled state, or width.** Any of the three
  makes AppKit re-tile the bar, which visibly splits the groups apart while the app
  is being used. Buttons stay enabled and explain themselves in their tooltip, and
  the plate-format item is icon-only because showing the format name resized it
  every time you clicked a plate tab of a different size.
- **Toolbar islands follow the placement region, not the code structure.** macOS
  draws one island per run of adjacent buttons and merges those runs regardless of
  `ToolbarItemGroup` or `ToolbarSpacer` — both were measured against the live
  `NSToolbarPlatterView` frames, and neither splits a run of plain buttons. Moving
  the saved-state pair to `.navigation` is what gives it an island of its own.
  Relatedly, `if #available` *inside* a `@ToolbarContentBuilder` silently discards
  the branch — `ToolbarSpacer` only takes effect when the availability check wraps
  the `.toolbar` modifier itself, which is why there are two toolbar variants.

`PlateFormat` is pure geometry. Custom names live on `PlateTemplate`, because every
"did the format change" guard in the app compares formats by dimensions alone.

`Layout` decodes by hand rather than through synthesis: Swift's generated decoder
ignores stored-property defaults, so a synthesized one would make every previously
saved document fail to open the moment a field is added.

`PlateEditor` reconciles the active plate, factor, level and selection from the
`document.$layout` sink rather than from any single action, because undo and redo
can delete whatever was active just as easily as an edit can. Doing it per-action
left redo able to strand the editor on a deleted factor, where painting wrote into
a factor that no longer existed — invisible on screen, but saved to the file.

The grid is a custom `NSView` rather than SwiftUI so that painting, drag
selection and key handling stay precise at 1536 wells; everything around it is
SwiftUI.

Every edit goes through `PlateEditor`, which funnels into
`PlateDocument.mutate`. That single choke point is what makes undo uniform:
each action stores the previous `Layout` and registers its inverse.

## Tests

`swift test` covers well naming, plate resizing, TSV/CSV round-trips, paste
header detection, dose series maths, and undo. Two suites go further:

- `PaintingInteractionTests` synthesizes real `NSEvent`s and feeds them to the
  grid, so drag-painting, header clicks, option-erase, shift-extend and the
  number-key hotkeys are exercised rather than assumed.
- `WorkbookTests` writes a real `.xlsx`, unzips it with `/usr/bin/unzip` (which
  validates CRCs and the deflate streams) and parses every part as XML.
- `LayoutCompatibilityTests` decodes documents written before the newer fields
  existed, so adding a field can never silently break saved files again.
- `RenderPreviewTests` asserts the plate fits its bounds for every shape at four
  canvas sizes, and pins the standard formats' cell sizes so a layout change that
  moves them is visible in the diff.

Two tests write artefacts when given a path, which is handy for eyeballing
changes:

```sh
PLATE_PREVIEW_PATH=/tmp/plate.png PLATE_XLSX_PATH=/tmp/layout.xlsx \
PLATE_ALL_FACTORS_PATH=/tmp/all-factors.png swift test
```

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE) — free for any noncommercial purpose,
including academic and nonprofit research, teaching, and personal projects. You may
read it, run it, modify it and share your changes; you may not use it commercially.

Commercial use requires a separate licence — open an issue to ask.

Copyright 2026 Lorenzo Netti. All rights not granted by the licence are reserved.
