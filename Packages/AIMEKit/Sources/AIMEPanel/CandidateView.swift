public import AppKit

/// What the panel shows. Built from a librime context snapshot by the input method,
/// or from sample data by the settings preview.
public struct PanelState: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public var label: String
        public var text: String
        public var comment: String
        /// SF Symbol drawn before the text (menu pages).
        public var symbol: String?
        public init(label: String, text: String, comment: String = "", symbol: String? = nil) {
            self.label = label
            self.text = text
            self.comment = comment
            self.symbol = symbol
        }
    }

    public var preedit: String
    /// Selected (converted) part of the preedit, as a UTF-16 range.
    public var preeditSelection: NSRange
    public var candidates: [Candidate]
    public var highlightedIndex: Int
    public var pageNumber: Int
    public var isLastPage: Bool
    /// A short status message (e.g. "中" / "A") shown instead of candidates.
    public var status: String?
    /// The status is work in progress (an AI action): drawn small, and the panel adds a
    /// moving glow around it.
    public var busy = false
    /// An AI layer (its action list, the running request, the results): the panel wears
    /// the turning ring of colour.
    public var glow = false
    /// A fainter note after the status ("Esc 取消").
    public var statusHint = ""
    /// A small solid chip before the status ("中" / "英" on the draft hint).
    public var statusBadge: String?
    /// Menu pages: a caption above the items, a two-column grid instead of the theme's
    /// layout, or a forced one-per-line list.
    public var title: String?
    public var presentation: Presentation = .candidates
    /// Shows the small AIME button at the trailing edge (opens the quick menu).
    public var showsMenuButton = false

    /// `paragraphs` is a list whose items wrap onto several lines (AI results): the
    /// highlighted one shows up to `paragraphLines` lines, the others a two-line preview.
    public enum Presentation: Sendable, Equatable { case candidates, grid, list, row, paragraphs }
    public static let paragraphLines = 8
    public static let paragraphWidth = 560.0

    /// Symbol keyboard: category tabs over a fixed grid of cells (`candidates` are the
    /// visible cells), with a scroll position and a key hint.
    public struct Board: Sendable, Equatable {
        public var tabs: [String]
        public var selectedTab: Int
        public var columns: Int
        public var visibleRows: Int
        public var firstRow: Int
        public var totalRows: Int
        public var hint: String
        /// Key that picks each visible cell ("q", "w", …), shown on the cell.
        public var keyHints: [String]

        public init(tabs: [String], selectedTab: Int, columns: Int, visibleRows: Int, firstRow: Int, totalRows: Int,
                    hint: String = "", keyHints: [String] = []) {
            self.keyHints = keyHints
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.columns = columns
            self.visibleRows = visibleRows
            self.firstRow = firstRow
            self.totalRows = totalRows
            self.hint = hint
        }
    }
    public var board: Board?

    /// The main action of a menu page: a full-width row above the items with its key
    /// ("Space") shown as a keycap. The panel adds a glow around it.
    public struct Hero: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var symbol: String
        public var key: String
        public init(title: String, detail: String = "", symbol: String, key: String) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.key = key
        }
    }
    public var hero: Hero?

    public init(
        preedit: String = "", preeditSelection: NSRange = NSRange(location: 0, length: 0),
        candidates: [Candidate] = [], highlightedIndex: Int = 0, pageNumber: Int = 0, isLastPage: Bool = true,
        status: String? = nil, title: String? = nil, presentation: Presentation = .candidates, showsMenuButton: Bool = false
    ) {
        self.preedit = preedit
        self.preeditSelection = preeditSelection
        self.candidates = candidates
        self.highlightedIndex = highlightedIndex
        self.pageNumber = pageNumber
        self.isLastPage = isLastPage
        self.status = status
        self.title = title
        self.presentation = presentation
        self.showsMenuButton = showsMenuButton
    }

    public var isEmpty: Bool { preedit.isEmpty && candidates.isEmpty && status == nil }

    /// Sample content for previews and screenshots.
    public static let sample = PanelState(
        preedit: "zhi neng ti",
        preeditSelection: NSRange(location: 0, length: 11),
        candidates: [
            .init(label: "1", text: "智能体"),
            .init(label: "2", text: "只能"),
            .init(label: "3", text: "智能", comment: "zhi neng"),
            .init(label: "4", text: "职能"),
            .init(label: "5", text: "Agent", comment: "英"),
        ],
        highlightedIndex: 0
    )
}

