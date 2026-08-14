import SwiftUI

/// A note on a well or a plate — deliberately small: a couple of lines about a
/// bubble, a smear, a well to treat with suspicion. Anything bigger belongs in
/// the lab notebook, not the layout.
struct NoteSheet: View {
    @ObservedObject var editor: PlateEditor
    let target: PlateEditor.NoteTarget
    @Environment(\.dismiss) private var dismiss

    @State private var text: String

    init(editor: PlateEditor, target: PlateEditor.NoteTarget) {
        self.editor = editor
        self.target = target
        _text = State(initialValue: editor.noteText(for: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editor.noteTitle(for: target))
                    .font(.title3.weight(.semibold))
                Text("Shown in the status bar, and exported with the Wells sheet. Leave empty to remove.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(height: 88)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    editor.saveNote(text, for: target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380)
    }
}
