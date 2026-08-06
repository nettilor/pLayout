import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Sidebar: View {
    @ObservedObject var editor: PlateEditor

    // A click means "select" and a quick second click on the same row means "rename".
    // Timed here rather than recognised as a double-tap gesture, so each row keeps
    // exactly one tap gesture and drag-to-reorder still works.
    @State private var clicks = RowClickTracker()
    @State private var editingFactorID: UUID?
    @State private var editingLevelID: UUID?
    // Explicit drag state: see RowReorder for why List's own .onMove cannot be used.
    @State private var draggedFactorID: UUID?
    @State private var draggedLevelID: UUID?
    @State private var dropTargetID: UUID?

    var body: some View {
        List {
            factorsSection
            conditionsSection
            displaySection
        }
        .listStyle(.sidebar)
        .frame(minWidth: 232)
    }

    // MARK: - Factors

    private var factorsSection: some View {
        Section {
            ForEach(Array(editor.layout.factors.enumerated()), id: \.element.id) { index, factor in
                let isActive = factor.id == editor.activeFactorID
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                        .font(.system(size: 11))
                    EditableName(
                        text: factor.name,
                        placeholder: "Factor",
                        isEditing: Binding(
                            get: { editingFactorID == factor.id },
                            set: { if !$0 { editingFactorID = nil } }
                        ),
                        onCommit: { editor.renameFactor(factor.id, to: $0) }
                    )
                    if factor.kind == .numeric {
                        Image(systemName: "number")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if index < 9 {
                        KeyCap(label: "⌘\(index + 1)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Selection happens on every click, including the first of a
                    // double, so it is never waiting on anything.
                    let renaming = clicks.isDoubleClick(on: factor.id)
                    editor.setActiveFactor(factor.id)
                    if renaming {
                        editingFactorID = factor.id
                    } else {
                        editingFactorID = nil
                        editor.focusCanvas()
                    }
                }
                .contextMenu {
                    Button(factor.kind == .numeric ? "Treat as Categorical" : "Treat as Numeric") {
                        editor.setFactorKind(factor.id, kind: factor.kind == .numeric ? .categorical : .numeric)
                    }
                    Divider()
                    Button("Delete Factor", role: .destructive) { editor.deleteFactor(factor.id) }
                        .disabled(editor.layout.factors.count <= 1)
                }
                .opacity(draggedFactorID == factor.id ? 0.4 : 1)
                .overlay(alignment: .top) { dropLine(showing: dropTargetID == factor.id) }
                .onDrag {
                    draggedFactorID = factor.id
                    return NSItemProvider(object: factor.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    isTargeted: Binding(
                        get: { dropTargetID == factor.id },
                        set: { dropTargetID = $0 ? factor.id : nil }
                    )
                ) { _ in dropFactor(onto: factor.id) }
            }
            Button {
                editor.addFactor()
            } label: {
                Label("Add Factor", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } header: {
            Text("Factors")
        } footer: {
            Text("Each factor is painted separately. Wells keep a value for every factor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Conditions (levels of the active factor)

    private var conditionsSection: some View {
        Section {
            if let factor = editor.activeFactor {
                if !factor.unit.isEmpty || factor.kind == .numeric {
                    HStack(spacing: 6) {
                        Text("Unit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        CommitTextField(placeholder: "µM, h, ng/mL…", text: factor.unit, font: .caption) {
                            editor.setFactorUnit(factor.id, unit: $0)
                        }
                    }
                }

                ForEach(Array(factor.levels.enumerated()), id: \.element.id) { index, level in
                    levelRow(index: index, level: level)
                        .opacity(draggedLevelID == level.id ? 0.4 : 1)
                        .overlay(alignment: .top) { dropLine(showing: dropTargetID == level.id) }
                        .onDrag {
                            draggedLevelID = level.id
                            return NSItemProvider(object: level.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.plainText],
                            isTargeted: Binding(
                                get: { dropTargetID == level.id },
                                set: { dropTargetID = $0 ? level.id : nil }
                            )
                        ) { _ in dropLevel(onto: level.id) }
                }

                Button {
                    editor.addLevel()
                } label: {
                    Label("Add Condition", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(editor.activeFactor?.name ?? "Conditions")
                Spacer()
                Menu {
                    Button("Recolour from Palette") { editor.recolorLevelsFromPalette() }
                    Button("Remove Unused Conditions") { editor.removeUnusedLevels() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func levelRow(index: Int, level: Level) -> some View {
        let isArmed = level.id == editor.armedLevelID
        let count = editor.wellCount(ofLevel: level)
        return HStack(spacing: 7) {
            if index < 10 {
                KeyCap(label: index == 9 ? "0" : "\(index + 1)", highlighted: isArmed)
            } else {
                KeyCap(label: "·")
            }
            SwatchPicker(hex: level.colorHex) { editor.setLevelColor(level.id, hex: $0) }
            EditableName(
                text: level.name,
                placeholder: "Name",
                isEditing: Binding(
                    get: { editingLevelID == level.id },
                    set: { if !$0 { editingLevelID = nil } }
                ),
                onCommit: { editor.renameLevel(level.id, to: $0) }
            )
            Text(count == 0 ? "—" : "\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            let renaming = clicks.isDoubleClick(on: level.id)
            editor.armedLevelID = level.id
            if renaming {
                editingLevelID = level.id
            } else {
                editingLevelID = nil
                editor.focusCanvas()
            }
        }
        .listRowBackground(
            isArmed
                ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12))
                : RoundedRectangle(cornerRadius: 5).fill(Color.clear)
        )
        .contextMenu {
            Button("Fill Selection with \(level.name)") {
                editor.armedLevelID = level.id
                editor.paintSelection()
            }
            Divider()
            Button("Delete Condition", role: .destructive) { editor.deleteLevel(level.id) }
        }
    }

    // MARK: - Reordering

    @ViewBuilder
    private func dropLine(showing: Bool) -> some View {
        if showing {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, -4)
        }
    }

    private func dropFactor(onto targetID: UUID) -> Bool {
        defer { draggedFactorID = nil; dropTargetID = nil }
        guard let dragged = draggedFactorID,
              let from = editor.layout.factors.firstIndex(where: { $0.id == dragged }),
              let to = editor.layout.factors.firstIndex(where: { $0.id == targetID }),
              from != to
        else { return false }
        editor.moveFactors(
            fromOffsets: IndexSet(integer: from),
            toOffset: RowReorder.offset(movingFrom: from, onto: to)
        )
        return true
    }

    private func dropLevel(onto targetID: UUID) -> Bool {
        defer { draggedLevelID = nil; dropTargetID = nil }
        guard let dragged = draggedLevelID,
              let levels = editor.activeFactor?.levels,
              let from = levels.firstIndex(where: { $0.id == dragged }),
              let to = levels.firstIndex(where: { $0.id == targetID }),
              from != to
        else { return false }
        editor.moveLevels(
            fromOffsets: IndexSet(integer: from),
            toOffset: RowReorder.offset(movingFrom: from, onto: to)
        )
        return true
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Text in wells")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { editor.layout.wellLabelMode },
                    set: { editor.setWellLabelMode($0) }
                )) {
                    ForEach(WellLabelMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if editor.layout.wellLabelMode == .allFactors {
                    Text(allFactorsHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            Toggle("Round wells", isOn: $editor.roundWells)
                .help("Ignored while stacked labels are showing — they need the full width of the well, so those are drawn as squares.")
            // In All factors the stacked list already shows every factor, so this
            // control would have nothing left to govern.
            if editor.layout.wellLabelMode != .allFactors {
                Toggle("Show other factors", isOn: $editor.showSecondaryFactors)
                    .disabled(editor.layout.factors.count < 2)
                    .help("Adds a colour strip along the bottom of each well for the factors you are not painting.")
            }
            Toggle(
                "Pad well IDs (A01)",
                isOn: Binding(
                    get: { editor.layout.padWellLabels },
                    set: { editor.setPadWellLabels($0) }
                )
            )
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private var allFactorsHint: String {
        editor.layout.factors.count < 2
            ? "Add a second factor to see stacked labels."
            : "One line per factor, in the order listed above. Any that do not fit drop to a colour strip. A key appears under the plate."
    }
}
