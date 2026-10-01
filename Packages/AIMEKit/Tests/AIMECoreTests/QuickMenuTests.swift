import Foundation
import Testing
@testable import AIMECore

struct QuickMenuTests {
    let content = QuickMenu.Content(
        phrases: (1...12).map { ("短语\($0)", "dy\($0)") },
        symbols: .init(categories: [.init(id: "math", title: "数学", symbol: "plus", items: ["＋", "－", "×"])]),
        frequentWords: [("智能体", 9)], usageStatsEnabled: true, polishEnabled: false)

    @Test func rootIsAGridAndDigitsOpenModules() {
        var menu = QuickMenu(content: content)
        #expect(menu.page.layout == .grid && menu.page.items.map(\.title) == ["常用语", "符号", "高频词", "设置"])
        #expect(menu.page.primary?.title == "AI 处理")
        #expect(menu.handle(.digit(2)) == .show)
        #expect(menu.page.id == .symbols && menu.page.board?.items == ["＋", "－", "×"])
        _ = menu.handle(.next); _ = menu.handle(.next)
        #expect(menu.handle(.space) == .perform(.insertAndStay("×")))   // keeps the board open
        #expect(menu.handle(.confirm) == .perform(.insert("×")))
    }

    @Test func lettersPickCellsLikeTheKeyboardAndDigitsSwitchTabs() {
        let symbols = QuickMenu.Symbols(categories: [
            .init(id: "a", title: "甲", symbol: nil, items: (0..<45).map { "s\($0)" }),
            .init(id: "b", title: "乙", symbol: nil, items: ["x", "y"]),
        ])
        var menu = QuickMenu(content: .init(symbols: symbols))
        _ = menu.handle(.digit(2))
        #expect(menu.page.board?.columns == 10 && menu.page.board?.visibleRows == 3)
        #expect(menu.handle(.letter("q", shifted: false)) == .perform(.insert("s0")))        // first key of the top row
        #expect(menu.handle(.letter("a", shifted: true)) == .perform(.insertAndStay("s10"))) // home row = second row; ⇧ stays open
        #expect(menu.handle(.letter("/", shifted: false)) == .perform(.insert("s29")))       // last key of the bottom row
        _ = menu.handle(.pageDown)                                                           // rows 2…4 are visible now
        #expect(menu.handle(.letter("q", shifted: false)) == .perform(.insert("s20")))
        #expect(menu.handle(.letter("/", shifted: false)) == .show)                          // no cell behind that key
        #expect(menu.handle(.digit(2)) == .show && menu.page.board?.items == ["x", "y"])
    }

    @Test func snippetCategoriesAreTabsWithThePhraseTableLast() {
        let snippets: [QuickMenu.Symbols.Category] = [
            .init(id: "1", title: "证件", symbol: nil, items: ["身份证 110101…"]),
            .init(id: "2", title: "地址", symbol: nil, items: ["北京市朝阳区…", "上海市徐汇区…"]),
            .init(id: "3", title: "空分类", symbol: nil, items: []),
        ]
        var menu = QuickMenu(content: .init(phrases: [("稍后回复", "uhhf")], snippets: snippets))
        _ = menu.handle(.digit(1))
        #expect(menu.page.board?.style == .list)
        #expect(menu.page.board?.categories.map(\.title) == ["证件", "地址", "短语"])          // empty ones dropped
        _ = menu.handle(.digit(2))
        #expect(menu.handle(.letter("s", shifted: false)) == .perform(.insert("上海市徐汇区…"))) // home-row keys pick rows
        _ = menu.handle(.digit(3))
        #expect(menu.handle(.confirm) == .perform(.insert("稍后回复")))
    }

    @Test func symbolBoardScrollsSwitchesCategoriesAndTakesClicks() {
        let many = QuickMenu.Symbols(categories: [
            .init(id: "a", title: "甲", symbol: nil, items: (0..<95).map { "a\($0)" }),
            .init(id: "b", title: "乙", symbol: nil, items: ["x", "y"]),
            .init(id: "empty", title: "空", symbol: nil, items: []),
        ])
        var menu = QuickMenu(content: .init(symbols: many))
        _ = menu.handle(.digit(2))
        #expect(menu.page.board?.categories.count == 2)                  // empty categories are dropped
        #expect(menu.page.board?.rowCount == 10 && menu.page.board?.visibleRange == 0..<30)
        for _ in 0..<3 { _ = menu.handle(.down) }                        // row 3 → view follows
        #expect(menu.page.board?.highlighted == 30 && menu.page.board?.firstRow == 1)
        _ = menu.handle(.pageDown)
        #expect(menu.page.board?.firstRow == 4)
        #expect(menu.page.board.map { $0.visibleRange.contains($0.highlighted) } == true)
        _ = menu.scrollBoard(rows: 99)
        #expect(menu.page.board?.firstRow == 7)                          // clamped to the last page
        #expect(menu.selectBoardCell(visibleIndex: 3) == .perform(.insertAndStay("a73")))
        _ = menu.handle(.tabNext)
        #expect(menu.page.board?.category == 1 && menu.page.board?.firstRow == 0)
        _ = menu.handle(.tabNext)
        #expect(menu.page.board?.category == 0)                          // wraps
        #expect(menu.selectBoardCategory(1) == .show && menu.page.board?.items == ["x", "y"])
        #expect(menu.handle(.back) == .show && menu.page.id == .root)
    }

