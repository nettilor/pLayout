import AppKit
import SwiftUI

struct Sidebar: View {
    @ObservedObject var editor: PlateEditor

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
                    CommitTextField(placeholder: "Factor", text: factor.name) {
                        editor.renameFactor(factor.id, to: $0)
                    }
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
                    editor.setActiveFactor(factor.id)
                    editor.focusCanvas()
                }
                .contextMenu {
                    Button(factor.kind == .numeric ? "Treat as Categorical" : "Treat as Numeric") {
                        editor.setFactorKind(factor.id, kind: factor.kind == .numeric ? .categorical : .numeric)
                    }
                    Divider()
                    Button("Delete Factor", role: .destructive) { editor.deleteFactor(factor.id) }
                        .disabled(editor.layout.factors.count <= 1)
                }
            }
            .onMove { source, destination in
                editor.moveFactors(fromOffsets: source, toOffset: destination)
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
                }
                .onMove { source, destination in
                    editor.moveLevels(fromOffsets: source, toOffset: destination)
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
            CommitTextField(placeholder: "Name", text: level.name) {
                editor.renameLevel(level.id, to: $0)
            }
            Text(count == 0 ? "—" : "\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            editor.armedLevelID = level.id
            editor.focusCanvas()
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
