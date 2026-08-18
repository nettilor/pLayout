import AppKit

/// Sits inside the PNG/PDF save panel while the plate is showing Overview block
/// outlines, so whether the figure keeps them is decided as the figure is made.
///
/// It appears only when there is something to decide — the outlines are on — for the
/// same reason the workbook panel hides its plates row in a single-plate document: a
/// control that changes nothing is noise in a dialog someone is trying to get through.
final class ImageExportAccessory: NSView {

    private let check = NSButton(
        checkboxWithTitle: "Include the block outlines", target: nil, action: nil
    )

    var includesGroups: Bool { check.state == .on }

    private static let defaultsKey = "imageExportIncludesGroupOutlines"

    /// Remembered between exports, like the workbook's arrangement: a figure for a
    /// paper tends to want the same treatment every time.
    static var remembered: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func remember(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    init(includesGroups: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 46))
        check.state = includesGroups ? .on : .off
        check.frame = NSRect(x: 20, y: 22, width: 340, height: 20)
        addSubview(check)

        let detail = NSTextField(
            labelWithString: "The lines round wells that share the same conditions."
        )
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 39, y: 4, width: 330, height: 15)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
