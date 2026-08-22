import XCTest
@testable import PLayout

/// The bench arithmetic. Every number here was worked out independently of the code —
/// this is the suite that has to fail if the recurrence, the rounding or the ordering
/// is ever "simplified".
final class DilutionPlanTests: XCTestCase {

    // MARK: - Fixture

    /// A 384-well plate carrying `compounds` drugs, each a factor of its own with a
    /// 3-fold series as its levels, `wells` wells at each concentration plus
    /// `vehicleWells` at zero. Doses are the rounded names Series Fill writes.
    ///
    /// One factor per drug is the whole model: a factor *is* the drug, its levels are the
    /// concentrations, `Factor.unit` is what they are in, and the stock hangs off the
    /// factor. Nothing pairs two factors any more.
    private func layout(
        doses: [String] = ["10", "3.33", "1.11", "0.37"],
        wells: Int = 24,
        vehicleWells: Int = 24,
        stock: StockConcentration? = StockConcentration(value: 10, unit: "mM"),
        doseUnit: String = "µM",
        compounds: [String] = ["Cpd1"],
        setup: (inout PrepSetup) -> Void = { _ in }
    ) -> Layout {
        var layout = Layout(plates: [Plate(name: "Plate 1", format: .well384)])

        var well = 0
        for (drugIndex, drugName) in compounds.enumerated() {
            var drug = Factor(
                name: drugName, kind: .numeric, unit: doseUnit, dilution: Dilution(stock: stock)
            )
            for (index, name) in (doses + (vehicleWells > 0 ? ["0"] : [])).enumerated() {
                drug.levels.append(Level(name: name, colorHex: Palette.color(at: index)))
            }
            layout.factors.append(drug)

            // Painted in a straight run across the plate; only the counts matter here.
            for level in drug.levels {
                let count = Double(level.name) == 0 ? vehicleWells : wells
                for _ in 0..<count {
                    layout.plates[0].setLevelID(level.id, factor: drug.id, well: well)
                    well += 1
                }
            }
            _ = drugIndex
        }

        var prep = PrepSetup()
        prep.wellVolume = 100
        prep.addedVolume = 10
        prep.overage = Overage(mode: .percent, percent: 20)
        prep.minimumPipetteVolume = 2
        setup(&prep)
        layout.prep = prep
        return layout
    }

    private func plan(_ layout: Layout) throws -> DilutionPlan.Compound {
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        return try XCTUnwrap(plan.compounds.first)
    }

    // MARK: - The worked example

    /// 10 mM stock · 100 µL well · 10 µL added (10×) · 3-fold from 10 µM · 24 wells each
    /// · +20 %. Asserted cell for cell.
    ///
    /// Every dose covers the same wells, so the tubes are **clones**: take 144, add 288,
    /// make 432, at every step — the way a protocol book writes a serial dilution and
    /// the way hands pipette one. 432 is the steady state of "its own need plus a third
    /// of itself" (288 × r/(r−1)); only the last tube, which feeds nothing, is smaller,
    /// and the tube above it simply keeps the difference as surplus rather than making
    /// every take a different number. The tapered chain this replaced asked for a
    /// different pipette setting per step to save a few µL of diluent.
    func testTheWorkedExampleIsExact() throws {
        let compound = try plan(layout())
        assertSerial(compound.method, fold: 3)
        XCTAssertEqual(compound.steps.count, 5, "four doses and the vehicle")

        let expected: [(name: String, working: Double, total: Double, source: Double,
                        diluent: Double, next: Double, toWells: Double)] = [
            ("10",   100,  432, 4.3,   427.7, 144, 288),
            ("3.33", 33.3, 432, 144,   288,   144, 288),
            ("1.11", 11.1, 432, 144,   288,    96, 336),
            ("0.37",  3.7, 288,  96,   192,     0, 288),
        ]
        for (index, want) in expected.enumerated() {
            let step = compound.steps[index]
            XCTAssertEqual(step.doseName, want.name)
            XCTAssertEqual(step.working, want.working, accuracy: 0.001, want.name)
            XCTAssertEqual(step.total, want.total, accuracy: 0.001, "total of \(want.name)")
            XCTAssertEqual(step.sourceVolume ?? -1, want.source, accuracy: 0.001, "take for \(want.name)")
            XCTAssertEqual(step.diluent ?? -1, want.diluent, accuracy: 0.001, "diluent for \(want.name)")
            XCTAssertEqual(step.toNextTube, want.next, accuracy: 0.001, "transfer out of \(want.name)")
            XCTAssertEqual(step.toWells, want.toWells, accuracy: 0.001, "to wells for \(want.name)")
        }

        let vehicle = try XCTUnwrap(compound.steps.last)
        XCTAssertTrue(vehicle.isVehicle)
        XCTAssertEqual(vehicle.total, 288, accuracy: 0.001)
        XCTAssertEqual(vehicle.sourceVolume ?? -1, 2.9, accuracy: 0.001, "solvent matching the top dose")
        XCTAssertEqual(vehicle.diluent ?? -1, 285.1, accuracy: 0.001)
    }

