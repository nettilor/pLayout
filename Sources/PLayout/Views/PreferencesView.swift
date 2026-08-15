import AppKit
import SwiftUI

/// The ⌘, window. App-wide display settings only — anything that belongs to the
/// experiment itself lives in the document and its sidebar, so it travels with the
/// `.plate` file rather than following whoever opens it.
struct PreferencesView: View {
    @ObservedObject private var preferences = Preferences.shared

    // Laid out directly rather than with `Form`. A grouped Form gives its control the
    // trailing column, which strands each radio button at the far edge of the window
    // with its label an inch away on the left; `.fixedSize()` to pull it back turns the
    // radio group horizontal and blows the window's width out. A `GroupBox` gives the
    // same look with none of that.
    // Tabs, since the seventh section arrived: a single column had grown past the
    // height of a 13" screen. The preview sits *below* the tabs rather than in
    // one, because every tab changes something it shows — and a preview below
    // the fold might as well not exist.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                displayTab
                    .tabItem { Label("Display", systemImage: "square.grid.3x3") }
                coloursTab
                    .tabItem { Label("Colours", systemImage: "paintpalette") }
                typeTab
                    .tabItem { Label("Plate Text", systemImage: "textformat") }
            }
            .padding([.horizontal, .top], 14)

            // Shown rather than described: what these settings are really about is
            // how they look across light and dark conditions at once, which is
            // exactly what a sentence cannot convey.
            VStack(alignment: .leading, spacing: 6) {
                section("Preview") {
                    WellPreview(
                        textStyle: preferences.wellTextStyle,
                        markerStyle: preferences.activeMarkerStyle,
                        customEmpty: preferences.customEmptyWellColor,
                        labelFont: preferences.canvasFont(
                            ofSize: 11 * CGFloat(preferences.canvasFontScale), weight: .semibold
                        )
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
            HStack {
                Button("Restore Defaults") { preferences.resetToDefaults() }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 460, height: 660)
    }

    private var displayTab: some View {
        tabBody {
            section("Well labels") {
                choice("Text colour", selection: $preferences.wellTextStyle)
                note(preferences.wellTextStyle.note)
            }
            section("Factor being painted") {
                choice("Active marker", selection: $preferences.activeMarkerStyle)
                note(preferences.activeMarkerStyle.note)
            }
            section("New documents") {
                choice("Well shape", selection: $preferences.newDocumentWellShape)
                note(preferences.newDocumentWellShape.note)
            }
            section("Sidebar") {
                Toggle(
                    "Show each factor's number of conditions",
                    isOn: $preferences.showFactorConditionCounts
                )
                .toggleStyle(.checkbox)
                .font(.callout)
                note("A count at the end of every factor row, the way conditions show how many wells they cover.")
            }
        }
    }

    private var coloursTab: some View {
        tabBody {
            section("New conditions") {
                choice("Colours", selection: $preferences.newConditionColors)
                note(preferences.newConditionColors.note)
            }
            section("Empty wells") {
                HStack(spacing: 10) {
                    ColorPicker("", selection: emptyWellColor, supportsOpacity: false)
                        .labelsHidden()
                    Text("Background of wells with no value")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { preferences.emptyWellColorHex = nil }
                        .disabled(preferences.emptyWellColorHex == nil)
                }
                note(preferences.emptyWellColorHex == nil
                    ? "The default follows light and dark mode."
                    : "A chosen colour is used as it is, everywhere — light mode, dark mode, Overview's backdrop, exports and print.")
            }
        }
    }

    private var typeTab: some View {
        tabBody {
            section("Plate text") {
                HStack(spacing: 10) {
                    Text("Font")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $preferences.canvasFontFamily) {
                        Text("System").tag(String?.none)
                        Divider()
                        ForEach(Self.fontFamilies, id: \.self) { family in
                            Text(family).tag(String?.some(family))
                        }
                    }
                    .labelsHidden()
                }
                HStack(spacing: 10) {
                    Text("Size")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Slider(value: $preferences.canvasFontScale, in: 0.7...1.8, step: 0.05)
                    Text("\(Int((preferences.canvasFontScale * 100).rounded())) %")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                note("Applies to the plate — wells, headers and the line key — and travels into exports and print. The window's own controls keep the system font.")
            }
        }
    }

    /// A tab is its sections in the same column the single-page window used —
    /// scrolling as a safety net, never as the design.
    private func tabBody(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted()

    /// Shows the resolved default when nothing is chosen, so the swatch is never a
    /// lie; writing to it makes the choice explicit. The default is a faint
    /// translucent grey, which the picker's swatch would render over its own dark
    /// backing as near-black — so it is flattened against the window background
    /// first, which is what an empty well actually sits on.
    private var emptyWellColor: Binding<Color> {
        Binding(
            get: {
                let fill = preferences.emptyWellFill(exportMode: false)
                guard fill.alphaComponent < 1 else { return Color(nsColor: fill) }
                let flat = NSColor.windowBackgroundColor.blended(
                    withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1)
                ) ?? fill
                return Color(nsColor: flat)
            },
            set: { preferences.emptyWellColorHex = NSColor($0).hexString }
        )
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func choice<Option: DisplayChoice>(
        _ title: String, selection: Binding<Option>
    ) -> some View where Option.AllCases: RandomAccessCollection {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Option.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row of wells in the palette's own colours, from its lightest to its darkest, each
/// drawn the way the plate draws the active factor's line: marker then label.
private struct WellPreview: View {
    let textStyle: WellTextStyle
    let markerStyle: ActiveMarkerStyle
    let customEmpty: NSColor?
    let labelFont: NSFont

    private static let samples: [(hex: String, name: String)] = [
        ("#F1CE63", "Vehicle"),
        ("#8CD17D", "Low"),
        ("#F28E2B", "Mid"),
        ("#5889BC", "High"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.samples, id: \.hex) { sample in
                let colour = NSColor(hex: sample.hex) ?? .gray
                well(
                    fill: colour,
                    marker: markerStyle == .deeperShade ? colour.contrastingShade : colour.labelInk(textStyle),
                    ink: colour.labelInk(textStyle),
                    name: sample.name
                )
            }
            // Overview's neutral tile has no colour of its own to contrast against, so
            // it follows the ink rather than the other way round.
            well(
                fill: customEmpty ?? (textStyle.prefersDarkNeutral
                    ? NSColor(white: 0.32, alpha: 1)
                    : NSColor.quaternaryLabelColor.withAlphaComponent(0.18)),
                marker: nil,
                ink: customEmpty.map { $0.labelInk(textStyle) } ?? textStyle.neutralInk,
                name: "Overview"
            )
        }
    }

    private func well(fill: NSColor, marker: NSColor?, ink: NSColor, name: String) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(Color(nsColor: marker ?? .clear))
                .frame(width: 6, height: 13)
            Text(name)
                .font(Font(labelFont))
                .lineLimit(1)
                .foregroundStyle(Color(nsColor: ink))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: fill)))
    }
}
