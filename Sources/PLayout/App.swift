import SwiftUI

@main
struct PlateLayoutApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PlateDocument() }) { file in
            ContentView(document: file.document)
        }
        // Pairs with the canvas's ideal size in ContentView: without both, a new
        // document window opens too small to show a 96-well plate comfortably.
        .defaultSize(width: 1240, height: 800)
        .commands { PlateCommands() }
    }
}

// MARK: - Focused document plumbing

private struct PlateEditorFocusKey: FocusedValueKey {
    typealias Value = PlateEditor
}

extension FocusedValues {
    var plateEditor: PlateEditor? {
        get { self[PlateEditorFocusKey.self] }
        set { self[PlateEditorFocusKey.self] = newValue }
    }
}

// MARK: - Menu bar

struct PlateCommands: Commands {
    @FocusedValue(\.plateEditor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print Plate…") { editor?.printPlate() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(editor == nil)
        }

        CommandGroup(after: .importExport) {
            Button("Export Excel Workbook…") { editor?.exportWorkbook() }
                .keyboardShortcut("e", modifiers: .command)
            Button("Export Tidy CSV…") { editor?.exportCSV() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Export Plate Image (PNG)…") { editor?.exportPNG() }
            Button("Export Plate Image (PDF)…") { editor?.exportPDF() }
            Divider()
            Button("Import Table…") { editor?.importTable() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { editor?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { editor?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Fit Plate to Window") { editor?.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            // Lives with zoom rather than with the editing commands: like zooming out,
            // it changes how much of the design you can take in at once.
            Button {
                editor?.toggleOverview()
            } label: {
                if editor?.isOverview == true {
                    Label("Overview", systemImage: "checkmark")
                } else {
                    Text("Overview")
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Plate") {
            Button("Fill Selection") { editor?.paintSelection() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Clear Selection") { editor?.clearSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Clear All Factors in Selection") { editor?.clearSelectionAllFactors() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Button("Select All Wells") { editor?.selectAllWells() }

            Divider()

            Button("Save State") { editor?.saveState() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Revert to Last Saved State") { editor?.revertToLatestState() }
                .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button("Series Fill…") { editor?.openSeriesSheet() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Randomise Selection") { editor?.randomizeSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Next Condition") { editor?.cycleLevel(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Condition") { editor?.cycleLevel(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Add Condition") { editor?.addLevel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Menu("Factor") {
                ForEach(Array((editor?.layout.factors ?? []).enumerated()), id: \.element.id) { index, factor in
                    Button(factor.name) { editor?.setActiveFactor(factor.id) }
                        .keyboardShortcut(
                            index < 9
                                ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                                : nil
                        )
                }
                Divider()
                Button("Next Factor") { editor?.cycleFactor(by: 1) }
                Button("Add Factor") { editor?.addFactor() }
            }

            Divider()

            Menu("Plate Format") {
                if let editor {
                    PlateFormatMenuItems(editor: editor)
                }
            }
            Button("Custom Plate Size…") { editor?.showingCustomFormatSheet = true }
            Button("Add Plate") { editor?.addPlate() }
            Button("Duplicate Plate") { editor?.duplicatePlate() }

            Divider()

            Menu("Text in Wells") {
                ForEach(WellLabelMode.allCases) { mode in
                    Button {
                        editor?.setWellLabelMode(mode)
                    } label: {
                        if mode == editor?.layout.wellLabelMode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }
        }
    }
}
