import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let plateLayout = UTType(exportedAs: "com.nettilor.playout")
}

final class PlateDocument: ReferenceFileDocument {
    typealias Snapshot = Layout

    @Published var layout: Layout

    static var readableContentTypes: [UTType] { [.plateLayout] }
    static var writableContentTypes: [UTType] { [.plateLayout] }

    init() {
        layout = .starter()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        layout = try JSONDecoder().decode(Layout.self, from: data)
    }

    func snapshot(contentType: UTType) throws -> Layout { layout }

    func fileWrapper(snapshot: Layout, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
    }

    /// Single funnel for every edit, so undo/redo is uniform and coalescing-free.
    func mutate(_ actionName: String, undoManager: UndoManager?, _ change: (inout Layout) -> Void) {
        var updated = layout
        change(&updated)
        guard updated != layout else { return }
        replace(with: updated, actionName: actionName, undoManager: undoManager)
    }

    private func replace(with new: Layout, actionName: String, undoManager: UndoManager?) {
        let previous = layout
        layout = new
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.replace(with: previous, actionName: actionName, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
    }
}