    /// The complaint that forced the clone rule, pinned: an 8-step series over one well
    /// per dose used to ask for 60, 60, 60, 59.3, 58, 53.3, 40 — a different pipette
    /// setting per step, to save a few µL of diluent. Every dose covers the same wells,
    /// so every step is "take X, add Y" and only the last tube is smaller.
    func testAUniformSeriesIsPipettedTheSameWayAtEveryStep() throws {
        let compound = try plan(layout(
            doses: ["10", "3.33", "1.11", "0.37", "0.123", "0.0412", "0.0137", "0.00457"],
            wells: 1, vehicleWells: 0
        ))
        let chain = compound.steps.filter { !$0.isVehicle }.dropFirst()   // from tube 2 on
        let takes = Set(chain.dropLast().map(\.sourceVolume))
        let diluents = Set(chain.dropLast().map(\.diluent))
        XCTAssertEqual(takes.count, 1, "every middle step is the same take: \(takes)")
        XCTAssertEqual(diluents.count, 1, "and the same diluent: \(diluents)")
        XCTAssertLessThan(
            chain.last!.total, chain.first!.total,
            "only the last tube, which feeds nothing, is smaller"
        )
    }

    /// The clone rule applies only when it is free. Doses covering different well counts
    /// genuinely need different tubes, and forcing them uniform would size every tube
    /// for the biggest — real waste, not a rounding of it.
    func testUnequalWellCountsStillSizeEachTubeForItsOwnWells() throws {
        var layout = self.layout(vehicleWells: 0)
        // Move the bottom dose to four times the wells of the others.
        let drug = layout.factors[0]
        let bottom = try XCTUnwrap(drug.levels.first { $0.name == "0.37" })
        for well in 300..<372 {
            layout.plates[0].setLevelID(bottom.id, factor: drug.id, well: well)
        }
        let compound = try plan(layout)
        let totals = Set(compound.steps.map(\.total))
        XCTAssertGreaterThan(totals.count, 2, "the tubes must differ when their needs do")
    }

