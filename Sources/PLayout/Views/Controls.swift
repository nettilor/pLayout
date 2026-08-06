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

/// A name that a single click selects and a double click renames.
///
/// Selecting a factor or a condition is by far the more common action, so it gets the
/// single click and the whole row's worth of target area; renaming is deliberate, so it
/// asks for a double click. Escape abandons an edit, Return and clicking away keep it.
struct SelectableNameField: View {
    let text: String
    var placeholder: String = ""
    var font: Font = .body
    let onSelect: () -> Void
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused { commit() }
                    }
                    // Closing a popover or collapsing a section tears the field down
                    // without ever moving focus, so catch that too.
                    .onDisappear(perform: commit)
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEditing)
                    // Simultaneous, not chained. Two ordinary tap gestures become
                    // exclusive, so the single click cannot resolve until the
                    // double-click interval has elapsed — which is felt as lag on the
                    // action you take most. Recognising them in parallel lets the
                    // selection land on mouse-up; a double click simply selects first
                    // and then opens the editor, which is harmless.
                    .simultaneousGesture(TapGesture().onEnded(onSelect))
                    .help("Double-click to rename")
            }
        }
    }

    private func beginEditing() {
        draft = text
        isEditing = true
        // Focus after the field exists, which also lets it win over any row-level
        // click handling that ran on the way in.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        focused = false
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != text else { return }
        onCommit(trimmed)
    }

    private func cancel() {
        isEditing = false
        focused = false
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
