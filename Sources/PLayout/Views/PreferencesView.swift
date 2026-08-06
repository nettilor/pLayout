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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Well labels") {
                        choice("Text colour", selection: $preferences.wellTextStyle)
                        note(preferences.wellTextStyle.note)
                    }
                    section("Factor being painted") {
                        choice("Active marker", selection: $preferences.activeMarkerStyle)
                        note(preferences.activeMarkerStyle.note)
                    }
                    // Shown rather than described: what both settings are really about
                    // is how they look across light and dark conditions at once, which
                    // is exactly what a sentence cannot convey.
                    section("Preview") {
                        WellPreview(
                            textStyle: preferences.wellTextStyle,
                            markerStyle: preferences.activeMarkerStyle
                        )
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Restore Defaults") { preferences.resetToDefaults() }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 460, height: 540)
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
                    marker: markerStyle == .deeperShade ? colour.deepened : colour.labelInk(textStyle),
                    ink: colour.labelInk(textStyle),
                    name: sample.name
                )
            }
            // Overview's neutral tile has no colour of its own to contrast against, so
            // it follows the ink rather than the other way round.
            well(
                fill: textStyle.prefersDarkNeutral
                    ? NSColor(white: 0.32, alpha: 1)
                    : NSColor.quaternaryLabelColor.withAlphaComponent(0.18),
                marker: nil,
                ink: textStyle.neutralInk,
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
                .font(.system(size: 11, weight: .semibold))
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
