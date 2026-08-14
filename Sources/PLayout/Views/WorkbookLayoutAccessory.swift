import AppKit

/// Sits inside the Excel save panel so the sheet arrangement is chosen at the moment
/// of exporting, rather than buried in a preference the user has to find first.
final class WorkbookLayoutAccessory: NSView {

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detail = NSTextField(labelWithString: "")
    private let offersScope: Bool

    var selectedLayout: WorkbookLayout {
        let options = WorkbookLayout.allCases
        let index = popup.indexOfSelectedItem
        guard options.indices.contains(index) else { return .sheetPerFactor }
        return options[index]
    }

    var selectedScope: WorkbookScope {
        guard offersScope else { return .allPlates }
        let options = WorkbookScope.allCases
        let index = scopePopup.indexOfSelectedItem
        guard options.indices.contains(index) else { return .allPlates }
        return options[index]
    }

    init(
        selected: WorkbookLayout, scope: WorkbookScope,
        plateCount: Int, activePlateName: String
    ) {
        // The plates row only exists when there is a choice to make: a single-plate
        // document exports the same workbook either way, and a control that changes
        // nothing is noise in a dialog someone is trying to get through.
        offersScope = plateCount > 1
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: offersScope ? 96 : 62))
        let top: CGFloat = offersScope ? 34 : 0

        let label = NSTextField(labelWithString: "Plate maps:")
        label.alignment = .right
        label.frame = NSRect(x: 12, y: 33 + top, width: 82, height: 17)
        addSubview(label)

        popup.addItems(withTitles: WorkbookLayout.allCases.map(\.label))
        popup.frame = NSRect(x: 98, y: 28 + top, width: 356, height: 25)
        popup.target = self
        popup.action = #selector(selectionChanged)
        if let index = WorkbookLayout.allCases.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
        addSubview(popup)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 101, y: 8 + top, width: 360, height: 15)
        addSubview(detail)

        if offersScope {
            let scopeLabel = NSTextField(labelWithString: "Plates:")
            scopeLabel.alignment = .right
            scopeLabel.frame = NSRect(x: 12, y: 11, width: 82, height: 17)
            addSubview(scopeLabel)

            let name = activePlateName.count > 26
                ? activePlateName.prefix(25) + "…"
                : activePlateName
            scopePopup.addItems(withTitles: ["All plates", "Just “\(name)”"])
            scopePopup.frame = NSRect(x: 98, y: 6, width: 356, height: 25)
            if let index = WorkbookScope.allCases.firstIndex(of: scope) {
                scopePopup.selectItem(at: index)
            }
            addSubview(scopePopup)
        }

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