    /// 10 µM out of a 10 mM stock is 0.1 % solvent in the well — the number a cell
    /// biologist already knows, and the cheapest check that the whole chain is right.
    func testSolventInTheWellIsTheDoseOverTheStock() throws {
        let compound = try plan(layout())
        XCTAssertEqual(compound.steps[0].solventInWellPercent ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(compound.steps[3].solventInWellPercent ?? -1, 0.0037, accuracy: 1e-9)

        // The identity has no volumes in it, so changing them must not move it.
        let other = try plan(layout { $0.wellVolume = 200; $0.addedVolume = 50 })
        XCTAssertEqual(other.steps[0].solventInWellPercent ?? -1, 0.1, accuracy: 1e-9)
    }

    // MARK: - The accumulation

    /// Tube 1 makes 432 µL, not the 288 µL its own wells need, because 144 µL of it goes
    /// into tube 2. Raising only the *last* tube's wells has to move the *first* tube.
    func testEachTubeHoldsItsWellsPlusTheTransferOut() throws {
        let compound = try plan(layout())
        for (index, step) in compound.steps.enumerated() where !step.isVehicle {
            XCTAssertEqual(step.total, step.toWells + step.toNextTube, accuracy: 0.001, "row \(index)")
            if index + 1 < compound.steps.count, !compound.steps[index + 1].isVehicle {
                XCTAssertEqual(
                    step.toNextTube, compound.steps[index + 1].sourceVolume ?? -1, accuracy: 0.001,
                    "what leaves tube \(index + 1) is what the next one takes"
                )
            }
        }
        XCTAssertEqual(compound.steps[0].total, 432, accuracy: 0.001)

        // Only the bottom tube's well count changes.
        var bigger = layout()
        let drug = bigger.factors[0]
        let dose = try XCTUnwrap(drug.levels.first { $0.name == "0.37" })
        let format = bigger.plates[0].format
        for well in 300..<372 {
            bigger.plates[0].setLevelID(dose.id, factor: drug.id, well: well)
        }
        XCTAssertLessThan(372, format.wellCount)
        let grown = try plan(bigger)
        XCTAssertEqual(grown.steps[3].wells, 96)
        XCTAssertEqual(grown.steps[0].total, 459, accuracy: 0.001,
                       "the first tube has to grow when the last one does")
    }

    func testEveryRowAddsUp() throws {
        for wells in [3, 7, 24, 96] {
            let compound = try plan(layout(wells: wells))
            for step in compound.steps {
                guard let source = step.sourceVolume, let diluent = step.diluent else { continue }
                XCTAssertEqual(source + diluent, step.total, accuracy: 0.001,
                               "source + diluent must be the total (\(wells) wells)")
            }
        }
    }

    /// If ceil and round are ever swapped, a tube quietly dispenses less than its wells
    /// need. At 0 % overage there is no slack to hide it.
    func testNoTubeDispensesLessThanItsWellsNeed() throws {
        let compound = try plan(layout { $0.overage = Overage(mode: .percent, percent: 0) })
        for step in compound.steps {
            XCTAssertGreaterThanOrEqual(
                step.toWells + 0.0001, Double(step.wells) * 10,
                "\(step.label) dispenses less than its wells take"
            )
        }
    }

    func testTotalsScaleWithTheWellCount() throws {
        let small = try plan(layout(wells: 12, vehicleWells: 0))
        let big = try plan(layout(wells: 24, vehicleWells: 0))
        XCTAssertEqual(big.steps[3].total, small.steps[3].total * 2, accuracy: 0.001)
    }

    func testTheWorkingConcentrationIsTheDoseTimesTheWellFold() throws {
        let tenTimes = try plan(layout())
        XCTAssertEqual(tenTimes.steps[0].working, 100, accuracy: 0.001)

        // Replacing the medium outright means the tubes are at 1×.
        let straight = try plan(layout { $0.wellVolume = 100; $0.addedVolume = 100 })
        XCTAssertEqual(straight.steps[0].working, 10, accuracy: 0.001)
    }

    // MARK: - Overage, all three ways

    func testEveryOverageModeIsHonoured() throws {
        // 24 wells × 10 µL = 240 µL of dispense, so 20 % is 48 and the 50 µL floor bites.
        let percent = try plan(layout(wells: 24, vehicleWells: 0) {
            $0.overage = Overage(mode: .percent, percent: 20)
        })
        XCTAssertEqual(percent.steps[3].total, 288, accuracy: 0.001)

        let floored = try plan(layout(wells: 24, vehicleWells: 0) {
            $0.overage = Overage(mode: .percentWithMinimum, percent: 20, minimumExtra: 50)
        })
        XCTAssertEqual(floored.steps[3].total, 290, accuracy: 0.001, "the floor wins at 24 wells")

        let fixed = try plan(layout(wells: 24, vehicleWells: 0) {
            $0.overage = Overage(mode: .fixed, fixedExtra: 50)
        })
        XCTAssertEqual(fixed.steps[3].total, 290, accuracy: 0.001)

        // At 3 wells the percentage is 6 µL, which is exactly what the floor is for.
        let thin = try plan(layout(wells: 3, vehicleWells: 0) {
            $0.overage = Overage(mode: .percent, percent: 20)
        })
        XCTAssertEqual(thin.steps[3].total, 36, accuracy: 0.001)
        let thick = try plan(layout(wells: 3, vehicleWells: 0) {
            $0.overage = Overage(mode: .percentWithMinimum, percent: 20, minimumExtra: 50)
        })
        XCTAssertEqual(thick.steps[3].total, 80, accuracy: 0.001)
    }

    // MARK: - Method detection

    func testARoundedThreeFoldSeriesIsStillSerial() {
        let fold = DilutionPlan.foldRatio(of: [10, 3.33, 1.11, 0.37])
        XCTAssertEqual(try XCTUnwrap(fold), 3, accuracy: 0.01)
    }

    func testTwoSignificantDigitsAreStillSerial() {
        XCTAssertEqual(try XCTUnwrap(DilutionPlan.foldRatio(of: [10, 3.3, 1.1, 0.37])), 3, accuracy: 0.05)
    }

    func testALinearSeriesIsNotSerial() {
        XCTAssertNil(DilutionPlan.foldRatio(of: [10, 8, 6, 4, 2]))
    }

    func testOneOddPointBreaksTheSeries() {
        XCTAssertNil(DilutionPlan.foldRatio(of: [10, 3.33, 1.5, 0.37]))
    }

    /// Two points fit a geometric series exactly by construction, so a ratio from them
    /// proves nothing at all.
    func testTwoDosesAreNeverCalledSerial() {
        XCTAssertNil(DilutionPlan.foldRatio(of: [10, 1]))
    }

    /// The doses are a set, not a sequence — they are sorted before being fitted, so the
    /// order they arrive in cannot change the answer. Repeats have no ratio at all.
    func testOrderDoesNotMatterAndRepeatsAreRefused() {
        XCTAssertEqual(
            try XCTUnwrap(DilutionPlan.foldRatio(of: [1, 3, 9])), 3, accuracy: 0.01
        )
        XCTAssertNil(DilutionPlan.foldRatio(of: [10, 10, 10]))
        XCTAssertNil(DilutionPlan.foldRatio(of: [10, 3.33, 3.33, 1.11]))
    }

    func testALinearSeriesFallsBackToIndividualFromStock() throws {
        let compound = try plan(layout(doses: ["30", "20", "10"], vehicleWells: 0))
        XCTAssertEqual(compound.method, .individual)
        for step in compound.steps {
            XCTAssertEqual(step.source, .stock)
            XCTAssertEqual(step.toNextTube, 0, "nothing is drawn off for a next tube")
        }
        XCTAssertTrue(
            compound.warnings.contains(.notSerial(.ratiosVary)),
            "automatic must not mean silent"
        )
    }

    func testTheVehicleDoesNotJoinTheFoldTest() throws {
        let compound = try plan(layout(doses: ["10", "5", "2.5", "1.25"]))
        assertSerial(compound.method, fold: 2)
    }

    // MARK: - One factor per drug

    func testEachDilutionFactorGetsItsOwnSeries() throws {
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout(compounds: ["Cpd1", "Cpd2"])))
        XCTAssertEqual(plan.compounds.map(\.name), ["Cpd1", "Cpd2"])
        for compound in plan.compounds {
            XCTAssertEqual(compound.steps.count, 5)
            XCTAssertEqual(compound.steps[0].wells, 24, "wells are counted per drug")
        }
    }

    /// Two drugs in one well is what the old two-factor shape could not say at all: a
    /// well had one compound and one dose. Each factor now counts its own wells, so a
    /// combination well belongs to both series.
    func testAWellPaintedWithTwoDrugsIsCountedForEach() throws {
        var layout = self.layout(compounds: ["Cpd1", "Cpd2"])
        let first = layout.factors[0]
        let second = layout.factors[1]
        // Well 0 already carries Cpd1's top dose; give it Cpd2's top dose as well.
        layout.plates[0].setLevelID(second.levels[0].id, factor: second.id, well: 0)

        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertEqual(plan.compounds[0].steps[0].wells, 24, "unchanged for the first drug")
        XCTAssertEqual(plan.compounds[1].steps[0].wells, 25, "and counted again for the second")
        XCTAssertEqual(
            layout.plates[0].levelID(factor: first.id, well: 0), first.levels[0].id,
            "the well genuinely holds both"
        )
    }

    /// A factor is only on the sheet because it says it is made by dilution. Untick it
    /// and it is an ordinary factor again — its levels are just labels.
    func testAFactorThatIsNotMarkedIsNotInThePlan() throws {
        var layout = self.layout(compounds: ["Cpd1", "Cpd2"])
        layout.factors[1].dilution = nil

        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertEqual(plan.compounds.map(\.name), ["Cpd1"])
    }

    /// The unit is per factor, so one drug can be quoted in µM beside another in ng/mL —
    /// which one shared dose factor could never do.
    func testTwoDrugsCanBeInDifferentUnits() throws {
        var layout = self.layout(compounds: ["Cpd1", "Cpd2"])
        layout.factors[1].unit = "ng/mL"
        layout.factors[1].dilution = Dilution(stock: StockConcentration(value: 5, unit: "mg/mL"))

        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertEqual(plan.compounds[0].unit, "µM")
        XCTAssertEqual(plan.compounds[1].unit, "ng/mL")
        // 5 mg/mL is 5,000,000 ng/mL, and each converts against its own factor's unit.
        XCTAssertEqual(plan.compounds[1].stockInDoseUnits ?? 0, 5_000_000, accuracy: 1)
        XCTAssertFalse(
            plan.allWarnings.contains { if case .unitsNotComparable = $0 { true } else { false } },
            "each drug's stock is compared against its own unit, so neither is a mismatch"
        )
    }

    func testAPlateScopedPlanOnlyCountsThatPlate() throws {
        var layout = self.layout()
        var second = layout.plates[0]
        second.id = UUID()
        second.name = "Plate 2"
        layout.plates.append(second)

        let all = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertEqual(all.compounds[0].steps[0].wells, 48)
        XCTAssertEqual(all.scopeText, "all 2 plates")

        layout.prep?.plateID = layout.plates[0].id
        let one = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertEqual(one.compounds[0].steps[0].wells, 24)
        XCTAssertEqual(one.scopeText, "Plate 1")
    }

    // MARK: - Warnings

    func testAMissingStockStillGivesTheVolumesToMake() throws {
        let compound = try plan(layout(stock: nil))
        XCTAssertEqual(compound.steps[0].total, 432, accuracy: 0.001, "the totals are the value-add")
        XCTAssertNil(compound.steps[0].sourceVolume, "how much stock to take is unknowable")
        XCTAssertEqual(compound.steps[1].sourceVolume ?? -1, 144, accuracy: 0.001,
                       "the rest of a serial chain never touches the stock")
        XCTAssertTrue(compound.warnings.contains(.noStock(compound: "Cpd1")))
    }

    func testAStockWeakerThanTheTopTubeIsAnError() throws {
        let compound = try plan(layout(stock: StockConcentration(value: 50, unit: "µM")))
        XCTAssertNil(compound.steps[0].sourceVolume)
        XCTAssertEqual(compound.steps[1].sourceVolume ?? -1, 144, accuracy: 0.001,
                       "the rest of the chain is unaffected")
        XCTAssertTrue(compound.warnings.contains {
            if case .stockTooWeak = $0 { return true } else { return false }
        })
    }

    func testAVolumeUnderThePipetteMinimumIsFlaggedOnItsStep() throws {
        let compound = try plan(layout(stock: StockConcentration(value: 1, unit: "M")))
        let step = compound.steps[0]
        XCTAssertTrue(step.warnings.contains {
            if case .belowPipetteMinimum = $0 { return true } else { return false }
        }, "0.04 µL out of a 1 M stock is not pipettable")
    }

    func testANonNumericDoseIsSkippedAndNamed() throws {
        var layout = self.layout()
        layout.factors[0].levels.append(Level(name: "n/a", colorHex: "#888888"))
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        // The warning belongs to the drug now, not to the sheet: one factor's levels can
        // be unreadable while another's are fine.
        XCTAssertTrue(plan.allWarnings.contains(.nonNumericDose(name: "n/a")))
        XCTAssertEqual(plan.compounds[0].steps.count, 5, "still four doses and a vehicle")
    }

    func testAddingMoreThanTheWellHoldsIsRefused() throws {
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout { $0.addedVolume = 200 }))
        XCTAssertTrue(plan.isEmpty, "an input error produces no tubes at all")
        XCTAssertTrue(plan.warnings.contains {
            if case .addedVolumeExceedsWell = $0 { return true } else { return false }
        })
    }

    /// A ticked drug with nothing painted must say so rather than vanish: its block is
    /// hidden (no tubes to show), so the warning is the only thing that explains where
    /// it went.
    func testATickedDrugWithNoPaintedWellsWarnsInsteadOfVanishing() throws {
        var layout = self.layout()
        let drug = layout.factors[0]
        for well in 0..<layout.plates[0].format.wellCount {
            layout.plates[0].setLevelID(nil, factor: drug.id, well: well)
        }
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.allWarnings.contains { warning in
            if case .noWells = warning { return true } else { return false }
        }, "the sheet has to name the drug that covers no wells")
    }

    /// A cleared or unusable value on a factor that is not a dilution is nothing at all.
    /// Creating the marker for it would let a stray commit from an empty field — blurred
    /// without typing, or a unit typed with no number — silently turn "Cell line" into a
    /// drug and mark the document Edited.
    func testANilStockOnAnUnmarkedFactorChangesNothing() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let undo = UndoManager()
        editor.undoManager = undo
        let factorID = document.layout.factors[0].id

        editor.setFactorStock(factorID, stock: nil)
        editor.setFactorStock(factorID, stock: StockConcentration(value: 0, unit: "mM"))

        XCTAssertNil(document.layout.factors[0].dilution, "the factor must stay unmarked")
        XCTAssertFalse(undo.canUndo, "and nothing was edited")
    }

    /// The prep window's numeric fields commit on losing focus whether or not anything
    /// was typed, and nil → PrepSetup() is a real edit `mutate` cannot short-circuit —
    /// so a no-op commit must not seed a setup into a document that has none.
    func testANoOpPrepCommitDoesNotSeedASetup() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let undo = UndoManager()
        editor.undoManager = undo

        editor.updatePrep("Well Volume") { $0.wellVolume = 100 }   // the default, unchanged
        XCTAssertNil(document.layout.prep, "an echo of the default is not a choice")
        XCTAssertFalse(undo.canUndo)

        editor.updatePrep("Well Volume") { $0.wellVolume = 50 }
        XCTAssertEqual(document.layout.prep?.wellVolume, 50, "a real choice still seeds")
    }

    /// Marking a factor is the opt-in now, so a document with none has no sheet — even
    /// when it has bench settings saved from a previous visit.
    func testNoDilutionFactorMeansNoPlan() {
        var layout = self.layout()
        layout.factors[0].dilution = nil
        XCTAssertNil(DilutionPlan.make(from: layout))
        layout.prep = nil
        XCTAssertNil(DilutionPlan.make(from: layout))
    }

    // MARK: - Units

    func testAMillimolarStockAgainstMicromolarDosesConverts() throws {
        let compound = try plan(layout())
        XCTAssertEqual(compound.stockInDoseUnits ?? -1, 10_000, accuracy: 0.001)
    }

    func testMolarAgainstMassPerVolumeRefusesRatherThanGuessing() throws {
        let compound = try plan(layout(stock: StockConcentration(value: 5, unit: "mg/mL")))
        XCTAssertNil(compound.stockInDoseUnits)
        XCTAssertTrue(compound.warnings.contains(
            .unitsNotComparable(dose: "µM", stock: "mg/mL")
        ))
    }

    func testAnUnrecognisedUnitIsAssumedToMatchAndSaysSo() throws {
        let compound = try plan(layout(stock: StockConcentration(value: 40, unit: "IU/mL"),
                                       doseUnit: "IU/mL"))
        XCTAssertEqual(compound.stockInDoseUnits ?? -1, 40, accuracy: 0.001)
        XCTAssertFalse(
            compound.warnings.contains { if case .unitAssumed = $0 { return true } else { return false } },
            "the two units are the same string, so there is nothing to warn about"
        )

        let mixed = try plan(layout(stock: StockConcentration(value: 40, unit: "IU/mL"),
                                    doseUnit: "µM"))
        XCTAssertTrue(
            mixed.warnings.contains { if case .unitAssumed = $0 { return true } else { return false } }
        )
    }

    // MARK: - The editor's side of it

    func testSettingAStockIsOneUndoStep() throws {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factorID = document.layout.factors[0].id

        // Attached after setup, or every edit above coalesces into this group.
        let undo = UndoManager()
        editor.undoManager = undo

        editor.setFactorStock(factorID, stock: StockConcentration(value: 10, unit: "mM"))
        XCTAssertEqual(document.layout.factors[0].dilution?.stock?.value, 10)
        undo.undo()
        XCTAssertNil(document.layout.factors[0].dilution)
    }

    func testAZeroStockClearsRatherThanStoringNothing() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factorID = document.layout.factors[0].id

        editor.setFactorStock(factorID, stock: StockConcentration(value: 10, unit: "mM"))
        editor.setFactorStock(factorID, stock: StockConcentration(value: 0, unit: "mM"))
        XCTAssertNil(document.layout.factors[0].dilution?.stock,
                     "a unit typed before a number is not a stock")
        XCTAssertNotNil(document.layout.factors[0].dilution,
                        "but the factor is still one you make by dilution")
    }

    /// Typing a stock says what you mean, so it marks the factor too.
    func testSettingAStockMarksTheFactorAsADilution() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factorID = document.layout.factors[0].id

        XCTAssertNil(document.layout.factors[0].dilution)
        editor.setFactorStock(factorID, stock: StockConcentration(value: 10, unit: "mM"))
        XCTAssertNotNil(document.layout.factors[0].dilution)
    }

    /// Turning the toggle off takes the stock with it — the two are one fact about the
    /// factor — and ⌘Z brings both back, because it is one edit.
    func testUnmarkingAFactorTakesItsStockAndUndoBringsItBack() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factorID = document.layout.factors[0].id
        editor.setFactorStock(factorID, stock: StockConcentration(value: 10, unit: "mM"))

        let undo = UndoManager()
        editor.undoManager = undo

        editor.setFactorIsDilution(factorID, false)
        XCTAssertNil(document.layout.factors[0].dilution)

        undo.undo()
        XCTAssertEqual(document.layout.factors[0].dilution?.stock?.value, 10)
    }

    func testTheFirstPrepEditSeedsASetupFromTheDocument() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        document.layout.factors[0].kind = .numeric

        XCTAssertNil(document.layout.prep, "nothing until it is asked for")
        editor.updatePrep { $0.wellVolume = 50 }
        XCTAssertEqual(document.layout.prep?.wellVolume, 50)
    }

    /// A drug carries its stock into another document, the way its unit does.
    func testACopiedDrugArrivesWithItsStock() throws {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        document.layout.factors[0].name = "Drug"
        document.layout.factors[0].levels[0].name = "Cpd1"
        document.layout.factors[0].dilution = Dilution(
            stock: StockConcentration(value: 10, unit: "mM")
        )
        let factor = document.layout.factors[0]
        document.layout.plates[0].setLevelID(factor.levels[0].id, factor: factor.id, well: 0)

        editor.selection = WellRange(single: WellPos(row: 0, col: 0))
        editor.customWells = nil
        editor.copyWells()

        let other = PlateDocument()
        let otherEditor = PlateEditor(document: other)
        otherEditor.selection = WellRange(single: WellPos(row: 2, col: 2))
        otherEditor.pasteWells()

        let arrived = other.layout.factors.first { $0.name == "Drug" }
        XCTAssertEqual(arrived?.dilution?.stock?.value, 10)
        XCTAssertEqual(arrived?.dilution?.stock?.unit, "mM")
    }

    // MARK: - Pipette rounding

    func testVolumesAreRoundedToWhatAPipetteCanBeSetTo() {
        XCTAssertEqual(DilutionPlan.pipetteRounded(4.267), 4.3, accuracy: 1e-9)
        XCTAssertEqual(DilutionPlan.pipetteRounded(138.667), 139, accuracy: 1e-9)
        XCTAssertEqual(DilutionPlan.pipetteCeiled(287.1), 288, accuracy: 1e-9)
        XCTAssertEqual(DilutionPlan.pipetteCeiled(4.21), 4.3, accuracy: 1e-9)
    }
}

