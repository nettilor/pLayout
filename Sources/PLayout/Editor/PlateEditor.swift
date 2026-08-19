import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Everything the UI does to a document funnels through here, so the AppKit grid,
/// the SwiftUI sidebar and the menu bar all stay in step.
final class PlateEditor: ObservableObject {

    let document: PlateDocument
    var undoManager: UndoManager?
    weak var canvas: PlateCanvasView?
    weak var zoomController: PlateZoomController?

    @Published var activePlateID: UUID?
    @Published var activeFactorID: UUID?
    @Published var armedLevelID: UUID?
    /// nil means nothing is selected — clicking off the plate clears it.
    @Published var selection: WellRange? = WellRange(single: WellPos(row: 0, col: 0))
    /// A discontiguous selection, entered with ⌘-click. Non-nil overrides `selection`;
    /// rectangle-only operations (copy, paste, series fill) see "no selection" instead
    /// of silently acting on a bounding box that includes wells the user excluded.
    @Published var customWells: Set<WellPos>?
    /// The last well ⌘-clicked or ⌘-dragged over, so ⇧-click and the arrow keys have
    /// somewhere to resume the rectangular model from.
    private(set) var customFocus: WellPos?
    /// ⌘-selected sidebar rows, for bulk deletion. Non-empty means painting is off —
    /// there is no single armed condition while several rows are selected.
    @Published var multiSelectedFactorIDs: Set<UUID> = []
    @Published var multiSelectedLevelIDs: Set<UUID> = []
    /// The condition whose sidebar row the mouse is over: every other well dims so
    /// the plate itself answers "where is this?". Transient — never saved, never
    /// exported — which is why it lives here and not in the document.
    @Published var spotlightLevelID: UUID?
    /// Non-nil presents the note sheet for a well or the plate.
    @Published var noteTarget: NoteTarget?
    /// The prep sheet's window, owned here so it is per-document by construction and
    /// cannot outlive the document it describes.
    private(set) var prepWindow: PrepWindowController?

    enum NoteTarget: Identifiable, Equatable {
        case well(Int)
        case plate
        /// A note on the board. Routed through the same sheet as the other two, which is
        /// what keeps sticky notes from needing any text-editing machinery of their own —
        /// and an `NSTextView` inside a magnified board would render soft anyway.
        case canvasNote(UUID)
        var id: String {
            switch self {
            case .well(let well): return "well-\(well)"
            case .plate: return "plate"
            case .canvasNote(let id): return "note-\(id.uuidString)"
            }
        }
    }
    @Published var hovered: WellPos?
    @Published var showSecondaryFactors = true
    /// Overview only: draw a line round each run of identical wells, so a dense plate
    /// reads as the blocks it was designed as rather than as a field of stacked text.
    /// Per window like the two display toggles beside it — this is how you are looking
    /// at the plate, not something about the plate.
    @Published var showOverviewGroups = false
    /// What counts as "identical": nil is every factor at once, a factor id is that one
    /// alone. Grouping on everything can box each well on its own — an XY position
    /// factor makes every well unique — and one factor is the coarse view that fixes it.
    @Published var overviewGroupFactorID: UUID?
    /// Seeded from Preferences when the document opens; the sidebar toggle drives it
    /// afterwards, so changing the default never disturbs a window already up.
    @Published var roundWells = Preferences.shared.newDocumentWellShape.isRound
    @Published var transientMessage: String = ""
    /// Set by the menu bar; ContentView presents the sheets off these.
    @Published var showingSeriesSheet = false
    @Published var showingXYFillSheet = false
    @Published var showingCustomFormatSheet = false
    /// 1 means "whole plate in view", which is also the minimum.
    @Published private(set) var zoomLevel: CGFloat = 1
    /// Set when the design matches a saved state, which fills in the bookmark icon.
    @Published private(set) var matchingSavedStateID: UUID?

    private var cancellables = Set<AnyCancellable>()
    private var messageResetWork: DispatchWorkItem?
    /// What Overview stepped away from, so leaving it puts the brush back where it
    /// was rather than dumping the user on factor 1 in whatever mode.
    private var overviewReturn: (mode: WellLabelMode, factorID: UUID?)?

    init(document: PlateDocument) {
        self.document = document
        activePlateID = document.layout.plates.first?.id
        // A document saved in Overview reopens in it, and Overview means no factor is
        // being painted — `reconcileTargets` only sees *changes*, so it cannot do this.
        if !document.layout.wellLabelMode.isOverview {
            activeFactorID = document.layout.factors.first?.id
            armedLevelID = document.layout.factors.first?.levels.first?.id
        }
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Template names are shown in this window's toolbar and plate tabs, but the
        // store is shared, so a rename in another document has to reach here too.
        PlateTemplateStore.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Display settings live outside any document, so a change in the Settings
        // window has to reach every open canvas — the canvas redraws off this editor's
        // objectWillChange and has no other way to hear about it.
        Preferences.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // `$layout` delivers the new value, unlike objectWillChange, and it fires for
        // undo and redo too — not just for edits made through this editor.
        document.$layout
            .sink { [weak self] updated in
                self?.refreshSavedStateMatch(in: updated)
                self?.reconcileTargets(in: updated)
            }
            .store(in: &cancellables)
        // A state bookmarks one plate, so the filled bookmark changes when the plate
        // does even though the document has not. `@Published` fires during `willSet`,
        // so the incoming id is used rather than the property.
        $activePlateID
            .sink { [weak self] id in
                guard let self else { return }
                self.refreshSavedStateMatch(in: self.layout, plate: id)
            }
            .store(in: &cancellables)
    }

    deinit {
        // The controller holds the editor unowned, so a window still on screen when the
        // document goes would be pointing at nothing.
        prepWindow?.close()
    }

    // MARK: - Derived state

    var layout: Layout { document.layout }

    var plateIndex: Int {
        if let id = activePlateID, let i = layout.plates.firstIndex(where: { $0.id == id }) { return i }
        return layout.plates.isEmpty ? -1 : 0
    }

    var plate: Plate? {
        let i = plateIndex
        return layout.plates.indices.contains(i) ? layout.plates[i] : nil
    }

    var format: PlateFormat { plate?.format ?? .well96 }
    var activeFactor: Factor? { layout.factor(id: activeFactorID) }
    var armedLevel: Level? { activeFactor?.level(id: armedLevelID) }

    /// Reading the plate rather than editing it: no factor is active, so a click
    /// selects wells without painting them.
    var isOverview: Bool { layout.wellLabelMode.isOverview }

    var overviewGroupBasis: WellGrouping.Basis {
        overviewGroupFactorID.map { WellGrouping.Basis.factor($0) } ?? .allFactors
    }

    /// Drawn only where it was asked for: Overview, and the toggle on.
    var drawsOverviewGroups: Bool { isOverview && showOverviewGroups }

    var secondaryFactors: [Factor] {
        layout.factors.filter { $0.id != activeFactorID }
    }

    func wellCount(ofLevel level: Level) -> Int {
        guard let factorID = activeFactorID, let plate else { return 0 }
        return plate.assignedWellCount(factor: factorID, level: level.id)
    }

    /// "B7 · Condition: Treated · Dose: 10" for the status bar.
    func summary(row: Int, col: Int) -> String {
        guard let plate, plate.format.contains(row: row, col: col) else { return "" }
        let well = plate.format.index(row: row, col: col)
        let label = WellNaming.wellLabel(row: row, col: col, padded: layout.padWellLabels)
        let parts = layout.factors.compactMap { factor -> String? in
            guard let id = plate.levelID(factor: factor.id, well: well),
                  let level = factor.level(id: id) else { return nil }
            return "\(factor.name): \(level.name)"
        }
        var text = parts.isEmpty ? "\(label) — empty" : "\(label)  ·  " + parts.joined(separator: "  ·  ")
        if let note = plate.note(well: well) {
            text += "  ·  ✎ \(note)"
        }
        return text
    }

    // MARK: - Notes

    /// The note sheet for the well under the cursor — the selection focus, or the
    /// last ⌘-clicked well when the selection is discontiguous.
    func openWellNoteSheet() {
        guard let plate else { return }
        guard let focus = selection?.focus ?? customFocus,
              plate.format.contains(row: focus.row, col: focus.col) else {
            return flash("Select a well first.")
        }
        noteTarget = .well(plate.format.index(row: focus.row, col: focus.col))
    }

    func openPlateNoteSheet() {
        noteTarget = .plate
    }

