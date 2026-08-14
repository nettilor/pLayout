import XCTest
@testable import PLayout

/// Whole-layout templates: complete .plate files in their own folder, listed by
/// name, overwritten by name, and readable back as ordinary layouts.
final class LayoutTemplateTests: XCTestCase {

    private var directory: URL!
    private var store: LayoutTemplateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-templates-\(UUID().uuidString)")
        store = LayoutTemplateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testSavingListsAndReadingBack() throws {
        var layout = Layout.starter()
        layout.factors[0].name = "Drug"
        try store.save(layout, named: "IC50 setup")

        XCTAssertEqual(store.templates.map(\.name), ["IC50 setup"])
        let decoded = try JSONDecoder().decode(
            Layout.self, from: Data(contentsOf: store.templates[0].url)
        )
        XCTAssertEqual(decoded.factors[0].name, "Drug")
    }

    func testSavingUnderTheSameNameReplaces() throws {
        try store.save(Layout.starter(), named: "Base")
        var second = Layout.starter()
        second.factors[0].name = "Replaced"
        try store.save(second, named: "Base")

        XCTAssertEqual(store.templates.count, 1)
        let decoded = try JSONDecoder().decode(
            Layout.self, from: Data(contentsOf: store.templates[0].url)
        )
        XCTAssertEqual(decoded.factors[0].name, "Replaced")
    }

    func testDeleteRemovesTheFile() throws {
        try store.save(Layout.starter(), named: "Doomed")
        store.delete(store.templates[0])
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Doomed.plate").path
        ))
    }

    func testNamesAreSanitisedIntoFileNames() {
        XCTAssertEqual(LayoutTemplateStore.sanitized("  A/B: run 2  "), "A-B- run 2")
        XCTAssertEqual(LayoutTemplateStore.sanitized("..."), "")
        XCTAssertEqual(LayoutTemplateStore.sanitized("   "), "")
    }
}