/// The drawn table. It is AppKit precisely so it can be rendered offscreen and asserted
/// on — a SwiftUI table could be neither printed nor tested (HANDOFF §1).
final class PrepTableTests: XCTestCase {

    private func table(_ layout: Layout, width: CGFloat = 560) throws -> PrepTableView {
        let view = PrepTableView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        view.setFrameSize(NSSize(width: width, height: view.intrinsicContentSize.height))
        return view
    }

    private func layout(doses: [String], wells: Int = 24) -> Layout {
        var layout = Layout(plates: [Plate(name: "Plate 1", format: .well384)])
        var drug = Factor(
            name: "Cpd1", kind: .numeric, unit: "µM",
            dilution: Dilution(stock: StockConcentration(value: 10, unit: "mM"))
        )
        for (index, name) in (doses + ["0"]).enumerated() {
            drug.levels.append(Level(name: name, colorHex: Palette.color(at: index)))
        }
        layout.factors = [drug]

        var well = 0
        for level in drug.levels {
            for _ in 0..<wells {
                layout.plates[0].setLevelID(level.id, factor: drug.id, well: well)
                well += 1
            }
        }
        var prep = PrepSetup()
        prep.wellVolume = 100
        prep.addedVolume = 10
        prep.overage = Overage(mode: .percent, percent: 20)
        layout.prep = prep
        return layout
    }

