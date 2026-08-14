import AppKit

/// A dotted release version — "1.2", "1.3.1", tag-style "v1.3" — compared numerically
/// part by part, so 1.10 comes after 1.9 and "1.2" equals "1.2.0". Anything that is
/// not digits and dots refuses to parse, and the caller treats that as "no update":
/// a malformed tag must never produce an update alert.
struct AppVersion: Comparable {
    let parts: [Int]

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    // Synthesized equality would compare the arrays, calling "1.2" and "1.2.0"
    // different — which would re-offer an update the user has already skipped.
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The slice of GitHub's `releases/latest` answer the checker needs. Drafts and
/// prereleases never appear at that endpoint, so a decoded release is a published one.
struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    /// The disk image to hand the user: the `pLayout-x.y.dmg` that `make_dmg.sh`
    /// produces, by name if a release ever carries a second image, else any `.dmg`.
    /// nil means the alert falls back to opening the release page instead.
    var dmgAsset: Asset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        return dmgs.first { $0.name.lowercased().hasPrefix("playout") } ?? dmgs.first
    }
}

/// Checks the GitHub releases page for a newer pLayout and offers to fetch it.
///
/// Deliberately not an installer: the download lands in ~/Downloads and the mounted
/// image opens, drag-to-Applications window and all — replacing the running app from
/// inside itself is the entire complexity of Sparkle, taken on without its safety.
/// Plain Foundation against the public API, no dependency, and quiet by design: the
/// automatic check runs at most once a day, says nothing when up to date, and nothing
/// at all offline — this app works offline and an update nag must never suggest
/// otherwise.
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let releasesPage = URL(string: "https://github.com/nettilor/pLayout/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/nettilor/pLayout/releases/latest")!

    /// What a fetched release means for this copy of the app.
    enum Verdict: Equatable {
        case update(GitHubRelease)
        case upToDate
        /// Newer, but the user said "Skip This Version" — only the automatic check
        /// honours that; asking by hand is asking to see it again.
        case skipped
    }

    private let defaults: UserDefaults
    private let preferences: Preferences
    private let currentVersion: String?

    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let skippedTagKey = "skippedUpdateTag"

    init(
        defaults: UserDefaults = .standard,
        preferences: Preferences = .shared,
        // nil when the binary runs outside its bundle (a bare `swift build` binary has
        // no Info.plist), which disables the comparison rather than mis-answering it.
        currentVersion: String? = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) {
        self.defaults = defaults
        self.preferences = preferences
        self.currentVersion = currentVersion
    }

    // MARK: - Policy, kept pure so the tests need no network

    /// "Once a day" with slack: 20 hours, so launching every morning counts as daily
    /// instead of forever falling a few minutes short of a strict 24.
    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > 20 * 60 * 60
    }

    static func verdict(
        for release: GitHubRelease, current: String?, skippedTag: String?, manual: Bool
    ) -> Verdict {
        guard
            let current = current.flatMap(AppVersion.init),
            let offered = AppVersion(release.tagName),
            offered > current
        else { return .upToDate }
        if !manual, let skipped = skippedTag.flatMap(AppVersion.init), skipped == offered {
            return .skipped
        }
        return .update(release)
    }

    /// A spot in ~/Downloads for the image, stepping aside from anything already
    /// there Finder-style ("pLayout-1.3 2.dmg") — an existing file is the user's,
    /// whatever it is, and is not this code's to overwrite.
    static func freeDestination(named name: String, in directory: URL? = nil) throws -> URL {
        let downloads = try directory
            ?? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent(
                "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }

    // MARK: - Entry points

    /// The launch check: only if enabled, only once a day, and held back a few seconds
    /// so its alert can never beat the document window it would sit in front of.
    func checkOnLaunch() {
        guard preferences.checkForUpdatesAutomatically,
              Self.isDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date)
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.check(manual: false)
        }
    }

    /// The menu item. Always checks, and unlike the launch check it answers out loud:
    /// "you're up to date" and "GitHub didn't answer" are both real answers to a
    /// question the user actually asked.
    func checkNow() {
        check(manual: true)
    }

    // MARK: - The check

    private func check(manual: Bool) {
        // The attempt is what is stamped, not the success — a Mac that is offline
        // every morning should stay quiet, not retry on every launch.
        defaults.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(
            url: Self.latestReleaseAPI,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data,
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
                    self.resolve(release, manual: manual)
                } else if manual {
                    self.sayCheckFailed(error)
                }
            }
        }.resume()
    }

    private func resolve(_ release: GitHubRelease, manual: Bool) {
        switch Self.verdict(
            for: release,
            current: currentVersion,
            skippedTag: defaults.string(forKey: Self.skippedTagKey),
            manual: manual
        ) {
        case .update:
            offer(release, manual: manual)
        case .upToDate where manual:
            sayUpToDate()
        case .upToDate, .skipped:
            break
        }
    }

    // MARK: - Talking to the user

    private func offer(_ release: GitHubRelease, manual: Bool) {
        let alert = NSAlert()
        alert.messageText = "pLayout \(Self.displayVersion(release.tagName)) is available"
        var info = "You're using \(currentVersion ?? "an unknown version")."
        if let notes = Self.notesExcerpt(release.body) {
            info += "\n\n\(notes)"
        }
        let asset = release.dmgAsset
        if asset != nil {
            info += "\n\nThe download lands in your Downloads folder and opens ready to drag into Applications."
        }
        alert.informativeText = info
        alert.addButton(withTitle: asset == nil ? "Open Release Page" : "Download & Open")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        if !manual {
            alert.addButton(withTitle: "Skip This Version")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let asset {
                download(asset)
            } else {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .alertThirdButtonReturn:
            defaults.set(release.tagName, forKey: Self.skippedTagKey)
        default:
            break
        }
    }

    private func download(_ asset: GitHubRelease.Asset) {
        URLSession.shared.downloadTask(with: asset.browserDownloadURL) { [weak self] tmp, response, error in
            // The temporary file dies when this handler returns, so the move cannot
            // hop to the main queue first — only the talking can.
            let landed: Result<URL, Error>
            if let tmp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                landed = Result {
                    let destination = try Self.freeDestination(named: asset.name)
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    return destination
                }
            } else {
                landed = .failure(error ?? URLError(.badServerResponse))
            }
            DispatchQueue.main.async {
                switch landed {
                case .success(let destination):
                    NSWorkspace.shared.open(destination)
                case .failure(let error):
                    self?.sayDownloadFailed(asset, error)
                }
            }
        }.resume()
    }

    private func sayUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "pLayout \(currentVersion ?? "") is the latest version."
        alert.runModal()
    }

    private func sayCheckFailed(_ error: Error?) {
        let alert = NSAlert()
        alert.messageText = "The update check didn't reach GitHub"
        alert.informativeText = (error?.localizedDescription).map { $0 + "\n\n" } ?? ""
        alert.informativeText += "You can look at the releases page yourself."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    private func sayDownloadFailed(_ asset: GitHubRelease.Asset, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The download didn't finish"
        alert.informativeText = error.localizedDescription
            + "\n\nYour browser can fetch the same file instead."
        alert.addButton(withTitle: "Download in Browser")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(asset.browserDownloadURL)
        }
    }

    /// "v1.3" reads as a git tag; the alert says "1.3", the way the app and the DMG
    /// name their versions.
    static func displayVersion(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// The first few meaningful lines of the release notes, so the alert says what the
    /// update *is* — trimmed hard, because an NSAlert is not a place to read markdown.
    static func notesExcerpt(_ body: String?, maxLines: Int = 5, maxCharacters: Int = 400) -> String? {
        guard let body else { return nil }
        let lines = body
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var excerpt = lines.prefix(maxLines).joined(separator: "\n")
        var truncated = lines.count > maxLines
        if excerpt.count > maxCharacters {
            excerpt = String(excerpt.prefix(maxCharacters))
            truncated = true
        }
        return truncated ? excerpt + "…" : excerpt
    }
}