    @Test func frequentWordsListPagesAndEscGoesBackThenCloses() {
        let words = (1...12).map { (text: "词\($0)", count: 20 - $0) }
        var menu = QuickMenu(content: .init(frequentWords: words, usageStatsEnabled: true))
        _ = menu.handle(.digit(3))
        #expect(menu.page.visibleItems.count == 9 && menu.page.pageCount == 2)
        #expect(menu.handle(.pageDown) == .show)
        #expect(menu.page.visibleItems.first?.title == "词10")
        #expect(menu.handle(.digit(2)) == .perform(.insert("词11")))
        #expect(menu.handle(.back) == .show)
        #expect(menu.page.id == .root)
        #expect(menu.handle(.back) == .close)
    }

    @Test func arrowsMoveInTwoColumnsAndConfirmSelects() {
        var menu = QuickMenu(content: content)
        #expect(menu.page.highlighted == -1)                                   // the main action is the default
        var fresh = QuickMenu(content: content)
        let opened: QuickMenu.Outcome = fresh.handle(.confirm)
        #expect(opened == QuickMenu.Outcome.show)   // opens the AI page
        _ = menu.handle(.down)      // main action → first item
        _ = menu.handle(.down)      // 0 → 2 (next row)
        _ = menu.handle(.next)      // 2 → 3
        #expect(menu.page.highlighted == 3)
        _ = menu.handle(.up); _ = menu.handle(.up)
        #expect(menu.page.highlighted == -1)                                   // back up to the main action
        _ = menu.handle(.down); _ = menu.handle(.down); _ = menu.handle(.next)
        #expect(menu.handle(.confirm) == .perform(.openSettings(pane: nil)))
        #expect(menu.handle(.space) == .show && menu.page.id == .ai)          // AI off: the page still offers 简繁转换
        #expect(menu.handle(.other) == .passThrough)
    }

    @Test func aiActionsIncludeTheUsersOwn() {
        var menu = QuickMenu(content: .init(polishEnabled: true, customActions: ["更口语", "总结"]))
        #expect(menu.page.items.map(\.title) == ["常用语", "符号", "高频词", "设置"])
        #expect(menu.page.primary?.title == "AI 处理" && menu.page.primary?.detail == "")
        #expect(menu.handle(.digit(4)) == .perform(.openSettings(pane: nil)))
        // Space is the main action: the AI page.
        #expect(menu.handle(.space) == .show && menu.page.id == .ai && menu.page.layout == .list)
        #expect(menu.page.items.map(\.title) == ["翻译", "润色", "简繁转换", "更口语", "总结", "添加自定义动作…"])
        #expect(menu.handle(.digit(1)) == .perform(.text(.translate)))
        #expect(menu.handle(.digit(5)) == .perform(.text(.custom(1))))
        #expect(menu.handle(.digit(6)) == .perform(.openSettings(pane: "ai")))
        #expect(menu.handle(.back) == .show && menu.page.id == .root)
        // The hotkey opens the AI page directly; Esc returns to the root.
        menu.open(.ai)
        #expect(menu.page.id == .ai && menu.handle(.digit(2)) == .perform(.text(.polish)))
        #expect(menu.handle(.back) == .show && menu.page.id == .root)
    }

    @Test func noAIEntryWithoutTextToWorkOn() {
        var content = QuickMenu.Content(polishEnabled: true)
        content.hasActionTarget = false
        var menu = QuickMenu(content: content)
        #expect(menu.page.primary == nil && menu.page.highlighted == 0)
        #expect(menu.page.items.map(\.title) == ["常用语", "符号", "高频词", "设置"])
        #expect(menu.handle(.space) == .show && menu.page.id == .phrases)   // Space is plain confirm again
    }

    @Test func frequentWordsExplainWhenStatisticsAreOff() {
        var menu = QuickMenu(content: QuickMenu.Content())
        _ = menu.handle(.digit(3))
        #expect(menu.page.items.isEmpty && menu.page.emptyMessage.contains("未开启"))
        #expect(menu.handle(.confirm) == .perform(.openSettings(pane: "stats")))
    }

    @Test func shippedSymbolsDecode() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("SharedSupport/aime/symbols.json"))
        let symbols = try JSONDecoder().decode(QuickMenu.Symbols.self, from: data)
        #expect(symbols.categories.count == 10 && symbols.categories.allSatisfy { $0.items.count >= 30 })
    }
}

struct ScriptConverterTests {
    @Test func convertsBothWaysLocally() {
        #expect(ScriptConverter.traditional("头发很长，发展很快") == "頭髮很長，發展很快")
        #expect(ScriptConverter.simplified("頭髮很長，發展很快") == "头发很长，发展很快")
        #expect(ScriptConverter.variants(for: "简体中文").map(\.label) == ["繁体"])
        #expect(ScriptConverter.variants(for: "繁體中文").map(\.label) == ["简体"])
        #expect(ScriptConverter.variants(for: "hello 123").isEmpty)
    }

    @Test func conversionIsOfferedEvenWithAIOff() {
        var menu = QuickMenu(content: .init(polishEnabled: false))
        #expect(menu.handle(.space) == .show && menu.page.id == .ai)
        #expect(menu.page.items.map(\.title) == ["翻译", "润色", "简繁转换", "添加自定义动作…"])
        #expect(menu.handle(.digit(1)) == .perform(.openSettings(pane: "ai")))
        #expect(menu.handle(.digit(3)) == .perform(.text(.convertScript)))
    }
}