    func testTheTableRendersAndGrowsWithTheTubeCount() throws {
        let short = try table(layout(doses: ["10", "3.33", "1.11"]))
        let long = try table(layout(doses: ["10", "3.33", "1.11", "0.37", "0.123", "0.0412"]))

        let png = try XCTUnwrap(short.pngData(), "the table produced no image")
        XCTAssertGreaterThan(png.count, 1000)
        XCTAssertGreaterThan(long.frame.height, short.frame.height, "more tubes, more page")

        if let path = ProcessInfo.processInfo.environment["PLATE_PREP_PATH"] {
            try XCTUnwrap(long.pngData()).write(to: URL(fileURLWithPath: path))
        }
    }

    /// AppKit will happily slice a page through the middle of a row.
    /// A bare "0.9" on a bench sheet is a question, not an instruction: every heading has
    /// to say what its numbers are in. Concentrations take the drug's own unit, volumes
    /// are always µL.
    func testEveryColumnHeadingNamesItsUnit() throws {
        let headings = try table(layout(doses: ["10", "3.33", "1.11"])).headingsForTesting
        // Concentrations in the drug's own unit, volumes always in µL.
        XCTAssertTrue(headings.contains("Dose (µM)"), headings.description)
        for volume in ["Take (µL)", "+ Diluent (µL)", "= Make (µL)"] {
            XCTAssertTrue(headings.contains(volume), headings.description)
        }
        XCTAssertFalse(headings.contains("Take"), "the bare heading is the one being replaced")
    }

