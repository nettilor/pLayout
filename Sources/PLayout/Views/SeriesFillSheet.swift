import AppKit
import SwiftUI

/// Dose series across the current selection — the reason most plate maps get built.
struct SeriesFillSheet: View {
    @ObservedObject var editor: PlateEditor
    @Environment(\.dismiss) private var dismiss

    @State private var spec = PlateEditor.SeriesSpec()

    private var values: [String] { editor.seriesValues(spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Series Fill")
                    .font(.title3.weight(.semibold))
                Text("Writes a value series into \(selectionDescription) of \(editor.activeFactor?.name ?? "the active factor").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Form {
                Picker("Direction", selection: $spec.direction) {
                    ForEach(PlateEditor.SeriesSpec.Direction.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Series", selection: $spec.mode) {
                    ForEach(PlateEditor.SeriesSpec.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Top value", value: $spec.start, format: .number)

                if spec.mode == .fold {
                    HStack(spacing: 8) {
                        TextField("Fold", value: $spec.foldFactor, format: .number)
                            .frame(width: 70)
                        Picker("", selection: $spec.dilute) {
                            Text("dilution (÷)").tag(true)
                            Text("increase (×)").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } else {
                    TextField("Step", value: $spec.step, format: .number)
                }

                Stepper("Significant digits: \(spec.significantDigits)", value: $spec.significantDigits, in: 1...6)

                Toggle("Last position is 0 (vehicle control)", isOn: $spec.lastIsZero)
            }
            .formStyle(.grouped)
            .frame(height: 250)

            VStack(alignment: .leading, spacing: 5) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            Text(value)
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
                        if values.isEmpty {
                            Text("Select some wells first.")
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
                    editor.applySeries(spec)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(values.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    private var selectionDescription: String {
        guard let selection = editor.selection else { return "the selection" }
        return "\(selection.rowCount)×\(selection.colCount) wells"
    }

    private var ramp: [String] {
        Palette.ramp(count: max(values.count, 1), baseHex: editor.activeFactor?.levels.first?.colorHex ?? Palette.color(at: 0))
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
