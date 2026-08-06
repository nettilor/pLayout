import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var document: PlateDocument
    @StateObject private var editor: PlateEditor
    @Environment(\.undoManager) private var undoManager

    @State private var showingShortcuts = false
    @State private var showingStates = false

    init(document: PlateDocument) {
        self.document = document
        _editor = StateObject(wrappedValue: PlateEditor(document: document))
    }

    var body: some View {
        plateContent.toolbar { toolbarContent }
    }

    private var plateContent: some View {
        NavigationSplitView {
            Sidebar(editor: editor)
        } detail: {
            VStack(spacing: 0) {
                plateBar
                Divider()
                // The ideal size here is what decides how large a new window opens,
                // so it is set to give a 96-well plate comfortable wells.
                PlateCanvas(editor: editor)
                    .frame(minWidth: 420, idealWidth: 940, minHeight: 320, idealHeight: 660)
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .focusedSceneValue(\.plateEditor, editor)
        .sheet(isPresented: $editor.showingSeriesSheet) {
            SeriesFillSheet(editor: editor)
        }
        .sheet(isPresented: $editor.showingCustomFormatSheet) {
            CustomFormatSheet(editor: editor)
        }
        .onAppear {
            if editor.undoManager == nil { editor.undoManager = undoManager }
        }
    }

    // MARK: - Plate tabs

    private var plateBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(editor.layout.plates) { plate in
                        plateChip(plate)
                    }
                }
                .padding(.vertical, 6)
            }
            Button {
                editor.addPlate()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add another plate to this layout")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
    }

    private func plateChip(_ plate: Plate) -> some View {
        let isActive = plate.id == editor.activePlateID
        return Button {
            editor.activePlateID = plate.id
            editor.select(WellRange(single: WellPos(row: 0, col: 0)))
        } label: {
            HStack(spacing: 5) {
                Text(plate.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                Text(editor.formatDisplayName(plate.format))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate Plate") {
                editor.activePlateID = plate.id
                editor.duplicatePlate()
            }
            Button("Delete Plate", role: .destructive) { editor.deletePlate(plate.id) }
                .disabled(editor.layout.plates.count <= 1)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let armed = editor.armedLevel, let factor = editor.activeFactor {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: armed.colorHex) ?? .gray))
                        .frame(width: 9, height: 9)
                    Text("\(factor.name): \(armed.name)")
                        .font(.system(size: 11, weight: .medium))
                }
            } else {
                Text("No condition armed — press 1–9 to pick one")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Text(hoverText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !editor.transientMessage.isEmpty {
                Text(editor.transientMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }

            if editor.canZoomOut {
                Button {
                    editor.zoomToFit()
                } label: {
                    Text("\(Int((editor.zoomLevel * 100).rounded()))%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Fit the plate to the window (⌘0)")

                Divider().frame(height: 12)
            }

            Text(selectionText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: editor.transientMessage)
    }

    private var hoverText: String {
        if let hovered = editor.hovered {
            return editor.summary(row: hovered.row, col: hovered.col)
        }
        guard let focus = editor.selection?.focus else { return "" }
        return editor.summary(row: focus.row, col: focus.col)
    }

    private var selectionText: String {
        guard let selection = editor.selection else { return "No selection" }
        let padded = editor.layout.padWellLabels
        let from = WellNaming.wellLabel(row: selection.minRow, col: selection.minCol, padded: padded)
        if selection.isSingleWell { return from }
        let to = WellNaming.wellLabel(row: selection.maxRow, col: selection.maxCol, padded: padded)
        return "\(from):\(to)  ·  \(selection.rowCount)×\(selection.colCount) = \(selection.wellCount)"
    }

    // MARK: - Toolbar

    // Saved states are a separate concept from the fill tools, so the two sit in
    // separate bubbles. Nothing here is conditionally present or conditionally
    // disabled — changing an item's structure or enabled state makes AppKit re-tile
    // the bar, which is what made the groups split apart while they were being used.

    /// macOS draws a toolbar "island" per run of adjacent buttons, and it merges
    /// those runs regardless of `ToolbarItemGroup` or `ToolbarSpacer` — both were
    /// tried, and neither splits a run of plain buttons. What does separate them is
    /// the placement region, so the saved-state pair lives in the leading region:
    /// its own island, still left of the fill tools.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) { formatMenu }
        ToolbarItemGroup(placement: .navigation) { saveStateButton; savedStatesButton }
        ToolbarItemGroup { seriesFillButton; randomiseButton }
        ToolbarItem { exportMenu }
        ToolbarItem { shortcutsButton }
    }

    /// Icon only, deliberately. Showing the format name here made the item's width
    /// change whenever the format did — including just clicking between plate tabs of
    /// different sizes — and AppKit re-tiles the whole bar when an item resizes, which
    /// is what made the groups jump around. The plate tabs already name the format.
    private var formatMenu: some View {
        Menu {
            PlateFormatMenuItems(editor: editor)
        } label: {
            Label("Plate Format", systemImage: "square.grid.3x3")
                .labelStyle(.iconOnly)
        }
        .help("Plate format — currently \(editor.formatDisplayName(editor.format))")
    }

    private var saveStateButton: some View {
        Button {
            editor.saveState()
        } label: {
            Label(
                "Save State",
                systemImage: editor.currentDesignIsSaved ? "bookmark.fill" : "bookmark"
            )
        }
        .help(
            editor.currentDesignIsSaved
                ? "This layout is already saved as a state"
                : "Bookmark the layout as it is now, so you can come back to it (\u{2325}\u{2318}S)"
        )
    }

    private var savedStatesButton: some View {
        Button {
            showingStates.toggle()
        } label: {
            Label("Saved States", systemImage: "clock.arrow.circlepath")
        }
        .help("Revert to, rename or delete a saved state (\u{2325}\u{2318}R reverts to the latest)")
        .popover(isPresented: $showingStates, arrowEdge: .bottom) {
            SavedStatesPopover(editor: editor)
        }
    }

    private var seriesFillButton: some View {
        Button {
            editor.showingSeriesSheet = true
        } label: {
            Label("Series Fill", systemImage: "chart.line.downtrend.xyaxis")
        }
        .help("Fill the selection with a dilution or step series (\u{21E7}\u{2318}D)")
    }

    private var randomiseButton: some View {
        Button {
            editor.randomizeSelection()
        } label: {
            Label("Randomise", systemImage: "shuffle")
        }
        .help("Shuffle the assigned values within the selection")
    }

    private var exportMenu: some View {
        Menu {
            Button("Excel Workbook\u{2026}") { editor.exportWorkbook() }
            Button("Tidy CSV\u{2026}") { editor.exportCSV() }
            Divider()
            Button("Plate Image (PNG)\u{2026}") { editor.exportPNG() }
            Button("Plate Image (PDF)\u{2026}") { editor.exportPDF() }
            Divider()
            Button("Import Table\u{2026}") { editor.importTable() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export or import plate data")
    }

    private var shortcutsButton: some View {
        Button {
            showingShortcuts.toggle()
        } label: {
            Label("Shortcuts", systemImage: "keyboard")
        }
        .popover(isPresented: $showingShortcuts, arrowEdge: .bottom) {
            ShortcutsCard()
        }
    }
}

// MARK: - Plate format menu

/// Shared by the toolbar menu and the Plate menu in the menu bar, so the two can
/// never drift apart.
struct PlateFormatMenuItems: View {
    @ObservedObject var editor: PlateEditor
    @ObservedObject private var store = PlateTemplateStore.shared

    var body: some View {
        ForEach(PlateFormat.standard) { format in
            item(format, title: format.detailedName)
        }
        if !store.templates.isEmpty {
            Divider()
            Section("Custom") {
                ForEach(store.templates) { template in
                    item(template.format, title: "\(template.name)  (\(template.rows)×\(template.cols))")
                }
            }
        }
        Divider()
        Button("Custom Size…") { editor.showingCustomFormatSheet = true }
    }

    private func item(_ format: PlateFormat, title: String) -> some View {
        Button {
            editor.setFormat(format)
        } label: {
            if format == editor.format {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - Shortcuts help

struct ShortcutsCard: View {
    private struct Row: Identifiable {
        let id = UUID()
        let key: String
        let detail: String
    }

    private let rows: [Row] = [
        Row(key: "1 – 9, 0", detail: "Arm condition 1–10"),
        Row(key: "[  /  ]", detail: "Previous / next condition"),
        Row(key: "drag", detail: "Paint a rectangle of wells"),
        Row(key: "⌘ drag", detail: "Free-hand brush"),
        Row(key: "⌥ drag", detail: "Erase wells"),
        Row(key: "click A / 1", detail: "Paint a whole row or column"),
        Row(key: "space  /  F", detail: "Fill the current selection"),
        Row(key: "⌫", detail: "Clear active factor  (⇧⌫ clears all)"),
        Row(key: "⎋", detail: "Disarm — select without painting"),
        Row(key: "arrows", detail: "Move · ⇧arrows extend selection"),
        Row(key: "⌘1 … ⌘9", detail: "Switch factor"),
        Row(key: "click away", detail: "Deselect — click off the plate"),
        Row(key: "pinch", detail: "Zoom in  ·  ⌘0 fits the plate again"),
        Row(key: "⌘C  /  ⌘V", detail: "Copy / paste as Excel cells"),
        Row(key: "⇧⌘C", detail: "Copy including row & column headers"),
        Row(key: "⌘P", detail: "Print the plate as shown"),
        Row(key: "⌥⌘S", detail: "Save this layout as a state you can return to"),
        Row(key: "⌥⌘R", detail: "Revert to the last saved state"),
        Row(key: "⌘Z", detail: "Undo — including saving and reverting states"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Keyboard & Mouse")
                .font(.headline)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.key)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(.primary)
                    Text(row.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
