import Combine
import Foundation

/// A named plate size the user saved for reuse. The name lives here rather than on
/// `PlateFormat` so that formats stay pure geometry — every "did the format change"
/// guard in the app compares them by dimensions alone.
struct PlateTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var rows: Int
    var cols: Int

    init(id: UUID = UUID(), name: String, rows: Int, cols: Int) {
        self.id = id
        self.name = name
        self.rows = rows
        self.cols = cols
    }

    init(id: UUID = UUID(), name: String, format: PlateFormat) {
        self.init(id: id, name: name, rows: format.rows, cols: format.cols)
    }

    var format: PlateFormat { PlateFormat(rows: rows, cols: cols) }

    var subtitle: String { "\(format.wellCount) wells · \(rows)×\(cols)" }
}

/// App-wide list of custom plate sizes, shared by every open document.
final class PlateTemplateStore: ObservableObject {
    static let shared = PlateTemplateStore()

    @Published private(set) var templates: [PlateTemplate] = []

    private let defaults: UserDefaults
    private let storageKey = "customPlateTemplates"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reading

    /// The name to show for a format: a matching template's name, else the well count.
    func displayName(for format: PlateFormat) -> String {
        if format.isStandard { return format.name }
        if let match = templates.first(where: { $0.format == format }) { return match.name }
        return format.name
    }

    func detailedName(for format: PlateFormat) -> String {
        let name = displayName(for: format)
        return name == format.name ? format.detailedName : "\(name)  (\(format.rows)×\(format.cols))"
    }

    func template(matching format: PlateFormat) -> PlateTemplate? {
        templates.first { $0.format == format }
    }

    // MARK: - Writing

    /// Returns nil when the shape is not worth saving: standard plates already have a
    /// name of their own, and a duplicate would show up twice in the format menu.
    @discardableResult
    func add(name: String, format: PlateFormat) -> PlateTemplate? {
        guard canSave(format) else { return nil }
        let template = PlateTemplate(name: uniqueName(from: name, format: format), format: format)
        templates.append(template)
        save()
        return template
    }

    func canSave(_ format: PlateFormat) -> Bool {
        !format.isStandard && template(matching: format) == nil
    }

    func remove(_ id: UUID) {
        templates.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].name = trimmed
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Falls back to a descriptive name, and disambiguates against what is already saved.
    private func uniqueName(from proposed: String, format: PlateFormat) -> String {
        var base = proposed.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "\(format.rows)×\(format.cols) plate" }
        let existing = Set(templates.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PlateTemplate].self, from: data)
        else { return }
        // Drop anything out of bounds, any shape that is really a standard plate, and
        // any duplicate shape — all three would produce confusing format menus.
        var seen = Set<PlateFormat>()
        templates = decoded.filter { template in
            guard PlateFormat.rowRange.contains(template.rows),
                  PlateFormat.columnRange.contains(template.cols),
                  !template.format.isStandard,
                  !seen.contains(template.format)
            else { return false }
            seen.insert(template.format)
            return true
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
