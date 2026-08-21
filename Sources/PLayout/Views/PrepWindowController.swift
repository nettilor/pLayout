import AppKit
import SwiftUI

/// Which document's prep window is frontmost.
///
/// `PlateCommands` observes this so ⌘P can retarget without depending on the focused
/// *scene*: the prep window is a hand-built `NSWindow` rather than a SwiftUI scene, so
/// `@FocusedObject` cannot be relied on to resolve while it is key — and a Print item
/// that greys out, or prints the wrong thing, reads as a bug the first time it happens.
final class PrepWindowRegistry: ObservableObject {
    static let shared = PrepWindowRegistry()

    /// Weak, so a closed document is not kept alive by having once been frontmost —
    /// and therefore hand-published, since `@Published` cannot be applied to a weak
    /// property.
    private weak var storage: PlateEditor?

    var keyEditor: PlateEditor? { storage }

    private init() {}

    func noteBecameKey(_ editor: PlateEditor) {
        guard storage !== editor else { return }
        objectWillChange.send()
        storage = editor
    }

    func noteResignedKey(_ editor: PlateEditor) {
        guard storage === editor else { return }
        objectWillChange.send()
        storage = nil
    }
}

/// The prep sheet's window.
///
/// The first `NSWindowController` in the project, and deliberately so rather than by
/// accident: the four existing dialogs are SwiftUI sheets, but this one has to sit beside
/// the plate and stay open while you paint, and it has to be able to *be* the key window
/// so ⌘P can target it. Owned by the `PlateEditor` that created it, which makes it
/// per-document by construction — no scene plumbing, and no guessing which document a
/// window belongs to.
final class PrepWindowController: NSWindowController, NSWindowDelegate {

    /// Weak, not `unowned`. The document window's close tears this down, and during
    /// `PlateEditor.deinit` an unowned read traps outright — `windowWillClose` fires
    /// from `close()` and would read an object already being destroyed.
    private weak var editor: PlateEditor?
    private var documentWindowObserver: NSObjectProtocol?

    init(editor: PlateEditor, title: String) {
        self.editor = editor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prep — \(title)"
        window.minSize = NSSize(width: 560, height: 420)
        // The document may be closed and reopened; releasing on close would leave the
        // controller holding a freed window.
        window.isReleasedWhenClosed = false
        // A hosting *controller*, not an `NSHostingView` set as the content view: with
        // the bare view, everything SwiftUI-native took up its layout space and drew
        // nothing at all. Verified in the running app.
        window.contentViewController = NSHostingController(rootView: PrepView(editor: editor))
        // A hosting controller sizes the window to what SwiftUI thinks the content wants,
        // which here is far too narrow and taller than the screen. Same lesson as the
        // document window (HANDOFF §2): the size has to be stated, and stated in both
        // places — `idealWidth` on the view and an explicit content size here.
        window.setContentSize(NSSize(width: 660, height: 760))
        // Set last, so it restores a saved frame *over* that default rather than being
        // overwritten by it. One shared name, taken by whichever prep window opens
        // first: AppKit's Bool result says whether the name was free, so a second
        // document's prep window simply goes without frame autosave rather than
        // silently stealing the first one's. A per-document name was tried and was
        // worse — it was derived from the object's identity, which changes every
        // launch, so no prep window ever restored its frame at all.
        _ = window.setFrameAutosaveName("PipettingPrepWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The window is built when the sheet is first opened, which for a new document is
    /// often before it has ever been saved — so the title has to be refreshed rather
    /// than fixed at birth, or it says "Untitled" for the rest of the session.
    func refreshTitle(_ title: String) {
        window?.title = "Prep — \(title)"
    }

    /// Hands this window the document's undo manager.
    ///
    /// It is a hand-built `NSWindow`, not a document window, so nothing in the responder
    /// chain above it offers one: every prep edit *was* undoable, but ⌘Z while the prep
    /// window was key did nothing at all and Edit ▸ Undo stayed greyed out — you had to
    /// click back to the plate first to undo what you had just typed here.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let editor else { return }
        PrepWindowRegistry.shared.noteBecameKey(editor)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let editor else { return }
        PrepWindowRegistry.shared.noteResignedKey(editor)
    }

    func windowWillClose(_ notification: Notification) {
        guard let editor else { return }
        PrepWindowRegistry.shared.noteResignedKey(editor)
    }

    /// Ties this window to the document window it was opened from.
    ///
    /// Nothing in AppKit says a hand-built window belongs to a document, and the editor's
    /// `deinit` cannot do it: the hosting controller's SwiftUI content holds the editor
    /// strongly, so editor → controller → window → content → editor is a cycle and the
    /// editor is never released. Left alone, closing the document leaves this window on
    /// screen still writing to a document that is no longer open — edits that go nowhere
    /// and are never saved. So the tie is made explicitly, and closing the document
    /// closes this and breaks the cycle.
    func follow(documentWindow: NSWindow?) {
        guard let documentWindow, documentWindowObserver == nil else { return }
        documentWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: documentWindow, queue: .main
        ) { [weak self] _ in self?.documentWindowClosed() }
    }

    private func documentWindowClosed() {
        if let documentWindowObserver {
            NotificationCenter.default.removeObserver(documentWindowObserver)
        }
        documentWindowObserver = nil
        if let editor { PrepWindowRegistry.shared.noteResignedKey(editor) }
        window?.delegate = nil
        // Dropping the content is what actually breaks the cycle: it is the SwiftUI view
        // inside it that holds the editor.
        window?.contentViewController = nil
        close()
        let editor = self.editor
        self.editor = nil
        // Hopped, so this controller is not deallocated part-way through its own method
        // when the editor lets go of its last reference to it.
        DispatchQueue.main.async { editor?.releasePrepWindow() }
    }

    deinit {
        if let documentWindowObserver {
            NotificationCenter.default.removeObserver(documentWindowObserver)
        }
    }
}