    func noteTitle(for target: NoteTarget) -> String {
        switch target {
        case .well(let well):
            guard let format = plate?.format, format.cols > 0 else { return "Note" }
            let label = WellNaming.wellLabel(
                row: well / format.cols, col: well % format.cols, padded: layout.padWellLabels
            )
            return "Note for \(label)"
        case .plate:
            return "Note for \(plate?.name ?? "this plate")"
        case .canvasNote:
            return "Note on the board"
        }
    }

    func noteText(for target: NoteTarget) -> String {
        switch target {
        case .well(let well): return plate?.note(well: well) ?? ""
        case .plate: return plate?.note ?? ""
        case .canvasNote(let id): return layout.canvas?[id]?.text ?? ""
        }
    }

    /// An emptied note is a removed one — the sheet says so instead of keeping a
    /// blank around to mark wells for no reason.
    func saveNote(_ text: String, for target: NoteTarget) {
        switch target {
        case .well(let well):
            editPlate("Edit Well Note") { $0.setNote(text, well: well) }
        case .plate:
            editPlate("Edit Plate Note") {
                $0.note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .canvasNote(let id):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An emptied sticky note is a removed one, exactly as an emptied well note is.
            guard !clean.isEmpty else { return deleteCanvasItem(id) }
            var items = canvasItems
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].text = clean
            edit("Edit Note") { layout in layout.canvas = CanvasLayout(items: items) }
        }
    }

    // MARK: - Mutation plumbing

    private func edit(_ name: String, _ change: (inout Layout) -> Void) {
        document.mutate(name, undoManager: undoManager, change)
    }

    private func editPlate(_ name: String, _ change: (inout Plate) -> Void) {
        let index = plateIndex
        guard index >= 0 else { return }
        edit(name) { layout in
            guard layout.plates.indices.contains(index) else { return }
            change(&layout.plates[index])
        }
    }

    /// Sidebar clicks move focus off the grid; hand it back so number keys keep working.
    /// Hands the keyboard back to whatever the plate is being edited in — the canvas in
    /// plate mode, the active card on the board. Without the board case, clicking a
    /// sidebar row would leave focus nowhere and the number keys would stop arming.
    func focusCanvasSurface() {
        if showsCanvas, let card = board?.activeCardView {
            card.window?.makeFirstResponder(card)
            return
        }
        focusCanvas()
    }

    func focusCanvas() {
        guard let canvas else { return }
        canvas.window?.makeFirstResponder(canvas)
    }

    func flash(_ message: String) {
        transientMessage = message
        messageResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.transientMessage = "" }
        messageResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Painting

    func paint(wells: [Int], level: UUID?, actionName: String? = nil) {
        guard let factorID = activeFactorID, !wells.isEmpty,
              layout.factors.contains(where: { $0.id == factorID })
        else { return }
        // Said out loud rather than silently ignored — a brush that does nothing
        // reads as a bug (§ Overview taught the same lesson).
        guard !isMultiSelecting else {
            return flash("Painting is off while several rows are selected — click a single row to continue.")
        }
        let name = actionName ?? (level == nil ? "Clear Wells" : "Paint Wells")
        editPlate(name) { plate in
            for well in wells { plate.setLevelID(level, factor: factorID, well: well) }
        }
    }

    func paintSelection() {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        guard armedLevelID != nil else {
            flash("Pick a condition first — press 1–9 or click one in the sidebar.")
            return
        }
        guard hasSelection else {
            flash("Select some wells first.")
            return
        }
        paint(wells: selectedWells, level: armedLevelID, actionName: "Fill Selection")
    }

    /// Every edit needs a factor to write into, and Overview deliberately has none.
    /// Said out loud rather than silently ignored — a key that does nothing reads as
    /// a bug, not as a mode.
    private func flashOverviewIsReadOnly() {
        flash("Overview is read-only — click a factor to start painting again.")
    }

    func clearSelection() {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        paint(wells: selectedWells, level: nil, actionName: "Clear Selection")
    }

    /// Removes every factor's value from the selected wells, not just the active one.
    func clearSelectionAllFactors() {
        let wells = selectedWells
        let factorIDs = layout.factors.map(\.id)
        editPlate("Clear All Factors") { plate in
            for factorID in factorIDs {
                for well in wells { plate.setLevelID(nil, factor: factorID, well: well) }
            }
        }
    }

    // MARK: - Selection & navigation

    var hasSelection: Bool { customWells?.isEmpty == false || selection != nil }

    /// The wells an action would apply to, or an empty list when nothing is selected.
    /// A discontiguous selection overrides the rectangle while it exists.
    var selectedWells: [Int] {
        if let customWells {
            let f = format
            return customWells.map { f.index(row: $0.row, col: $0.col) }.sorted()
        }
        return selection?.indices(in: format) ?? []
    }

    /// The current selection as positions, whichever model it is in — the seed for
    /// entering the discontiguous mode without losing what was already selected.
    var selectionAsPositions: Set<WellPos> {
        if let customWells { return customWells }
        guard let range = selection?.clamped(to: format) else { return [] }
        var out: Set<WellPos> = []
        for row in range.minRow...range.maxRow {
            for col in range.minCol...range.maxCol { out.insert(WellPos(row: row, col: col)) }
        }
        return out
    }

    /// ⌘-click, the macOS standard: add an unselected well, remove a selected one.
    /// Entering this mode dissolves the rectangle into a set; any plain click, drag,
    /// arrow or select-all puts the rectangular model back.
    func toggleWell(_ pos: WellPos) {
        guard format.contains(row: pos.row, col: pos.col) else { return }
        var set = selectionAsPositions
        if !set.insert(pos).inserted { set.remove(pos) }
        customFocus = pos
        selection = nil
        customWells = set.isEmpty ? nil : set
    }

    /// ⌘-drag with nothing armed: adds a whole rectangle to the selection on top of
    /// `base` — the set as it stood at mouse-down, so the live drag can be replayed
    /// from it instead of accumulating every intermediate rectangle.
    func addToSelection(base: Set<WellPos>, rect: WellRange) {
        let clamped = rect.clamped(to: format)
        var set = base
        for row in clamped.minRow...clamped.maxRow {
            for col in clamped.minCol...clamped.maxCol { set.insert(WellPos(row: row, col: col)) }
        }
        customFocus = clamped.focus
        selection = nil
        customWells = set
    }

    func select(_ range: WellRange) {
        customWells = nil
        selection = range.clamped(to: format)
    }

    func selectAllWells() {
        customWells = nil
        selection = .wholePlate(format)
    }

    func clearSelectionMarquee() {
        customWells = nil
        selection = nil
    }

    func moveCursor(dRow: Int, dCol: Int, extend: Bool) {
        let f = format
        // Arrowing out of a discontiguous selection collapses it onto the last well
        // touched, the way every Mac list and table collapses on arrow keys.
        if customWells != nil {
            let from = customFocus ?? WellPos(row: 0, col: 0)
            customWells = nil
            selection = WellRange(single: WellPos(
                row: min(max(from.row + dRow, 0), f.rows - 1),
                col: min(max(from.col + dCol, 0), f.cols - 1)
            ))
            return
        }
        // Arrowing with nothing selected starts again at A1.
        guard let current = selection else {
            selection = WellRange(single: WellPos(row: 0, col: 0))
            return
        }
        let next = WellPos(
            row: min(max(current.focus.row + dRow, 0), f.rows - 1),
            col: min(max(current.focus.col + dCol, 0), f.cols - 1)
        )
        selection = extend
            ? WellRange(anchor: current.anchor, focus: next)
            : WellRange(single: next)
    }

    // MARK: - Sidebar multi-selection

    /// ⌘-click in the sidebar lists, for deleting several rows at once. While either
    /// set is non-empty there is no single armed condition, so painting is off; any
    /// plain interaction — clicking a row, arming by number key, Escape — leaves it.
    var isMultiSelecting: Bool {
        !multiSelectedFactorIDs.isEmpty || !multiSelectedLevelIDs.isEmpty
    }

    func toggleFactorInMultiSelection(_ id: UUID) {
        guard layout.factors.contains(where: { $0.id == id }) else { return }
        var set = multiSelectedFactorIDs
        // The active factor is the row already "selected", so it seeds the set —
        // ⌘-clicking a second row reads as selecting both, like any Mac list.
        if set.isEmpty, let active = activeFactorID, active != id { set.insert(active) }
        if !set.insert(id).inserted { set.remove(id) }
        if set.count <= 1 {
            multiSelectedFactorIDs = []
            if let only = set.first { setActiveFactor(only) }
            return
        }
        multiSelectedLevelIDs = []
        multiSelectedFactorIDs = set
        armedLevelID = nil
    }

