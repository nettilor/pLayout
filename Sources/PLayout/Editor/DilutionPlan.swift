import Foundation

// MARK: - Warnings

/// Something the bench needs to be told. A value rather than a string assembled in a
/// view, so the window, the printout and the workbook say the same words and tests can
/// assert on the case rather than on prose.
enum PrepWarning: Equatable {

    enum Severity: Int, Comparable {
        case note, caution, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    enum NotSerialReason: Equatable {
        case tooFewSteps(Int)
        case ratiosVary
    }

    case noWells(compound: String)
    case addedVolumeExceedsWell(added: Double, well: Double)
    case nonNumericDose(name: String)
    case unitAssumed(dose: String, stock: String)
    case unitsNotComparable(dose: String, stock: String)
    case noStock(compound: String)
    case stockTooWeak(compound: String, stock: String, needed: String)
    case stockUsedNeat(compound: String)
    case belowPipetteMinimum(tube: String, volume: Double, minimum: Double)
    case solventInWell(top: Double, bottom: Double)
    case notSerial(NotSerialReason)
    /// The sheet was scoped to one plate and that plate is no longer in the document.
    case scopedPlateMissing

    var severity: Severity {
        switch self {
        case .addedVolumeExceedsWell, .unitsNotComparable, .stockTooWeak:
            return .error
        case .noStock, .belowPipetteMinimum, .unitAssumed, .nonNumericDose,
             .scopedPlateMissing:
            return .caution
        case .noWells, .stockUsedNeat, .solventInWell, .notSerial:
            return .note
        }
    }

    var text: String {
        func number(_ value: Double) -> String {
            PlateEditor.formatValue(value, significantDigits: 3)
        }
        switch self {
        case .noWells(let compound):
            return "\(compound) has no wells on the plate, so there is nothing to make."
        case .addedVolumeExceedsWell(let added, let well):
            // The same guard refuses both ends: nothing added, and more added than fits.
            // One message cannot serve both — "you cannot add 0 µL to a well" reads as
            // nonsense rather than as the remedy.
            guard added > 0 else {
                return "Nothing is added to the wells. Set how much of each well comes "
                    + "from the tubes."
            }
            return "You cannot add \(number(added)) µL to a well that ends up holding "
                + "\(number(well)) µL. Set the added volume to the well volume or less."
        case .nonNumericDose(let name):
            return "“\(name)” is not a number, so it has no concentration and is left out."
        case .unitAssumed(let dose, let stock):
            let doseText = dose.isEmpty ? "no unit" : "“\(dose)”"
            let stockText = stock.isEmpty ? "no unit" : "“\(stock)”"
            return "Doses are in \(doseText) and the stock in \(stockText); they are taken "
                + "to be the same unit."
        case .unitsNotComparable(let dose, let stock):
            return "Doses are in “\(dose)” but the stock is in “\(stock)” — converting needs "
                + "a molecular weight this document does not have. Enter the stock in “\(dose)”."
        case .noStock(let compound):
            return "No stock concentration for \(compound), so the volume to take from it is "
                + "unknown. The volumes to make are still right."
        case .stockTooWeak(let compound, let stock, let needed):
            return "\(compound)'s stock is \(stock), weaker than the \(needed) the first tube "
                + "needs. Use a stronger stock, or add more per well."
        case .stockUsedNeat(let compound):
            return "\(compound)'s stock is exactly the first tube's concentration — use it "
                + "as it is, undiluted."
        case .belowPipetteMinimum(let tube, let volume, let minimum):
            return "\(tube) needs \(number(volume)) µL, under the \(number(minimum)) µL you "
                + "said you can pipette accurately. Make an intermediate dilution first."
        case .solventInWell(let top, let bottom):
            return top == bottom
                ? "Solvent in the well: \(number(top)) %."
                : "Solvent in the well: \(number(top)) % at the top dose down to "
                    + "\(number(bottom)) % at the bottom. Match the vehicle to the top."
        case .notSerial(let reason):
            switch reason {
            case .tooFewSteps(let count):
                return count < 2
                    ? "One dose, so there is nothing to serially dilute — it is made from stock."
                    : "Two doses prove no ratio, so each is made straight from the stock."
            case .ratiosVary:
                return "The doses are not a constant fold series, so each tube is made "
                    + "straight from the stock rather than from the one above it."
            }
        case .scopedPlateMissing:
            return "This sheet was set to one plate, and that plate is no longer in the "
                + "document — the volumes below cover every plate instead."
        }
    }
}

// MARK: - The plan

/// What to put in which tube, worked out from the plate.
///
/// Pure: it takes a `Layout` and gives back numbers. No AppKit, no pasteboard, no file
/// format — `Editor/` for the same reason `WellGrouping` is, since the window, the
/// printout and the exporter all consume it and none of them should own it.
struct DilutionPlan: Equatable {

