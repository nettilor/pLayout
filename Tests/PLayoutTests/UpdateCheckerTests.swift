import XCTest
@testable import PLayout

/// The update check's policy is pure functions precisely so it can be tested without
/// a network: what a tag means, when a check is due, which asset is the download,
/// and what an answer from GitHub decodes to.
final class UpdateCheckerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "update-checker-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Versions

    func testVersionsCompareNumericallyNotLexically() {
        XCTAssertTrue(AppVersion("1.10")! > AppVersion("1.9")!)
        XCTAssertTrue(AppVersion("2")! > AppVersion("1.99.99")!)
    }

    func testTheVPrefixAndAMissingZeroAreCosmetic() {
        XCTAssertEqual(AppVersion("v1.3"), AppVersion("1.3"))
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertFalse(AppVersion("1.2")! < AppVersion("1.2.0")!)
        XCTAssertFalse(AppVersion("1.2.0")! < AppVersion("1.2")!)
    }

    /// A malformed tag must parse to nothing rather than to something — the verdict
    /// treats nil as "no update", and a wrong guess here becomes a wrong alert.
    func testGarbageRefusesToParse() {
        for tag in ["", "v", "beta", "1.2b", "1..2", "1.2-rc1", "-1.2"] {
            XCTAssertNil(AppVersion(tag), "\(tag) parsed")
        }
    }

    // MARK: - The verdict

    private func release(tag: String, assets: [GitHubRelease.Asset] = []) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            htmlURL: URL(string: "https://example.com/releases/tag/\(tag)")!,
            body: nil,
            assets: assets
        )
    }

    func testANewerTagIsAnUpdateAndAnythingElseIsNot() {
        let newer = release(tag: "v1.3")
        XCTAssertEqual(
            UpdateChecker.verdict(for: newer, current: "1.2", skippedTag: nil, manual: false),
            .update(newer)
        )
        for tag in ["v1.2", "1.2.0", "v1.1", "not-a-version"] {
            XCTAssertEqual(
                UpdateChecker.verdict(for: release(tag: tag), current: "1.2", skippedTag: nil, manual: false),
                .upToDate, "\(tag) against 1.2"
            )
        }
    }

    /// A bare `swift build` binary has no Info.plist and so no version. That copy
    /// can't be updated by a DMG anyway, so the checker must stay silent, not guess.
    func testAnUnknownOwnVersionNeverOffersAnything() {
        XCTAssertEqual(
            UpdateChecker.verdict(for: release(tag: "v9.9"), current: nil, skippedTag: nil, manual: true),
            .upToDate
        )
    }

    func testSkipSilencesTheAutomaticCheckButNotTheMenuItem() {
        let offered = release(tag: "v1.3")
        XCTAssertEqual(
            UpdateChecker.verdict(for: offered, current: "1.2", skippedTag: "v1.3", manual: false),
            .skipped
        )
        // Asking by hand is asking to see it again.
        XCTAssertEqual(
            UpdateChecker.verdict(for: offered, current: "1.2", skippedTag: "v1.3", manual: true),
            .update(offered)
        )
        // And a release beyond the skipped one speaks up again on its own.
        let next = release(tag: "v1.4")
        XCTAssertEqual(
            UpdateChecker.verdict(for: next, current: "1.2", skippedTag: "v1.3", manual: false),
            .update(next)
        )
    }

    // MARK: - Cadence

    func testTheDailyCheckIsDueOnceThenNotAgainUntilTomorrow() {
        let now = Date()
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        // 20 hours, not 24: launching every morning still counts as daily.
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-21 * 3600), now: now))
    }

    // MARK: - What GitHub sends back

    func testARealReleaseAnswerDecodesToTheTagTheNotesAndTheImage() throws {
        let json = """
        {
          "tag_name": "v1.3",
          "html_url": "https://github.com/nettilor/pLayout/releases/tag/v1.3",
          "draft": false,
          "prerelease": false,
          "body": "### Added\\r\\n- An update checker\\r\\n",
          "assets": [
            {"name": "checksums.txt",
             "browser_download_url": "https://example.com/checksums.txt",
             "content_type": "text/plain"},
            {"name": "pLayout-1.3.dmg",
             "browser_download_url": "https://example.com/pLayout-1.3.dmg",
             "content_type": "application/x-apple-diskimage"}
          ]
        }
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v1.3")
        XCTAssertEqual(release.dmgAsset?.name, "pLayout-1.3.dmg")
        XCTAssertEqual(UpdateChecker.notesExcerpt(release.body), "### Added\n- An update checker")
    }

    func testTheDownloadIsTheAppsOwnImageOrFailingThatAnyImage() {
        let app = GitHubRelease.Asset(name: "pLayout-1.3.dmg", browserDownloadURL: URL(string: "https://example.com/a")!)
        let other = GitHubRelease.Asset(name: "Extras.dmg", browserDownloadURL: URL(string: "https://example.com/b")!)
        let text = GitHubRelease.Asset(name: "notes.txt", browserDownloadURL: URL(string: "https://example.com/c")!)
        XCTAssertEqual(release(tag: "v1.3", assets: [text, other, app]).dmgAsset, app)
        XCTAssertEqual(release(tag: "v1.3", assets: [text, other]).dmgAsset, other)
        // No image at all: the alert falls back to opening the release page.
        XCTAssertNil(release(tag: "v1.3", assets: [text]).dmgAsset)
    }

    func testTheNotesExcerptStaysAlertSized() {
        XCTAssertNil(UpdateChecker.notesExcerpt(nil))
        XCTAssertNil(UpdateChecker.notesExcerpt("\n \n"))
        let long = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = UpdateChecker.notesExcerpt(long)!
        XCTAssertEqual(excerpt, "line 1\nline 2\nline 3\nline 4\nline 5…")
    }

    // MARK: - Landing the file

    /// An existing file in Downloads is the user's, whatever it is — the download
    /// steps aside Finder-style instead of replacing it.
    func testTheDownloadNeverOverwritesWhatIsAlreadyThere() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-checker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try UpdateChecker.freeDestination(named: "pLayout-1.3.dmg", in: dir)
        XCTAssertEqual(first.lastPathComponent, "pLayout-1.3.dmg")

        try Data().write(to: first)
        let second = try UpdateChecker.freeDestination(named: "pLayout-1.3.dmg", in: dir)
        XCTAssertEqual(second.lastPathComponent, "pLayout-1.3 2.dmg")

        try Data().write(to: second)
        let third = try UpdateChecker.freeDestination(named: "pLayout-1.3.dmg", in: dir)
        XCTAssertEqual(third.lastPathComponent, "pLayout-1.3 3.dmg")
    }

    // MARK: - The preference

    func testAutomaticCheckingIsOnByDefaultRemembersAndResets() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.checkForUpdatesAutomatically)

        preferences.checkForUpdatesAutomatically = false
        XCTAssertFalse(Preferences(defaults: defaults).checkForUpdatesAutomatically)

        preferences.resetToDefaults()
        XCTAssertTrue(preferences.checkForUpdatesAutomatically)
    }
}