    /// "In tube" is the tube's own concentration, which only differs from the dose when
    /// the well takes less than its whole volume from it. At 1× it was the same number in
    /// two columns — which is exactly what made the heading read as a mystery.
    func testInTubeIsOnlyShownWhenItDiffersFromTheDose() throws {
        var oneToOne = layout(doses: ["10", "3.33", "1.11"])
        oneToOne.prep?.addedVolume = 100      // the well takes all of its volume from the tube
        let plain = try table(oneToOne)
        XCTAssertFalse(plain.headingsForTesting.contains { $0.hasPrefix("In tube") },
                       plain.headingsForTesting.description)

        var concentrated = oneToOne
        concentrated.prep?.addedVolume = 10   // 10× tubes
        let folded = try table(concentrated)
        XCTAssertTrue(folded.headingsForTesting.contains("In tube (µM)"),
                      folded.headingsForTesting.description)
    }

    func testAPageNeverBreaksThroughTheMiddleOfARow() throws {
        let view = try table(layout(doses: ["10", "3.33", "1.11", "0.37", "0.123", "0.0412"]))
        let height = view.frame.height
        XCTAssertGreaterThan(height, 60)

        var moved = 0
        for step in stride(from: 40.0, to: height - 5, by: 3.0) {
            let bottom = view.pageBottom(top: 0, proposedBottom: step)
            XCTAssertLessThanOrEqual(bottom, step)
            XCTAssertGreaterThan(bottom, 0, "a break at or above the top would never finish")
            if bottom != step { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 0, "some of those proposals must have landed inside a row")
    }

    func testAnEmptyPlanDrawsNothingRatherThanCrashing() {
        let view = PrepTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.plan = nil
        XCTAssertNotNil(view.pngData())
    }
}

/// Unit parsing on its own — the piece that decides whether two concentrations can be
/// divided at all.
final class ConcentrationUnitTests: XCTestCase {

