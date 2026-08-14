import AppKit
import SwiftUI

/// Numbers wells as imaging positions the way a Keyence microscope names them —
/// an "XY" factor whose levels run XY01… in the order the stage will visit them.
struct XYFillSheet: View {
    @ObservedObject var editor: PlateEditor
    @Environment(\.dismiss) private var dismiss

    @State private var spec: PlateEditor.XYFillSpec

    /// Chips beyond this stay behind the "→ XY96" tail; a 1536-well preview
    /// would otherwise build 1536 views for a strip nobody scrolls to the end of.
    private let previewLimit = 16

    init(editor: PlateEditor) {
        self.editor = editor
        // The swatch starts on the colour the fill would use anyway, so leaving it
        // alone is exactly the automatic behaviour.
        let existing = editor.layout.factors.first { $0.name == PlateEditor.xyFactorName }
        let hex = existing?.levels.first?.colorHex
            ?? PlateEditor.newLevelColor(in: editor.layout, fallback: editor.layout.factors.count)
        _spec = State(initialValue: .init(baseHex: hex))
    }

    private var wellCount: Int { editor.xyFillWells(spec).count }
    private var names: [String] { PlateEditor.xyNames(count: wellCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("XY Position Fill")
                    .font(.title3.weight(.semibold))
                Text("Numbers \(targetDescription) as factor “\(PlateEditor.xyFactorName)”, in the order the microscope visits them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Form {
                Picker("Pattern", selection: $spec.pattern) {
                    ForEach(PlateEditor.XYFillSpec.Pattern.allCases) { pattern in
                        Text(pattern.label).tag(pattern)
                    }
                }
                .pickerStyle(.segmented)

                // The same swatch-and-grid every condition colour goes through —
                // a bare system picker here would break the app's own pattern.
                HStack {
                    Text("Gradient colour")
                    Spacer()
                    SwatchPicker(hex: spec.baseHex ?? Palette.color(at: 0)) {
                        spec.baseHex = $0
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 130)

            VStack(alignment: .leading, spacing: 5) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(names.prefix(previewLimit).enumerated()), id: \.offset) { index, name in
                            Text(name)
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(previewColor(at: index))
                                )
                                .foregroundStyle(previewTextColor(at: index))
                        }
                        if names.count > previewLimit {
                            Text("→ \(names.last ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if names.isEmpty {
                            Text("No plate to number.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fill") {
                    editor.applyXYFill(spec)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(names.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    private var targetDescription: String {
        if let custom = editor.customWells, !custom.isEmpty {
            return "the \(custom.count) selected wells"
        }
        guard let selection = editor.selection, !selection.isSingleWell else { return "the whole plate" }
        return "\(selection.rowCount)×\(selection.colCount) wells"
    }

    private var ramp: [String] {
        let base = spec.baseHex
            ?? editor.layout.factors.first { $0.name == PlateEditor.xyFactorName }?.levels.first?.colorHex
            ?? PlateEditor.newLevelColor(in: editor.layout, fallback: editor.layout.factors.count)
        return Palette.ramp(count: max(wellCount, 1), baseHex: base)
    }

    private func previewColor(at index: Int) -> Color {
        let hexes = ramp
        guard hexes.indices.contains(index), let color = NSColor(hex: hexes[index]) else {
            return Color.secondary.opacity(0.15)
        }
        return Color(nsColor: color)
    }

    private func previewTextColor(at index: Int) -> Color {
        let hexes = ramp
        guard hexes.indices.contains(index), let color = NSColor(hex: hexes[index]) else { return .primary }
        return Color(nsColor: color.contrastingLabelColor)
    }
}
