import AppKit
import Foundation
import Testing
@testable import AIMECore
@testable import AIMEPanel

struct PanelTests {
    static let frontend: ConfigValue = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedSupport/aime.yaml")
        return try! ConfigValue.load(contentsOf: url)
    }()

    @Test func parsesRimeColorFormats() {
        let bgr = ThemeColor(rime: "0xFF3366CC", format: "bgr")
        #expect(bgr == ThemeColor(red: 0xCC / 255, green: 0x66 / 255, blue: 0x33 / 255, alpha: 1))
        let argb = ThemeColor(rime: "0x80FF0000", format: "argb")
        #expect(argb?.red == 1 && argb?.alpha == Double(0x80) / 255)
        let rgba = ThemeColor(rime: "0x00FF00FF", format: "rgba")
        #expect(rgba?.green == 1 && rgba?.alpha == 1)
        #expect(ThemeColor(rime: "0x112233", format: "bgr")?.alpha == 1)
        #expect(ThemeColor(rime: "nonsense", format: "bgr") == nil)
        #expect(ThemeColor(rime: "0x80FF0000", format: "argb")?.argbString == "0x80FF0000")
    }

    @Test func resolvesLightAndDarkSchemes() {
        let light = PanelTheme(frontend: Self.frontend, dark: false)
        let dark = PanelTheme(frontend: Self.frontend, dark: true)
        #expect(light.schemeName == "aime_light")
        #expect(dark.schemeName == "aime_dark")
        #expect(light.layout == .linear)
        #expect(light.fontPoint == 17)
    }

    @Test(arguments: ["argb", "rgba", "bgr"])
    func numericColorsRetainLeadingZeroes(format: String) throws {
        let yaml = try ConfigValue.parse(yaml: "blue: 31487\nblack: 0\nhex_blue: 0x007AFF\n")
        #expect(yaml["blue"] == .int(0x007AFF))
        #expect(yaml["hex_blue"] == .string("0x007AFF"))
        #expect(ThemeColor(rime: yaml["blue"], format: format) == ThemeColor(rime: "0x007AFF", format: format))
        #expect(ThemeColor(rime: yaml["black"], format: format) == ThemeColor(red: 0, green: 0, blue: 0))
        #expect(ThemeColor(rime: .int(0x80123456), format: format) == ThemeColor(rime: "0x80123456", format: format))
    }

    @Test func explicitAlphaAndInvalidNumericColorsRemainDistinct() {
        #expect(ThemeColor(rime: "0x00000000", format: "argb") == .clear)
        #expect(ThemeColor(rime: "0x00123456", format: "argb")?.alpha == 0)
        #expect(ThemeColor(rime: .int(-1), format: "argb") == nil)
        #expect(ThemeColor(rime: .int(Int(UInt32.max) + 1), format: "argb") == nil)
        #expect(ThemeColor(rime: .double(.infinity), format: "argb") == nil)
        #expect(ThemeColor(rime: .double(1.5), format: "argb") == nil)
    }

    @Test func numericImportedBlueReachesCandidateTheme() throws {
        let frontend = try ConfigValue.parse(yaml: """
        style:
          color_scheme: imported_blue
        preset_color_schemes:
          imported_blue:
            name: 浅蓝测试
            color_format: argb
            back_color: 0xFFFFFF
            candidate_text_color: 0
            hilited_candidate_back_color: 31487
            hilited_candidate_text_color: 0xFFFFFF
        """)
        let theme = PanelTheme(frontend: frontend, dark: false)
        #expect(theme.displayName == "浅蓝测试")
        #expect(theme.hilitedCandidateBackColor == ThemeColor(red: 0, green: Double(0x7A)/255, blue: 1))
        #expect(theme.candidateTextColor == ThemeColor(red: 0, green: 0, blue: 0))
    }

    @Test func legacyHighlightBackgroundIsUsedOnlyWithoutCandidateOverride() throws {
        var frontend = try ConfigValue.parse(yaml: """
        style:
          color_scheme: legacy
        preset_color_schemes:
          legacy:
            hilited_back_color: 0xF8AA4D
        """)
        let expected = ThemeColor(red: Double(0x4D)/255, green: Double(0xAA)/255, blue: Double(0xF8)/255)
        #expect(PanelTheme(frontend: frontend, dark: false).hilitedCandidateBackColor == expected)
        frontend.set("0x0E6BD8", at: "preset_color_schemes/legacy/hilited_candidate_back_color")
        #expect(PanelTheme(frontend: frontend, dark: false).hilitedCandidateBackColor == ThemeColor(rime: "0x0E6BD8", format: "bgr"))
        frontend.set("0x00000000", at: "preset_color_schemes/legacy/hilited_candidate_back_color")
        #expect(PanelTheme(frontend: frontend, dark: false).hilitedCandidateBackColor == .clear)
        frontend.set("invalid", at: "preset_color_schemes/legacy/hilited_candidate_back_color")
        let defaultTheme = PanelTheme(frontend: .map([]), dark: false)
        #expect(PanelTheme(frontend: frontend, dark: false).hilitedCandidateBackColor == defaultTheme.hilitedCandidateBackColor)
    }

    @MainActor @Test func numericBlueIsDrawnByActualCandidateView() throws {
        var frontend = Self.frontend
        frontend.set("argb", at: "preset_color_schemes/aime_light/color_format")
        frontend.set(.int(0x007AFF), at: "preset_color_schemes/aime_light/hilited_candidate_back_color")
        let view = CandidateView()
        view.theme = PanelTheme(frontend: frontend, dark: false)
        view.state = .sample
        view.frame = NSRect(origin: .zero, size: view.fittingContentSize)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var bluePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent < 0.02, abs(color.greenComponent - CGFloat(0x7A)/255) < 0.02,
                   color.blueComponent > 0.98 { bluePixels += 1 }
            }
        }
        #expect(bluePixels > 100)
        if let directory = ProcessInfo.processInfo.environment["AIME_TEST_ARTIFACT_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("I14-candidate-blue.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Every shipped scheme must keep candidate text legible (WCAG AA for large text).
    @Test func shippedSchemesAreLegible() {
        for (id, _) in PanelTheme.schemeNames(in: Self.frontend) {
            let theme = PanelTheme(frontend: Self.frontend, dark: false, schemeOverride: id)
            #expect(theme.minimumTextContrast >= 3.0, "\(id) contrast \(theme.minimumTextContrast)")
        }
    }

    @Test func tokenizesCandidateFormats() {
        #expect(CandidateView.tokenize("[label] [candidate] [comment]", dropComment: true) == ["[label]", " ", "[candidate]"])
        #expect(CandidateView.tokenize("[label]. [candidate] [comment]", dropComment: false) == ["[label]", ". ", "[candidate]", " ", "[comment]"])
    }

    @MainActor
    @Test func layoutGrowsWithCandidatesAndLayout() {
        let view = CandidateView()
        var theme = PanelTheme(frontend: Self.frontend, dark: false)
        view.theme = theme
        view.state = .sample
        let linear = view.fittingContentSize
        theme.layout = .stacked
        view.theme = theme
        let stacked = view.fittingContentSize
        #expect(linear.width > stacked.width)
        #expect(stacked.height > linear.height)
        view.state = PanelState()
        #expect(view.fittingContentSize.height < linear.height)
    }
}

