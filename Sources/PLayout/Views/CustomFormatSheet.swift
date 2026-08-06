import AppKit
import SwiftUI

/// Define an arbitrary m × n plate and optionally keep it as a reusable template.
struct CustomFormatSheet: View {
    @ObservedObject var editor: PlateEditor
    @ObservedObject private var store = PlateTemplateStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var rows: Int
    @State private var cols: Int
    @State private var name: String = ""
    @State private var saveAsTemplate = true

    init(editor: PlateEditor) {
        self.editor = editor
        _rows = State(initialValue: editor.format.rows)
        _cols = State(initialValue: editor.format.cols)
    }

    private var format: PlateFormat { PlateFormat(rows: rows, cols: cols) }

    private var alreadySaved: Bool { store.template(matching: format) != nil }
    private var canSaveTemplate: Bool { store.canSave(format) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom Plate Size")
                    .font(.title3.weight(.semibold))
                Text("Any layout from 1×1 up to \(PlateFormat.rowRange.upperBound)×\(PlateFormat.columnRange.upperBound) wells.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    dimensionField("Rows", value: $rows, range: PlateFormat.rowRange, hint: "A–\(WellNaming.rowLabel(rows - 1))")
                    dimensionField("Columns", value: $cols, range: PlateFormat.columnRange, hint: "1–\(cols)")

                    Divider()

                    Toggle("Save as a template", isOn: $saveAsTemplate)
                        .toggleStyle(.checkbox)
                        .disabled(!canSaveTemplate)
                    if alreadySaved {
                        Text("Already saved as “\(store.template(matching: format)?.name ?? "")”.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if format.isStandard {
                        Text("\(format.name) is a standard plate — it is already in the menu.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if saveAsTemplate {
                        TextField("Name", text: $name, prompt: Text("\(rows)×\(cols) plate"))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }
                .frame(width: 210)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(format.wellCount) wells")
                        .font(.callout.weight(.medium))
                    PlatePreview(format: format)
                        .frame(width: 210, height: 148)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                    Text("Wells A1 – \(WellNaming.wellLabel(row: rows - 1, col: cols - 1, padded: editor.layout.padWellLabels))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)

            if !store.templates.isEmpty {
                Divider().padding(.top, 16)
                savedTemplates
            }

            Divider()

            HStack {
                if editor.plate.map({ $0.formatChangeWouldLoseData(format) }) == true {
                    Label("Some assigned wells fall outside this size", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Size") {
                    let applied = editor.applyCustomFormat(
                        rows: rows, cols: cols,
                        templateName: (saveAsTemplate && canSaveTemplate) ? name : nil
                    )
                    // Backing out of the data-loss warning should leave the sheet up.
                    if applied { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    private func dimensionField(
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>, hint: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 62, alignment: .leading)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 54)
                .onChange(of: value.wrappedValue) { _, new in
                    let clamped = min(max(new, range.lowerBound), range.upperBound)
                    if clamped != new { value.wrappedValue = clamped }
                }
            Stepper(title, value: value, in: range)
                .labelsHidden()
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var savedTemplates: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved templates")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.templates) { template in
                        HStack(spacing: 8) {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            CommitTextField(placeholder: "Name", text: template.name, font: .callout) {
                                store.rename(template.id, to: $0)
                            }
                            Text(template.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button {
                                rows = template.rows
                                cols = template.cols
                            } label: {
                                Text("Use")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            Button {
                                store.remove(template.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(template.format == format
                                      ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
            .frame(maxHeight: 108)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Miniature well grid so the shape is obvious before committing to it.
private struct PlatePreview: View {
    let format: PlateFormat

    var body: some View {
        Canvas { context, size in
            let pad: CGFloat = 8
            let available = CGSize(width: size.width - pad * 2, height: size.height - pad * 2)
            let cell = min(available.width / CGFloat(format.cols), available.height / CGFloat(format.rows))
            let dot = max(1, cell * 0.72)
            let originX = (size.width - cell * CGFloat(format.cols)) / 2
            let originY = (size.height - cell * CGFloat(format.rows)) / 2

            for row in 0..<format.rows {
                for col in 0..<format.cols {
                    let rect = CGRect(
                        x: originX + CGFloat(col) * cell + (cell - dot) / 2,
                        y: originY + CGFloat(row) * cell + (cell - dot) / 2,
                        width: dot, height: dot
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Color.accentColor.opacity(0.55))
                    )
                }
            }
        }
    }
}
