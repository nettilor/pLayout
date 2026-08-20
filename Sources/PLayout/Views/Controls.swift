import AppKit
import SwiftUI

/// Text field that writes back on Return or when focus leaves, so renaming
/// something does not create one undo step per keystroke.
struct CommitTextField: View {
    let placeholder: String
    let text: String
    var font: Font = .body
    /// A name cannot be blank — the model refuses it and the row would be left looking
    /// empty — but an optional field like a factor's unit has to be clearable, so the
    /// two behaviours are chosen here rather than guessed from the value.
    var allowsEmpty: Bool = false
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
        if trimmed.isEmpty && !allowsEmpty {
            draft = text
            return
        }
        // Nothing typed, nothing committed. This fires on losing focus *and* again on
        // disappearing, so without it merely clicking into a field and out again — or
        // just closing the window — reports an edit. Most owners turn that into a no-op
        // change the model discards, but one that seeds a value into a document which
        // never had one cannot: the prep sheet went from "never used" to "configured"
        // because someone clicked in the Diluent box, which put an undo step nobody
        // performed on the stack and a Prep tab in every Excel export from then on.
        guard trimmed != text else { return }
        onCommit(trimmed)
    }
}

/// A row's name: plain text normally, an editable field while `isEditing`.
///
/// It carries **no gestures at all**. Every attempt to put one here — exclusive or
/// simultaneous, single or double — either stalled the row's click for the
/// double-click interval or swallowed the press that `List` needs to start a reorder
/// drag. The owning row keeps its single tap gesture and decides what a click means,
/// which is the arrangement reordering already worked with.
///
/// Escape abandons an edit; Return or clicking away keeps it.
struct EditableName: View {
    let text: String
    var placeholder: String = ""
    var font: Font = .body
    @Binding var isEditing: Bool
    let onCommit: (String) -> Void

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
                    // Switching rows tears the field down without moving focus.
                    .onDisappear(perform: commit)
                    .onAppear {
                        draft = text
                        DispatchQueue.main.async { focused = true }
                    }
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Double-click to rename")
            }
        }
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

/// Reordering rows by dragging them onto one another.
///
/// `List`'s own `.onMove` is wired up correctly here — the outline view registers the
/// reorder drop type and its data source hands back a pasteboard writer for exactly the
/// factor and condition rows — but the rows also carry a tap gesture for selection, and
/// SwiftUI's gesture tracking consumes the mouse movement before AppKit can turn it into
/// a drag session. Rather than give up the click behaviour, the drag is driven explicitly.
enum RowReorder {
    /// `move(fromOffsets:toOffset:)` inserts *before* `toOffset` using pre-move indices,
    /// so dropping onto a row further down needs one added to land after it.
    static func offset(movingFrom from: Int, onto to: Int) -> Int {
        to > from ? to + 1 : to
    }
}

/// Turns a stream of row clicks into "select" or "rename" by timing them, rather than
/// by adding a second gesture recogniser that would compete for the pointer.
@MainActor
struct RowClickTracker {
    private var lastID: UUID?
    private var lastAt: TimeInterval = 0

    /// True when this click is the second of a double click on the same row.
    /// Consumes the pair, so a third click starts counting again. The clock and the
    /// interval are injectable so the rule can be tested without waiting on a timer.
    mutating func isDoubleClick(
        on id: UUID,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        interval: TimeInterval = NSEvent.doubleClickInterval
    ) -> Bool {
        let isDouble = id == lastID && now - lastAt <= interval
        lastID = isDouble ? nil : id
        lastAt = isDouble ? 0 : now
        return isDouble
    }
}

/// Colour swatch that opens the shared palette, with a system picker for anything else.
///
/// The grid reads in two directions on purpose: **across** a row to tell two conditions
/// apart, **down** a column for the same hue lighter or darker. That is the whole reason
/// it is laid out by hand rather than as a `LazyVGrid` — the column *is* the meaning.
struct SwatchPicker: View {
    let hex: String
    /// What the other conditions of this factor are already using, so a duplicate shows
    /// up before it is picked rather than after. Distinctness is a property of the set,
    /// and this is the only place the set is visible.
    var used: [String] = []
    let onPick: (String) -> Void

    @State private var showing = false
    @State private var family: Palette.Family = .standard

    private let shadeCount = 5
    private let swatch: CGFloat = 22
    private let gap: CGFloat = 5

    private var gridWidth: CGFloat {
        swatch * 8 + gap * 7
    }

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
        .popover(isPresented: $showing, arrowEdge: .bottom) { palettePopover }
    }

    private var palettePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $family) {
                ForEach(Palette.Family.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(family.hues.enumerated()), id: \.offset) { _, hue in
                    VStack(spacing: gap) {
                        ForEach(
                            Array(Palette.shades(of: hue, count: shadeCount).enumerated()),
                            id: \.offset
                        ) { _, shade in
                            swatchButton(shade)
                        }
                    }
                }
            }
            .frame(width: gridWidth)

            Text(family.note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: gridWidth, alignment: .topLeading)
                // Two lines' worth of room whether or not this note needs it, so
                // switching family does not shuffle everything below it.
                .frame(minHeight: 26, alignment: .topLeading)

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
    }

    private func swatchButton(_ candidate: String) -> some View {
        let colour = NSColor(hex: candidate) ?? .gray
        let isCurrent = Palette.matches(candidate, hex)
        let isTaken = used.contains { Palette.matches($0, candidate) }
        return Button {
            onPick(candidate)
            showing = false
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: colour))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            isCurrent ? Color.accentColor : Color.black.opacity(0.15),
                            lineWidth: isCurrent ? 2 : 0.5
                        )
                )
                // Drawn in the swatch's own label colour so the dot is legible on a
                // pale tint and on a near-black shade alike.
                .overlay(alignment: .topTrailing) {
                    if isTaken {
                        Circle()
                            .fill(Color(nsColor: colour.contrastingLabelColor))
                            .frame(width: 5, height: 5)
                            .padding(2.5)
                    }
                }
                .frame(width: swatch, height: swatch)
        }
        .buttonStyle(.plain)
        .help(isTaken ? "\(candidate) — already used by another condition" : candidate)
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