/// Draws the candidate list with Core Text. No Auto Layout, no SwiftUI: layout is a
/// single pass over a handful of attributed strings, cheap enough to run per keystroke.
public final class CandidateView: NSView {
    public var theme: PanelTheme = .fallback { didSet { fonts.removeAll(); symbolImages.removeAll(); cachedLineMetrics = nil; invalidate() } }
    public var state: PanelState = PanelState() { didSet { if state != oldValue { invalidate() } } }
    /// Draw the preedit row even when `inline_preedit` is on (settings preview).
    public var forcePreedit = false { didSet { invalidate() } }
    /// The input method panel draws its background on an animatable layer instead.
    public var drawsBackground = true { didSet { needsDisplay = true } }
    public var onSelect: ((Int) -> Void)?
    /// Widest the content may get (0 = unlimited). A row that does not fit wraps onto the
    /// next line and a single candidate wider than this is cut with an ellipsis, so long
    /// phrases (addresses…) never push the panel off the screen.
    public var maxContentWidth: CGFloat = 0 { didSet { if maxContentWidth != oldValue { invalidate() } } }
    /// Hard limit for a row of candidates (the screen); 0 means `maxContentWidth` is the only limit.
    public var maxRowWidth: CGFloat = 0 { didSet { if maxRowWidth != oldValue { invalidate() } } }
    /// The trailing AIME button was clicked.
    public var onMenu: (() -> Void)?
    /// Symbol board: a category tab was clicked / the wheel scrolled by rows.
    public var onTab: ((Int) -> Void)?
    public var onScrollRows: ((Int) -> Void)?
    private var tabItems: [(line: CTLine, rect: NSRect, width: CGFloat)] = []
    private var hintLine: (line: CTLine, origin: NSPoint)?
    private var scrollThumb: (track: NSRect, thumb: NSRect)?
    private var wheelAccumulator: CGFloat = 0
    private var menuButtonRect: NSRect = .zero
    private var busyIconRect: NSRect = .zero
    private var badgeLayout: (line: NSAttributedString, rect: NSRect)?
    /// Whether the 中 / 英 chip is laid out (for tests).
    var hasStatusBadge: Bool {
        if needsLayoutPass { performLayout() }
        return badgeLayout != nil
    }
    /// The main action row was clicked.
    public var onHero: (() -> Void)?
    private struct HeroLayout {
        var rect: NSRect
        var symbol: String
        var title: NSAttributedString
        var detail: NSAttributedString
        var key: NSAttributedString
    }
    private var heroLayout: HeroLayout?
    /// Where the main action row is drawn (view coordinates), `.zero` when there is none.
    public var heroFrame: NSRect {
        if needsLayoutPass { performLayout() }
        return heroLayout?.rect ?? .zero
    }
    public var heroCornerRadius: CGFloat { min(10, theme.hilitedCornerRadius + 3) }
    /// Where the AIME button is drawn (view coordinates), `.zero` when it is not shown.
    public var menuButtonFrame: NSRect {
        if needsLayoutPass { performLayout() }
        return menuButtonRect
    }
    private var symbolImages: [String: NSImage] = [:]
    public var onPage: ((_ backward: Bool) -> Void)?

    private struct Item {
        var line: CTLine
        var rect: NSRect
        var textSize: NSSize
        var ascent: CGFloat
        var symbol: String?
        /// Menu items draw "label · icon · text": the label is its own line.
        var labelLine: CTLine?
        var labelWidth: CGFloat = 0
        /// Board cells: the key that picks the cell, drawn small in its top-left corner.
        var cornerHint: CTLine?
        /// Wrapped items: the lines after the first, one `paragraphStep` apart.
        var moreLines: [CTLine] = []
        /// Wrapped items: the comment as a small tag before the first line.
        var tagLine: CTLine?
    }
    /// Room a tag takes before the first line (pill plus gap).
    private func tagSpace(_ tag: CTLine?) -> CGFloat {
        guard let tag else { return 0 }
        return ceil(CTLineGetTypographicBounds(tag, nil, nil, nil)) + 12 + 7
    }
    private var tagFontPoint: Double { max(10, (theme.fontPoint * 0.62).rounded()) }
    /// Distance between the baselines of a wrapped item's lines.
    private var paragraphStep: CGFloat { lineMetrics.height + 2 }
    private static let symbolGap: CGFloat = 6
    /// Fixed line box for candidates, from the theme's candidate / label / comment fonts
    /// (with a little headroom for emoji and fallback glyphs). Cached per theme.
    private var cachedLineMetrics: (ascent: CGFloat, height: CGFloat)?
    private var lineMetrics: (ascent: CGFloat, height: CGFloat) {
        if let cachedLineMetrics { return cachedLineMetrics }
        let all = [font(theme.fontFace, theme.fontPoint), font(theme.labelFontFace, theme.labelFontPoint),
                   font(theme.commentFontFace, theme.commentFontPoint)]
        let ascent: CGFloat = ceil((all.map(\.ascender).max() ?? 0) * 1.06)
        let descent: CGFloat = ceil((all.map { -$0.descender }.max() ?? 0) * 1.06)
        let metrics: (ascent: CGFloat, height: CGFloat) = (ascent, ascent + descent)
        cachedLineMetrics = metrics
        return metrics
    }

    /// Shared baseline for a horizontal row (fonts fall back per glyph, e.g. ＋ vs ×).
    private var rowMetrics: (ascent: CGFloat, textHeight: CGFloat)?
    /// Font lookups by name are slow; a theme uses at most a handful.
    private var fonts: [String: NSFont] = [:]

    private var preeditLine: NSAttributedString?
    private var preeditRect: NSRect = .zero
    private var items: [Item] = []
    private var contentSize: NSSize = .zero

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override var intrinsicContentSize: NSSize { contentSize }

    public var fittingContentSize: NSSize {
        if needsLayoutPass { performLayout() }
        return contentSize
    }

    private var needsLayoutPass = true
    /// Candidates drawn edge to edge (PanelTheme.HighlightShape.filled) and the insets
    /// the layout used, so drawing can tell which highlight sides touch the panel edge.
    private var filledHighlight = false
    private var layoutInsets: (x: Double, y: Double) = (0, 0)

