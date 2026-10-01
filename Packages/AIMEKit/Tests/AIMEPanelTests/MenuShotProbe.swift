import AppKit
import Testing
@testable import AIMECore
@testable import AIMEPanel

/// Renders the quick menu into screenshots (AIME_PANEL_SHOTS=<dir>); skipped otherwise.
@MainActor
@Suite(.serialized)
struct MenuShotProbe {
    static func state(_ menu: QuickMenu) -> PanelState {
        let page = menu.page
        if let board = page.board { return PanelState(board: board) }
        return PanelState(candidates: page.visibleItems.enumerated().map {
            .init(label: "\($0.offset + 1)", text: $0.element.title, comment: $0.element.detail, symbol: $0.element.symbol)
        }, highlightedIndex: page.highlighted, title: page.title,
        presentation: page.layout == .grid ? .grid : page.layout == .row ? .row : .list)
    }

    @Test(arguments: [false, true]) func shot(dark: Bool) async throws {
        guard let out = ProcessInfo.processInfo.environment["AIME_PANEL_SHOTS"] else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let symbols = try JSONDecoder().decode(QuickMenu.Symbols.self,
                                               from: Data(contentsOf: repo.appendingPathComponent("SharedSupport/aime/symbols.json")))
        let panel = CandidatePanel()
        var theme = PanelTheme(frontend: PanelTests.frontend, dark: dark)
        theme.translucency = false
        panel.theme = theme
        let screen = NSScreen.main!.frame
        let cursor = NSRect(x: 300, y: screen.height - 300, width: 1, height: 18)
        var menu = QuickMenu(content: .init(
            phrases: [("稍后回复你", "uhhf"), ("我的邮箱是 hi@example.com", "yx"), ("收到，谢谢！", "sd")],
            symbols: symbols, frequentWords: [("智能体", 42), ("提示词", 30)], usageStatsEnabled: true, polishEnabled: true,
            snippets: [
                .init(id: "1", title: "证件", symbol: nil, items: ["110101199001011234", "护照 E12345678"]),
                .init(id: "2", title: "手机号", symbol: nil, items: ["138 0000 0000", "+1 (415) 555-0100"]),
                .init(id: "3", title: "地址", symbol: nil, items: ["北京市朝阳区建国路 88 号 SOHO 现代城 A 座 1201 室，邮编 100022，收件人 罗先生", "上海市徐汇区漕溪北路 1 号"]),
            ]))
        var shots: [(String, PanelState)] = [("root", Self.state(menu))]
        _ = menu.handle(.digit(1)); _ = menu.handle(.digit(3))
        shots.append(("snippets", Self.state(menu)))
        _ = menu.handle(.back)
        _ = menu.handle(.digit(2)); _ = menu.handle(.next); _ = menu.handle(.down)
        shots.append(("board-zh", Self.state(menu)))
        _ = menu.handle(.tabNext); _ = menu.handle(.tabNext); _ = menu.handle(.pageDown)
        shots.append(("board-num", Self.state(menu)))
        for (name, state) in shots {
            panel.show(state, at: cursor)
            try await Task.sleep(for: .milliseconds(450))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R", "270,250,560,330", "\(out)/menu-\(name)-\(dark ? "dark" : "light").png"]
            try process.run(); process.waitUntilExit()
        }
        panel.hide()
    }
}
