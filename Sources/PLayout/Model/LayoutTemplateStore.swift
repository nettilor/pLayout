import AppKit
import Combine
import Foundation

/// App-wide list of whole-layout starting points: complete `.plate` files kept in
/// Application Support, one per template. A new document "from template" is an
/// untitled duplicate of that file through the standard document machinery, so
/// the template itself can never be edited by accident.
final class LayoutTemplateStore: ObservableObject {
    static let shared = LayoutTemplateStore()

    struct Template: Identifiable, Equatable {
        var name: String
        var url: URL
        var id: URL { url }
    }

    @Published private(set) var templates: [Template] = []

    private let directory: URL

    /// The directory is injectable so tests never touch the real library.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pLayout/Templates", isDirectory: true)
        refresh()
    }

    func refresh() {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        templates = found
            .filter { $0.pathExtension == "plate" }
            .map { Template(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves the layout as a template, overwriting one of the same name — saving
    /// again under a name *is* updating that template.
    func save(_ layout: Layout, named name: String) throws {
        let clean = Self.sanitized(name)
        guard !clean.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: directory.appendingPathComponent("\(clean).plate"))
        refresh()
    }

    func delete(_ template: Template) {
        try? FileManager.default.removeItem(at: template.url)
        refresh()
    }

    /// Opens a new untitled document seeded with the template — a duplicate, so
    /// saving it prompts for a location and the template file stays untouched.
    func openNewDocument(from template: Template) {
        do {
            try NSDocumentController.shared.duplicateDocument(
                withContentsOf: template.url, copying: true, displayName: template.name
            )
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open the template"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// A file name, not a path: separators and leading dots have no business in one.
    static func sanitized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
