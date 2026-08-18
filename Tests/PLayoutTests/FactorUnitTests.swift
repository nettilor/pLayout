import XCTest
@testable import PLayout

/// A unit belongs to any factor, not only a dose. Seeding density, timepoint, volume,
/// passage — all of them have one, and none of them is numeric in the sense the dose
/// series means. Optional throughout: blank changes nothing, filled in it travels into
/// the export headings.
final class FactorUnitTests: XCTestCase {

    func testACategoricalFactorCanCarryAUnit() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0].id

        editor.setFactorUnit(factor, unit: "h")
        XCTAssertEqual(document.layout.factors[0].unit, "h")
        XCTAssertEqual(document.layout.factors[0].kind, .categorical, "no type change comes with it")
        XCTAssertEqual(document.layout.factors[0].displayName, "Condition (h)")
    }

    /// The field has to be clearable, or a unit typed by mistake is permanent.
    func testAUnitCanBeClearedAgain() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0].id
        editor.setFactorUnit(factor, unit: "h")

        let undo = UndoManager()
        editor.undoManager = undo

        editor.setFactorUnit(factor, unit: "")
        XCTAssertEqual(document.layout.factors[0].unit, "")
        XCTAssertEqual(document.layout.factors[0].displayName, "Condition")

        undo.undo()
        XCTAssertEqual(document.layout.factors[0].unit, "h", "clearing is an ordinary undoable edit")
    }

    func testWhitespaceIsNotAUnit() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.setFactorUnit(document.layout.factors[0].id, unit: "   ")
        XCTAssertEqual(document.layout.factors[0].unit, "")
    }

    func testTheUnitOfEveryFactorReachesTheTidyTable() {
        var layout = Layout.starter()
        layout.factors[0].unit = "h"
        var seeding = Factor(name: "Seeding", unit: "cells/well")
        seeding.levels = [Level(name: "5000", colorHex: "#1B3A5C")]
        layout.factors.append(seeding)

        let header = Exporter.tidyGrid(layout: layout)[0]
        XCTAssertTrue(header.contains("Condition (h)"), header.joined(separator: " | "))
        XCTAssertTrue(header.contains("Seeding (cells/well)"), header.joined(separator: " | "))
    }
}