    private func factor(_ from: String, _ to: String) -> Double? {
        switch ConcentrationUnit.parse(from).conversion(to: ConcentrationUnit.parse(to)) {
        case .exact(let value), .assumed(let value): return value
        case .incompatible: return nil
        }
    }

    func testMolarPrefixes() {
        XCTAssertEqual(try XCTUnwrap(factor("mM", "µM")), 1000, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(factor("M", "nM")), 1e9, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(factor("nM", "µM")), 0.001, accuracy: 1e-9)
    }

    /// ⌥M types U+00B5 and a paper pastes U+03BC; they are different characters and both
    /// have to mean micro.
    func testBothMicroSignsAndPlainUAreTheSame() {
        XCTAssertEqual(try XCTUnwrap(factor("\u{00B5}M", "\u{03BC}M")), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(factor("uM", "\u{00B5}M")), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(factor("  mM ", "um")), 1000, accuracy: 1e-6)
    }

    func testMassPerVolume() {
        XCTAssertEqual(try XCTUnwrap(factor("mg/mL", "µg/mL")), 1000, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(factor("mg/mL", "g/L")), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(factor("ng/mL", "µg/mL")), 0.001, accuracy: 1e-9)
    }

    /// The slash rule covers mol/L spellings for free, including per-mL ones.
    func testMolePerVolumeSpellings() {
        XCTAssertEqual(try XCTUnwrap(factor("mol/L", "M")), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(factor("nmol/mL", "µM")), 1, accuracy: 1e-9)
    }