    func toggleLevelInMultiSelection(_ id: UUID) {
        guard activeFactor?.levels.contains(where: { $0.id == id }) == true else { return }
        var set = multiSelectedLevelIDs
        if set.isEmpty, let armed = armedLevelID, armed != id { set.insert(armed) }
        if !set.insert(id).inserted { set.remove(id) }
        if set.count <= 1 {
            multiSelectedLevelIDs = []
            if let only = set.first { armLevel(only) }
            return
        }
        multiSelectedFactorIDs = []
        multiSelectedLevelIDs = set
        armedLevelID = nil
    }

    /// A plain sidebar click on a condition row: arm it and leave multi-selection.
    func armLevel(_ id: UUID) {
        exitMultiSelection()
        armedLevelID = id
    }

    private func exitMultiSelection() {
        if !multiSelectedFactorIDs.isEmpty { multiSelectedFactorIDs = [] }
        if !multiSelectedLevelIDs.isEmpty { multiSelectedLevelIDs = [] }
    }

    /// Deletes the ⌘-selected conditions as one undo step.
    func deleteLevels(_ ids: Set<UUID>) {
        guard let factorID = activeFactorID, !ids.isEmpty else { return }
        edit("Delete Conditions") { layout in
            for id in ids { layout.removeLevel(id, from: factorID) }
        }
        exitMultiSelection()
        if armedLevelID == nil { armedLevelID = activeFactor?.levels.first?.id }
    }

    /// Deletes the ⌘-selected factors as one undo step, keeping at least one.
    func deleteFactors(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var doomed = ids
        if layout.factors.allSatisfy({ doomed.contains($0.id) }), let spare = layout.factors.first {
            doomed.remove(spare.id)
            flash("A layout needs at least one factor — \(spare.name) stays.")
        }
        guard !doomed.isEmpty else { return }
        edit("Delete Factors") { layout in
            for id in doomed { layout.removeFactor(id) }
        }
        exitMultiSelection()
        if armedLevelID == nil, !isOverview { armedLevelID = activeFactor?.levels.first?.id }
    }

    // MARK: - Level & factor hotkeys

    func armLevel(atIndex index: Int) {
        guard let factor = activeFactor, factor.levels.indices.contains(index) else { return }
        exitMultiSelection()
        armedLevelID = factor.levels[index].id
    }

    func cycleLevel(by delta: Int) {
        guard let factor = activeFactor, !factor.levels.isEmpty else { return }
        exitMultiSelection()
        let current = armedLevelID.flatMap { factor.index(of: $0) } ?? -1
        let count = factor.levels.count
        let next = ((current + delta) % count + count) % count
        armedLevelID = factor.levels[next].id
    }

    func disarmLevel() {
        exitMultiSelection()
        armedLevelID = nil
    }

    func setActiveFactor(_ id: UUID) {
        leaveOverview()
        exitMultiSelection()
        spotlightLevelID = nil
        activeFactorID = id
        armedLevelID = layout.factor(id: id)?.levels.first?.id
    }

    func cycleFactor(by delta: Int) {
        guard !layout.factors.isEmpty else { return }
        // Overview has no active factor, so Tab picks one up again from the end it is
        // heading towards rather than skipping the factor it should have landed on.
        guard let current = layout.factorIndex(id: activeFactorID) else {
            setActiveFactor(layout.factors[delta < 0 ? layout.factors.count - 1 : 0].id)
            return
        }
        let count = layout.factors.count
        setActiveFactor(layout.factors[((current + delta) % count + count) % count].id)
    }

    func setActiveFactor(atIndex index: Int) {
        guard layout.factors.indices.contains(index) else { return }
        setActiveFactor(layout.factors[index].id)
    }

    // MARK: - Level editing

    /// The colour for a condition about to be created, honouring the Settings choice.
    /// Takes the layout the level is joining rather than reading the editor's own,
    /// because during a paste the set of used colours grows with every new value.
    static func newLevelColor(in layout: Layout, fallback index: Int) -> String {
        Preferences.shared.newConditionColors == .neverRepeat
            ? Palette.firstColor(avoiding: layout.usedLevelColors(), fallbackIndex: index)
            : Palette.color(at: index)
    }

    func addLevel(name: String? = nil) {
        guard let factorID = activeFactorID, let factor = activeFactor else { return }
        let count = factor.levels.count
        let level = Level(
            name: name ?? "Condition \(count + 1)",
            colorHex: Self.newLevelColor(in: layout, fallback: count)
        )
        edit("Add Level") { layout in
            guard let i = layout.factorIndex(id: factorID) else { return }
            layout.factors[i].levels.append(level)
        }
        armedLevelID = level.id
    }