    /// How the tubes are built. Chosen from the numbers rather than by the user: a
    /// constant fold ratio is what makes serial dilution possible at all.
    enum Method: Equatable {
        case serial(fold: Double)
        case individual

        var label: String {
            switch self {
            case .serial(let fold):
                return "Serial, \(PlateEditor.formatValue(fold, significantDigits: 3))-fold"
            case .individual:
                return "Each tube from the stock"
            }
        }
    }

    /// Where a tube's concentrated half comes from.
    enum Source: Equatable {
        case stock
        case tube(index: Int)
        /// The vehicle, carrying the same solvent as the top dose.
        case neatSolvent
        /// The vehicle, with no stock to match against.
        case diluentOnly
    }

    struct Step: Equatable {
        /// The level name exactly as painted, so the sheet and the plate agree.
        var doseName: String
        var dose: Double
        /// The concentration in the tube: `dose × wellVolume / addedVolume`.
        var working: Double
        var wells: Int
        /// µL to make — the number read first.
        var total: Double
        /// µL of this tube that reaches the plate.
        var toWells: Double
        /// µL of this tube drawn off to make the next one; 0 for the last.
        var toNextTube: Double
        var source: Source
        /// nil when the stock is missing or too weak to say.
        var sourceVolume: Double?
        /// Defined as the remainder, never rounded again, so every printed row adds up.
        var diluent: Double?
        var isVehicle: Bool
        var solventInWellPercent: Double?
        var warnings: [PrepWarning] = []

        var label: String { isVehicle ? "Vehicle" : doseName }
    }

    /// One drug's series — one factor's worth.
    struct Compound: Equatable {
        /// The factor's name, which is the drug's name.
        var name: String
        /// The colour of its most concentrated level. A numeric factor's levels are a
        /// single-hue ramp, so the top of that ramp stands for the drug.
        var colorHex: String?
        var stock: StockConcentration?
        /// The stock in this drug's own unit, once converted.
        var stockInDoseUnits: Double?
        /// This drug's unit, carried per drug rather than per plan — one sheet can hold a
        /// series in µM beside one in ng/mL.
        var unit: String
        var method: Method
        /// Most concentrated first; the vehicle, if any, last.
        var steps: [Step]
        var warnings: [PrepWarning] = []

        var displayName: String { name.isEmpty ? "Working solutions" : name }
        var totalDiluent: Double { steps.compactMap(\.diluent).reduce(0, +) }
    }

    var compounds: [Compound]
    var setup: PrepSetup
    /// "Plate 1" or "all 3 plates" — printed in the header so a scoped plan cannot be
    /// misread inside a workbook that covers something else.
    var scopeText: String
    var warnings: [PrepWarning] = []

    var isEmpty: Bool { compounds.allSatisfy { $0.steps.isEmpty } }
    var totalDiluent: Double { compounds.reduce(0) { $0 + $1.totalDiluent } }

