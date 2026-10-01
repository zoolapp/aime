import AppKit
import SwiftUI

/// AIME Settings' own look: a tinted canvas, white (or raised dark) cards with hairline
/// borders, one trailing control column and a brand accent — instead of the stock
/// grouped form.
enum Theme {
    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) {
            let value = $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }

    private static func overlay(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }

    // Surfaces are neutral, close to the system's own (a beige "paper" canvas read as
    // yellow and dated); the brand lives in the accent: vermilion #B64032, ink #242321.
    // Paper #F7F2E9 is kept for brand moments (onboarding, icon tiles), not for panes.
    /// Pane background.
    static let canvas = dynamic(light: (246/255, 246/255, 245/255), dark: (28/255, 28/255, 29/255))
    static let sidebar = dynamic(light: (239/255, 239/255, 238/255), dark: (22/255, 22/255, 23/255))
    /// Raised surface (cards).
    static let card = dynamic(light: (1, 1, 1), dark: (40/255, 40/255, 42/255))
    static let cardBorder = overlay(light: 0.08, dark: 0.09)
    static let divider = overlay(light: 0.06, dark: 0.07)
    /// Fills (prominent buttons, toggles, selection). Dark mode is a touch lighter and still
    /// carries white labels at ≥ 4.5:1.
    static let accent = dynamic(light: (182/255, 64/255, 50/255), dark: (196/255, 80/255, 63/255))
    /// Accent as text or icon on a surface: ≥ 4.5:1 on cards in both modes.
    static let accentText = dynamic(light: (182/255, 64/255, 50/255), dark: (224/255, 117/255, 96/255))
    static let onAccent = Color.white
    static let text = dynamic(light: (36/255, 35/255, 33/255), dark: (242/255, 242/255, 240/255))
    static let secondaryText = dynamic(light: (107/255, 106/255, 103/255), dark: (163/255, 163/255, 160/255))
    static let paper = Color(red: 247/255, green: 242/255, blue: 233/255)
    /// Neutral tile behind pane and sidebar icons.
    static let iconTile = dynamic(light: (36/255, 35/255, 33/255), dark: (58/255, 58/255, 60/255))
    static let success = dynamic(light: (0.111, 0.530, 0.260), dark: (0.374, 0.829, 0.497))
    static let warning = dynamic(light: (0.664, 0.372, 0.089), dark: (0.967, 0.676, 0.301))

    static let cardRadius: CGFloat = 12
    static let contentWidth: CGFloat = 760
    static let gutter: CGFloat = 28

    /// The one content column every pane uses, computed from the pane's full width (not
    /// the scroll view's, which changes when a scroller appears) so nothing shifts when
    /// switching panes.
    static func column(in width: CGFloat) -> (leading: CGFloat, width: CGFloat) {
        let columnWidth = max(320, min(contentWidth, width - gutter * 2 - 16))
        return (max(gutter, (width - columnWidth) / 2), columnWidth)
    }
}

/// Places pane content in the shared column. `scrolls: false` for panes that manage
/// their own height (editors, tables).
struct PaneColumn<Content: View>: View {
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let column = Theme.column(in: proxy.size.width)
            if scrolls {
                ScrollView {
                    content
                        .frame(width: column.width, alignment: .leading)
                        .padding(.leading, column.leading)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                content
                    .frame(width: column.width, alignment: .leading)
                    .padding(.leading, column.leading)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
    }
}

extension ContainerValues {
    /// A section (or row) that draws without the card chrome, e.g. the pane header.
    @Entry var isPlain = false
}

/// Card container used by the form style and by hand-built panes.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardBorder))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Renders `Form { Section { … } }` as titled cards with hairline separators.
struct CardFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaneColumn {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: configuration.content) { section in
                    let plain = section.content.first?.containerValues.isPlain ?? false
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.header.isEmpty {
                            section.header
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .textCase(nil)
                                .padding(.horizontal, 4)
                        }
                        if plain {
                            section.content
                        } else {
                            Card {
                                let rows = section.content
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    row.padding(.horizontal, 16).padding(.vertical, 11)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if index < rows.count - 1 {
                                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 16)
                                    }
                                }
                            }
                        }
                        if !section.footer.isEmpty {
                            section.footer.font(.caption).foregroundStyle(Theme.secondaryText).padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
        .toggleStyle(TrailingSwitchToggleStyle())
        .labeledContentStyle(RowLabeledContentStyle())
    }
}

extension FormStyle where Self == CardFormStyle {
    static var cards: CardFormStyle { CardFormStyle() }
}

/// Label on the left, switch on the trailing control line.
struct TrailingSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
    }
}

/// Label left, content right-aligned — the row layout of every card.
struct RowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
    }
}

extension View {
    /// Full-height panes (YAML editor, phrase table) in the shared column.
    func paneColumn() -> some View { PaneColumn(scrolls: false) { self } }
}
