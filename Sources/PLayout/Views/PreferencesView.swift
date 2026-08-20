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
            section("Canvas") {
                HStack(spacing: 10) {
                    ColorPicker("", selection: canvasBackgroundColor, supportsOpacity: false)
                        .labelsHidden()
                    Text("Background of the board")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { preferences.canvasBackgroundColorHex = nil }
                        .disabled(preferences.canvasBackgroundColorHex == nil)
                }
                note(preferences.canvasBackgroundColorHex == nil
                    ? "The default follows light and dark mode. The board is behind the cards on the canvas (⇧⌘K); it is never exported or printed."
                    : "Used exactly as chosen, in both light and dark mode. The dot grid takes its own contrast from it, so it stays visible on a dark board as well as a pale one.")
            }
            section("Overview blocks") {
                HStack(spacing: 10) {
                    ColorPicker("", selection: groupOutlineColor, supportsOpacity: false)
                        .labelsHidden()
                    Text("Line round wells that match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { preferences.groupOutlineColorHex = nil }
                        .disabled(preferences.groupOutlineColorHex == nil)
                }
                HStack(spacing: 10) {
                    Text("Thickness")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $preferences.groupOutlineThickness,
                        in: Preferences.groupOutlineThicknessRange, step: 0.5
                    )
                    Text(String(format: "%.1f pt", preferences.groupOutlineThickness))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                BlockOutlinePreview(
                    color: preferences.groupOutlineColor(exportMode: false),
                    width: preferences.groupOutlineThickness,
                    tile: preferences.emptyWellFill(exportMode: false)
                )
                note("Drawn in Overview when “Group identical wells” is on. On a dense plate the line is capped at a quarter of the well, however thick it is set here.")
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
            set: { preferences.emptyWellColorHex = chosen($0, over: preferences.emptyWellFill(exportMode: false)) }
        )
    }

    /// The board's background is opaque, so unlike the empty-well swatch there is nothing
    /// to flatten it against — what the picker shows is what the board paints.
    private var canvasBackgroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: preferences.canvasBackground) },
            set: { preferences.canvasBackgroundColorHex = chosen($0, over: preferences.canvasBackground) }
        )
    }

    /// Same shape as the empty-well binding: the swatch shows the resolved default
    /// until a choice is made, so it never shows a colour the plate is not using.
    private var groupOutlineColor: Binding<Color> {
        Binding(
            get: {
                let ink = preferences.groupOutlineColor(exportMode: false)
                guard ink.alphaComponent < 1 else { return Color(nsColor: ink) }
                let flat = NSColor.windowBackgroundColor.blended(
                    withFraction: ink.alphaComponent, of: ink.withAlphaComponent(1)
                ) ?? ink
                return Color(nsColor: flat)
            },
            set: { preferences.groupOutlineColorHex = chosen($0, over: preferences.groupOutlineColor(exportMode: false)) }
        )
    }

    /// A colour only counts as *chosen* when it differs from what is already showing.
    ///
    /// `ColorPicker` echoes its binding back through `set` as a concrete colour, so
    /// without this merely opening the Settings window froze the appearance-following
    /// default into a fixed hex — turning "no opinion" into an opinion nobody expressed,
    /// and lighting up Reset to Default for a colour the user never picked.
    private func chosen(_ new: Color, over current: NSColor) -> String? {
        let hex = NSColor(new).hexString
        return hex == current.hexString ? nil : hex
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

/// Three wells with the block outline round them — the setting shown rather than
/// described, since a colour and a line weight are exactly the two things a sentence
/// cannot convey.
private struct BlockOutlinePreview: View {
    let color: NSColor
    let width: Double
    let tile: NSColor

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle()
                    .fill(Color(nsColor: tile))
                    .frame(width: 34, height: 24)
                    .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .overlay(Rectangle().strokeBorder(Color(nsColor: color), lineWidth: width))
        .padding(.vertical, 2)
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
