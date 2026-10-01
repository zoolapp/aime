public import AIMECore
public import Foundation

/// An RGBA color parsed from Rime color notation.
public struct ThemeColor: Sendable, Hashable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public static let clear = ThemeColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// Parses `0xAABBGGRR` (Squirrel default), `0xAARRGGBB` (`argb`) or `0xRRGGBBAA`
    /// (`rgba`). Six-digit values are opaque.
    public init?(rime value: ConfigValue?, format: String) {
        guard var text = value?.stringValue?.lowercased() else { return nil }
        if value?.intValue != nil, !text.hasPrefix("0x"), let int = value?.intValue { text = String(int, radix: 16) }
        if text.hasPrefix("0x") { text.removeFirst(2) } else if text.hasPrefix("#") { text.removeFirst() }
        guard let raw = UInt32(text, radix: 16), text.count == 6 || text.count == 8 else { return nil }
        let hasAlpha = text.count == 8
        let b0 = Double(raw & 0xff) / 255, b1 = Double((raw >> 8) & 0xff) / 255
        let b2 = Double((raw >> 16) & 0xff) / 255, b3 = hasAlpha ? Double((raw >> 24) & 0xff) / 255 : 1
        switch format {
        case "argb": self.init(red: b2, green: b1, blue: b0, alpha: b3)
        case "rgba":
            self = hasAlpha
                ? ThemeColor(red: b3, green: b2, blue: b1, alpha: b0)
                : ThemeColor(red: b2, green: b1, blue: b0, alpha: 1)
        default: self.init(red: b0, green: b1, blue: b2, alpha: b3)
        }
    }

    /// `0xAARRGGBB` for writing back with `color_format: argb`.
    public var argbString: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "0x" + byte(alpha) + byte(red) + byte(green) + byte(blue)
    }

    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio against another opaque color.
    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Composites this color over an opaque background.
    public func over(_ background: ThemeColor) -> ThemeColor {
        ThemeColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }
}

/// Everything the candidate panel needs to render, resolved from `aime.yaml`
/// (`style` + the active `preset_color_schemes` entry, the scheme winning).
public struct PanelTheme: Sendable, Hashable {
    public enum Layout: String, Sendable { case linear, stacked }

    public var schemeName: String
    public var displayName: String
    public var layout: Layout
    public var vertical: Bool
    public var inlinePreedit: Bool
    public var inlineCandidate: Bool
    public var translucency: Bool
    public var alpha: Double
    public var cornerRadius: Double
    public var hilitedCornerRadius: Double
    /// The highlight radius as configured (may be 0), before AIME's soft minimum.
    public var configuredHilitedCornerRadius: Double
    public var borderHeight: Double
    public var borderWidth: Double
    public var lineSpacing: Double
    public var spacing: Double
    public var baseOffset: Double
    /// Widest the candidate window may get, in points (0 = only limited by the screen).
    public var maxWidth: Double
    public var fontFace: String
    public var fontPoint: Double
    public var labelFontFace: String
    public var labelFontPoint: Double
    public var commentFontFace: String
    public var commentFontPoint: Double
    public var candidateFormat: String

    public var backColor: ThemeColor
    public var borderColor: ThemeColor
    public var preeditBackColor: ThemeColor
    public var textColor: ThemeColor
    public var hilitedTextColor: ThemeColor
    public var hilitedBackColor: ThemeColor
    public var candidateTextColor: ThemeColor
    public var commentTextColor: ThemeColor
    public var labelColor: ThemeColor
    public var hilitedCandidateBackColor: ThemeColor
    public var hilitedCandidateTextColor: ThemeColor
    public var hilitedCommentTextColor: ThemeColor
    public var hilitedCandidateLabelColor: ThemeColor

    public static let fallback = PanelTheme(frontend: .map([]), dark: false)
    static let minimumCornerRadius = 8.0
    static let minimumHilitedCornerRadius = 5.0

    /// Names of all color schemes defined in the frontend config.
    public static func schemeNames(in frontend: ConfigValue) -> [(id: String, name: String)] {
        (frontend["preset_color_schemes"]?.entries ?? []).map { ($0.key, $0.value["name"]?.stringValue ?? $0.key) }
    }

