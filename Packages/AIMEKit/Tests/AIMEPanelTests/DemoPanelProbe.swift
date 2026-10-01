import AppKit
import Testing
@testable import AIMECore
@testable import AIMEPanel

/// Renders the panel states the website's home demo animates (quick menu, AI layer,
/// 常用语, symbol board, typing, AI results) with the real candidate view and AIME's
/// shipped light and dark schemes, so the web demo can match them.
///
///     AIME_DEMO_OUT=<dir> swift test --filter DemoPanelProbe
@MainActor
@Suite struct DemoPanelProbe {
    static func state(_ menu: QuickMenu) -> PanelState {
        let page = menu.page
        if let board = page.board { return PanelState(board: board) }
        var state = PanelState(candidates: page.visibleItems.enumerated().map {
            .init(label: "\($0.offset + 1)", text: $0.element.title, comment: $0.element.detail, symbol: $0.element.symbol)
        }, highlightedIndex: page.highlighted, title: page.title,
        presentation: page.layout == .grid ? .grid : page.layout == .row ? .row : .list)
        if let primary = page.primary {
            state.hero = .init(title: primary.title, detail: primary.detail, symbol: primary.symbol ?? "sparkles", key: "Space")
        }
        return state
    }

    @Test func render() throws {
        guard let out = ProcessInfo.processInfo.environment["AIME_DEMO_OUT"] else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let frontend = try ConfigValue.parse(yaml: String(contentsOf: repo.appendingPathComponent("SharedSupport/aime.yaml"), encoding: .utf8))
        let symbols = try JSONDecoder().decode(QuickMenu.Symbols.self,
                                               from: Data(contentsOf: repo.appendingPathComponent("SharedSupport/aime/symbols.json")))
        var content = QuickMenu.Content(
            symbols: symbols, frequentWords: [("智能体", 42), ("提示词", 30)], usageStatsEnabled: true, polishEnabled: true,
            customActions: ["粤语"],
            snippets: [
                .init(id: "phone", title: "手机号", symbol: nil, items: ["+852 6100 6100"]),
                .init(id: "mail", title: "邮箱", symbol: nil, items: ["hello@zool.app"]),
                .init(id: "addr", title: "地址", symbol: nil, items: ["香港中环皇后大道中 99 号"]),
            ])
        content.hasActionTarget = true
        var menu = QuickMenu(content: content)
        var shots: [(String, PanelState)] = [("menu-root", Self.state(menu))]
        _ = menu.selectPrimary()
        shots.append(("menu-ai", Self.state(menu)))
        menu = QuickMenu(content: content)
        _ = menu.handle(.digit(1))
        shots.append(("menu-snippets", Self.state(menu)))
        menu = QuickMenu(content: content)
        _ = menu.handle(.digit(2))
        shots.append(("menu-symbols", Self.state(menu)))
        shots.append(("typing", PanelState(
            preedit: "wo zhi dao", preeditSelection: NSRange(location: 0, length: 10),
            candidates: [.init(label: "1", text: "我知道"), .init(label: "2", text: "我只到"), .init(label: "3", text: "我"),
                         .init(label: "4", text: "窝"), .init(label: "5", text: "沃")], highlightedIndex: 0)))
        shots.append(("ai-result", PanelState(
            candidates: [.init(label: "1", text: "I know a nice restaurant nearby. See you at eight?", comment: "翻译"),
                         .init(label: "2", text: "I know a great place nearby — shall we meet at 8?", comment: "润色")],
            highlightedIndex: 0, presentation: .paragraphs)))
        shots.append(("ai-cantonese", PanelState(
            candidates: [.init(label: "1", text: "我知附近有間唔錯嘅餐廳，八點見？", comment: "粤语")],
            highlightedIndex: 0, presentation: .paragraphs)))

        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            var config = frontend
            config.set(false, at: "style/translucency")
            let theme = PanelTheme(frontend: config, dark: dark)
            for (name, state) in shots {
                let view = CandidateView()
                view.theme = theme
                view.state = state
                view.layoutSubtreeIfNeeded()
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                try write(view, to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func write(_ view: NSView, to url: URL) throws {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