extension PanelTests {
    /// Resizes settle on the exact fitting size (motion off → immediate; on → after the
    /// animation the window shrinks back to fit).
    @MainActor
    @Test func panelSettlesOnFittingSize() {
        let panel = CandidatePanel()
        panel.animationsEnabled = false
        panel.theme = PanelTheme(frontend: Self.frontend, dark: false)
        let cursor = NSRect(x: 200, y: 400, width: 1, height: 18)
        panel.show(.sample, at: cursor)
        let wide = panel.frameSize
        panel.show(PanelState(candidates: [.init(label: "1", text: "你")]), at: cursor)
        #expect(panel.frameSize.width < wide.width)
        #expect(panel.view.fittingContentSize.width == panel.frameSize.width)
        // Typing never shrinks the window while it is visible (no window-server resize).
        let window = panel.windowSize
        #expect(window.width >= wide.width)
        panel.show(.sample, at: cursor)
        #expect(panel.windowSize == window)
        panel.hide()
    }
}

extension PanelTests {
    /// Square-cornered schemes (win10) still get AIME's subtle radius unless the user sets 0.
    @Test func aimeCornerRadiusWinsOverScheme() {
        var frontend = Self.frontend
        frontend.set(.map([.init("corner_radius", 0), .init("hilited_corner_radius", 0)]), at: "preset_color_schemes/square")
        let square = PanelTheme(frontend: frontend, dark: false, schemeOverride: "square")
        #expect(square.cornerRadius == 10 && square.hilitedCornerRadius == 6)
        // Imported Squirrel styles replace the whole style map (no style/aime): soft minimum.
        var imported = frontend
        imported.set(nil, at: "style/aime")
        let soft = PanelTheme(frontend: imported, dark: false, schemeOverride: "square")
        #expect(soft.cornerRadius == 8 && soft.hilitedCornerRadius == 5)
        frontend.set(0, at: "style/aime/corner_radius")
        #expect(PanelTheme(frontend: frontend, dark: false, schemeOverride: "square").cornerRadius == 0)
    }
}