    private func invalidate() {
        needsLayoutPass = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Fonts & strings

    private func font(_ face: String, _ size: Double) -> NSFont {
        let key = "\(face)\u{0}\(size)"
        if let cached = fonts[key] { return cached }
        let resolved = resolveFont(face, size)
        fonts[key] = resolved
        return resolved
    }

    private func resolveFont(_ face: String, _ size: Double) -> NSFont {
        if face.hasPrefix("SF Pro Rounded"), let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        }
        return NSFont(name: face, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func nsColor(_ color: ThemeColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private func candidateLine(_ candidate: PanelState.Candidate, highlighted: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let textFont = font(theme.fontFace, theme.fontPoint)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph, .baselineOffset: 0]

        func append(_ string: String, _ font: NSFont, _ color: ThemeColor) {
            guard !string.isEmpty else { return }
            var attributes = base
            attributes[.font] = font
            attributes[.foregroundColor] = nsColor(color)
            // Core Text reads its own color key.
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = nsColor(color).cgColor
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        // Supports both "[label] [candidate] [comment]" and legacy "%c. %@".
        var format = theme.candidateFormat
        if format.contains("%c") || format.contains("%@") {
            format = format.replacingOccurrences(of: "%c", with: "[label]").replacingOccurrences(of: "%@", with: "[candidate] [comment]")
        }
        for token in Self.tokenize(format, dropComment: candidate.comment.isEmpty) {
            switch token {
            case "[label]":
                append(candidate.label, font(theme.labelFontFace, theme.labelFontPoint),
                       highlighted ? theme.hilitedCandidateLabelColor : theme.labelColor)
            case "[candidate]":
                append(candidate.text, textFont, highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor)
            case "[comment]":
                append(candidate.comment, font(theme.commentFontFace, theme.commentFontPoint),
                       highlighted ? theme.hilitedCommentTextColor : theme.commentTextColor)
            default:
                append(token, font(theme.labelFontFace, theme.labelFontPoint),
                       highlighted ? theme.hilitedCandidateLabelColor : theme.labelColor)
            }
        }
        return text
    }

    /// Splits a candidate format into placeholders and literal runs. When the comment
    /// is empty, the placeholder and the whitespace right before it are dropped.
    nonisolated static func tokenize(_ format: String, dropComment: Bool) -> [String] {
        var tokens: [String] = []
        var literal = ""
        var rest = Substring(format)
        while let first = rest.first {
            if let placeholder = ["[label]", "[candidate]", "[comment]"].first(where: { rest.hasPrefix($0) }) {
                if placeholder == "[comment]", dropComment {
                    literal = String(literal.reversed().drop(while: \.isWhitespace).reversed())
                } else {
                    if !literal.isEmpty { tokens.append(literal) }
                    literal = ""
                    tokens.append(placeholder)
                }
                rest = rest.dropFirst(placeholder.count)
            } else {
                literal.append(first)
                rest = rest.dropFirst()
            }
        }
        if !literal.isEmpty { tokens.append(literal) }
        return tokens
    }

    // MARK: - Layout

    private func performLayout() {
        needsLayoutPass = false
        items.removeAll(keepingCapacity: true)
        preeditLine = nil

        // Edge-to-edge highlights only for plain candidate pages; menus, boards and
        // status lines keep a margin.
        filledHighlight = theme.highlightShape == .filled && state.presentation == .candidates
            && state.board == nil && state.status == nil && state.hero == nil
        let insetX = filledHighlight ? theme.borderWidth : theme.borderWidth + 2
        let insetY = filledHighlight ? theme.borderHeight : theme.borderHeight + 1
        layoutInsets = (insetX, insetY)
        let padX = max(4, theme.hilitedCornerRadius * 0.9), padY = 3.0
        var cursorY = insetY
        var maxWidth = 0.0

        tabItems.removeAll(keepingCapacity: true)
        hintLine = nil
        scrollThumb = nil
        // Everything from the previous state goes, whichever branch lays out this one
        // (a board returns early: a stale main-action row would be drawn over it).
        heroLayout = nil
        busyIconRect = .zero
        badgeLayout = nil
        menuButtonRect = .zero
        if let board = state.board {
            layoutBoard(board, insetX: insetX, insetY: insetY)
            return
        }

        if let status = state.status {
            // Work in progress is a quiet caption with a sparkle, not a full-size line.
            let point = state.busy ? max(11, (theme.fontPoint * 0.74).rounded()) : theme.fontPoint
            let line = NSMutableAttributedString(string: status, attributes: [
                .font: font(theme.fontFace, point),
                .foregroundColor: nsColor(theme.candidateTextColor).withAlphaComponent(state.busy ? 0.78 : 1),
            ])
            if !state.statusHint.isEmpty {
                line.append(NSAttributedString(string: "   " + state.statusHint, attributes: [
                    .font: font(theme.fontFace, max(10, point - 1)),
                    .foregroundColor: nsColor(theme.candidateTextColor).withAlphaComponent(0.55),
                ]))
            }
            let size = line.size()
            preeditLine = line
            var x = insetX + padX
            if let badge = state.statusBadge, !badge.isEmpty {
                let badgeLine = NSAttributedString(string: badge, attributes: [
                    .font: font(theme.labelFontFace, max(10, (point * 0.78).rounded())),
                    .foregroundColor: nsColor(theme.hilitedCandidateTextColor),
                ])
                let badgeSize = badgeLine.size()
                let rect = NSRect(x: x, y: insetY + padY + (ceil(size.height) - ceil(badgeSize.height) - 4) / 2,
                                  width: ceil(badgeSize.width) + 10, height: ceil(badgeSize.height) + 4)
                badgeLayout = (badgeLine, rect)
                x = rect.maxX + 8
            }
            if state.busy {
                let side = ceil(point * 1.15)
                x += 3
                busyIconRect = NSRect(x: x, y: insetY + padY + (ceil(size.height) - side) / 2, width: side, height: side)
                x = busyIconRect.maxX + 6
            }
            preeditRect = NSRect(x: x, y: insetY + padY, width: ceil(size.width), height: ceil(size.height))
            contentSize = NSSize(width: preeditRect.maxX + padX + insetX + (state.busy ? 5 : 0), height: preeditRect.maxY + padY + insetY)
            return
        }

        if !state.preedit.isEmpty, forcePreedit || !theme.inlinePreedit {
            let line = NSMutableAttributedString(string: state.preedit, attributes: [
                .font: font(theme.fontFace, theme.fontPoint * 0.88), .foregroundColor: nsColor(theme.textColor),
            ])
            let selection = NSIntersectionRange(state.preeditSelection, NSRange(location: 0, length: line.length))
            if selection.length > 0 {
                line.addAttribute(.foregroundColor, value: nsColor(theme.hilitedTextColor), range: selection)
                line.addAttribute(.backgroundColor, value: nsColor(theme.hilitedBackColor), range: selection)
            }
            let size = line.size()
            preeditLine = line
            preeditRect = NSRect(x: insetX + padX, y: cursorY + (filledHighlight ? 4 : 1), width: ceil(size.width), height: ceil(size.height))
            cursorY = preeditRect.maxY + theme.lineSpacing + 2
            maxWidth = preeditRect.maxX + padX
        }

        // Menu caption (quick menu pages) sits where the preedit row would be.
        if let title = state.title, !title.isEmpty {
            let line = NSAttributedString(string: title, attributes: [
                .font: font(theme.labelFontFace, theme.fontPoint * 0.72), .foregroundColor: nsColor(theme.commentTextColor),
            ])
            let size = line.size()
            preeditLine = line
            preeditRect = NSRect(x: insetX + padX, y: cursorY + 2, width: ceil(size.width), height: ceil(size.height))
            cursorY = preeditRect.maxY + theme.lineSpacing + 3
            maxWidth = preeditRect.maxX + padX
        }

        enum Mode { case linear, stacked, grid }
        let mode: Mode = switch state.presentation {
        case .grid: .grid
        case .list, .paragraphs: .stacked
        case .row: .linear
        case .candidates: theme.layout == .stacked ? .stacked : .linear
        }
        let symbolSide = ceil(theme.fontPoint * 1.05)
        menuButtonRect = .zero
        rowMetrics = nil

        // Main action row (menu pages): icon, title, what it offers, and its key.
        var heroNatural = 0.0
        if let hero = state.hero {
            let text = theme.candidateTextColor
            let title = NSAttributedString(string: hero.title, attributes: [
                .font: font(theme.fontFace, theme.fontPoint), .foregroundColor: nsColor(text),
            ])
            let detail = NSAttributedString(string: hero.detail, attributes: [
                .font: font(theme.commentFontFace, max(10, (theme.fontPoint * 0.72).rounded())),
                .foregroundColor: nsColor(text).withAlphaComponent(0.6),
            ])
            let key = NSAttributedString(string: hero.key, attributes: [
                .font: font(theme.labelFontFace, max(10, (theme.fontPoint * 0.68).rounded())),
                .foregroundColor: nsColor(text).withAlphaComponent(0.78),
            ])
            let height = ceil(lineMetrics.height) + padY * 2 + 8
            heroNatural = 10 + symbolSide + 8 + ceil(title.size().width) + (hero.detail.isEmpty ? 0 : 10 + ceil(detail.size().width)) + 18
                + ceil(key.size().width) + 14 + 8
            heroLayout = HeroLayout(rect: NSRect(x: insetX, y: cursorY, width: heroNatural, height: height),
                                    symbol: hero.symbol, title: title, detail: detail, key: key)
            cursorY += height + max(5, theme.lineSpacing + 3)
            maxWidth = max(maxWidth, insetX + heroNatural)
        }

        var x = insetX
        var rowHeight = 0.0
        // Room for text inside one candidate, and the right edge a row may reach (leaving
        // space for the AIME button when it is shown).
        // Only a row reserves room for the button; a vertical list puts it in a header or footer.
        let buttonReserve: CGFloat = state.showsMenuButton && mode == .linear ? symbolSide + 12 : 0
        let widthLimit = maxContentWidth > 0 ? max(160, maxContentWidth - insetX - buttonReserve) : 0
        let textLimit = widthLimit > 0 ? widthLimit - insetX - padX * 2 : 0
        var wrapped = false
        struct Measured {
            var line: CTLine, moreLines: [CTLine] = [], tagLine: CTLine? = nil, labelLine: CTLine?, labelWidth: CGFloat, symbol: String?
            var textSize: NSSize, width: Double, height: Double
        }
        var measured: [Measured] = []
        measured.reserveCapacity(state.candidates.count)
        for (index, candidate) in state.candidates.enumerated() {
            let highlighted = index == state.highlightedIndex
            // Items with an icon keep the number first: label, icon, then the text.
            var labelLine: CTLine?
            var labelWidth: CGFloat = 0
            var shown = candidate
            let wraps = state.presentation == .paragraphs
            if candidate.symbol != nil || wraps {
                shown.label = ""
                let label = NSAttributedString(string: candidate.label, attributes: [
                    .font: font(theme.labelFontFace, theme.labelFontPoint),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        nsColor(highlighted ? theme.hilitedCandidateLabelColor : theme.labelColor).cgColor,
                ])
                let created = CTLineCreateWithAttributedString(label)
                labelLine = created
                labelWidth = ceil(CTLineGetTypographicBounds(created, nil, nil, nil)) + Self.symbolGap
            }
            // Wrapped items show the comment ("正式", "另一种说法") as a small tag instead
            // of trailing text in the comment font.
            var tagLine: CTLine?
            if wraps, !candidate.comment.isEmpty {
                let color = nsColor(highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor)
                tagLine = CTLineCreateWithAttributedString(NSAttributedString(string: candidate.comment, attributes: [
                    .font: font(theme.labelFontFace, tagFontPoint),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.withAlphaComponent(0.72).cgColor,
                ]))
                shown.comment = ""
            }
            let firstIndent = Double(tagSpace(tagLine))
            // Without its label the formatted text may start with a space; wrapped items
            // would then have continuation lines left of the first one.
            let formatted = NSMutableAttributedString(attributedString: candidateLine(shown, highlighted: highlighted))
            if wraps {
                while formatted.string.hasPrefix(" ") { formatted.deleteCharacters(in: NSRange(location: 0, length: 1)) }
            }
            var line = CTLineCreateWithAttributedString(formatted)
            var typographicWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            var moreLines: [CTLine] = []
            let wrapWidth = min(textLimit > 0 ? Double(textLimit) : PanelState.paragraphWidth, PanelState.paragraphWidth) - Double(labelWidth)
            if wraps, typographicWidth > wrapWidth - firstIndent {
                // Break into lines; the last one allowed ends with an ellipsis.
                let full = formatted
                let typesetter = CTTypesetterCreateWithAttributedString(full)
                let limit = highlighted ? PanelState.paragraphLines : 2
                var lines: [CTLine] = []
                var start = 0
                while start < full.length, lines.count < limit {
                    let width = lines.isEmpty ? wrapWidth - firstIndent : wrapWidth
                    let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, width))
                    if lines.count == limit - 1, start + count < full.length {
                        let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: full.length - start))
                        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                            .font: font(theme.fontFace, theme.fontPoint),
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                                nsColor(highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor).cgColor,
                        ]))
                        lines.append(CTLineCreateTruncatedLine(rest, width, .end, ellipsis)
                            ?? CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                        break
                    }
                    lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                    start += count
                }
                if let first = lines.first {
                    line = first
                    moreLines = Array(lines.dropFirst())
                    typographicWidth = lines.enumerated().map {
                        CTLineGetTypographicBounds($0.element, nil, nil, nil) + ($0.offset == 0 ? firstIndent : 0)
                    }.max() ?? wrapWidth
                }
            } else if wraps {
                typographicWidth += firstIndent
            } else if mode != .grid, textLimit > 0 {
                let limit = Double(textLimit) - Double(labelWidth) - (candidate.symbol == nil ? 0 : Double(symbolSide + Self.symbolGap))
                if typographicWidth > limit {
                    let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                        .font: font(theme.fontFace, theme.fontPoint),
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            nsColor(highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor).cgColor,
                    ]))
                    if let truncated = CTLineCreateTruncatedLine(line, max(40, limit), .end, ellipsis) {
                        line = truncated
                        typographicWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                    }
                }
            }
            // Height and baseline come from the theme's fonts, never from the content: an
            // emoji or a fallback font in one candidate must not make the panel jump.
            let size = NSSize(width: typographicWidth, height: lineMetrics.height + CGFloat(moreLines.count) * paragraphStep)
            let symbolWidth = (candidate.symbol == nil ? 0 : symbolSide + Self.symbolGap) + labelWidth
            measured.append(Measured(line: line, moreLines: moreLines, tagLine: tagLine, labelLine: labelLine, labelWidth: labelWidth, symbol: candidate.symbol,
                                     textSize: NSSize(width: ceil(size.width), height: size.height),
                                     width: ceil(size.width) + symbolWidth + padX * 2, height: ceil(size.height) + padY * 2))
        }
        // Where a row breaks. A page of ordinary candidates stays on one line however many
        // there are (only the screen limits it, as in other input methods). The maximum
        // width applies once the page holds a long candidate — wider than a third of it.
        let gap = max(0, theme.spacing - padX)
        var rowLimit = widthLimit
        if mode == .linear, widthLimit > 0, maxRowWidth > maxContentWidth,
           measured.allSatisfy({ $0.width <= Double(maxContentWidth) / 3 }) {
            rowLimit = maxRowWidth - insetX - buttonReserve
        }
        for entry in measured {
            let ascent = lineMetrics.ascent
            let width = entry.width, height = entry.height
            let rect: NSRect
            switch mode {
            case .linear:
                // Wrap like a paragraph when the row is full (the numbers stay valid: every
                // candidate of the page is still shown).
                if rowLimit > 0, x > insetX, x + width > rowLimit {
                    x = insetX
                    cursorY += height + theme.lineSpacing
                    wrapped = true
                }
                rect = NSRect(x: x, y: cursorY, width: width, height: height)
                x = rect.maxX + gap
                rowHeight = max(rowHeight, height)
            case .stacked, .grid:
                rect = NSRect(x: insetX, y: cursorY, width: width, height: height)
                if mode == .stacked { cursorY = rect.maxY + theme.lineSpacing }
            }
            items.append(Item(line: entry.line, rect: rect, textSize: entry.textSize,
                              ascent: ascent, symbol: entry.symbol, labelLine: entry.labelLine, labelWidth: entry.labelWidth,
                              moreLines: entry.moreLines, tagLine: entry.tagLine))
            maxWidth = max(maxWidth, rect.maxX)
        }
        switch mode {
        case .stacked:
            // Uniform highlight width in stacked mode looks tidier.
            let widest = items.map(\.rect.width).max() ?? 0
            for index in items.indices { items[index].rect.size.width = widest }
            maxWidth = max(maxWidth, insetX + widest)
            if !items.isEmpty { cursorY -= theme.lineSpacing }
        case .grid:
            // Two equal columns; cells are as wide as the widest item (with a floor).
            let gap = max(4, theme.spacing * 0.5)
            let cellWidth = max(132, items.map(\.rect.width).max() ?? 0, ceil((heroNatural - gap) / 2))
            let cellHeight = (items.map(\.rect.height).max() ?? 0) + 4
            for index in items.indices {
                let column = CGFloat(index % 2), row = CGFloat(index / 2)
                items[index].rect = NSRect(x: insetX + column * (cellWidth + gap), y: cursorY + row * (cellHeight + theme.lineSpacing),
                                           width: cellWidth, height: cellHeight)
            }
            let rows = CGFloat((items.count + 1) / 2)
            if rows > 0 { cursorY += rows * cellHeight + (rows - 1) * theme.lineSpacing }
            maxWidth = max(maxWidth, insetX + cellWidth * 2 + gap)
        case .linear:
            for index in items.indices { items[index].rect.size.height = rowHeight }
            if !items.isEmpty {
                rowMetrics = (items.map(\.ascent).max() ?? 0, items.map(\.textSize.height).max() ?? 0)
            }
            cursorY += rowHeight
        }
        // The AIME button. A row: right after the last candidate (wrapped rows: the top-right
        // corner). A vertical list never gets a second column for it: it sits at the end
        // of the preedit row when there is one, otherwise in a slim footer, right-aligned.
        if state.showsMenuButton, !items.isEmpty, mode == .linear {
            let side = min(items[0].rect.height, symbolSide + 8)
            let lastEdge: Double = items.last.map { Double($0.rect.maxX) } ?? maxWidth
            let originX = (!wrapped ? lastEdge : maxWidth) + 2
            menuButtonRect = NSRect(x: originX, y: items[0].rect.minY + (items[0].rect.height - side) / 2, width: side, height: side)
            maxWidth = menuButtonRect.maxX
        } else if state.showsMenuButton, !items.isEmpty, mode == .stacked {
            let side = symbolSide + 4
            if preeditLine != nil {
                maxWidth = max(maxWidth, preeditRect.maxX + 10 + side)
                menuButtonRect = NSRect(x: maxWidth - side, y: preeditRect.midY - side / 2, width: side, height: side)
            } else {
                cursorY += 3
                menuButtonRect = NSRect(x: maxWidth - side, y: cursorY, width: side, height: side)
                cursorY += side
            }
        }
        heroLayout?.rect.size.width = maxWidth - insetX
        if state.candidates.isEmpty, preeditLine != nil, heroLayout == nil { cursorY -= theme.lineSpacing + 2 }
        contentSize = NSSize(width: ceil(maxWidth + insetX), height: ceil(cursorY + insetY))
        // Edge to edge, a vertical list's highlight spans the whole row.
        if filledHighlight, mode == .stacked {
            for index in items.indices { items[index].rect.size.width = contentSize.width - insetX * 2 - items[index].rect.minX + insetX }
        }
    }

    /// The highlight behind a candidate. Filled: sides that touch the panel edge are
    /// pushed past it so the panel's rounded clip forms those corners, and inner corners
    /// use the configured radius (often 0). Inset: concentric with the panel corner when
    /// close to it (PanelTheme.insetHighlightRadius).
    func highlightPath(for rect: NSRect) -> NSBezierPath {
        let panelRadius = min(theme.cornerRadius, contentSize.height / 2)
        guard filledHighlight else {
            let radius = theme.insetHighlightRadius(gap: min(layoutInsets.x, layoutInsets.y), panelRadius: panelRadius)
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        let bounds = NSRect(origin: .zero, size: contentSize)
        let reach = panelRadius + 2, tolerance = 0.75
        var r = rect
        if r.minX <= layoutInsets.x + tolerance { r.size.width += r.minX + reach; r.origin.x = -reach }
        if r.maxX >= bounds.maxX - layoutInsets.x - tolerance { r.size.width = bounds.maxX + reach - r.minX }
        if r.minY <= layoutInsets.y + tolerance { r.size.height += r.minY + reach; r.origin.y = -reach }
        if r.maxY >= bounds.maxY - layoutInsets.y - tolerance { r.size.height = bounds.maxY + reach - r.minY }
        let radius = min(theme.configuredHilitedCornerRadius, r.height / 2, r.width / 2)
        return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    }

    /// Tabs on top, a fixed `columns × visibleRows` grid (so the panel never resizes while
    /// scrolling or switching categories), a slim scroll indicator and a hint line.
    private func layoutBoard(_ board: PanelState.Board, insetX: Double, insetY: Double) {
        menuButtonRect = .zero
        rowMetrics = nil
        let cell = ceil(theme.fontPoint * 1.95)
        let gap: CGFloat = 2
        let tabFont = font(theme.labelFontFace, max(11, theme.fontPoint * 0.74))
        var x = insetX
        let tabHeight = ceil(tabFont.ascender - tabFont.descender) + 10
        let digitFont = font(theme.labelFontFace, max(9, theme.fontPoint * 0.58))
        for (index, title) in board.tabs.enumerated() {
            let selected = index == board.selectedTab
            // The digit that jumps to the tab (1…9, then 0), dimmer than the title.
            let digit = index < 9 ? "\(index + 1)" : index == 9 ? "0" : ""
            let text = NSMutableAttributedString(string: digit.isEmpty ? "" : digit + " ", attributes: [
                .font: digitFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    nsColor(selected ? theme.hilitedCandidateLabelColor : theme.labelColor).withAlphaComponent(0.85).cgColor,
            ])
            text.append(NSAttributedString(string: title, attributes: [
                .font: tabFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    nsColor(selected ? theme.hilitedCandidateTextColor : theme.commentTextColor).cgColor,
            ]))
            let line = CTLineCreateWithAttributedString(text)
            let width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
            let rect = NSRect(x: x, y: insetY, width: width + 18, height: tabHeight)
            tabItems.append((line, rect, width))
            x = rect.maxX + 2
        }
        // The grid spans the tab strip: cells stretch horizontally, the scroll indicator
        // sits at the panel's trailing edge.
        let scrolls = board.totalRows > board.visibleRows
        let tabsWidth = x - 2 - insetX
        let minimumGrid = CGFloat(board.columns) * cell + CGFloat(board.columns - 1) * gap
        let gridWidth = max(minimumGrid, tabsWidth - (scrolls ? 9 : 0))
        let cellWidth = (gridWidth - CGFloat(board.columns - 1) * gap) / CGFloat(board.columns)
        let gridTop = insetY + tabHeight + 8
        let isList = board.columns == 1
        let itemFont = font(theme.fontFace, isList ? theme.fontPoint * 0.92 : theme.fontPoint)
        let hintFont = font(theme.labelFontFace, max(9, theme.fontPoint * (isList ? 0.7 : 0.5)))
        // List rows are as tall as a line of text; grid cells are square-ish.
        let rowHeight = isList ? lineMetrics.height + 10 : cell
        let listWidth = max(gridWidth, 360)
        let cellSpan = isList ? listWidth : cellWidth
        for (index, candidate) in state.candidates.enumerated() {
            let highlighted = index == state.highlightedIndex
            let column = CGFloat(index % board.columns), row = CGFloat(index / board.columns)
            let rect = NSRect(x: insetX + column * (cellSpan + gap), y: gridTop + row * (rowHeight + gap), width: cellSpan, height: rowHeight)
            var hint: CTLine?
            var hintWidth: CGFloat = 0
            if board.keyHints.indices.contains(index) {
                let created = CTLineCreateWithAttributedString(NSAttributedString(string: board.keyHints[index].uppercased(), attributes: [
                    .font: hintFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        nsColor(highlighted ? theme.hilitedCandidateLabelColor : theme.labelColor).withAlphaComponent(isList ? 0.9 : 0.7).cgColor,
                ]))
                hint = created
                hintWidth = ceil(CTLineGetTypographicBounds(created, nil, nil, nil))
            }
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: candidate.text, attributes: [
                .font: itemFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    nsColor(highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor).cgColor,
            ]))
            var width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
            if isList {
                // Long snippets are cut with an ellipsis instead of widening the panel.
                let available = Double(cellSpan) - 20 - Double(hintWidth) - 10
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                    .font: itemFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        nsColor(highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor).cgColor,
                ]))
                if Double(width) > available, let truncated = CTLineCreateTruncatedLine(line, available, .end, ellipsis) {
                    line = truncated
                    width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
                items.append(Item(line: line, rect: rect, textSize: NSSize(width: width, height: lineMetrics.height), ascent: lineMetrics.ascent,
                                  labelLine: hint, labelWidth: hintWidth + 10))
            } else {
                items.append(Item(line: line, rect: rect, textSize: NSSize(width: width, height: lineMetrics.height), ascent: lineMetrics.ascent,
                                  cornerHint: hint))
            }
        }
        let gridHeight = CGFloat(board.visibleRows) * rowHeight + CGFloat(board.visibleRows - 1) * gap
        let bodyWidth = isList ? listWidth : gridWidth
        var contentWidth = max(x - 2, insetX + bodyWidth)
        if scrolls {
            let track = NSRect(x: insetX + bodyWidth + 6, y: gridTop, width: 3, height: gridHeight)
            let fraction = CGFloat(board.visibleRows) / CGFloat(board.totalRows)
            let travel = gridHeight * (1 - fraction)
            let offset = travel * CGFloat(board.firstRow) / CGFloat(max(1, board.totalRows - board.visibleRows))
            scrollThumb = (track, NSRect(x: track.minX, y: track.minY + offset, width: 3, height: max(12, gridHeight * fraction)))
            contentWidth = max(contentWidth, track.maxX)
        }
        var bottom = gridTop + gridHeight
        if !board.hint.isEmpty {
            let hintFont = font(theme.labelFontFace, max(10, theme.fontPoint * 0.62))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: board.hint, attributes: [
                .font: hintFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): nsColor(theme.commentTextColor).cgColor,
            ]))
            hintLine = (line, NSPoint(x: insetX + 2, y: bottom + 8 + hintFont.ascender))
            bottom += 8 + ceil(hintFont.ascender - hintFont.descender)
            contentWidth = max(contentWidth, insetX + ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 4)
        }
        contentSize = NSSize(width: ceil(contentWidth + insetX), height: ceil(bottom + insetY))
    }

    /// Tinted SF Symbol, cached per name / size / color.
    private func symbolImage(_ name: String, side: CGFloat, color: ThemeColor) -> NSImage? {
        let key = "\(name)|\(side)|\(color.red),\(color.green),\(color.blue),\(color.alpha)"
        if let cached = symbolImages[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.82, weight: .regular)
            .applying(.init(paletteColors: [nsColor(color)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        symbolImages[key] = image
        return image
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: ThemeColor) {
        guard let image = symbolImage(name, side: rect.height, color: color) else { return }
        let size = image.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    public override func layout() {
        super.layout()
        if needsLayoutPass { performLayout() }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        if needsLayoutPass { performLayout() }
        let bounds = NSRect(origin: .zero, size: contentSize)
        let radius = min(theme.cornerRadius, bounds.height / 2)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)

        if drawsBackground {
            nsColor(theme.effectiveBackColor).setFill()
            background.fill()
        }
        // Highlights never poke out of the rounded background; edge-to-edge ones take
        // its corners. The border is stroked last, over them.
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
            if drawsBackground, theme.borderColor.alpha > 0 {
                nsColor(theme.borderColor).setStroke()
                background.lineWidth = 1
                background.stroke()
            }
        }
        if drawsBackground { background.addClip() }

        if let preeditLine {
            if theme.preeditBackColor.alpha > 0, state.status == nil {
                nsColor(theme.preeditBackColor).setFill()
                NSBezierPath(roundedRect: preeditRect.insetBy(dx: -4, dy: -2), xRadius: 4, yRadius: 4).fill()
            }
            preeditLine.draw(at: preeditRect.origin)
            if let badge = badgeLayout {
                nsColor(theme.hilitedCandidateBackColor.alpha > 0 ? theme.hilitedCandidateBackColor : theme.candidateTextColor).setFill()
                NSBezierPath(roundedRect: badge.rect, xRadius: 4, yRadius: 4).fill()
                let size = badge.line.size()
                badge.line.draw(at: NSPoint(x: badge.rect.midX - size.width / 2, y: badge.rect.midY - size.height / 2))
            }
            if busyIconRect != .zero {
                var tint = theme.candidateTextColor
                tint.alpha *= 0.72
                drawSymbol("sparkles", in: busyIconRect, color: tint)
            }
        }

        if let hero = heroLayout {
            let rect = hero.rect, text = nsColor(theme.candidateTextColor)
            text.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: heroCornerRadius, yRadius: heroCornerRadius).fill()
            let side = ceil(theme.fontPoint * 1.05)
            var x = rect.minX + 10
            drawSymbol(hero.symbol, in: NSRect(x: x, y: rect.midY - side / 2, width: side, height: side), color: theme.candidateTextColor)
            x += side + 8
            let titleSize = hero.title.size(), detailSize = hero.detail.size(), keySize = hero.key.size()
            hero.title.draw(at: NSPoint(x: x, y: rect.midY - titleSize.height / 2))
            x += ceil(titleSize.width) + 10
            hero.detail.draw(at: NSPoint(x: x, y: rect.midY - detailSize.height / 2 + 0.5))
            // Keycap at the trailing edge.
            let cap = NSRect(x: rect.maxX - 8 - (ceil(keySize.width) + 14), y: rect.midY - (ceil(keySize.height) + 6) / 2,
                             width: ceil(keySize.width) + 14, height: ceil(keySize.height) + 6)
            let capPath = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            text.withAlphaComponent(0.07).setFill()
            capPath.fill()
            text.withAlphaComponent(0.24).setStroke()
            capPath.lineWidth = 1
            capPath.stroke()
            hero.key.draw(at: NSPoint(x: cap.midX - keySize.width / 2, y: cap.midY - keySize.height / 2))
        }

        let context = NSGraphicsContext.current?.cgContext
        context?.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // flipped view
        if let board = state.board, let context {
            for (index, tab) in tabItems.enumerated() {
                if index == board.selectedTab {
                    nsColor(theme.hilitedCandidateBackColor).setFill()
                    NSBezierPath(roundedRect: tab.rect, xRadius: tab.rect.height / 2, yRadius: tab.rect.height / 2).fill()
                }
                var ascent: CGFloat = 0, descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(tab.line, &ascent, &descent, nil)
                context.textPosition = CGPoint(x: tab.rect.midX - tab.width / 2, y: tab.rect.midY + (ascent - descent) / 2)
                CTLineDraw(tab.line, context)
            }
            if let scrollThumb {
                nsColor(theme.commentTextColor).withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: scrollThumb.track, xRadius: 1.5, yRadius: 1.5).fill()
                nsColor(theme.commentTextColor).withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: scrollThumb.thumb, xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let hintLine {
                context.textPosition = hintLine.origin
                CTLineDraw(hintLine.line, context)
            }
        }
        for (index, item) in items.enumerated() {
            if index == state.highlightedIndex, theme.hilitedCandidateBackColor.alpha > 0 {
                nsColor(theme.hilitedCandidateBackColor).setFill()
                highlightPath(for: item.rect).fill()
            }
            let size = item.textSize
            guard let context else { continue }
            let gridCell = state.board.map { $0.columns > 1 } ?? false
            var x = gridCell ? item.rect.midX - size.width / 2
                : item.rect.minX + (state.board != nil ? 10 : max(4, theme.hilitedCornerRadius * 0.9))
            if let cornerHint = item.cornerHint {
                var hintAscent: CGFloat = 0
                _ = CTLineGetTypographicBounds(cornerHint, &hintAscent, nil, nil)
                context.textPosition = CGPoint(x: item.rect.minX + 4, y: item.rect.minY + 2 + hintAscent)
                CTLineDraw(cornerHint, context)
            }
            let top = item.rect.minY + (item.rect.height - (rowMetrics?.textHeight ?? size.height)) / 2
            let baseline = top + (rowMetrics?.ascent ?? item.ascent)
            if let labelLine = item.labelLine {
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(labelLine, context)
                x += item.labelWidth
            }
            if let symbol = item.symbol {
                let side = ceil(theme.fontPoint * 1.05)
                let highlighted = index == state.highlightedIndex
                drawSymbol(symbol, in: NSRect(x: x, y: item.rect.midY - side / 2, width: side, height: side),
                           color: highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor)
                x += side + Self.symbolGap
            }
            if let tag = item.tagLine {
                // Pill centred on the first line, text after it.
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = ceil(CTLineGetTypographicBounds(tag, &ascent, &descent, nil))
                let height = ceil(ascent + descent) + 4
                let lineTop = baseline - item.ascent
                let pill = NSRect(x: x, y: lineTop + (lineMetrics.height - height) / 2, width: width + 12, height: height)
                let highlighted = index == state.highlightedIndex
                nsColor(highlighted ? theme.hilitedCandidateTextColor : theme.candidateTextColor)
                    .withAlphaComponent(highlighted ? 0.16 : 0.08).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
                context.textPosition = CGPoint(x: pill.minX + 6, y: pill.midY + (ascent - descent) / 2)
                CTLineDraw(tag, context)
                context.textPosition = CGPoint(x: x + tagSpace(tag), y: baseline)
            } else {
                context.textPosition = CGPoint(x: x, y: baseline)
            }
            CTLineDraw(item.line, context)
            for (offset, line) in item.moreLines.enumerated() {
                context.textPosition = CGPoint(x: x, y: baseline + CGFloat(offset + 1) * paragraphStep)
                CTLineDraw(line, context)
            }
        }
        if menuButtonRect != .zero {
            drawSymbol("square.grid.2x2", in: menuButtonRect.insetBy(dx: 2, dy: 2), color: theme.commentTextColor)
        }
    }

    // MARK: - Mouse

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if menuButtonRect.insetBy(dx: -3, dy: -3).contains(point) { onMenu?(); return }
        if let hero = heroLayout, hero.rect.contains(point) { onHero?(); return }
        if let tab = tabItems.firstIndex(where: { $0.rect.contains(point) }) { onTab?(tab); return }
        if let index = items.firstIndex(where: { $0.rect.contains(point) }) { onSelect?(index) }
    }

    public override func scrollWheel(with event: NSEvent) {
        if state.board != nil {
            // One row per notch; precise (trackpad) deltas accumulate to a row.
            wheelAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            let rows = Int(wheelAccumulator / 24)
            if rows != 0 {
                wheelAccumulator -= CGFloat(rows) * 24
                onScrollRows?(-rows)
            }
            return
        }
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if abs(delta) > 3 { onPage?(delta > 0) }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