    func testCrossFamilyIsRefused() {
        XCTAssertNil(factor("µM", "mg/mL"))
        XCTAssertNil(factor("mg/mL", "nM"))
    }

    func testUnknownUnitsAreAssumedToMatch() {
        XCTAssertEqual(
            ConcentrationUnit.parse("IU/mL").conversion(to: ConcentrationUnit.parse("µM")),
            .assumed(1)
        )
        XCTAssertEqual(
            ConcentrationUnit.parse("IU/mL").conversion(to: ConcentrationUnit.parse("iu/ml")),
            .exact(1),
            "the same unit, however exotic, is exact and silent"
        )
        XCTAssertEqual(
            ConcentrationUnit.parse("").conversion(to: ConcentrationUnit.parse("")),
            .exact(1)
        )
    }
}

// MARK: -

/// `Method` carries a Double, so equality needs a tolerance the enum cannot give.
/// A free function rather than an `XCTestCase` method: a member of that name shadows
/// the global `XCTAssertEqual` for the whole file.
private func assertSerial(
    _ method: DilutionPlan.Method, fold expected: Double, accuracy: Double = 0.01,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard case .serial(let fold) = method else {
        return XCTFail("expected a serial dilution, got \(method)", file: file, line: line)
    }
    XCTAssertEqual(fold, expected, accuracy: accuracy, file: file, line: line)
}
