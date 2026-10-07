public import Foundation

/// The quick menu opened from the candidate window (button or hotkey): a small stack of
/// pages the user walks with digits / arrows / Return / Esc. Pure state — the input
/// method renders `page` in the panel and performs the returned `Outcome`.
public struct QuickMenu: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case open(PageID)
        /// Commit this text into the app and close the menu.
        case insert(String)
        /// Commit this text and keep the menu open (several symbols in a row).
        case insertAndStay(String)
        case openSettings(pane: String?)
        /// Run an AI action on the draft, the selection or the text just typed.
        case text(TextActionKind)
        /// Not available: show the message, stay on the page.
        case notice(String)
    }

    public enum TextActionKind: Sendable, Equatable {
        case polish, translate
        /// 简繁转换: local, no AI involved.
        case convertScript
        /// Index into the user's custom actions.
        case custom(Int)
    }

    public enum PageID: Sendable, Equatable {
        case root, phrases, symbols, symbolCategory(String), frequentWords, emojis, ai
    }

    public struct Item: Sendable, Equatable {
        public var title: String
        public var detail: String
        /// SF Symbol name (grid pages).
        public var symbol: String?
        /// Explicit digit for reserved root entries; other items use their position.
        public var selectionKey: Int?
        public var action: Action

        public init(_ title: String, detail: String = "", symbol: String? = nil, selectionKey: Int? = nil, action: Action) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.selectionKey = selectionKey
            self.action = action
        }
    }

    public struct Page: Sendable, Equatable {
        public enum Layout: Sendable, Equatable { case grid, list, row }
        public var id: PageID
        public var title: String
        public var layout: Layout
        public var items: [Item]
        /// Shown when `items` is empty.
        public var emptyMessage: String
        public var highlighted = 0
        public var pageIndex = 0
        /// The symbol keyboard: category tabs over a scrolling grid (replaces `items`).
        public var board: Board?
        /// The page's main action, shown above the items and run with Space.
        public var primary: Item?
        public var pageSize: Int { layout == .grid ? 8 : 9 }

        public var pageCount: Int { max(1, (items.count + pageSize - 1) / pageSize) }
        public var visibleItems: ArraySlice<Item> {
            let start = min(pageIndex * pageSize, items.count)
            return items[start..<min(start + pageSize, items.count)]
        }

        public func selectionKey(visibleIndex index: Int) -> Int {
            let visible = Array(visibleItems)
            guard visible.indices.contains(index) else { return index + 1 }
            return visible[index].selectionKey ?? index + 1
        }
    }

    /// Category tabs over a scrolling grid (symbols) or list (常用语), like a phone's
    /// symbol keyboard. Digits switch the tab; every visible cell has a letter key, laid
    /// out like the keyboard itself, that picks it directly.
    public struct Board: Sendable, Equatable {
        public enum Style: Sendable, Equatable {
            /// 10 columns × 3 rows, keyed by the three letter rows of the keyboard.
            case grid
            /// One item per row, keyed by the home row.
            case list
        }

        public var style: Style
        public var categories: [Symbols.Category]
        public var category = 0
        /// Index into the current category's items.
        public var highlighted = 0
        /// First visible row.
        public var firstRow = 0

        public init(style: Style, categories: [Symbols.Category]) {
            self.style = style
            self.categories = categories
        }

        public var columns: Int { style == .grid ? 10 : 1 }
        /// Grid: the three letter rows. List: as many rows as the fullest category needs,
        /// up to the home row's nine keys, so the panel keeps one height across tabs.
        public var visibleRows: Int {
            style == .grid ? 3 : min(Self.listKeys.count, max(1, categories.map(\.items.count).max() ?? 1))
        }
        /// Keys for the visible cells, in reading order.
        public var keys: [Character] { style == .grid ? Self.gridKeys : Self.listKeys }
        static let gridKeys = Array("qwertyuiopasdfghjkl;zxcvbnm,./")
        static let listKeys = Array("asdfghjkl")

        public var items: [String] { categories.indices.contains(category) ? categories[category].items : [] }
        public var rowCount: Int { (items.count + columns - 1) / columns }
        public var maxFirstRow: Int { max(0, rowCount - visibleRows) }
        /// Items currently on screen.
        public var visibleRange: Range<Int> {
            let start = min(firstRow * columns, items.count)
            return start..<min(start + columns * visibleRows, items.count)
        }

        /// The item a letter key picks, if that cell is on screen.
        public func item(forKey key: Character) -> (index: Int, text: String)? {
            guard let position = keys.firstIndex(of: key) else { return nil }
            let index = visibleRange.lowerBound + position
            return visibleRange.contains(index) ? (index, items[index]) : nil
        }

        mutating func selectCategory(_ index: Int) {
            guard !categories.isEmpty else { return }
            category = (index % categories.count + categories.count) % categories.count
            highlighted = 0
            firstRow = 0
        }

        /// Moves the highlight; the view follows so it stays visible.
        mutating func move(by delta: Int) {
            guard !items.isEmpty else { return }
            let target = highlighted + delta
            guard items.indices.contains(target) else { return }
            highlighted = target
            revealHighlight()
        }

        mutating func revealHighlight() {
            let row = highlighted / columns
            if row < firstRow { firstRow = row }
            if row >= firstRow + visibleRows { firstRow = row - visibleRows + 1 }
            firstRow = min(max(0, firstRow), maxFirstRow)
        }

        /// Scrolls by rows (wheel / Page keys); the highlight is pulled into view.
        mutating func scroll(rows: Int) {
            firstRow = min(max(0, firstRow + rows), maxFirstRow)
            guard !items.isEmpty else { return }
            let row = highlighted / columns
            if row < firstRow { highlighted = min(items.count - 1, firstRow * columns + highlighted % columns) }
            if row >= firstRow + visibleRows {
                highlighted = min(items.count - 1, (firstRow + visibleRows - 1) * columns + highlighted % columns)
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Redraw the (possibly different) current page.
        case show
        case perform(Action)
        /// The menu closed without an action.
        case close
        /// Not a menu key: close and let the key through.
        case passThrough
    }

    public enum Key: Sendable, Equatable {
        case digit(Int), next, previous, up, down, confirm, space, back, pageDown, pageUp, tabNext, tabPrevious
        /// A letter-row key on a board; shifted keeps the board open after inserting.
        case letter(Character, shifted: Bool)
        case other
    }

    public struct Symbols: Sendable, Codable, Equatable {
        public struct Category: Sendable, Codable, Equatable {
            public var id: String
            public var title: String
            public var symbol: String?
            public var items: [String]
        }
        public var categories: [Category]

        public init(categories: [Category] = []) { self.categories = categories }

        /// `aime/symbols.json` from the user directory (override) or the shared data.
        public static func load(_ paths: AIMEPaths) -> Symbols {
            load(paths, filename: "symbols.json")
        }

        /// `aime/emoji.json` uses the same category board and user override rules.
        public static func loadEmojis(_ paths: AIMEPaths) -> Symbols {
            load(paths, filename: "emoji.json")
        }

        private static func load(_ paths: AIMEPaths, filename: String) -> Symbols {
            let candidates = [paths.aimeDir.appendingPathComponent(filename),
                              paths.sharedDataDir?.appendingPathComponent("aime/\(filename)")].compactMap(\.self)
            for url in candidates {
                if let data = try? Data(contentsOf: url), let symbols = try? JSONDecoder().decode(Symbols.self, from: data) { return symbols }
            }
            return Symbols()
        }
    }

    /// What the menu can show; gathered by the caller when the menu opens.
    public struct Content: Sendable, Equatable {
        public var phrases: [(text: String, code: String)] { phraseTexts.indices.map { (phraseTexts[$0], phraseCodes[$0]) } }
        var phraseTexts: [String]
        var phraseCodes: [String]
        public var symbols: Symbols
        public var emojis: Symbols
        public var frequentWords: [(text: String, count: Int)] { wordTexts.indices.map { (wordTexts[$0], wordCounts[$0]) } }
        var wordTexts: [String]
        var wordCounts: [Int]
        public var usageStatsEnabled: Bool
        public var polishEnabled: Bool
        /// There is text an AI action could work on (a composition, a draft, a selection
        /// or something just typed). Without it the menu offers no AI entry.
        public var hasActionTarget = true
        /// Names of the user's custom AI actions.
        public var customActions: [String]
        /// The user's 常用语 categories (证件, 手机号, 地址…).
        public var snippets: [Symbols.Category]

        public init(phrases: [(text: String, code: String)] = [], symbols: Symbols = Symbols(),
                    frequentWords: [(text: String, count: Int)] = [], usageStatsEnabled: Bool = false, polishEnabled: Bool = false,
                    customActions: [String] = [], snippets: [Symbols.Category] = [], emojis: Symbols = Symbols()) {
            phraseTexts = phrases.map(\.text)
            phraseCodes = phrases.map(\.code)
            self.symbols = symbols
            self.emojis = emojis
            wordTexts = frequentWords.map(\.text)
            wordCounts = frequentWords.map(\.count)
            self.usageStatsEnabled = usageStatsEnabled
            self.polishEnabled = polishEnabled
            self.customActions = customActions
            self.snippets = snippets
        }
    }

    public let content: Content
    /// Current page is last; Esc pops.
    public private(set) var stack: [Page]

    public init(content: Content) {
        self.content = content
        stack = []
        stack = [makePage(.root)]
    }

    public var page: Page { stack[stack.count - 1] }

    func makePage(_ id: PageID) -> Page {
        switch id {
        case .root:
            let items = [
                Item("常用语", symbol: "text.quote", action: .open(.phrases)),
                Item("符号", symbol: "number", action: .open(.symbols)),
                Item("高频词", symbol: "chart.bar.xaxis", action: .open(.frequentWords)),
                Item("表情", symbol: "face.smiling", action: .open(.emojis)),
                Item("设置", symbol: "gearshape", selectionKey: 0, action: .openSettings(pane: nil)),
            ]
            var page = Page(id: id, title: "AIME", layout: .grid, items: items, emptyMessage: "")
            // AI is the main action: Space opens it, digits pick the rest. When AI is off
            // it leads to its settings.
            guard content.hasActionTarget else { return page }
            // Opens even with AI off: 简繁转换 there is local.
            page.primary = Item("AI 处理", symbol: "sparkles", action: .open(.ai))
            page.highlighted = -1 // nothing in the grid is selected: Return runs the main action too
            return page
        case .ai:
            // The actions work on the draft, the selection, or what was just typed.
            // With AI off its actions lead to the setting; 简繁转换 runs locally either way.
            let on = content.polishEnabled
            func ai(_ kind: TextActionKind) -> Action { on ? .text(kind) : .openSettings(pane: "ai") }
            var items = [
                Item("翻译", detail: on ? "中英互译" : "AI 未开启", symbol: "character.bubble", action: ai(.translate)),
                Item("润色", detail: on ? "更通顺，意思不变" : "AI 未开启", symbol: "wand.and.stars", action: ai(.polish)),
                Item("简繁转换", detail: "本地转换", symbol: "arrow.triangle.2.circlepath", action: .text(.convertScript)),
            ]
            for (index, name) in content.customActions.enumerated() {
                items.append(Item(name, symbol: "sparkle", action: ai(.custom(index))))
            }
            items.append(Item("添加自定义动作…", symbol: "plus", action: .openSettings(pane: "ai")))
            return Page(id: id, title: "AI 处理   按数字选择 · Esc 返回", layout: .list, items: items, emptyMessage: "")
        case .phrases:
            // The user's categories first, then the custom phrase table as a last tab.
            var page = Page(id: id, title: "常用语", layout: .list, items: [], emptyMessage: "还没有常用语：在设置 › 常用语 里添加分类和内容")
            var categories = content.snippets.filter { !$0.items.isEmpty }
            if !content.phrases.isEmpty {
                categories.append(.init(id: "phrases", title: "短语", symbol: nil, items: content.phrases.map(\.text)))
            }
            if !categories.isEmpty { page.board = Board(style: .list, categories: categories) }
            return page
        case .symbols:
            var page = Page(id: id, title: "符号", layout: .grid, items: [], emptyMessage: "没有可用的符号表")
            let categories = content.symbols.categories.filter { !$0.items.isEmpty }
            if !categories.isEmpty { page.board = Board(style: .grid, categories: categories) }
            return page
        case .emojis:
            var page = Page(id: id, title: "表情", layout: .grid, items: [], emptyMessage: "没有可用的表情表")
            let categories = content.emojis.categories.filter { !$0.items.isEmpty }
            if !categories.isEmpty { page.board = Board(style: .grid, categories: categories) }
            return page
        case let .symbolCategory(category):
            let found = content.symbols.categories.first { $0.id == category }
            let items = (found?.items ?? []).map { Item($0, action: .insert($0)) }
            return Page(id: id, title: found?.title ?? "符号", layout: .row, items: items, emptyMessage: "这个分类是空的")
        case .frequentWords:
            let items = content.frequentWords.map { Item($0.text, detail: "\($0.count) 次", action: .insert($0.text)) }
            let empty = content.usageStatsEnabled ? "还没有统计数据，打一会儿字再来看" : "高频词统计未开启，按回车前往设置"
            return Page(id: id, title: "高频词", layout: .list, items: items, emptyMessage: empty)
        }
    }

    /// Jumps straight to a page (a hotkey); Esc still goes back to the root.
    public mutating func open(_ id: PageID) {
        stack = [makePage(.root), makePage(id)]
    }

    // MARK: - Symbol board (mouse)

    /// Click on a category tab.
    public mutating func selectBoardCategory(_ index: Int) -> Outcome {
        guard stack[stack.count - 1].board != nil else { return .show }
        stack[stack.count - 1].board?.selectCategory(index)
        return .show
    }

    /// Click on a visible cell: insert and stay open.
    public mutating func selectBoardCell(visibleIndex index: Int) -> Outcome {
        guard var board = stack[stack.count - 1].board else { return .show }
        let absolute = board.visibleRange.lowerBound + index
        guard board.items.indices.contains(absolute) else { return .show }
        board.highlighted = absolute
        stack[stack.count - 1].board = board
        return .perform(.insertAndStay(board.items[absolute]))
    }

    public mutating func scrollBoard(rows: Int) -> Outcome {
        stack[stack.count - 1].board?.scroll(rows: rows)
        return .show
    }

    private mutating func handleBoard(_ key: Key) -> Outcome {
        guard var board = stack[stack.count - 1].board else { return .show }
        defer { if stack.last?.board != nil { stack[stack.count - 1].board = board } }
        switch key {
        case .back:
            stack.removeLast()
            return stack.isEmpty ? .close : .show
        case .next: board.move(by: 1)
        case .previous: board.move(by: -1)
        case .down: board.move(by: board.columns)
        case .up: board.move(by: -board.columns)
        case .pageDown: board.scroll(rows: board.visibleRows)
        case .pageUp: board.scroll(rows: -board.visibleRows)
        case .tabNext: board.selectCategory(board.category + 1)
        case .tabPrevious: board.selectCategory(board.category - 1)
        case let .digit(number):
            // Digits jump to a category (1 = first tab, 0 would be the tenth).
            let tabNumber = number == 0 ? 10 : number
            if (1...board.categories.count).contains(tabNumber) { board.selectCategory(tabNumber - 1) }
        case .confirm:
            guard board.items.indices.contains(board.highlighted) else { return .show }
            return .perform(.insert(board.items[board.highlighted]))
        case .space:
            guard board.items.indices.contains(board.highlighted) else { return .show }
            return .perform(.insertAndStay(board.items[board.highlighted]))
        case let .letter(key, shifted):
            // The key's cell, laid out like the keyboard. Unshifted inserts and closes;
            // shifted inserts and stays for the next one.
            guard let picked = board.item(forKey: key) else { return .show }
            board.highlighted = picked.index
            return .perform(shifted ? .insertAndStay(picked.text) : .insert(picked.text))
        case .other:
            return .passThrough
        }
        return .show
    }

    /// Runs the page's main action (Space, or a click on it).
    public mutating func selectPrimary() -> Outcome {
        guard let primary = page.primary else { return .show }
        if case let .open(id) = primary.action {
            stack.append(makePage(id))
            return .show
        }
        return .perform(primary.action)
    }

    /// Activates the visible item at `index` (mouse click or digit).
    public mutating func select(visibleIndex index: Int) -> Outcome {
        let visible = Array(page.visibleItems)
        guard visible.indices.contains(index) else { return .show }
        switch visible[index].action {
        case let .open(id):
            stack.append(makePage(id))
            return .show
        case let action:
            return .perform(action)
        }
    }

    public mutating func handle(_ key: Key) -> Outcome {
        if page.board != nil {
            let outcome = handleBoard(key)
            if stack.isEmpty { stack = [makePage(.root)]; return .close }
            return outcome
        }
        var current = page
        let visibleCount = current.visibleItems.count
        defer { if stack.last?.id == current.id { stack[stack.count - 1] = current } }
        switch key {
        case .back:
            guard stack.count > 1 else { return .close }
            stack.removeLast()
            current = page
            return .show
        case .tabNext, .tabPrevious:
            return .show
        case .letter:
            return .passThrough
        case .confirm, .space:
            if current.primary != nil, key == .space || current.highlighted < 0 {
                stack[stack.count - 1] = current
                let outcome = selectPrimary()
                current = page
                return outcome
            }
            if visibleCount == 0 {
                // Empty 高频词 with statistics off: Return leads to the setting.
                if current.id == .frequentWords, !content.usageStatsEnabled { return .perform(.openSettings(pane: "stats")) }
                return .show
            }
            stack[stack.count - 1] = current
            let outcome = select(visibleIndex: current.highlighted)
            current = page
            return outcome
        case let .digit(number):
            guard let index = (0..<visibleCount).first(where: { current.selectionKey(visibleIndex: $0) == number }) else { return .show }
            stack[stack.count - 1] = current
            let outcome = select(visibleIndex: index)
            current = page
            return outcome
        case .next, .previous, .up, .down:
            guard visibleCount > 0 else { return .show }
            let columns = current.layout == .grid ? 2 : 1
            if current.primary != nil {
                // From the main action into the items, and back up to it from the first row.
                if current.highlighted < 0 { current.highlighted = 0; return .show }
                if key == .up, current.highlighted < columns { current.highlighted = -1; return .show }
            }
            let step: Int = switch key {
            case .next: 1
            case .previous: -1
            case .down: columns
            default: -columns
            }
            current.highlighted = ((current.highlighted + step) % visibleCount + visibleCount) % visibleCount
            return .show
        case .pageDown:
            if current.pageIndex + 1 < current.pageCount { current.pageIndex += 1; current.highlighted = 0 }
            return .show
        case .pageUp:
            if current.pageIndex > 0 { current.pageIndex -= 1; current.highlighted = 0 }
            return .show
        case .other:
            return .passThrough
        }
    }
}