    func renameLevel(_ levelID: UUID, to newName: String) {
        guard let factorID = activeFactorID else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Rename Level") { layout in
            guard let fi = layout.factorIndex(id: factorID),
                  let li = layout.factors[fi].levels.firstIndex(where: { $0.id == levelID })
            else { return }
            layout.factors[fi].levels[li].name = trimmed
        }
    }

    func setLevelColor(_ levelID: UUID, hex: String) {
        guard let factorID = activeFactorID else { return }
        edit("Change Colour") { layout in
            guard let fi = layout.factorIndex(id: factorID),
                  let li = layout.factors[fi].levels.firstIndex(where: { $0.id == levelID })
            else { return }
            layout.factors[fi].levels[li].colorHex = hex
        }
    }

    func deleteLevel(_ levelID: UUID) {
        guard let factorID = activeFactorID else { return }
        edit("Delete Level") { layout in
            layout.removeLevel(levelID, from: factorID)
        }
        if armedLevelID == levelID { armedLevelID = activeFactor?.levels.first?.id }
    }

    func moveLevels(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let factorID = activeFactorID else { return }
        edit("Reorder Levels") { layout in
            guard let fi = layout.factorIndex(id: factorID) else { return }
            layout.factors[fi].levels.move(fromOffsets: source, toOffset: destination)
        }
    }

    func recolorLevelsFromPalette() {
        guard let factorID = activeFactorID, let factor = activeFactor else { return }
        let hexes: [String]
        if factor.kind == .numeric {
            hexes = Palette.ramp(count: factor.levels.count, baseHex: Palette.color(at: 0))
        } else if Preferences.shared.newConditionColors == .neverRepeat {
            // The factor's own colours are being replaced, so only the *other* factors
            // count against the choice — and each pick counts against the next.
            var used = layout.usedLevelColors(excluding: factorID)
            hexes = (0..<factor.levels.count).map { i in
                let hex = Palette.firstColor(avoiding: used, fallbackIndex: i)
                used.insert(Palette.normalized(hex))
                return hex
            }
        } else {
            hexes = (0..<factor.levels.count).map { Palette.color(at: $0) }
        }
        edit("Recolour Levels") { layout in
            guard let fi = layout.factorIndex(id: factorID) else { return }
            for (i, hex) in hexes.enumerated() where layout.factors[fi].levels.indices.contains(i) {
                layout.factors[fi].levels[i].colorHex = hex
            }
        }
    }

    func removeUnusedLevels() {
        guard let factorID = activeFactorID else { return }
        let before = activeFactor?.levels.count ?? 0
        edit("Remove Unused Levels") { layout in
            layout.pruneUnusedLevels(factorID: factorID)
        }
        let after = activeFactor?.levels.count ?? 0
        flash(before == after ? "No unused conditions." : "Removed \(before - after) unused condition(s).")
        if armedLevelID.flatMap({ activeFactor?.level(id: $0) }) == nil {
            armedLevelID = activeFactor?.levels.first?.id
        }
    }

    // MARK: - Factor editing

    func addFactor() {
        let factor = Factor(
            name: layout.uniqueFactorName(base: "Factor"),
            levels: [Level(name: "Level 1", colorHex: Self.newLevelColor(in: layout, fallback: 0))]
        )
        edit("Add Factor") { layout in layout.factors.append(factor) }
        setActiveFactor(factor.id)
    }

    func renameFactor(_ factorID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Rename Factor") { layout in
            guard let i = layout.factorIndex(id: factorID) else { return }
            layout.factors[i].name = trimmed
        }
    }

    func setFactorUnit(_ factorID: UUID, unit: String) {
        edit("Set Unit") { layout in
            guard let i = layout.factorIndex(id: factorID) else { return }
            layout.factors[i].unit = unit.trimmingCharacters(in: .whitespaces)
        }
    }

    func setFactorKind(_ factorID: UUID, kind: FactorKind) {
        edit("Change Factor Type") { layout in
            guard let i = layout.factorIndex(id: factorID) else { return }
            layout.factors[i].kind = kind
        }
    }

    /// Factor order is also the order of the stacked well labels, so this is a
    /// layout decision rather than cosmetic bookkeeping.
    func moveFactors(fromOffsets source: IndexSet, toOffset destination: Int) {
        edit("Reorder Factors") { layout in
            layout.factors.move(fromOffsets: source, toOffset: destination)
        }
    }

    func deleteFactor(_ factorID: UUID) {
        guard layout.factors.count > 1 else {
            flash("A layout needs at least one factor.")
            return
        }
        edit("Delete Factor") { layout in layout.removeFactor(factorID) }
        if activeFactorID == factorID, let first = layout.factors.first {
            setActiveFactor(first.id)
        }
    }

    // MARK: - Plates

    func addPlate() {
        let plate = Plate(name: layout.uniquePlateName(base: "Plate"), format: format)
        edit("Add Plate") { layout in layout.plates.append(plate) }
        activePlateID = plate.id
        customWells = nil
        selection = WellRange(single: WellPos(row: 0, col: 0))
    }

    func duplicatePlate() {
        guard let current = plate else { return }
        var copy = current
        copy.id = UUID()
        copy.name = layout.uniquePlateName(base: current.name + " copy")
        edit("Duplicate Plate") { layout in layout.plates.append(copy) }
        activePlateID = copy.id
    }

    func deletePlate(_ plateID: UUID) {
        guard layout.plates.count > 1 else {
            flash("A layout needs at least one plate.")
            return
        }
        let index = layout.plates.firstIndex { $0.id == plateID }
        edit("Delete Plate") { layout in layout.plates.removeAll { $0.id == plateID } }
        if activePlateID == plateID {
            let fallback = min(index ?? 0, layout.plates.count - 1)
            activePlateID = layout.plates.indices.contains(fallback) ? layout.plates[fallback].id : layout.plates.first?.id
        }
    }

    func renamePlate(_ plateID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Rename Plate") { layout in
            guard let i = layout.plates.firstIndex(where: { $0.id == plateID }) else { return }
            layout.plates[i].name = trimmed
        }
    }

    /// Returns false when the user backed out of the data-loss warning, so callers can
    /// avoid committing side effects for a change that did not happen.
    @discardableResult
    func setFormat(_ newFormat: PlateFormat) -> Bool {
        guard let current = plate else { return false }
        guard current.format != newFormat else { return true }
        if current.formatChangeWouldLoseData(newFormat) {
            let alert = NSAlert()
            alert.messageText = "Switch to a \(formatDisplayName(newFormat)) plate?"
            alert.informativeText = "Wells outside the smaller plate already have values assigned. Those assignments will be discarded. You can undo this."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        editPlate("Change Plate Format") { plate in plate.changeFormat(to: newFormat) }
        selection = selection?.clamped(to: newFormat)
        customWells = clippingCustomWells(to: newFormat)
        return true
    }

    /// Turns the plate a quarter clockwise, and back again next time. Undoable and saved
    /// with the document like the other display settings, because an export renders the
    /// plate as it is shown.
    func rotatePlate() {
        let wasTurned = isTurned
        edit("Turn Plate") { layout in layout.orientation = wasTurned ? .upright : .turned }
        // Says where A1 went, which is the quickest way to see which way round it is.
        flash(wasTurned ? "Upright. A1 is top left." : "Turned 90°. A1 is now top right.")
    }

    /// Quarter turns clockwise for the plate currently shown. Depends on the plate,
    /// because `.automatic` lies a tall plate down and leaves a wide one alone.
    var quarterTurns: Int { layout.orientation.quarterTurns(for: format) }
    var isTurned: Bool { quarterTurns != 0 }

    func setPadWellLabels(_ padded: Bool) {
        edit("Well Label Style") { layout in layout.padWellLabels = padded }
    }

    /// Saved with the document so a layout reopens — and exports — the way it was designed.
    ///
    /// Overview also drops the active factor, which `reconcileTargets` enforces as the
    /// mode's invariant. What it was before is captured *here*, before the edit, since
    /// reconciling the new layout is what clears it.
    func setWellLabelMode(_ mode: WellLabelMode) {
        let entering = mode.isOverview && !isOverview
        let resume = entering ? (mode: layout.wellLabelMode, factorID: activeFactorID) : overviewReturn

        edit("Well Labels") { layout in layout.wellLabelMode = mode }

        if mode.isOverview {
            overviewReturn = resume
        } else {
            // Leaving by picking another text mode keeps the factor you were painting.
            if let id = resume?.factorID, layout.factors.contains(where: { $0.id == id }) {
                setActiveFactor(id)
            }
            overviewReturn = nil
        }
    }

    /// Steps into Overview, or back out to whatever it was showing before. Bound to a
    /// single shortcut because "stand back and read the whole plate" is a glance, not
    /// a mode you navigate into and out of by hand.
    func toggleOverview() {
        setWellLabelMode(isOverview ? (overviewReturn?.mode ?? .allFactors) : .overview)
    }

    /// Overview is a look, not a destination: touching a factor puts you back to
    /// painting, in the mode you were in when you stepped away.
    private func leaveOverview() {
        guard isOverview else { return }
        let resume = overviewReturn?.mode ?? .allFactors
        edit("Well Labels") { layout in
            layout.wellLabelMode = resume.isOverview ? .allFactors : resume
        }
        overviewReturn = nil
    }

    // MARK: - Saved states

    /// A state bookmarks one plate, so every list here is scoped to the active one.
    /// Switching plates shows that plate's own history and nothing else.
    var savedStates: [LayoutSnapshot] { layout.snapshots(for: activePlateID) }
    var hasSavedStates: Bool { !savedStates.isEmpty }
    /// Newest first, which is the order the revert menu should offer them in.
    var savedStatesNewestFirst: [LayoutSnapshot] { savedStates.reversed() }

    private static let stateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    func title(for state: LayoutSnapshot) -> String {
        "\(state.name)  ·  \(Self.stateTimeFormatter.string(from: state.savedAt))"
    }

    /// "Saved 14:32 · 96-well · 42 wells filled" — enough to tell two states apart.
    func subtitle(for state: LayoutSnapshot) -> String {
        var parts = ["Saved \(Self.stateTimeFormatter.string(from: state.savedAt))"]
        if let plate = state.plates.first {
            parts.append(PlateTemplateStore.shared.displayName(for: plate.format))
            let filled = (0..<plate.format.wellCount).count { well in
                state.factors.contains { plate.levelID(factor: $0.id, well: well) != nil }
            }
            parts.append("\(filled) well\(filled == 1 ? "" : "s") filled")
        }
        // Only the ones written before states were per-plate carry more than one.
        if state.plateID == nil, state.plates.count > 1 {
            parts.append("whole document, \(state.plates.count) plates")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Every one of these goes through `edit`, so saving, reverting, renaming and
    /// deleting are all ordinary undoable steps — a mis-click costs one ⌘Z.
    func saveState() {
        guard let plateID = activePlateID, let plate else {
            flash("No plate to save.")
            return
        }
        // Saving the same layout twice would just clutter the list.
        if let existing = layout.snapshotMatching(plate: plateID) {
            flash("\(plate.name) is already saved as \(existing.name).")
            return
        }
        var dropped = 0
        let now = Date()
        edit("Save State") { layout in
            dropped = layout.captureSnapshot(at: now, plate: plateID)
        }
        flash(
            dropped > 0
                ? "Saved. Keeping the \(layout.snapshots.count) most recent states."
                : "Saved \(layout.snapshots.last?.name ?? "state") for \(plate.name). ⌘Z undoes this."
        )
    }

    func renameState(_ id: UUID, to newName: String) {
        edit("Rename State") { layout in layout.renameSnapshot(id, to: newName) }
    }

    func deleteState(_ id: UUID) {
        guard let doomed = layout.snapshots.first(where: { $0.id == id }) else { return }
        edit("Delete State") { layout in layout.removeSnapshot(id) }
        flash("Deleted \(doomed.name). ⌘Z restores it.")
    }

    func revertToLatestState() {
        guard let latest = savedStates.last else {
            flash("No saved states for \(plate?.name ?? "this plate") yet — use the bookmark button first.")
            return
        }
        revertToState(latest.id)
    }

    func revertToState(_ id: UUID) {
        guard let target = layout.snapshots.first(where: { $0.id == id }) else { return }
        let before = layout
        edit("Revert to \(target.name)") { layout in
            _ = layout.restoreSnapshot(id)
        }
        // `edit` no-ops when nothing changed, so say so rather than implying a revert.
        if layout == before {
            flash("Already matches \(target.name).")
        } else {
            flash("Reverted to \(target.name). ⌘Z puts it back.")
        }
    }

    /// Recomputed whenever the document changes rather than on every redraw: the
    /// comparison walks every well of every plate, which is far too much work to do
    /// inside a SwiftUI body evaluation.
    private func refreshSavedStateMatch(in layout: Layout, plate plateID: UUID? = nil) {
        let match = layout.snapshotMatching(plate: plateID ?? activePlateID)?.id
        if match != matchingSavedStateID { matchingSavedStateID = match }
    }

    /// True when the design on screen is exactly one of the saved states.
    var currentDesignIsSaved: Bool { matchingSavedStateID != nil }

    /// Keeps what the editor is pointing at valid for the layout that just arrived.
    /// Driven from the `$layout` sink rather than from any one action, because undo and
    /// redo can also delete the active plate, factor or level — and a stale
    /// `activeFactorID` means painting writes into a factor that no longer exists,
    /// which is invisible on screen but does end up in the saved file.
    ///
    /// Takes the incoming layout as a parameter: `@Published` emits during `willSet`,
    /// so `document.layout` is still the previous value while this runs.
    private func reconcileTargets(in layout: Layout) {
        if activePlateID == nil || !layout.plates.contains(where: { $0.id == activePlateID }) {
            activePlateID = layout.plates.first?.id
        }
        // Overview means "nothing is being painted", and the mode lives in the document,
        // so undo and redo can move in and out of it too. Enforcing the invariant here
        // rather than at the call sites is what keeps those paths honest.
        if layout.wellLabelMode.isOverview {
            activeFactorID = nil
        } else if activeFactorID == nil || !layout.factors.contains(where: { $0.id == activeFactorID }) {
            activeFactorID = layout.factors.first?.id
        }
        let factor = layout.factors.first { $0.id == activeFactorID }
        // Only re-arm a level that has gone stale. A nil means the user pressed Escape
        // to select without painting, and that choice should survive.
        if let armed = armedLevelID, factor?.levels.contains(where: { $0.id == armed }) != true {
            armedLevelID = factor?.levels.first?.id
        }
        if let plate = layout.plates.first(where: { $0.id == activePlateID }) {
            selection = selection?.clamped(to: plate.format)
            customWells = clippingCustomWells(to: plate.format)
        }
        // A hover spotlight is only meaningful over a condition the active factor
        // still has; undo, redo or a delete can take that condition away mid-hover.
        if let spotlight = spotlightLevelID,
           layout.factors.first(where: { $0.id == activeFactorID })?.level(id: spotlight) == nil {
            spotlightLevelID = nil
        }
        // Grouping on a factor that has just been deleted would silently box nothing;
        // fall back to grouping on everything, which is the setting's own default.
        if let grouped = overviewGroupFactorID, !layout.factors.contains(where: { $0.id == grouped }) {
            overviewGroupFactorID = nil
        }
        // Undo and redo can delete ⌘-selected rows out from under the sets; a set
        // pruned below two members is no longer a multi-selection at all.
        let factorIDs = Set(layout.factors.map(\.id))
        let prunedFactors = multiSelectedFactorIDs.intersection(factorIDs)
        if prunedFactors != multiSelectedFactorIDs {
            multiSelectedFactorIDs = prunedFactors.count > 1 ? prunedFactors : []
        }
        let levelIDs = Set(layout.factors.first { $0.id == activeFactorID }?.levels.map(\.id) ?? [])
        let prunedLevels = multiSelectedLevelIDs.intersection(levelIDs)
        if prunedLevels != multiSelectedLevelIDs {
            multiSelectedLevelIDs = prunedLevels.count > 1 ? prunedLevels : []
        }
    }

    /// Unlike the rectangle, a discontiguous well cannot be clamped to the nearest
    /// edge without landing on a well the user never chose — it is dropped instead.
    private func clippingCustomWells(to format: PlateFormat) -> Set<WellPos>? {
        guard let customWells else { return nil }
        let kept = customWells.filter { format.contains(row: $0.row, col: $0.col) }
        return kept.isEmpty ? nil : kept
    }

    // MARK: - Custom plate sizes

    /// Applies an arbitrary size, optionally remembering it as a reusable template.
    /// The template is saved only once the size has actually been applied, so backing
    /// out of the data-loss warning leaves nothing behind.
    @discardableResult
    func applyCustomFormat(rows: Int, cols: Int, templateName: String?) -> Bool {
        let format = PlateFormat(rows: rows, cols: cols)
        guard setFormat(format) else { return false }
        if let templateName {
            PlateTemplateStore.shared.add(name: templateName, format: format)
        }
        return true
    }

    func formatDisplayName(_ format: PlateFormat) -> String {
        PlateTemplateStore.shared.displayName(for: format)
    }

    func formatDetailedName(_ format: PlateFormat) -> String {
        PlateTemplateStore.shared.detailedName(for: format)
    }

    // MARK: - The board

    /// Per window, never saved. The arrangement travels with the document; which way you
    /// happen to be looking at it does not, and a `.plate` a colleague opens must not
    /// surprise them with a mode they never asked for. Overview is in the document
    /// because it is exported; the board changes no export at all.
    @Published var showsCanvas = false
    /// The board, while one is on screen. Weak, and only ever read to resolve focus and
    /// to bring a card into view.
    weak var board: CanvasBoardView?

    /// The board as it should be shown — saved cards where they were left, everything
    /// else placed around them. Computed, never written: the app autosaves in place, so
    /// writing placements on entry would mean looking at a layout rewrote its file.
    var canvasItems: [CanvasItem] {
        // `layout.prep`, not `prepPlan`: the latter falls back to a default setup so the
        // prep window can show a table the moment it opens, which would put a prep card
        // on the board of every document that has never used the feature. Same opt-in
        // rule as the workbook's Prep tab.
        let hasPrep = layout.prep != nil && prepPlan?.isEmpty == false
        return CanvasArrangement.resolved(
            saved: layout.canvas, plates: layout.plates,
            orientation: layout.orientation, includesPrep: hasPrep
        )
    }

    func toggleCanvas() {
        showsCanvas.toggle()
    }

    /// Commits a card's place. Called once, on mouse up, so a drag is one ⌘Z.
    ///
    /// It writes **every** card, not just the moved one: the first deliberate move
    /// freezes the arrangement exactly as it looks, so the auto-placed cards around it
    /// cannot shuffle when the board next resolves.
    func setCanvasFrame(_ id: UUID, to frame: CGRect, actionName: String = "Move Card") {
        var items = canvasItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].frame = CanvasFrame(frame)
        edit(actionName) { layout in layout.canvas = CanvasLayout(items: items) }
    }

    /// Array order is z-order, so raising a card is moving it to the end.
    func bringCanvasItemToFront(_ id: UUID) {
        var items = canvasItems
        guard let index = items.firstIndex(where: { $0.id == id }), index != items.count - 1
        else { return }
        let item = items.remove(at: index)
        items.append(item)
        edit("Bring to Front") { layout in layout.canvas = CanvasLayout(items: items) }
    }

    func addCanvasNote(at point: CGPoint) {
        var items = canvasItems
        let frame = CGRect(origin: point, size: CanvasArrangement.noteSize)
        let note = CanvasItem(kind: .note, frame: CanvasFrame(frame))
        items.append(note)
        edit("Add Note") { layout in layout.canvas = CanvasLayout(items: items) }
        noteTarget = .canvasNote(note.id)
    }

    /// Only notes can be removed — a plate's card is the plate, and hiding one would be a
    /// way to lose a plate without deleting it.
    func deleteCanvasItem(_ id: UUID) {
        var items = canvasItems
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .note
        else { return }
        items.remove(at: index)
        edit("Delete Note") { layout in layout.canvas = CanvasLayout(items: items) }
    }

    /// Clicking a card is how a plate becomes the editable one. Deliberately does not
    /// touch the selection: unlike a plate tab, a card click is often just "look at that
    /// one", and `reconcileTargets` already clamps the selection to the new format.
    func activatePlate(_ id: UUID) {
        guard activePlateID != id, layout.plates.contains(where: { $0.id == id }) else { return }
        activePlateID = id
    }

    // MARK: - Pipetting prep

    /// The plan as it stands, or nil until a dose factor has been chosen. Recomputed on
    /// demand rather than cached: it is a pure function of the layout, and the window
    /// redraws off `objectWillChange` like everything else.
    var prepPlan: DilutionPlan? { DilutionPlan.make(from: layout, setup: effectivePrepSetup) }

    /// What the prep window is showing: the document's own setup once there is one, and
    /// a sensible default before that. Opening the window is not an edit.
    var effectivePrepSetup: PrepSetup { layout.prep ?? defaultPrepSetup() }

    /// Whether a condition row should carry its stock. Only on the factor the prep sheet
    /// is actually using for compounds, and only when a stock is set — a placeholder on
    /// every condition of every document, for a feature most never touch, is exactly the
    /// clutter to avoid.
    func showsStock(on level: Level) -> Bool {
        guard level.stock?.isUsable == true, let compound = layout.prep?.compoundFactorID
        else { return false }
        return activeFactorID == compound
    }

    /// What the prep sheet starts from when a document has never had one: the first
    /// numeric factor, which after a Series Fill is the dose. The compound factor is
    /// left unset — guessing which factor is the drug would be wrong as often as right,
    /// and the picker is the first thing in the window.
    func defaultPrepSetup() -> PrepSetup {
        var setup = PrepSetup()
        setup.doseFactorID = layout.factors.first { $0.kind == .numeric }?.id
            ?? layout.factors.first?.id
        return setup
    }

    /// Opens the prep window, or brings it to the front if it is already up. No Overview
    /// guard, unlike every other sheet opener in this file: reading a prep plan with
    /// nothing armed is exactly what Overview is for.
    func openPrepWindow() {
        let controller = prepWindow ?? PrepWindowController(editor: self, title: suggestedBaseName)
        prepWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Every prep edit funnels through here, so each one is an ordinary undo step.
    func updatePrep(_ actionName: String = "Prep Settings", _ change: (inout PrepSetup) -> Void) {
        let seed = layout.prep ?? defaultPrepSetup()
        edit(actionName) { layout in
            var setup = layout.prep ?? seed
            change(&setup)
            layout.prep = setup
        }
    }

    /// The stock lives on the compound's condition, so this is a level edit like any
    /// other. A nil or unusable value clears it rather than storing a zero.
    func setStock(_ stock: StockConcentration?, for levelID: UUID, in factorID: UUID) {
        edit("Stock Concentration") { layout in
            guard let fi = layout.factorIndex(id: factorID),
                  let li = layout.factors[fi].levels.firstIndex(where: { $0.id == levelID })
            else { return }
            layout.factors[fi].levels[li].stock = (stock?.isUsable == true) ? stock : nil
        }
    }

    // MARK: - Clipboard

    /// Copies the selection as tab-separated text — pastes straight into Excel.
    func copySelection(includeHeaders: Bool = false) {
        // A discontiguous selection has no honest grid: a bounding box would copy
        // wells the user deliberately excluded. Excel refuses this too.
        guard customWells == nil else {
            return flash("Copy needs a rectangular selection.")
        }
        guard let plate, let selection else { return }
        guard let factor = activeFactor else {
            flash("No factor selected — click one in the sidebar to copy its values.")
            return
        }
        let range = selection.clamped(to: plate.format)
        var grid: [[String]] = []

        if includeHeaders {
            var header = [""]
            for c in range.minCol...range.maxCol { header.append("\(c + 1)") }
            grid.append(header)
        }
        for r in range.minRow...range.maxRow {
            var row: [String] = includeHeaders ? [WellNaming.rowLabel(r)] : []
            for c in range.minCol...range.maxCol {
                let well = plate.format.index(row: r, col: c)
                let id = plate.levelID(factor: factor.id, well: well)
                row.append(factor.level(id: id)?.name ?? "")
            }
            grid.append(row)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TSV.serialize(grid), forType: .string)
        flash("Copied \(range.wellCount) well\(range.wellCount == 1 ? "" : "s") as \(factor.name).")
    }

    func cutSelection() {
        // Refused as one piece: if the copy half cannot run, the clear half must not
        // either, or a cut would destroy wells it never copied.
        guard customWells == nil else {
            return flash("Cut needs a rectangular selection.")
        }
        copySelection()
        clearSelection()
    }

    /// Copies the selection with **every** factor's value, not just the one being
    /// painted — the way to lift a piece of a design and put it down somewhere else.
    /// Excel still gets a readable grid out of it: one cell per well, the factors'
    /// values joined, which is the same shape as the workbook's one-cell map.
    func copyWells() {
        // Rectangular for the same reason `copySelection` is: a block has a shape, and
        // a bounding box round a discontiguous selection would carry wells that were
        // deliberately left out.
        guard customWells == nil else {
            return flash("Copy Wells needs a rectangular selection.")
        }
        guard let plate, let selection else { return }
        guard !layout.factors.isEmpty else { return flash("Nothing to copy — the layout has no factors.") }
        let range = selection.clamped(to: plate.format)
        WellClipboard.capture(plate: plate, factors: layout.factors, range: range).write()
        let count = range.wellCount
        flash("Copied \(count) well\(count == 1 ? "" : "s") with all \(layout.factors.count) factors.")
    }

    /// Puts a copied block back, creating any factor or condition this document has
    /// not seen. One undo step, however much it had to create.
    func pasteWells() {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        guard let clipboard = WellClipboard.read() else {
            return flash("No copied wells — use Copy Wells (⌥⌘C) first.")
        }
        let index = plateIndex
        guard index >= 0 else { return }

        let originRow = selection?.minRow ?? 0
        let originCol = selection?.minCol ?? 0
        var report = WellClipboard.Report()
        edit("Paste Wells") { layout in
            report = clipboard.apply(to: &layout, plateIndex: index, atRow: originRow, col: originCol)
        }

        selection = WellRange(
            anchor: WellPos(row: originRow, col: originCol),
            focus: WellPos(row: originRow + clipboard.rows - 1, col: originCol + clipboard.cols - 1)
        ).clamped(to: format)
        customWells = nil

        // A pasted block can create the very factor or condition the sidebar is
        // pointing at nothing for, so put the brush somewhere valid before saying so.
        if activeFactorID == nil || layout.factor(id: activeFactorID) == nil {
            if let first = layout.factors.first { setActiveFactor(first.id) }
        }
        if armedLevelID.flatMap({ activeFactor?.level(id: $0) }) == nil {
            armedLevelID = activeFactor?.levels.first?.id
        }

        var created: [String] = []
        if report.createdFactors > 0 {
            created.append("\(report.createdFactors) factor\(report.createdFactors == 1 ? "" : "s")")
        }
        if report.createdConditions > 0 {
            created.append("\(report.createdConditions) condition\(report.createdConditions == 1 ? "" : "s")")
        }
        let tail = created.isEmpty ? "" : " — added \(created.joined(separator: " and "))"
        flash("Pasted \(report.wells) well\(report.wells == 1 ? "" : "s")\(tail).")
    }

    /// Pastes a block of text values, creating any conditions it has not seen before.
    func pasteFromPasteboard() {
        // A block copied with ⌥⌘C carries every factor, so ⌘V puts all of it back
        // rather than painting the active factor with the joined text flavour that
        // sits beside it for Excel's benefit.
        if WellClipboard.isOnPasteboard() { return pasteWells() }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard !isOverview else { return flashOverviewIsReadOnly() }
        guard let factorID = activeFactorID else { return }

        var grid = TSV.parse(text)
        if grid.count == 1 && grid[0].count == 1 && text.contains(",") {
            grid = CSV.parse(text)
        }
        grid = TSV.strippingPlateHeaders(grid)
        guard !grid.isEmpty else { return }

        // With nothing selected, paste lands at the top-left corner of the plate.
        let originRow = selection?.minRow ?? 0
        let originCol = selection?.minCol ?? 0
        applyGrid(grid, factorID: factorID, atRow: originRow, col: originCol, actionName: "Paste")

        let rows = grid.count
        let cols = grid.map(\.count).max() ?? 0
        selection = WellRange(
            anchor: WellPos(row: originRow, col: originCol),
            focus: WellPos(row: originRow + rows - 1, col: originCol + cols - 1)
        ).clamped(to: format)
    }

    /// Shared by paste and file import.
    private func applyGrid(_ grid: [[String]], factorID: UUID, atRow originRow: Int, col originCol: Int, actionName: String) {
        let index = plateIndex
        guard index >= 0 else { return }
        var created = 0

        edit(actionName) { layout in
            guard layout.plates.indices.contains(index),
                  let fi = layout.factorIndex(id: factorID) else { return }
            let format = layout.plates[index].format

            for (dr, row) in grid.enumerated() {
                let r = originRow + dr
                guard r >= 0, r < format.rows else { continue }
                for (dc, raw) in row.enumerated() {
                    let c = originCol + dc
                    guard c >= 0, c < format.cols else { continue }
                    let value = raw.trimmingCharacters(in: .whitespaces)
                    let well = format.index(row: r, col: c)
                    if value.isEmpty {
                        layout.plates[index].setLevelID(nil, factor: factorID, well: well)
                    } else {
                        let existed = layout.factors[fi].level(named: value) != nil
                        let levelID = layout.factors[fi].ensureLevel(
                            named: value,
                            colorHex: existed ? nil : Self.newLevelColor(
                                in: layout, fallback: layout.factors[fi].levels.count
                            )
                        )
                        if !existed { created += 1 }
                        layout.plates[index].setLevelID(levelID, factor: factorID, well: well)
                    }
                }
            }
        }

        if created > 0 { flash("Added \(created) new condition\(created == 1 ? "" : "s") from pasted values.") }
        if armedLevelID.flatMap({ activeFactor?.level(id: $0) }) == nil {
            armedLevelID = activeFactor?.levels.first?.id
        }
    }

    // MARK: - Generators

    struct SeriesSpec {
        enum Direction: String, CaseIterable, Identifiable {
            case acrossColumns, downRows
            var id: String { rawValue }
            var label: String { self == .acrossColumns ? "Across columns →" : "Down rows ↓" }
        }
        enum Mode: String, CaseIterable, Identifiable {
            case fold, linear
            var id: String { rawValue }
            var label: String { self == .fold ? "Fold dilution" : "Linear step" }
        }
        var direction: Direction = .acrossColumns
        var mode: Mode = .fold
        var start: Double = 10
        var foldFactor: Double = 3
        var dilute: Bool = true
        var step: Double = -1
        var significantDigits: Int = 3
        var lastIsZero: Bool = false
    }

    /// Guarded here rather than by disabling the toolbar button: a disabled item
    /// re-tiles the whole toolbar, and a sheet that can only refuse on Apply is a
    /// worse answer than saying so up front.
    func openSeriesSheet() {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        showingSeriesSheet = true
    }

    /// The formatted values a series would write, used for the live preview too.
    func seriesValues(_ spec: SeriesSpec) -> [String] {
        guard let plate, let selection else { return [] }
        let range = selection.clamped(to: plate.format)
        let steps = spec.direction == .acrossColumns ? range.colCount : range.rowCount
        guard steps > 0 else { return [] }

        return (0..<steps).map { k in
            if spec.lastIsZero && k == steps - 1 { return "0" }
            let raw: Double
            switch spec.mode {
            case .linear:
                raw = spec.start + spec.step * Double(k)
            case .fold:
                let f = spec.foldFactor <= 0 ? 1 : spec.foldFactor
                raw = spec.dilute ? spec.start / pow(f, Double(k)) : spec.start * pow(f, Double(k))
            }
            return Self.formatValue(raw, significantDigits: spec.significantDigits)
        }
    }

    /// Writes a dose series across the selection — the common case this app exists for.
    func applySeries(_ spec: SeriesSpec) {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        guard let factorID = activeFactorID, let plate, let selection else { return }
        let range = selection.clamped(to: plate.format)
        let values = seriesValues(spec)
        let steps = values.count
        guard steps > 0 else { return }

        let ramp = Palette.ramp(count: steps, baseHex: activeFactor?.levels.first?.colorHex ?? Palette.color(at: 0))
        let index = plateIndex

        edit("Series Fill") { layout in
            guard layout.plates.indices.contains(index), let fi = layout.factorIndex(id: factorID) else { return }
            layout.factors[fi].kind = .numeric
            var idForStep: [UUID] = []
            for (k, value) in values.enumerated() {
                let id = layout.factors[fi].ensureLevel(named: value)
                if let li = layout.factors[fi].levels.firstIndex(where: { $0.id == id }) {
                    layout.factors[fi].levels[li].colorHex = ramp[k]
                }
                idForStep.append(id)
            }
            // Keep numeric levels ordered high-to-low so the sidebar reads like a dilution series.
            layout.factors[fi].levels.sort { a, b in
                switch (Double(a.name), Double(b.name)) {
                case let (x?, y?): return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.name < b.name
                }
            }
            let format = layout.plates[index].format
            for r in range.minRow...range.maxRow {
                for c in range.minCol...range.maxCol {
                    guard format.contains(row: r, col: c) else { continue }
                    let k = spec.direction == .acrossColumns ? c - range.minCol : r - range.minRow
                    guard idForStep.indices.contains(k) else { continue }
                    layout.plates[index].setLevelID(idForStep[k], factor: factorID, well: format.index(row: r, col: c))
                }
            }
        }
        armedLevelID = activeFactor?.levels.first?.id
        flash("Filled \(steps)-point series: \(values.first ?? "") → \(values.last ?? "")")
    }

    // MARK: - XY position fill

    struct XYFillSpec {
        enum Pattern: String, CaseIterable, Identifiable {
            case acrossColumns, downRows, serpentine
            var id: String { rawValue }
            var label: String {
                switch self {
                case .acrossColumns: return "Across columns →"
                case .downRows: return "Down rows ↓"
                case .serpentine: return "Serpentine ⇄"
                }
            }
        }
        var pattern: Pattern = .acrossColumns
        /// Base hue for the position ramp. nil means automatic: the hue the XY
        /// factor already has, else the next colour the palette would hand out.
        var baseHex: String?
    }

    static let xyFactorName = "XY"

    /// The wells an XY fill would number, in the order the pattern walks them.
    /// No selection means the whole plate — and so does a single well, because
    /// that is just the resting cursor, and one imaging position is never the ask.
    ///
    /// The walk happens in *display* space: the fill mirrors what the user will do
    /// at the instrument, holding the plate the way it is drawn, so a turned plate
    /// numbers along the rows the user actually sees. The mapping is asked of
    /// `PlateGeometry` rather than derived here — the rotation stays in one place.
    func xyFillWells(_ spec: XYFillSpec) -> [Int] {
        guard let plate else { return [] }
        let format = plate.format
        let geo = PlateGeometry(
            format: format, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            quarterTurns: quarterTurns
        )

        var shown: [WellPos] = []
        if let custom = customWells, !custom.isEmpty {
            // A discontiguous selection is numbered as it stands — the pattern walks
            // the chosen wells and skips the rest, which is exactly how positions are
            // picked on the instrument when some wells are not worth imaging.
            shown = custom.filter { format.contains(row: $0.row, col: $0.col) }.map {
                let d = geo.displayPosition(row: $0.row, col: $0.col)
                return WellPos(row: d.row, col: d.col)
            }
        } else if let range = selection.flatMap({ $0.isSingleWell ? nil : $0 })?.clamped(to: format) {
            // A model-space rectangle is a display-space rectangle at every turn.
            let a = geo.displayPosition(row: range.minRow, col: range.minCol)
            let b = geo.displayPosition(row: range.maxRow, col: range.maxCol)
            for row in min(a.row, b.row)...max(a.row, b.row) {
                for col in min(a.col, b.col)...max(a.col, b.col) {
                    shown.append(WellPos(row: row, col: col))
                }
            }
        } else {
            for row in 0..<geo.displayRows {
                for col in 0..<geo.displayCols { shown.append(WellPos(row: row, col: col)) }
            }
        }

        let ordered: [WellPos]
        switch spec.pattern {
        case .acrossColumns:
            ordered = shown.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        case .downRows:
            ordered = shown.sorted { ($0.col, $0.row) < ($1.col, $1.row) }
        case .serpentine:
            // Direction alternates by the row's rank among the rows actually being
            // visited, so the snake never wastes a pass on an empty row.
            let byRow = Dictionary(grouping: shown, by: \.row)
            ordered = byRow.keys.sorted().enumerated().flatMap { rank, row in
                let cols = byRow[row]!.sorted { $0.col < $1.col }
                return rank.isMultiple(of: 2) ? cols : cols.reversed()
            }
        }
        return ordered.map {
            let m = geo.modelPosition(displayRow: $0.row, displayCol: $0.col)
            return format.index(row: m.row, col: m.col)
        }
    }

    /// XY01, XY02, … — two digits like the instrument names its positions,
    /// widening only when the count outgrows them (XY001… on a 384).
    static func xyNames(count: Int) -> [String] {
        guard count > 0 else { return [] }
        let width = max(2, String(count).count)
        return (1...count).map { String(format: "XY%0\(width)d", $0) }
    }

    /// Same guard and reason as `openSeriesSheet`.
    func openXYFillSheet() {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        showingXYFillSheet = true
    }

    /// Numbers the wells as Keyence-style imaging positions: an "XY" factor whose
    /// levels run XY01… in the order the microscope will visit them.
    func applyXYFill(_ spec: XYFillSpec) {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        let wells = xyFillWells(spec)
        let index = plateIndex
        guard !wells.isEmpty, index >= 0 else { return }
        let names = Self.xyNames(count: wells.count)

        // Re-running renumbers the one XY factor rather than growing a second,
        // and keeps the hue it already has so the plate does not change colour.
        let existing = layout.factors.first {
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(Self.xyFactorName) == .orderedSame
        }
        let factorID = existing?.id ?? UUID()
        let baseHex = spec.baseHex
            ?? existing?.levels.first?.colorHex
            ?? Self.newLevelColor(in: layout, fallback: layout.factors.count)
        let ramp = Palette.ramp(count: wells.count, baseHex: baseHex)

        edit("XY Position Fill") { layout in
            let fi: Int
            if let i = layout.factorIndex(id: factorID) {
                fi = i
            } else {
                layout.factors.append(Factor(id: factorID, name: Self.xyFactorName))
                fi = layout.factors.count - 1
            }
            guard layout.plates.indices.contains(index) else { return }
            for (k, name) in names.enumerated() {
                let id = layout.factors[fi].ensureLevel(named: name)
                // The ramp stretches with the count, so an existing level's colour
                // is rewritten too — a re-run must stay one smooth gradient.
                if let li = layout.factors[fi].levels.firstIndex(where: { $0.id == id }) {
                    layout.factors[fi].levels[li].colorHex = ramp[k]
                }
                layout.plates[index].setLevelID(id, factor: factorID, well: wells[k])
            }
        }
        setActiveFactor(factorID)
        flash("Numbered \(wells.count) positions: \(names.first ?? "") → \(names.last ?? "")")
    }

    /// Shuffles the existing values inside the selection — randomised placement
    /// to guard against plate position effects.
    func randomizeSelection() {
        guard !isOverview else { return flashOverviewIsReadOnly() }
        guard let factorID = activeFactorID, let plate else { return }
        let wells = selectedWells
        guard wells.count > 1 else { return }
        var values = wells.map { plate.levelID(factor: factorID, well: $0) }
        values.shuffle()
        let index = plateIndex
        edit("Randomise Selection") { layout in
            guard layout.plates.indices.contains(index) else { return }
            for (well, value) in zip(wells, values) {
                layout.plates[index].setLevelID(value, factor: factorID, well: well)
            }
        }
        flash("Randomised \(wells.count) wells.")
    }

    static func formatValue(_ value: Double, significantDigits: Int) -> String {
        if value == 0 { return "0" }
        let digits = max(1, min(significantDigits, 12))
        var text = String(format: "%.\(digits)g", value)
        if text.contains("."), !text.lowercased().contains("e") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    // MARK: - Import / export

    var suggestedBaseName: String {
        let title = NSApp.keyWindow?.title ?? ""
        let cleaned = title.replacingOccurrences(of: " — Edited", with: "")
            .replacingOccurrences(of: ".plate", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "Untitled" ? "Plate Layout" : cleaned
    }

    /// ⌘P prints whichever of this document's two views is frontmost. The routing is a
    /// new method rather than a change to `printPlate`, so the plate path is provably
    /// untouched.
    func printFrontmost() {
        if prepWindow?.window?.isKeyWindow == true, let plan = prepPlan {
            PrepTableView.print(plan: plan, jobName: "\(suggestedBaseName) — prep")
        } else {
            printPlate()
        }
    }

    private func save(
        data: @autoclosure () -> Data?, name: String, ext: String, accessory: NSView? = nil
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(ext)"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        panel.accessoryView = accessory
        // `data` is an autoclosure so it is built after the panel closes, and can
        // therefore read whatever the accessory view ended up set to.
        guard panel.runModal() == .OK, let url = panel.url, let payload = data() else { return }
        do {
            try payload.write(to: url, options: .atomic)
            flash("Exported \(url.lastPathComponent)")
        } catch {
            presentError(error, title: "Could not export")
        }
    }

    func exportWorkbook() {
        let options = WorkbookLayoutAccessory(
            selected: WorkbookLayout.remembered,
            scope: WorkbookScope.remembered,
            jointMap: WorkbookJointMap.remembered,
            plateCount: layout.plates.count,
            activePlateName: layout.plates.first { $0.id == activePlateID }?.name ?? "this plate"
        )
        save(
            data: {
                let choice = options.selectedLayout
                choice.remember()
                let scope = options.selectedScope
                scope.remember()
                let joint = options.selectedJointMap
                joint.remember()
                return Exporter.workbook(
                    from: self.layout, sheetLayout: choice,
                    onlyPlate: scope == .activePlate ? self.activePlateID : nil,
                    jointSeparator: joint.enabled ? joint.resolvedSeparator : nil
                )
            }(),
            name: suggestedBaseName,
            ext: "xlsx",
            accessory: options
        )
    }

    func exportCSV() {
        let text = CSV.serialize(Exporter.tidyGrid(layout: layout))
        save(data: Data(text.utf8), name: suggestedBaseName, ext: "csv")
    }

    func exportPNG() {
        let options = imageExportAccessory()
        save(
            data: self.rendering { $0.pngData(includingGroupOutlines: self.exportGroups(options)) },
            name: suggestedBaseName, ext: "png", accessory: options
        )
    }

    func exportPDF() {
        let options = imageExportAccessory()
        save(
            data: self.rendering { $0.pdfData(includingGroupOutlines: self.exportGroups(options)) },
            name: suggestedBaseName, ext: "pdf", accessory: options
        )
    }

    /// Runs a render against the right canvas.
    ///
    /// In plate mode that is the editing surface, exactly as before. On the board there
    /// is no full-size canvas — only cards, whose size is whatever they were dragged to —
    /// so it renders a detached one at a stated size instead. Same move as
    /// `PrepTableView.print`, and it quietly fixes the older wart that an exported PNG's
    /// resolution depended on how wide the window happened to be.
    private func rendering<T>(_ body: (PlateCanvasView) -> T?) -> T? {
        if !showsCanvas, let canvas { return body(canvas) }
        guard plate != nil else { return nil }
        let size = NSSize(width: 1180, height: 820)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        let view = PlateCanvasView.offscreen(editor: self, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return withExtendedLifetime(window) { body(view) }
    }

    /// Only offered when the plate is actually drawing block outlines — otherwise the
    /// checkbox would govern something that is not there.
    private func imageExportAccessory() -> ImageExportAccessory? {
        guard drawsOverviewGroups else { return nil }
        return ImageExportAccessory(includesGroups: ImageExportAccessory.remembered)
    }

    /// Read after the panel closes, since `save` builds its data lazily for exactly this.
    private func exportGroups(_ options: ImageExportAccessory?) -> Bool {
        guard let options else { return true }
        ImageExportAccessory.remember(options.includesGroups)
        return options.includesGroups
    }

    /// Prints the plate exactly as it is currently shown — active factor, label mode
    /// and colours all included — scaled to fill one page.
    func printPlate() {
        _ = rendering { canvas -> Bool? in
            canvas.printPlate(jobName: suggestedBaseName)
            return true
        }
    }

    // MARK: - Zoom

    /// The floor the current surface imposes: 1 for the plate, well below it for the
    /// board. Published so the status bar can tell "already fitted" from "zoomed out".
    @Published private(set) var minimumZoomLevel: CGFloat = 1

    var canZoomOut: Bool { zoomLevel > minimumZoomLevel * 1.001 }

    /// Whether the status bar shows its zoom readout at all. On the board, fit-all is
    /// usually below 1, so `canZoomOut` alone would hide the readout exactly when it is
    /// most wanted.
    var showsZoomReadout: Bool { canZoomOut || abs(zoomLevel - 1) > 0.001 }

    func zoomIn() { zoomController?.setZoom(zoomLevel * 1.4) }
    func zoomOut() { zoomController?.setZoom(zoomLevel / 1.4) }

    /// Everything in view. On the plate that is magnification 1; on the board it is
    /// whatever fits every card, which only the board can work out.
    func zoomToFit() { zoomController?.fitContent() }

    /// Pushed in by the scroll view; `magnification` is not observable on its own.
    func noteZoomChanged(_ value: CGFloat) {
        // Before the early return: a pinch that lands on the same number still has to be
        // able to tell us the surface underneath changed.
        let floor = zoomController?.minimumZoom ?? 1
        if abs(floor - minimumZoomLevel) > 0.0001 { minimumZoomLevel = floor }
        guard abs(value - zoomLevel) > 0.001 else { return }
        zoomLevel = value
    }

    func importTable() {
        guard let factorID = activeFactorID else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.message = "Choose a CSV or TSV file laid out like the plate."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var grid = url.pathExtension.lowercased() == "csv" ? CSV.parse(text) : TSV.parse(text)
            if grid.count == 1, grid[0].count == 1 { grid = CSV.parse(text) }
            grid = TSV.strippingPlateHeaders(grid)
            guard !grid.isEmpty else {
                flash("That file did not contain a readable table.")
                return
            }
            applyGrid(grid, factorID: factorID, atRow: 0, col: 0, actionName: "Import Table")
            flash("Imported \(grid.count) × \(grid[0].count) values into \(activeFactor?.name ?? "factor").")
        } catch {
            presentError(error, title: "Could not read that file")
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
