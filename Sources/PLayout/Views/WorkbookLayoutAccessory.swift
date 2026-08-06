import AppKit

/// Sits inside the Excel save panel so the sheet arrangement is chosen at the moment
/// of exporting, rather than buried in a preference the user has to find first.
final class WorkbookLayoutAccessory: NSView {

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detail = NSTextField(labelWithString: "")

    var selectedLayout: WorkbookLayout {
        let options = WorkbookLayout.allCases
        let index = popup.indexOfSelectedItem
        guard options.indices.contains(index) else { return .sheetPerFactor }
        return options[index]
    }

    init(selected: WorkbookLayout) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 62))

        let label = NSTextField(labelWithString: "Plate maps:")
        label.alignment = .right
        label.frame = NSRect(x: 12, y: 33, width: 82, height: 17)
        addSubview(label)

        popup.addItems(withTitles: WorkbookLayout.allCases.map(\.label))
        popup.frame = NSRect(x: 98, y: 28, width: 288, height: 25)
        popup.target = self
        popup.action = #selector(selectionChanged)
        if let index = WorkbookLayout.allCases.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
        addSubview(popup)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 101, y: 8, width: 285, height: 15)
        addSubview(detail)

        updateDetail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func selectionChanged() {
        updateDetail()
    }

    private func updateDetail() {
        detail.stringValue = selectedLayout.detail
    }
}