    public init(frontend: ConfigValue, dark: Bool, schemeOverride: String? = nil) {
        let style = frontend["style"] ?? .map([])
        let lightName = style["color_scheme"]?.stringValue ?? "aime_light"
        let darkName = style["color_scheme_dark"]?.stringValue
        let name = schemeOverride ?? (dark ? (darkName ?? lightName) : lightName)
        let scheme = frontend.value(at: "preset_color_schemes/\(name)") ?? .map([])
        let format = scheme["color_format"]?.stringValue ?? "bgr"

        // What the user set in AIME Settings (`style/aime/*`) wins; then the color scheme's
        // own value (Squirrel semantics); then the style. Choosing a scheme changes colors,
        // never the layout or font the user picked.
        let aime = style["aime"]
        func value(_ key: String) -> ConfigValue? { aime?[key] ?? scheme[key] ?? style[key] }
        func double(_ key: String, _ fallback: Double) -> Double { value(key)?.doubleValue ?? fallback }
        func string(_ key: String, _ fallback: String) -> String { value(key)?.stringValue ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { value(key)?.boolValue ?? fallback }
        func color(_ key: String, _ fallback: ThemeColor) -> ThemeColor { ThemeColor(rime: scheme[key], format: format) ?? fallback }

        // Neutral surfaces, ink text, vermilion selection (as the shipped aime_light / aime_dark).
        let defaultBack = dark ? ThemeColor(red: 30/255, green: 30/255, blue: 32/255, alpha: 0.95) : ThemeColor(red: 252/255, green: 252/255, blue: 251/255, alpha: 0.96)
        let defaultText = dark ? ThemeColor(red: 242/255, green: 242/255, blue: 240/255) : ThemeColor(red: 36/255, green: 35/255, blue: 33/255)
        let accent = ThemeColor(red: 182/255, green: 64/255, blue: 50/255) // approved vermilion; white highlight text in both modes

        schemeName = name
        displayName = scheme["name"]?.stringValue ?? name
        let layoutName = string("candidate_list_layout", "linear")
        layout = layoutName == "stacked" ? .stacked : .linear
        vertical = string("text_orientation", "horizontal") == "vertical"
        inlinePreedit = bool("inline_preedit", true)
        inlineCandidate = bool("inline_candidate", false)
        translucency = bool("translucency", false)
        alpha = min(1, max(0.1, double("alpha", 1)))
        // Without an explicit `style/aime` radius (which may be 0) AIME keeps a soft
        // minimum, so square schemes (win10) and imported Squirrel styles still look rounded.
        cornerRadius = aime?["corner_radius"]?.doubleValue
            ?? max(double("corner_radius", 10), Self.minimumCornerRadius)
        hilitedCornerRadius = aime?["hilited_corner_radius"]?.doubleValue
            ?? max(double("hilited_corner_radius", 6), Self.minimumHilitedCornerRadius)
        configuredHilitedCornerRadius = max(0, value("hilited_corner_radius")?.doubleValue ?? hilitedCornerRadius)
        borderHeight = double("border_height", 6)
        borderWidth = double("border_width", 8)
        lineSpacing = double("line_spacing", 4)
        spacing = double("spacing", 8)
        baseOffset = double("base_offset", 0)
        maxWidth = max(0, double("max_width", 640))
        fontFace = string("font_face", "PingFang SC").components(separatedBy: ",").first!.trimmingCharacters(in: .whitespaces)
        fontPoint = double("font_point", 17)
        labelFontFace = string("label_font_face", fontFace).components(separatedBy: ",").first!.trimmingCharacters(in: .whitespaces)
        labelFontPoint = double("label_font_point", fontPoint * 0.8)
        commentFontFace = string("comment_font_face", fontFace).components(separatedBy: ",").first!.trimmingCharacters(in: .whitespaces)
        commentFontPoint = double("comment_font_point", fontPoint * 0.8)
        candidateFormat = string("candidate_format", "[label] [candidate] [comment]")

        backColor = color("back_color", defaultBack)
        borderColor = color("border_color", .clear)
        preeditBackColor = color("preedit_back_color", .clear)
        textColor = color("text_color", defaultText)
        hilitedTextColor = color("hilited_text_color", textColor)
        hilitedBackColor = color("hilited_back_color", .clear)
        candidateTextColor = color("candidate_text_color", textColor)
        commentTextColor = color("comment_text_color", dark ? ThemeColor(red: 163/255, green: 163/255, blue: 160/255) : ThemeColor(red: 107/255, green: 106/255, blue: 103/255))
        labelColor = color("label_color", commentTextColor)
        hilitedCandidateBackColor = color("hilited_candidate_back_color", accent)
        hilitedCandidateTextColor = color("hilited_candidate_text_color", ThemeColor(red: 1, green: 1, blue: 1))
        hilitedCommentTextColor = color("hilited_comment_text_color", hilitedCandidateTextColor)
        hilitedCandidateLabelColor = color("hilited_candidate_label_color", hilitedCommentTextColor)
    }

    /// Panel background as drawn: dimmed for translucency and overall alpha.
    /// True when the scheme's background is dark; the blur material must match it or
    /// light text ends up on a light backdrop.
    public var hasDarkBackground: Bool {
        let opaque = ThemeColor(red: backColor.red, green: backColor.green, blue: backColor.blue)
        return opaque.contrast(with: ThemeColor(red: 1, green: 1, blue: 1)) > opaque.contrast(with: ThemeColor(red: 0, green: 0, blue: 0))
    }

    public var effectiveBackColor: ThemeColor {
        var back = backColor
        if translucency { back.alpha *= 0.72 }
        back.alpha *= alpha
        return back
    }

    /// Minimum WCAG contrast between candidate text and its background (normal and
    /// highlighted). Used by tests and the appearance editor's legibility warning.
    public var minimumTextContrast: Double {
        let base = dimmedBackground
        let normal = candidateTextColor.over(base).contrast(with: base)
        let highlightBase = hilitedCandidateBackColor.over(base)
        let highlighted = hilitedCandidateTextColor.over(highlightBase).contrast(with: highlightBase)
        return min(normal, highlighted)
    }

    /// Background as seen by the user, assuming a mid-gray desktop behind translucent panels.
    var dimmedBackground: ThemeColor {
        backColor.over(ThemeColor(red: 0.5, green: 0.5, blue: 0.5))
    }
}

extension PanelTheme {
    /// How the highlighted candidate meets the panel's edge.
    public enum HighlightShape: Sendable, Hashable {
        /// Squirrel's edge-to-edge style (borders of 0–2 pt): the highlight reaches the
        /// panel's edge and takes the panel's own corner where it touches one.
        case filled
        /// The highlight floats inside the panel with a margin.
        case inset
    }

    public var highlightShape: HighlightShape { borderWidth <= 2 && borderHeight <= 2 ? .filled : .inset }

    /// Radius of a floating highlight sitting `gap` points inside a panel corner of
    /// `panelRadius`. Close to the corner it is concentric with it (no wedge of panel
    /// color in the corner); with a generous margin the theme's own radius is kept.
    public func insetHighlightRadius(gap: Double, panelRadius: Double) -> Double {
        gap < panelRadius / 2 ? max(2, panelRadius - gap) : min(hilitedCornerRadius, panelRadius)
    }
}