extension PanelTests {
    /// A shorter state after a taller one keeps its text visible: the clip follows the
    /// content's top edge in the (flipped) text view.
    @MainActor
    @Test func textClipFollowsShrinkingContent() {
        let panel = CandidatePanel()
        panel.animationsEnabled = false
        panel.theme = PanelTheme(frontend: Self.frontend, dark: false)
        let cursor = NSRect(x: 200, y: 400, width: 1, height: 18)
        var tall = PanelState.sample
        tall.presentation = .list
        panel.show(tall, at: cursor)
        panel.show(PanelState(candidates: [.init(label: "1", text: "你")]), at: cursor)
        #expect(panel.textClipFrame.minY == 0)
        #expect(panel.textClipFrame.size == panel.frameSize)
        panel.hide()
    }
}

extension PanelTests {
    /// The panel's height depends on the theme only: one candidate, several, emoji or
    /// Latin text all give the same height (no vertical jump while typing).
    @MainActor
    @Test func heightIsIndependentOfCandidateContent() {
        let view = CandidateView()
        view.theme = PanelTheme(frontend: Self.frontend, dark: false)
        func height(_ texts: [String], comment: String = "") -> CGFloat {
            view.state = PanelState(candidates: texts.enumerated().map { .init(label: "\($0.offset + 1)", text: $0.element, comment: comment) })
            return view.fittingContentSize.height
        }
        let single = height(["你"])
        #expect(height(["你好", "👋", "拟好", "Hello", "ǚ", "①"]) == single)
        #expect(height(["你好"], comment: "ni hao") == single)
        #expect(height(["g", "Ágy", "█", "🇨🇳"]) == single)
    }
}

extension PanelTests {
    /// Choosing a scheme changes colors only: layout and font set in AIME Settings
    /// (`style/aime/*`) win over what the scheme carries.
    @Test func settingsWinOverSchemeLayoutAndFont() {
        var frontend = Self.frontend
        frontend.set(.map([.init("candidate_list_layout", "stacked"), .init("font_point", 30)]), at: "preset_color_schemes/vertical")
        let plain = PanelTheme(frontend: frontend, dark: false, schemeOverride: "vertical")
        #expect(plain.layout == .stacked && plain.fontPoint == 30)   // Squirrel semantics without a user choice
        frontend.set("linear", at: "style/aime/candidate_list_layout")
        frontend.set(16, at: "style/aime/font_point")
        let chosen = PanelTheme(frontend: frontend, dark: false, schemeOverride: "vertical")
        #expect(chosen.layout == .linear && chosen.fontPoint == 16)
    }
}

