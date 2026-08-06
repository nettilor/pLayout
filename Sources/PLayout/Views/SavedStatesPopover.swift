import AppKit
import SwiftUI

/// The saved-state list. A popover rather than a `Menu` because each row needs an
/// editable name and a delete button, which a macOS menu cannot host.
struct SavedStatesPopover: View {
    @ObservedObject var editor: PlateEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if editor.savedStates.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(editor.savedStatesNewestFirst) { state in
                            row(state)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 330)
    }

    private var header: some View {
        HStack {
            Text("Saved states")
                .font(.callout.weight(.semibold))
            Spacer()
            Text("⌥⌘S saves · ⌘Z undoes")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing saved yet.")
                .font(.callout)
            Text("Save a state before trying a new combination, and you can always come back to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func row(_ state: LayoutSnapshot) -> some View {
        let isCurrent = state.id == editor.matchingSavedStateID
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.55))
                .help(isCurrent ? "The plate matches this state right now" : "")

            VStack(alignment: .leading, spacing: 1) {
                CommitTextField(placeholder: "Name", text: state.name, font: .callout) {
                    editor.renameState(state.id, to: $0)
                }
                Text(editor.subtitle(for: state))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                editor.revertToState(state.id)
                dismiss()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(isCurrent)
            .help(isCurrent ? "Already showing this state" : "Revert the plate to this state")

            Button(role: .destructive) {
                editor.deleteState(state.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete this state — ⌘Z brings it back")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }
}