    /// Every warning in the plan, worst first, deduplicated.
    var allWarnings: [PrepWarning] {
        var seen: [PrepWarning] = []
        for warning in warnings + compounds.flatMap({ $0.warnings + $0.steps.flatMap(\.warnings) })
        where !seen.contains(warning) {
            seen.append(warning)
        }
        return seen.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Building

extension DilutionPlan {

    /// The whole plan for a document, or nil when the document has no prep setup.
    static func make(from layout: Layout) -> DilutionPlan? {
        // Marking a factor is the opt-in; the bench numbers are defaults until touched.
        // Guarding on `layout.prep` here quietly required the prep window to have been
        // opened once — a document with a marked drug and untouched settings exported a
        // workbook with no Prep tab, against the gate's own stated intent.
        make(from: layout, setup: layout.prep ?? PrepSetup())
    }

    /// The plan for a setup that may not have been committed to the document yet — which
    /// is what lets the prep window show a table the moment it opens, without an undo
    /// step for having opened a window.
    static func make(from layout: Layout, setup: PrepSetup) -> DilutionPlan? {
        // One series per factor that says it is made by dilution, in sidebar order so the
        // sheet reads like the plate. Nothing to choose and nothing to cross-tab: a
        // factor *is* a drug, and its levels are the concentrations it is used at.
        let drugs = layout.factors.filter { $0.dilution != nil }
        guard !drugs.isEmpty else { return nil }

        let scoped = setup.plateID.flatMap { id in
            layout.plates.first { $0.id == id }.map { [$0] }
        }
        let plates = scoped ?? layout.plates

        var plan = DilutionPlan(
            compounds: [], setup: setup, scopeText: scopeText(layout: layout, setup: setup)
        )

        // Deleting the plate a sheet was scoped to silently widened it to every plate,
        // and every tube volume changed with it. The scope is still stored — undoing the
        // deletion brings it back — but a sheet printed in between must say so rather
        // than quietly describing a different experiment.
        if setup.plateID != nil, scoped == nil {
            plan.warnings.append(.scopedPlateMissing)
        }

        // An input error, not something to work around: refuse rather than print tubes
        // that cannot be made.
        guard setup.addedVolume > 0, setup.wellVolume > 0,
              setup.addedVolume <= setup.wellVolume
        else {
            plan.warnings.append(
                .addedVolumeExceedsWell(added: setup.addedVolume, well: setup.wellVolume)
            )
            return plan
        }

        for drug in drugs {
            plan.compounds.append(
                compound(
                    drug: drug, counts: wellCounts(plates: plates, factor: drug), setup: setup
                )
            )
        }
        return plan
    }

    /// Wells per level of one factor, walked once. `Plate.assignedWellCount` answers this
    /// for a single level; a factor with eight of them would walk the plate eight times.
    private static func wellCounts(plates: [Plate], factor: Factor) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for plate in plates {
            for well in 0..<plate.format.wellCount {
                guard let level = plate.levelID(factor: factor.id, well: well) else { continue }
                counts[level, default: 0] += 1
            }
        }
        return counts
    }

    private static func scopeText(layout: Layout, setup: PrepSetup) -> String {
        if let id = setup.plateID, let plate = layout.plates.first(where: { $0.id == id }) {
            return plate.name
        }
        if layout.plates.count == 1 { return layout.plates[0].name }
        return "all \(layout.plates.count) plates"
    }
}

// MARK: - One compound's tubes

extension DilutionPlan {

    private static func compound(
        drug: Factor, counts: [UUID: Int], setup: PrepSetup
    ) -> Compound {
        let name = drug.name
        var warnings: [PrepWarning] = []
        let ownStock = drug.dilution?.stock

        // A level whose name is not a number cannot be a concentration. The toggle can be
        // put on any factor, so say which ones could not be read rather than leaving an
        // empty series to explain itself.
        for level in drug.levels where Double(level.name) == nil {
            warnings.append(.nonNumericDose(name: level.name))
        }

        // The stock, in this drug's own unit — each drug converts against its own, which
        // is what lets one be in µM while another is in ng/mL.
        var stockInDoseUnits: Double?
        if let stock = ownStock, stock.isUsable {
            let doseUnit = ConcentrationUnit.parse(drug.unit)
            switch ConcentrationUnit.parse(stock.unit).conversion(to: doseUnit) {
            case .exact(let factor):
                stockInDoseUnits = stock.value * factor
            case .assumed(let factor):
                stockInDoseUnits = stock.value * factor
                warnings.append(.unitAssumed(dose: drug.unit, stock: stock.unit))
            case .incompatible:
                warnings.append(.unitsNotComparable(dose: drug.unit, stock: stock.unit))
            }
        }

        // Concentrations actually painted, highest first; the vehicle apart.
        var actives: [(level: Level, dose: Double, wells: Int)] = []
        var vehicleWells = 0
        for level in drug.levels {
            guard let wells = counts[level.id], wells > 0, let dose = Double(level.name) else { continue }
            if dose == 0 {
                vehicleWells += wells
            } else {
                actives.append((level, dose, wells))
            }
        }
        actives.sort { $0.dose > $1.dose }

        // A ticked drug with nothing painted has no tubes to show, and its block is
        // hidden — so without this it simply vanishes from the sheet, and the only
        // explanation lives in the sidebar's well counts. The warning is the mechanism
        // that keeps an empty series honest.
        if actives.isEmpty, vehicleWells == 0 {
            warnings.append(.noWells(compound: name))
        }

        let method = self.method(for: actives.map(\.dose), warnings: &warnings)
        var steps = tubes(
            actives: actives, method: method, setup: setup,
            stockInDoseUnits: stockInDoseUnits, compound: name,
            warnings: &warnings
        )

        // The vehicle carries the same solvent as the top dose, so the control differs
        // from the treated wells in one thing only.
        if vehicleWells > 0 {
            let base = Double(vehicleWells) * setup.addedVolume
            let total = pipetteCeiled(base + setup.overage.extra(onWellsVolume: base))
            let topFraction = steps.first.flatMap { step -> Double? in
                guard let source = step.sourceVolume, step.total > 0, source > 0 else { return nil }
                return source / step.total
            }
            let solvent = topFraction.map { pipetteRounded(total * $0) }
            steps.append(
                Step(
                    doseName: "0", dose: 0, working: 0, wells: vehicleWells, total: total,
                    toWells: total, toNextTube: 0,
                    source: solvent == nil ? .diluentOnly : .neatSolvent,
                    sourceVolume: solvent, diluent: total - (solvent ?? 0), isVehicle: true,
                    solventInWellPercent: steps.first?.solventInWellPercent
                )
            )
        }

        if !actives.isEmpty, stockInDoseUnits == nil, ownStock?.isUsable != true,
           !warnings.contains(where: { if case .unitsNotComparable = $0 { return true } else { return false } }) {
            warnings.append(.noStock(compound: name.isEmpty ? "this series" : name))
        }
        if let top = steps.first(where: { !$0.isVehicle })?.solventInWellPercent,
           let bottom = steps.last(where: { !$0.isVehicle })?.solventInWellPercent {
            warnings.append(.solventInWell(top: top, bottom: bottom))
        }

        return Compound(
            name: name, colorHex: drug.levels.first?.colorHex, stock: ownStock,
            stockInDoseUnits: stockInDoseUnits, unit: drug.unit, method: method,
            steps: steps, warnings: warnings
        )
    }