extension PanelTests {
    /// Long candidates (addresses) wrap onto more lines and a single over-long one is
    /// truncated: the panel never exceeds its maximum width, and every candidate stays.
    @MainActor
    @Test func longCandidatesWrapWithinTheMaximumWidth() {
        let view = CandidateView()
        view.theme = PanelTheme(frontend: Self.frontend, dark: false)
        let address = "北京市朝阳区建国路 88 号 SOHO 现代城 A 座 1201 室"
        let state = PanelState(candidates: (1...5).map { .init(label: "\($0)", text: address + " \($0)") }, showsMenuButton: true)
        view.state = state
        let unlimited = view.fittingContentSize
        view.maxContentWidth = 640
        let limited = view.fittingContentSize
        #expect(unlimited.width > 1500)
        #expect(limited.width <= 640)
        #expect(limited.height > unlimited.height * 3)          // one candidate per line now

        view.state = PanelState(candidates: [.init(label: "1", text: String(repeating: "很长的短语", count: 40))])
        #expect(view.fittingContentSize.width <= 640)            // a single candidate is cut with an ellipsis

        view.state = PanelState(candidates: [.init(label: "1", text: "你好"), .init(label: "2", text: "拟好")])
        let short = view.fittingContentSize
        view.maxContentWidth = 0
        #expect(view.fittingContentSize == short)               // ordinary rows are unaffected

        // Nine ordinary candidates stay on one line even when they add up to more than the
        // maximum width; only the screen limit wraps them.
        let nine = PanelState(candidates: (1...9).map { .init(label: "\($0)", text: "人工智能") }, showsMenuButton: true)
        view.state = nine
        let oneLine = view.fittingContentSize
        #expect(oneLine.width > 640)
        view.maxContentWidth = 640
        view.maxRowWidth = 1296
        #expect(view.fittingContentSize == oneLine)
        view.maxRowWidth = 700
        #expect(view.fittingContentSize.width <= 700 && view.fittingContentSize.height > oneLine.height)
        // Long candidates still break at the maximum width, not at the screen.
        view.maxRowWidth = 1296
        view.state = state
        #expect(view.fittingContentSize.width <= 640)
        #expect(PanelTheme(frontend: Self.frontend, dark: false).maxWidth == 640)
    }
}

extension PanelTests {
    /// Work in progress is a small caption with a glow that goes away with the next state.
    @MainActor
    @Test func busyStateIsCompactAndGlows() throws {
        let panel = CandidatePanel()
        panel.animationsEnabled = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] != nil
        panel.theme = PanelTheme(frontend: Self.frontend, dark: ProcessInfo.processInfo.environment["AIME_PANEL_DARK"] != nil)
        let cursor = NSRect(x: 300, y: 500, width: 2, height: 20)
        panel.show(PanelState(status: "正在翻译   Esc 取消"), at: cursor)
        let plain = panel.frameSize
        #expect(!panel.isBusyShown)
        var working = PanelState(status: "正在翻译")
        working.busy = true
        working.statusHint = "Esc 取消"
        panel.show(working, at: cursor)
        #expect(panel.isBusyShown)
        #expect(panel.frameSize.height < plain.height)          // smaller type than a normal status
        // Optional screenshot for visual review: AIME_PANEL_SHOT=/path/to.png
        if let path = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] {
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-R", "270,\(Int(NSScreen.screens[0].frame.height) - 500 - 20),320,110", path]
            try shot.run()
            shot.waitUntilExit()
        }
        panel.show(PanelState(candidates: [.init(label: "1", text: "Hello")]), at: cursor)
        #expect(!panel.isBusyShown)
        panel.hide()
    }
}

