import XCTest
import AppKit
@testable import PLayout

/// The click rule is plain arithmetic precisely so it can be tested — the gesture
/// recognisers it replaced could not be, and each attempt with them broke either the
/// click latency or drag-to-reorder.
@MainActor
final class RowClickTrackerTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testASingleClickIsNotADoubleClick() {
        var clicks = RowClickTracker()
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0, interval: 0.5))
    }

    func testTwoQuickClicksOnTheSameRowAreADoubleClick() {
        var clicks = RowClickTracker()
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0, interval: 0.5))
        XCTAssertTrue(clicks.isDoubleClick(on: a, now: 0.2, interval: 0.5))
    }

    func testASlowSecondClickIsTwoSelections() {
        var clicks = RowClickTracker()
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0, interval: 0.5))
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0.9, interval: 0.5))
    }

    func testClicksOnDifferentRowsNeverPairUp() {
        var clicks = RowClickTracker()
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0, interval: 0.5))
        XCTAssertFalse(clicks.isDoubleClick(on: b, now: 0.1, interval: 0.5))
    }

    /// A triple click should rename once, not rename again on the third click.
    func testTheThirdClickStartsCountingAgain() {
        var clicks = RowClickTracker()
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0, interval: 0.5))
        XCTAssertTrue(clicks.isDoubleClick(on: a, now: 0.15, interval: 0.5))
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 0.3, interval: 0.5))
        XCTAssertTrue(clicks.isDoubleClick(on: a, now: 0.45, interval: 0.5))
    }

    func testExactlyAtTheIntervalStillCounts() {
        var clicks = RowClickTracker()
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: 1.0, interval: 0.5))
        XCTAssertTrue(clicks.isDoubleClick(on: a, now: 1.5, interval: 0.5))
    }

    func testDefaultsToTheSystemDoubleClickInterval() {
        var clicks = RowClickTracker()
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(clicks.isDoubleClick(on: a, now: now))
        XCTAssertTrue(clicks.isDoubleClick(on: a, now: now + NSEvent.doubleClickInterval / 2))
    }
}

/// Dropping row A onto row B has to become the offset `move(fromOffsets:toOffset:)`
/// expects, which is defined against *pre-move* indices — the off-by-one when moving
/// downwards is the whole reason this is a named function with tests.
final class RowReorderTests: XCTestCase {

    func testMovingUpLandsOnTheTargetIndex() {
        XCTAssertEqual(RowReorder.offset(movingFrom: 3, onto: 1), 1)
        XCTAssertEqual(RowReorder.offset(movingFrom: 1, onto: 0), 0)
    }

    func testMovingDownLandsAfterTheTarget() {
        XCTAssertEqual(RowReorder.offset(movingFrom: 0, onto: 2), 3)
        XCTAssertEqual(RowReorder.offset(movingFrom: 1, onto: 4), 5)
    }

    /// The offsets have to produce the order a user would expect from the drop.
    func testOffsetsProduceTheExpectedOrder() {
        func reorder(_ items: [String], from: Int, onto: Int) -> [String] {
            var copy = items
            copy.move(fromOffsets: IndexSet(integer: from),
                      toOffset: RowReorder.offset(movingFrom: from, onto: onto))
            return copy
        }
        let start = ["A", "B", "C", "D"]
        XCTAssertEqual(reorder(start, from: 3, onto: 0), ["D", "A", "B", "C"])
        XCTAssertEqual(reorder(start, from: 0, onto: 3), ["B", "C", "D", "A"])
        XCTAssertEqual(reorder(start, from: 2, onto: 1), ["A", "C", "B", "D"])
        XCTAssertEqual(reorder(start, from: 1, onto: 2), ["A", "C", "B", "D"])
    }
}
