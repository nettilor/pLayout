import AppKit

/// Which shape the tidy CSV takes: a column per factor, or a row per well per drug.
///
/// Only offered when the document has a factor made by dilution — with nothing to
/// collapse the two shapes are the same file, and a control that cannot change the
/// output is noise in a dialog someone is trying to get through. The workbook makes the
/// same decision without asking, by adding its long sheet only when there is one.
enum TidyShape: String, CaseIterable {
    case wide
    case long

    var label: String {
        switch self {
        case .wide: return "One column per factor"
        case .long: return "One row per well, per drug"
        }
    }

    var detail: String {
        switch self {
        case .wide:
            return "Every factor gets a column. Two drugs means two columns, each blank"
                + " where the other is not."
        case .long:
            return "Compound, Concentration and Unit columns instead — group by compound"
                + " and plot straight against concentration."
        }
    }

    private static let defaultsKey = "tidyExportShape"

    /// Remembered between exports, like the workbook's arrangement: analysis downstream
    /// expects the same shape every time.
    static var remembered: TidyShape {
        AppDefaults.store.string(forKey: defaultsKey).flatMap(TidyShape.init(rawValue:)) ?? .wide
    }

    func remember() {
        AppDefaults.store.set(rawValue, forKey: Self.defaultsKey)
    }
}

final class TidyExportAccessory: NSView {

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    var selectedShape: TidyShape {
        let options = TidyShape.allCases
        let index = popup.indexOfSelectedItem
        guard options.indices.contains(index) else { return .wide }
        return options[index]
    }

    init(selected: TidyShape) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 64))

        let label = NSTextField(labelWithString: "Shape")
        label.frame = NSRect(x: 20, y: 36, width: 48, height: 18)
        addSubview(label)

        popup.addItems(withTitles: TidyShape.allCases.map(\.label))
        popup.frame = NSRect(x: 68, y: 32, width: 330, height: 25)
        popup.target = self
        popup.action = #selector(shapeChanged)
        if let index = TidyShape.allCases.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
        addSubview(popup)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 70, y: 4, width: 330, height: 26)
        detail.maximumNumberOfLines = 2
        addSubview(detail)
        shapeChanged()
    }

    private let detail = NSTextField(labelWithString: "")

    /// The panel says what each shape does rather than making you export one to find
    /// out — the same reason `WorkbookLayout` carries a `detail` beside its `label`.
    @objc private func shapeChanged() {
        detail.stringValue = selectedShape.detail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