extension PanelTests {
    /// A menu page's main action is a full-width row with a glow; it goes away with the page.
    @MainActor
    @Test func heroRowSpansTheGridAndGlows() throws {
        let panel = CandidatePanel()
        panel.animationsEnabled = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] != nil
        panel.theme = PanelTheme(frontend: Self.frontend, dark: ProcessInfo.processInfo.environment["AIME_PANEL_DARK"] != nil)
        let cursor = NSRect(x: 300, y: 500, width: 2, height: 20)
        var state = PanelState(candidates: [
            .init(label: "1", text: "常用语", symbol: "text.quote"), .init(label: "2", text: "符号", symbol: "number"),
            .init(label: "3", text: "高频词", symbol: "chart.bar.xaxis"), .init(label: "4", text: "设置", symbol: "gearshape"),
        ], highlightedIndex: -1, title: "AIME   空格 AI · 数字选择 · Esc 关闭", presentation: .grid)
        panel.show(state, at: cursor)
        let plain = panel.frameSize
        #expect(!panel.isHeroGlowShown && panel.view.heroFrame == .zero)
        state.hero = .init(title: "AI 处理", symbol: "sparkles", key: "Space")
        panel.show(state, at: cursor)
        #expect(panel.isHeroGlowShown)
        #expect(panel.frameSize.height > plain.height)
        let hero = panel.view.heroFrame
        #expect(hero.width > 200 && hero.maxX <= panel.frameSize.width)
        if let path = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] {
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-R", "270,\(Int(NSScreen.screens[0].frame.height) - 500 - 20),440,220", path]
            try shot.run()
            shot.waitUntilExit()
        }
        // Opening a board (符号) from the menu: no main-action row or ring may remain.
        var board = PanelState(board: QuickMenu.Board(style: .grid, categories: [.init(id: "p", title: "标点", symbol: nil, items: ["，", "。", "！"])]))
        board.title = "符号"
        panel.show(board, at: cursor)
        #expect(!panel.isHeroGlowShown && panel.view.heroFrame == .zero)
        panel.show(state, at: cursor)
        panel.show(PanelState(candidates: [.init(label: "1", text: "你好")]), at: cursor)
        #expect(!panel.isHeroGlowShown)
        panel.hide()
    }
}

extension PanelTests {
    /// Long AI results wrap: the highlighted one shows several lines, the others a
    /// two-line preview, all within the paragraph width.
    @MainActor
    @Test func longResultsWrapOntoLines() throws {
        let panel = CandidatePanel()
        panel.animationsEnabled = false
        panel.theme = PanelTheme(frontend: Self.frontend, dark: ProcessInfo.processInfo.environment["AIME_PANEL_DARK"] != nil)
        let cursor = NSRect(x: 300, y: 700, width: 2, height: 20)
        let long = String(repeating: "The quick brown fox jumps over the lazy dog, and then keeps running through the field. ", count: 6)
        let zh = String(repeating: "今天的会议主要讨论了下个季度的产品路线图，以及各个团队需要配合的事项。", count: 5)
        func state(_ highlighted: Int) -> PanelState {
            PanelState(candidates: [.init(label: "1", text: long, comment: "自然"), .init(label: "2", text: zh, comment: "另一种说法"),
                                    .init(label: "3", text: "Short one.", comment: "简洁")],
                       highlightedIndex: highlighted, title: "翻译   ↩ 替换 · C 复制 · Esc 取消", presentation: .paragraphs)
        }
        panel.show(state(0), at: cursor)
        let first = panel.frameSize
        #expect(first.width <= PanelState.paragraphWidth + 60)
        var list = state(0)
        list.presentation = .list
        let single = CandidateView()
        single.theme = panel.theme
        single.state = list
        #expect(first.height > single.fittingContentSize.height * 2)   // several lines instead of one cut line
        panel.show(state(2), at: cursor)
        #expect(panel.frameSize.height < first.height)                  // the long ones fold to a preview
        if let path = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] {
            panel.show(state(0), at: cursor)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-R", "270,\(Int(NSScreen.screens[0].frame.height) - 700 - 20),660,420", path]
            try shot.run()
            shot.waitUntilExit()
        }
        panel.hide()
    }
}

extension PanelTests {
    /// The AI action list wears the ring; the next ordinary state drops it.
    @MainActor
    @Test func aiLayerGlows() throws {
        let panel = CandidatePanel()
        panel.animationsEnabled = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] != nil
        panel.theme = PanelTheme(frontend: Self.frontend, dark: ProcessInfo.processInfo.environment["AIME_PANEL_DARK"] != nil)
        let cursor = NSRect(x: 300, y: 500, width: 2, height: 20)
        var state = PanelState(candidates: [
            .init(label: "1", text: "翻译", comment: "中英互译", symbol: "character.bubble"),
            .init(label: "2", text: "润色", comment: "更通顺，意思不变", symbol: "wand.and.stars"),
            .init(label: "3", text: "更口语", symbol: "sparkle"),
            .init(label: "4", text: "添加自定义动作…", symbol: "plus"),
        ], title: "AI 处理   按数字选择 · Esc 返回", presentation: .list)
        state.glow = true
        panel.show(state, at: cursor)
        #expect(panel.isBusyShown)
        if let path = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-R", "270,\(Int(NSScreen.screens[0].frame.height) - 500 - 20),400,240", path]
            try shot.run()
            shot.waitUntilExit()
        }
        panel.show(PanelState(candidates: [.init(label: "1", text: "你好")]), at: cursor)
        #expect(!panel.isBusyShown)
        panel.hide()
    }
}