    /// Serial when the doses are a constant fold series, individual otherwise — and it
    /// always says which, because "automatic" must not mean "silent".
    private static func method(for doses: [Double], warnings: inout [PrepWarning]) -> Method {
        guard doses.count >= minimumSerialSteps else {
            if !doses.isEmpty { warnings.append(.notSerial(.tooFewSteps(doses.count))) }
            return .individual
        }
        guard let fold = foldRatio(of: doses) else {
            warnings.append(.notSerial(.ratiosVary))
            return .individual
        }
        return .serial(fold: fold)
    }

    private static func tubes(
        actives: [(level: Level, dose: Double, wells: Int)], method: Method, setup: PrepSetup,
        stockInDoseUnits: Double?, compound: String, warnings: inout [PrepWarning]
    ) -> [Step] {
        guard !actives.isEmpty else { return [] }
        let fold = setup.foldOverWell
        let working = actives.map { $0.dose * fold }
        let needs = actives.map { entry -> Double in
            let base = Double(entry.wells) * setup.addedVolume
            return base + setup.overage.extra(onWellsVolume: base)
        }
        let n = actives.count

        var totals = [Double](repeating: 0, count: n)
        var transfers = [Double](repeating: 0, count: n)   // what tube k draws from tube k-1

        switch method {
        case .serial(let ratio):
            // Walked from the most dilute upward, because tube k has to hold its own
            // dispense *and* the transfer that makes tube k+1. Rounding happens inside
            // the recurrence, not after it, so the printed numbers are the ones used:
            // totals are ceiled (making slightly too much is harmless) while transfers
            // are rounded to nearest (which keeps the concentration honest), and the
            // ceiled total is where the slack for that comes from.
            //
            // When every tube needs the same volume — the normal plate, one replicate
            // count per dose — the tubes are made **clones**: the same take and the same
            // diluent at every step, the way every protocol book writes a serial
            // dilution and the way hands actually pipette one. That is the steady state
            // of the recurrence (V = need + V/ratio); without the floor, the last
            // tube's smallness rippled up the chain and the sheet asked for 59.3, then
            // 58, then 53.3 µL of what should have been "take 60, seven times" — a
            // different pipette setting per step, to save a few µL of diluent. Only the
            // last tube, which feeds nothing, is smaller. When needs genuinely differ,
            // the floor is absent and each tube is sized for its own wells as before.
            let uniformNeed: Double? = Set(needs).count == 1 && n >= 2 && ratio > 1
                ? needs[0] : nil
            let steadyFloor = uniformNeed.map { pipetteCeiled($0 * ratio / (ratio - 1)) }
            totals[n - 1] = pipetteCeiled(needs[n - 1])
            for k in stride(from: n - 2, through: 0, by: -1) {
                transfers[k + 1] = pipetteRounded(totals[k + 1] / ratio)
                // `max`, never a replacement: the floor may only add headroom, so the
                // guarantee that a tube holds its wells plus the transfer out survives
                // by construction.
                totals[k] = max(
                    pipetteCeiled(needs[k] + transfers[k + 1]), steadyFloor ?? 0
                )
            }
        case .individual:
            for k in 0..<n { totals[k] = pipetteCeiled(needs[k]) }
        }

        var steps: [Step] = []
        for k in 0..<n {
            let fromStock = k == 0 || method == .individual
            var source: Double?
            if fromStock {
                if let stock = stockInDoseUnits, stock > 0 {
                    if stock < working[k] {
                        warnings.append(
                            .stockTooWeak(
                                compound: compound,
                                stock: PlateEditor.formatValue(stock, significantDigits: 3),
                                needed: PlateEditor.formatValue(working[k], significantDigits: 3)
                            )
                        )
                    } else {
                        if stock == working[k] { warnings.append(.stockUsedNeat(compound: compound)) }
                        source = pipetteRounded(totals[k] * working[k] / stock)
                    }
                }
            } else {
                source = transfers[k]
            }

            let toNext = k + 1 < n ? transfers[k + 1] : 0
            var step = Step(
                doseName: actives[k].level.name, dose: actives[k].dose, working: working[k],
                wells: actives[k].wells, total: totals[k], toWells: totals[k] - toNext,
                toNextTube: toNext,
                source: fromStock ? .stock : .tube(index: k - 1),
                sourceVolume: source, diluent: source.map { totals[k] - $0 }, isVehicle: false,
                solventInWellPercent: stockInDoseUnits.map { actives[k].dose / $0 * 100 }
            )
            if let source, source < setup.minimumPipetteVolume {
                step.warnings.append(
                    .belowPipetteMinimum(
                        tube: "\(compound) \(actives[k].level.name)", volume: source,
                        minimum: setup.minimumPipetteVolume
                    )
                )
            }
            steps.append(step)
        }
        return steps
    }
}

// MARK: - The arithmetic, exposed for testing

extension DilutionPlan {

