import AppKit
import SwiftUI

/// Text field that writes back on Return or when focus leaves, so renaming
/// something does not create one undo step per keystroke.
struct CommitTextField: View {
    let placeholder: String
    let text: String
    var font: Font = .body
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onSubmit {
                commit()
                focused = false
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            // Losing focus is not guaranteed when the field is torn down — closing a
            // popover destroys the row outright — so commit on the way out too.
            .onDisappear { commit() }
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !focused { draft = newValue }
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        // A blank name is refused by the model, which then reports no change at all —
        // so put the old one back rather than leaving the field looking empty.
        if trimmed.isEmpty {
            draft = text
        } else {
            onCommit(trimmed)
        }
    }
}

/// Colour swatch that opens the shared palette, with a system picker for anything else.
struct SwatchPicker: View {
    let hex: String
    let onPick: (String) -> Void

    @State private var showing = false

    private let columns = Array(repeating: GridItem(.fixed(20), spacing: 6), count: 5)

    var body: some View {
        Button {
            showing = true
        } label: {
            Circle()
                .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Palette.categorical, id: \.self) { candidate in
                        Button {
                            onPick(candidate)
                            showing = false
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: NSColor(hex: candidate) ?? .gray))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(
                                            candidate.caseInsensitiveCompare(hex) == .orderedSame
                                                ? Color.accentColor : Color.black.opacity(0.15),
                                            lineWidth: candidate.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 0.5
                                        )
                                )
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()
                ColorPicker(
                    "Custom…",
                    selection: Binding(
                        get: { Color(nsColor: NSColor(hex: hex) ?? .gray) },
                        set: { onPick(NSColor($0).hexString) }
                    ),
                    supportsOpacity: false
                )
                .font(.callout)
            }
            .padding(12)
            .frame(width: 168)
        }
    }
}

/// Small rounded key cap used for hotkey hints.
struct KeyCap: View {
    let label: String
    var highlighted: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(highlighted ? Color.white : Color.secondary)
            .frame(minWidth: 16)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? Color.accentColor : Color.secondary.opacity(0.14))
            )
    }
}