extension PanelTests {
    /// A vertical list keeps one column: the AIME button goes to a footer (or the preedit
    /// row), never to the right of the candidates.
    @MainActor
    @Test func verticalListKeepsOneColumnForTheMenuButton() throws {
        let view = CandidateView()
        var theme = PanelTheme(frontend: Self.frontend, dark: false)
        theme.layout = .stacked
        view.theme = theme
        let candidates: [PanelState.Candidate] = ["智能体", "只能", "智能", "职能"].enumerated().map { .init(label: "\($0.offset + 1)", text: $0.element) }
        view.state = PanelState(candidates: candidates)
        let plain = view.fittingContentSize
        view.state = PanelState(candidates: candidates, showsMenuButton: true)
        let withButton = view.fittingContentSize
        #expect(withButton.width == plain.width)                 // no second column
        #expect(withButton.height > plain.height)                // a slim footer instead
        #expect(view.menuButtonFrame.minY >= plain.height - 12)  // below the last candidate
        #expect(view.menuButtonFrame.maxX <= withButton.width)
        // A preedit row in the panel does not pull the button up beside it.
        view.state = PanelState(preedit: "zhi neng", candidates: candidates)
        let withPreedit = view.fittingContentSize
        view.state = PanelState(preedit: "zhi neng", candidates: candidates, showsMenuButton: true)
        #expect(view.menuButtonFrame.minY >= withPreedit.height - 12)
        if let path = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] {
            let panel = CandidatePanel()
            panel.theme = theme
            panel.show(PanelState(candidates: candidates, showsMenuButton: true), at: NSRect(x: 300, y: 500, width: 2, height: 20))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-R", "270,\(Int(NSScreen.screens[0].frame.height) - 500 - 20),260,260", path]
            try shot.run()
            shot.waitUntilExit()
            panel.hide()
        }
    }
}


extension PanelTests {
    /// The draft hint leads with a 中 / 英 chip.
    @MainActor
    @Test func draftHintShowsTheModeChip() throws {
        let view = CandidateView()
        view.theme = PanelTheme(frontend: Self.frontend, dark: false)
        view.state = PanelState(status: "↩ 上屏   长按 ⌥ 动作")
        let plain = view.fittingContentSize
        var state = PanelState(status: "↩ 上屏   长按 ⌥ 动作")
        state.statusBadge = "英"
        view.state = state
        #expect(view.fittingContentSize.width > plain.width + 10)
        #expect(view.fittingContentSize.height == plain.height)
        // The chip belongs to that hint only: the next state (the quick menu) must not keep it.
        view.state = PanelState(candidates: [.init(label: "1", text: "常用语", symbol: "text.quote")], presentation: .grid)
        let menu = view.fittingContentSize
        view.state = PanelState(candidates: [.init(label: "1", text: "常用语", symbol: "text.quote")], title: "x", presentation: .grid)
        view.state = PanelState(candidates: [.init(label: "1", text: "常用语", symbol: "text.quote")], presentation: .grid)
        #expect(view.fittingContentSize == menu && !view.hasStatusBadge)
        if let path = ProcessInfo.processInfo.environment["AIME_PANEL_SHOT"] {
            let panel = CandidatePanel()
            panel.theme = view.theme
            panel.show(state, at: NSRect(x: 300, y: 500, width: 2, height: 20))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-R", "270,\(Int(NSScreen.screens[0].frame.height) - 500 - 20),300,90", path]
            try shot.run()
            shot.waitUntilExit()
            panel.hide()
        }
    }
}