    /// Within this much of a perfect geometric series still counts as a fold series.
    ///
    /// Tight on purpose. Concentrations survive only as level names rounded to three
    /// significant digits, so ~0.5 % of error is baked in and 2 % clears it comfortably
    /// while rejecting anything genuinely non-geometric by a wide margin. The asymmetry
    /// is what makes tight safe: the fallback is never *wrong*, only more pipetting,
    /// where a false positive prints a recipe that makes the wrong concentrations.
    static let foldTolerance = 0.02

    /// Two doses fit a geometric series exactly by construction, so a ratio drawn from
    /// them proves nothing.
    static let minimumSerialSteps = 3

    /// The constant ratio a set of doses is built on, or nil when they are not geometric.
    ///
    /// Fitted across the whole series rather than compared pairwise: a pairwise ratio
    /// compounds the rounding of two names and drifts along the series.
    static func foldRatio(of doses: [Double]) -> Double? {
        let sorted = doses.filter { $0 > 0 }.sorted(by: >)
        guard sorted.count >= minimumSerialSteps else { return nil }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0 > $1 }) else { return nil }

        let ratio = exp(
            (log(sorted[0]) - log(sorted[sorted.count - 1])) / Double(sorted.count - 1)
        )
        guard ratio.isFinite, ratio > 1 else { return nil }
        for (k, value) in sorted.enumerated() {
            let predicted = sorted[0] / pow(ratio, Double(k))
            guard predicted > 0, abs(value - predicted) / predicted <= foldTolerance else {
                return nil
            }
        }
        return ratio
    }

    /// What a pipette can actually be set to: 0.1 µL under 100 µL, 1 µL at or above it.
    static func pipetteGranularity(_ volume: Double) -> Double { volume < 100 ? 0.1 : 1 }

    static func pipetteRounded(_ volume: Double) -> Double {
        let step = pipetteGranularity(volume)
        return ((volume / step).rounded() * step).rounded(toPlaces: 4)
    }

    static func pipetteCeiled(_ volume: Double) -> Double {
        let step = pipetteGranularity(volume)
        return ((volume / step).rounded(.up) * step).rounded(toPlaces: 4)
    }
}

private extension Double {
    /// Kills the floating-point dust that 0.1-sized steps leave behind, so a volume
    /// compares and prints as the number it is meant to be.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
