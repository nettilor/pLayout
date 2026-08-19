import AppKit
import SwiftUI

@main
struct PlateLayoutApp: App {
    init() {
        // Quiet unless there is news: at most daily, delayed past window creation,
        // and skipped entirely when the toggle in the app menu is off.
        UpdateChecker.shared.checkOnLaunch()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { PlateDocument() }) { file in
            ContentView(document: file.document)
        }
        // Pairs with the canvas's ideal size in ContentView: without both, a new
        // document window opens too small to show a 96-well plate comfortably.
        .defaultSize(width: 1240, height: 800)
        .commands { PlateCommands() }

        // A `Settings` scene is what puts "Settings…" in the app menu under ⌘, — there
        // is no command to add by hand, and adding one would collide with it.
        Settings {
            PreferencesView()
        }
    }
}

// MARK: - Menu bar

struct PlateCommands: Commands {
    // @FocusedObject, not @FocusedValue: the Factor menu bakes ⌘1–⌘9 onto items by
    // position, and key equivalents dispatch against the menu as last built, without
    // opening it. A plain focused value never re-evaluates when the layout changes,
    // so a sidebar reorder left ⌘n switching to the factors' old order.
    @FocusedObject private var editor: PlateEditor?

    // For the update items, which need no document. The auto-check toggle lives here
    // beside the manual check rather than in ⌘, — the Settings window is a section
    // past its height budget already, and the two belong side by side anyway.
    @ObservedObject private var preferences = Preferences.shared
    // Observed so the submenu rebuilds when a template is saved or removed —
    // the same staleness the Factor menu taught (§ HANDOFF 2h).
    @ObservedObject private var layoutTemplates = LayoutTemplateStore.shared
    // Observed so ⌘P retitles the moment a prep window takes or loses focus.
    @ObservedObject private var prepWindows = PrepWindowRegistry.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
            Toggle("Check for Updates Automatically", isOn: $preferences.checkForUpdatesAutomatically)
        }

        CommandGroup(after: .newItem) {
            Menu("New from Template") {
                if layoutTemplates.templates.isEmpty {
                    Text("No templates yet — save one below.")
                } else {
                    ForEach(layoutTemplates.templates) { template in
                        Button(template.name) { layoutTemplates.openNewDocument(from: template) }
                    }
                    Divider()
                    Menu("Remove Template") {
                        ForEach(layoutTemplates.templates) { template in
                            Button(template.name) { layoutTemplates.delete(template) }
                        }
                    }
                }
            }
            Button("Save as Template…") { saveCurrentLayoutAsTemplate() }
                .disabled(editor == nil)
        }

        CommandGroup(replacing: .printItem) {
            // Retargets by whichever of a document's two windows is frontmost, and says
            // which one it means: a ⌘P whose destination you cannot see reads as a bug
            // the first time it surprises you. The target comes from the registry rather
            // than from @FocusedObject because the prep window is a plain NSWindow, not
            // a SwiftUI scene, and a focused-object miss would grey the item out.
            Button(prepWindows.keyEditor != nil ? "Print Prep Sheet…" : "Print Plate…") {
                (prepWindows.keyEditor ?? editor)?.printFrontmost()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(prepWindows.keyEditor == nil && editor == nil)
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

        // Beside the standard Copy and Paste, because that is exactly what they are —
        // the same gesture on the whole well rather than on the factor being painted.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Wells with All Factors") { editor?.copyWells() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Paste Wells") { editor?.pasteWells() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(editor == nil)
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
            // The third "how you are looking at the design" toggle, beside Overview and
            // Turn Plate. ⇧⌘K rather than anything with ⌥: ⌥⌘D is a system shortcut and
            // never arrives, which is the kind of thing only the running app tells you.
            Button {
                editor?.toggleCanvas()
            } label: {
                if editor?.showsCanvas == true {
                    Label("Canvas", systemImage: "checkmark")
                } else {
                    Text("Canvas")
                }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            Button {
                editor?.rotatePlate()
            } label: {
                if editor?.isTurned == true {
                    Label("Turn Plate 90°", systemImage: "checkmark")
                } else {
                    Text("Turn Plate 90°")
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Plate") {
            Button("Fill Selection") { editor?.paintSelection() }
                .keyboardShortcut(.return, modifiers: .command)
            // ⌫ on the canvas clears the active factor; ⌘⌫ empties the wells
            // completely. The menu carries the ⌘ variant — a bare-⌫ equivalent
            // here would swallow Delete inside every rename field.
            Button("Clear Selection") { editor?.clearSelection() }
            Button("Clear All Factors in Selection") { editor?.clearSelectionAllFactors() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Select All Wells") { editor?.selectAllWells() }
            Button("Well Note…") { editor?.openWellNoteSheet() }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("Save State") { editor?.saveState() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Revert to Last Saved State") { editor?.revertToLatestState() }
                .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button("Series Fill…") { editor?.openSeriesSheet() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("XY Position Fill…") { editor?.openXYFillSheet() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            // ⌥⌘P, not the ⌥⌘D that would have paired it with Series Fill's ⇧⌘D:
            // **⌥⌘D is a system shortcut** — macOS toggles the Dock with it and the
            // event never reaches the app. Verified by driving the real app; the menu
            // item worked when clicked and the key equivalent did nothing at all.
            Button("Pipetting Prep Sheet…") { editor?.openPrepWindow() }
                .keyboardShortcut("p", modifiers: [.command, .option])
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

    /// One field, one question — a template is a starting point, not a document,
    /// so it takes a name and nothing else.
    private func saveCurrentLayoutAsTemplate() {
        guard let editor else { return }
        let alert = NSAlert()
        alert.messageText = "Save as Template"
        alert.informativeText = "The whole layout — factors, conditions, plates and their painting — becomes a starting point under File > New from Template. Saving under an existing name replaces that template."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Template name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              !LayoutTemplateStore.sanitized(field.stringValue).isEmpty else { return }
        do {
            try LayoutTemplateStore.shared.save(editor.layout, named: field.stringValue)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not save the template"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }
}
