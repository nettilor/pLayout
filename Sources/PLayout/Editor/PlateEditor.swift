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
    @Published var hovered: WellPos?
    @Published var showSecondaryFactors = true
    /// Seeded from Preferences when the document opens; the sidebar toggle drives it
    /// afterwards, so changing the default never disturbs a window already up.
    @Published var roundWells = Preferences.shared.newDocumentWellShape.isRound
    @Published var transientMessage: String = ""
    /// Set by the menu bar; ContentView presents the sheets off these.
    @Published var showingSeriesSheet = false
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
        return parts.isEmpty ? "\(label) — empty" : "\(label)  ·  " + parts.joined(separator: "  ·  ")
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

    var hasSelection: Bool { selection != nil }

    /// The wells an action would apply to, or an empty list when nothing is selected.
    var selectedWells: [Int] {
        selection?.indices(in: format) ?? []
    }

    func select(_ range: WellRange) {
        selection = range.clamped(to: format)
    }

    func selectAllWells() {
        selection = .wholePlate(format)
    }

    func clearSelectionMarquee() {
        selection = nil
    }

    func moveCursor(dRow: Int, dCol: Int, extend: Bool) {
        let f = format
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

    // MARK: - Level & factor hotkeys

    func armLevel(atIndex index: Int) {
        guard let factor = activeFactor, factor.levels.indices.contains(index) else { return }
        armedLevelID = factor.levels[index].id
    }

    func cycleLevel(by delta: Int) {
        guard let factor = activeFactor, !factor.levels.isEmpty else { return }
        let current = armedLevelID.flatMap { factor.index(of: $0) } ?? -1
        let count = factor.levels.count
        let next = ((current + delta) % count + count) % count
        armedLevelID = factor.levels[next].id
    }

    func disarmLevel() { armedLevelID = nil }

    func setActiveFactor(_ id: UUID) {
        leaveOverview()
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

    func addLevel(name: String? = nil) {
        guard let factorID = activeFactorID, let factor = activeFactor else { return }
        let count = factor.levels.count
        let level = Level(
            name: name ?? "Condition \(count + 1)",
            colorHex: Palette.color(at: count)
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
        let hexes = factor.kind == .numeric
            ? Palette.ramp(count: factor.levels.count, baseHex: Palette.color(at: 0))
            : (0..<factor.levels.count).map { Palette.color(at: $0) }
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
            levels: [Level(name: "Level 1", colorHex: Palette.color(at: 0))]
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
        return true
    }

    /// Turns the plate on its side. Undoable and saved with the document like the other
    /// display settings, because an export renders the plate as it is shown.
    func toggleOrientation() {
        edit("Flip Plate") { layout in layout.transposedView.toggle() }
        flash(layout.transposedView ? "Rows across, columns down." : "Columns across, rows down.")
    }

    var isTransposed: Bool { layout.transposedView }

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
        }
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

    // MARK: - Clipboard

    /// Copies the selection as tab-separated text — pastes straight into Excel.
    func copySelection(includeHeaders: Bool = false) {
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
        copySelection()
        clearSelection()
    }

    /// Pastes a block of text values, creating any conditions it has not seen before.
    func pasteFromPasteboard() {
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
                        let levelID = layout.factors[fi].ensureLevel(named: value)
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

    private var suggestedBaseName: String {
        let title = NSApp.keyWindow?.title ?? ""
        let cleaned = title.replacingOccurrences(of: " — Edited", with: "")
            .replacingOccurrences(of: ".plate", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "Untitled" ? "Plate Layout" : cleaned
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
        let options = WorkbookLayoutAccessory(selected: WorkbookLayout.remembered)
        save(
            data: {
                let choice = options.selectedLayout
                choice.remember()
                return Exporter.workbook(from: self.layout, sheetLayout: choice)
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
        save(data: canvas?.pngData(), name: suggestedBaseName, ext: "png")
    }

    func exportPDF() {
        save(data: canvas?.pdfData(), name: suggestedBaseName, ext: "pdf")
    }

    /// Prints the plate exactly as it is currently shown — active factor, label mode
    /// and colours all included — scaled to fill one page.
    func printPlate() {
        guard let canvas else { return }
        canvas.printPlate(jobName: suggestedBaseName)
    }

    // MARK: - Zoom

    var canZoomOut: Bool { zoomLevel > 1.001 }

    func zoomIn() { zoomController?.setZoom(zoomLevel * 1.4) }
    func zoomOut() { zoomController?.setZoom(zoomLevel / 1.4) }

    /// Back to "whole plate in view", which is the minimum zoom.
    func zoomToFit() { zoomController?.setZoom(1) }

    /// Pushed in by the scroll view; `magnification` is not observable on its own.
    func noteZoomChanged(_ value: CGFloat) {
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
