import AppKit
import SwiftUI

/// What goes in the prep window: the bench parameters at the top, the stocks under them,
/// and the table they produce below — recomputed on every change, the way Series Fill's
/// preview strip is.
struct PrepView: View {
    @ObservedObject var editor: PlateEditor

    private var setup: PrepSetup { editor.effectivePrepSetup }
    private var plan: DilutionPlan? { editor.prepPlan }

    /// No SwiftUI `ScrollView` anywhere in here. Inside this window's hosting controller
    /// a `ScrollView` took up its layout space and rendered nothing at all — not the
    /// controls, not even the AppKit table inside it — which is the same shape of failure
    /// HANDOFF §1 records for `ImageRenderer`. The controls are laid out plainly, and the
    /// one thing that genuinely needs to scroll does it in an `NSScrollView`.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settings
            stocks
            Divider()
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 660, minHeight: 420, idealHeight: 760)
        .background(undoShortcuts)
    }

    /// ⌘Z and ⇧⌘Z, for this window only.
    ///
    /// The Edit menu's Undo binds to the focused SwiftUI *scene*, and this is a plain
    /// `NSWindow` — so every prep edit was undoable and ⌘Z here did nothing at all until
    /// you clicked back to the plate window. Scoped to this view rather than by replacing
    /// the menu's own group, which would take ⌘Z away from every text field in the app.
    /// Zero-sized: the menu item stays the discoverable route, this only makes the key
    /// work where the edit was made.
    private var undoShortcuts: some View {
        ZStack {
            Button("Undo") { editor.undoManager?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(editor.undoManager?.canUndo != true)
            Button("Redo") { editor.undoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(editor.undoManager?.canRedo != true)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Settings

    /// Laid out directly rather than with `Form`, for the reason `PreferencesView`
    /// already records: a grouped `Form` inside a hosting view gives its controls the
    /// trailing column and, here, drew nothing at all. `GroupBox` gives the same look
    /// with none of that.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("What is being made") {
                labelled("Doses") {
                    Picker("", selection: doseFactorSelection) {
                        Text("None").tag(UUID?.none)
                        ForEach(editor.layout.factors) { factor in
                            Text(factor.displayName).tag(UUID?.some(factor.id))
                        }
                    }
                    .labelsHidden()
                }
                labelled("Compounds") {
                    Picker("", selection: field(\.compoundFactorID, "Prep Compound Factor")) {
                        Text("None — one series").tag(UUID?.none)
                        ForEach(editor.layout.factors.filter { $0.id != setup.doseFactorID }) { factor in
                            Text(factor.name).tag(UUID?.some(factor.id))
                        }
                    }
                    .labelsHidden()
                }
                if editor.layout.plates.count > 1 {
                    labelled("Plates") {
                        Picker("", selection: plateScopeSelection) {
                            Text("All plates").tag(UUID?.none)
                            ForEach(editor.layout.plates) { plate in
                                Text(plate.name).tag(UUID?.some(plate.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            section("Volumes") {
                labelled("In each well") {
                    HStack(spacing: 6) {
                        volumeField(field(\.wellVolume, "Well Volume"))
                        Text("µL, of which").foregroundStyle(.secondary)
                        volumeField(field(\.addedVolume, "Added Volume"))
                        Text("µL is added").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                Text(foldNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                labelled("Make extra") {
                    HStack(spacing: 6) {
                        Picker("", selection: field(\.overage.mode, "Overage")) {
                            ForEach(Overage.Mode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if setup.overage.mode != .fixed {
                            volumeField(field(\.overage.percent, "Overage"))
                            Text("%").foregroundStyle(.secondary)
                        }
                        if setup.overage.mode == .percentWithMinimum {
                            volumeField(field(\.overage.minimumExtra, "Overage"))
                            Text("µL").foregroundStyle(.secondary)
                        }
                        if setup.overage.mode == .fixed {
                            volumeField(field(\.overage.fixedExtra, "Overage"))
                            Text("µL").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                labelled("Pipette at least") {
                    HStack(spacing: 6) {
                        volumeField(field(\.minimumPipetteVolume, "Pipette Minimum"))
                        Text("µL").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                labelled("Diluent") {
                    CommitTextField(
                        placeholder: "medium", text: setup.diluent, font: .body, allowsEmpty: true
                    ) { value in
                        editor.updatePrep("Diluent") { $0.diluent = value.isEmpty ? "medium" : value }
                    }
                    .frame(width: 160)
                }
                Toggle("Include in the Excel workbook", isOn: field(\.includeInWorkbook, "Prep in Workbook"))
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        }
    }

    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            content()
        }
    }

    private var foldNote: String {
        let setup = self.setup
        guard setup.addedVolume > 0, setup.wellVolume > 0 else { return "" }
        guard setup.addedVolume <= setup.wellVolume else {
            return "More is added than the well ends up holding — nothing can be made from that."
        }
        let fold = PlateEditor.formatValue(setup.foldOverWell, significantDigits: 3)
        return setup.foldOverWell == 1
            ? "The tubes are at the final concentration: the well takes all of its volume from them."
            : "The tubes are \(fold)× working solutions."
    }

    private func volumeField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 62)
            .multilineTextAlignment(.trailing)
    }

    // MARK: - Stocks

    @ViewBuilder
    private var stocks: some View {
        let compounds = editor.layout.factor(id: setup.compoundFactorID)
        VStack(alignment: .leading, spacing: 6) {
            Text(compounds.map { "Stocks — \($0.name)" } ?? "Stock")
                .font(.headline)
            if let compounds {
                if compounds.levels.isEmpty {
                    Text("That factor has no conditions yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(compounds.levels) { level in
                    StockRow(
                        name: level.name, colorHex: level.colorHex, stock: level.stock,
                        defaultUnit: defaultStockUnit,
                        set: { editor.setStock($0, for: level.id, in: compounds.id) }
                    )
                }
            } else {
                StockRow(
                    name: "All wells", colorHex: nil, stock: setup.stock,
                    defaultUnit: defaultStockUnit,
                    // Filtered exactly as `setStock` filters a compound's: a unit typed
                    // before a number is not a stock, and storing `0 mM` put "stock 0 mM"
                    // in the workbook where the window and the printout both say "no
                    // stock set".
                    set: { stock in
                        editor.updatePrep("Stock Concentration") {
                            $0.stock = stock?.isUsable == true ? stock : nil
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// One condition's stock.
    ///
    /// A `View` rather than a function so the unit has somewhere of its own to live.
    /// Clearing the number clears the whole `StockConcentration` in the model — "not
    /// set" is one state, not a value and a unit that can be half-present — so with
    /// nowhere else to keep it the unit went with the number, and the next figure typed
    /// silently fell back to the dose factor's unit. Correcting a 10 mM stock to 5 the
    /// ordinary way (select, delete, type 5) stored **5 µM**: a thousandfold error on a
    /// printed sheet, with nothing anywhere to warn you. It also means a unit typed
    /// before a number survives, where before it was dropped on the floor.
    private struct StockRow: View {
        let name: String
        let colorHex: String?
        let stock: StockConcentration?
        let defaultUnit: String
        let set: (StockConcentration?) -> Void

        @State private var unit: String = ""

        private var effectiveUnit: String { unit.isEmpty ? defaultUnit : unit }

        var body: some View {
            HStack(spacing: 8) {
                if let colorHex {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: NSColor(hex: colorHex) ?? .gray))
                        .frame(width: 11, height: 11)
                }
                Text(name)
                    .frame(width: 130, alignment: .leading)
                    .lineLimit(1)
                // An optional binding, so a compound with no stock shows an empty field
                // rather than a zero — "not set" and "zero" are different things here,
                // and the vehicle condition is legitimately the former.
                TextField(
                    "—",
                    value: Binding<Double?>(
                        get: { stock?.isUsable == true ? stock?.value : nil },
                        set: { value in
                            guard let value else { return set(nil) }
                            set(StockConcentration(value: value, unit: effectiveUnit))
                        }
                    ),
                    format: .number
                )
                .frame(width: 70)
                CommitTextField(
                    placeholder: defaultUnit.isEmpty ? "mM" : defaultUnit,
                    text: unit, font: .body, allowsEmpty: true
                ) { typed in
                    unit = typed
                    set(StockConcentration(value: stock?.value ?? 0, unit: typed))
                }
                .frame(width: 80)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .onAppear { unit = stock?.unit ?? "" }
            // The model still wins when it changes underneath — an undo, or a stock
            // arriving with a pasted compound. A stock cleared to nil deliberately does
            // *not* clear the unit: that is the whole point of keeping it here.
            .onChange(of: stock?.unit) { _, new in
                if let new, new != unit { unit = new }
            }
        }
    }

    /// The dose factor's own unit is the likeliest answer, and it makes the common case
    /// — a stock quoted in the same unit as the doses — a single number to type.
    private var defaultStockUnit: String {
        editor.layout.factor(id: setup.doseFactorID)?.unit ?? ""
    }

    // MARK: - Table

    @ViewBuilder
    private var table: some View {
        if let plan, !plan.isEmpty || !plan.allWarnings.isEmpty {
            PrepTable(plan: plan)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing to make yet")
                    .font(.headline)
                Text(
                    plan == nil
                        ? "Pick the factor that carries the doses."
                        : "No wells on the plate carry a dose, so there is nothing to pipette."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let plan, let worst = plan.allWarnings.first, worst.severity != .note {
                Circle()
                    .fill(worst.severity == .error ? Color.red : Color.orange)
                    .frame(width: 7, height: 7)
                Text(worst.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            // Carries ⌘P itself, which is what makes the shortcut reliable while this
            // window is key whatever the menu bar decides to do.
            Button("Print…") {
                guard let plan = editor.prepPlan else { return }
                PrepTableView.print(plan: plan, jobName: "\(editor.suggestedBaseName) — prep")
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(plan?.isEmpty ?? true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Binding

    /// Every field writes through `updatePrep`, so each change is one ordinary undo step
    /// and the setup is created in the document the first time something is actually set.
    /// Choosing the factor that is currently the *compound* factor clears that in the
    /// same edit. Without it `compoundFactorID` kept pointing at a factor the Compounds
    /// picker filters out, so the control rendered blank and could not be cleared — and
    /// the plan cross-tabbed the factor against itself, giving every condition its own
    /// one-tube "compound".
    private var doseFactorSelection: Binding<UUID?> {
        Binding(
            get: { editor.effectivePrepSetup.doseFactorID },
            set: { value in
                editor.updatePrep("Prep Dose Factor") {
                    $0.doseFactorID = value
                    if let value, $0.compoundFactorID == value { $0.compoundFactorID = nil }
                }
            }
        )
    }

    /// A scope pointing at a plate that has been deleted matches no tag, so the picker
    /// renders blank and cannot be changed. It reads as "All plates" — which is what the
    /// sheet is actually showing — while leaving the stored id alone, so undoing the
    /// deletion still brings the scope back.
    private var plateScopeSelection: Binding<UUID?> {
        Binding(
            get: {
                let id = editor.effectivePrepSetup.plateID
                return editor.layout.plates.contains { $0.id == id } ? id : nil
            },
            set: { value in editor.updatePrep("Prep Plate Scope") { $0.plateID = value } }
        )
    }

    private func field<T>(
        _ keyPath: WritableKeyPath<PrepSetup, T>, _ actionName: String
    ) -> Binding<T> {
        Binding(
            get: { editor.effectivePrepSetup[keyPath: keyPath] },
            set: { value in editor.updatePrep(actionName) { $0[keyPath: keyPath] = value } }
        )
    }
}

/// The table in an `NSScrollView`, which is the only scrolling in this window — see the
/// note on `body`. The table sizes itself to the clip view's width, so the columns always
/// span the window rather than running off the right of it.
private struct PrepTable: NSViewRepresentable {
    let plan: DilutionPlan

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = PrepTableView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        table.autoresizingMask = [.width]
        table.plan = plan
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? PrepTableView else { return }
        table.plan = plan
        table.fitWidth(to: scroll.contentSize.width)
    }
}
