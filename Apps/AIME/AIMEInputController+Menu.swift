import AIMECore
import AIMEPanel
import AppKit
import InputMethodKit

/// Quick menu in the candidate window: 常用语 / 符号 / 高频词 / AI 处理 / 设置.
/// Opened by holding a modifier (⌥ by default), with the panel's AIME button or ⌃⌥M;
/// digits, arrows, Return and Esc walk it — no mouse needed.
extension AIMEInputController {
    func isMenuHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return event.keyCode == 46 && flags == [.control, .option] // ⌃⌥M
    }

    /// Starts the hold timer; when the modifier is still held on its own afterwards, the
    /// menu opens (or closes, if it is already open).
    func scheduleMenuHold(token: Int) {
        // While the key is held a ring fills around the AIME button: the menu grows from there.
        if quickMenu == nil { InputEngine.shared.panel.showHoldCue(duration: ModifierHold.duration) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ModifierHold.duration))
            guard let self else { return }
            guard self.menuHold.fire(token: token) else {
                if !self.menuHold.isArmed { InputEngine.shared.panel.hideHoldCue(animated: true) }
                return
            }
            // Holding again while the menu is open keeps it open: keys pressed with the
            // modifier still down (digits for tabs, letters for cells) act on the menu.
            if self.quickMenu == nil { self.openMenu(client: nil) }
        }
    }

    /// Gathers what the menu can offer (a few small local files) and shows the root page.
    func openMenu(client: (any IMKTextInput)?, page: QuickMenu.PageID? = nil) {
        let engine = InputEngine.shared
        let paths = engine.paths
        let store = SettingsStore(paths: paths)
        let table = store.phraseTables().first { !$0.schemas.isEmpty } ?? PhraseTable(name: "custom_phrase", schemas: [])
        let phrases = CustomPhrases.load(from: store.phraseTableURL(table)).phrases.map { (text: $0.text, code: $0.code) }
        let words = engine.features.usageStats
            ? UsageStatsStore().summary(days: 30).words.prefix(27).map { (text: $0.text, count: $0.count) } : []
        var content = QuickMenu.Content(
            phrases: phrases, symbols: .load(paths), frequentWords: Array(words),
            usageStatsEnabled: engine.features.usageStats, polishEnabled: engine.features.aiPolish,
            customActions: engine.features.aiActions.map(\.name), snippets: Snippets.load(paths).menuCategories)
        // Nothing typed or selected: no AI entry (there is nothing for it to work on).
        content.hasActionTarget = hasActionTarget(client: client)
        quickMenu = QuickMenu(content: content)
        cancelPolish()
        engine.cancelStatus()
        if let page { quickMenu?.open(page) }
        // Lets the first-run guide check off "hold ⌥". An event only, no content.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.zool.aime.menu.opened"), object: nil, userInfo: nil, deliverImmediately: true)
        menuShown = (quickMenu?.stack.count ?? 1, 0)
        showMenu(client: client, transition: .morph)
    }

    func closeMenu() {
        guard quickMenu != nil else { return }
        quickMenu = nil
        // Back to whatever was there: candidates while composing, the draft hint, or nothing.
        if isComposing || !draft.isEmpty {
            InputEngine.shared.panel.pendingTransition = .pop
            sync(client: menuClient(nil))
        } else {
            InputEngine.shared.panel.hide()
        }
    }

    private func menuClient(_ client: (any IMKTextInput)?) -> (any IMKTextInput)? { client ?? (self.client() as? (any IMKTextInput)) }

    /// Draws the current page. Without an explicit transition the direction is derived
    /// from how the page stack changed: deeper pushes, shallower pops, a new category fades.
    private func showMenu(client: (any IMKTextInput)?, transition explicit: CandidatePanel.Transition? = nil) {
        guard let menu = quickMenu else { return }
        let page = menu.page
        let depth = menu.stack.count, category = page.board?.category ?? 0
        let transition: CandidatePanel.Transition = explicit
            ?? (depth > menuShown.depth ? .push : depth < menuShown.depth ? .pop : category != menuShown.category ? .fade : .none)
        menuShown = (depth, category)
        let panel = InputEngine.shared.panel
        let visible = Array(page.visibleItems)
        let title = page.pageCount > 1 ? "\(page.title)  \(page.pageIndex + 1)/\(page.pageCount)"
            : page.id == .root ? "\(page.title)   \(page.primary == nil ? "" : "空格 AI · ")数字选择 · Esc 关闭" : page.title
        panel.view.forcePreedit = false
        if let board = page.board {
            panel.view.onSelect = { [weak self] index in self?.perform(self?.quickMenu?.selectBoardCell(visibleIndex: index) ?? .close, client: nil) }
            panel.view.onTab = { [weak self] index in self?.perform(self?.quickMenu?.selectBoardCategory(index) ?? .close, client: nil) }
            panel.view.onScrollRows = { [weak self] rows in self?.perform(self?.quickMenu?.scrollBoard(rows: rows) ?? .close, client: nil) }
            let state = PanelState(board: board)
            panel.show(state, at: cursorRect(client: menuClient(client)), transition: transition)
            return
        }
        panel.view.onSelect = { [weak self] index in self?.perform(self?.quickMenu?.select(visibleIndex: index) ?? .close, client: nil) }
        panel.view.onPage = { [weak self] backward in self?.perform(self?.quickMenu?.handle(backward ? .pageUp : .pageDown) ?? .close, client: nil) }
        panel.view.onHero = { [weak self] in self?.perform(self?.quickMenu?.selectPrimary() ?? .close, client: nil) }
        var state = visible.isEmpty
            ? PanelState(status: page.emptyMessage)
            : PanelState(
                candidates: visible.enumerated().map {
                    PanelState.Candidate(label: "\($0.offset + 1)", text: $0.element.title, comment: $0.element.detail, symbol: $0.element.symbol)
                },
                highlightedIndex: page.highlighted, title: title,
                presentation: page.layout == .grid ? .grid : page.layout == .row ? .row : .list)
        state.glow = page.id == .ai // the AI layer wears the ring from here to the result
        if let primary = page.primary {
            state.hero = .init(title: primary.title, detail: primary.detail, symbol: primary.symbol ?? "sparkles", key: "Space")
        }
        panel.show(state, at: cursorRect(client: menuClient(client)), transition: transition)
    }

    /// Returns true when the key belongs to the menu.
    func handleMenuKey(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        guard quickMenu != nil else { return false }
        // The key that opened the menu may still be held: digits then count as plain digits,
        // so "hold, press 2" works without letting go.
        let flags = NSEvent.ModifierFlags(rawValue: menuHold.withoutHoldKey(event.modifierFlags.rawValue))
        let plain = flags.intersection([.command, .option, .control]).isEmpty
        let key: QuickMenu.Key
        switch event.keyCode {
        case 53: key = .back
        case 36, 76: key = .confirm
        case 49: key = .space
        case 48: key = event.modifierFlags.contains(.shift) ? .tabPrevious : .tabNext
        case 124: key = .next
        case 123: key = .previous
        case 125: key = .down
        case 126: key = .up
        case 121: key = .pageDown
        case 116: key = .pageUp
        case 51: key = .back // ⌫ goes up one level, like Esc
        default:
            let character = event.charactersIgnoringModifiers ?? ""
            let onBoard = quickMenu?.page.board != nil
            if plain, let digit = Int(character) { key = .digit(digit == 0 ? 10 : digit) } // 0 is the tenth tab
            // Boards: the letter rows pick the cell under that key (⇧ keeps the board open).
            // `charactersIgnoringModifiers` keeps Shift, so map by key position instead.
            else if plain, onBoard, let letter = Self.boardKey(forKeyCode: event.keyCode) {
                key = .letter(letter, shifted: event.modifierFlags.contains(.shift))
            }
            else if plain, onBoard, ["=", "]"].contains(character) { key = .pageDown }
            else if plain, onBoard, ["-", "["].contains(character) { key = .pageUp }
            else if plain, ["=", ".", "]"].contains(character) { key = .pageDown }
            else if plain, ["-", ",", "["].contains(character) { key = .pageUp }
            else { key = .other }
        }
        guard let outcome = quickMenu?.handle(key) else { return false }
        return perform(outcome, client: client)
    }

    /// The unshifted character of a letter-row key (ANSI positions): Q…P, A…;, Z…/.
    static func boardKey(forKeyCode keyCode: UInt16) -> Character? {
        let keys: [UInt16: Character] = [
            12: "q", 13: "w", 14: "e", 15: "r", 17: "t", 16: "y", 32: "u", 34: "i", 31: "o", 35: "p",
            0: "a", 1: "s", 2: "d", 3: "f", 5: "g", 4: "h", 38: "j", 40: "k", 37: "l", 41: ";",
            6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 45: "n", 46: "m", 43: ",", 47: ".", 44: "/",
        ]
        return keys[keyCode]
    }

    @discardableResult
    private func perform(_ outcome: QuickMenu.Outcome, client: (any IMKTextInput)?) -> Bool {
        let client = menuClient(client)
        switch outcome {
        case .show:
            showMenu(client: client)
            return true
        case .close:
            closeMenu()
            return true
        case .passThrough:
            closeMenu()
            return false
        case let .perform(action):
            switch action {
            case .open:
                showMenu(client: client)
            case let .insertAndStay(text):
                // The board stays open for the next symbol.
                client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                showMenu(client: client)
            case let .insert(text):
                quickMenu = nil
                InputEngine.shared.panel.hide()
                // A pending composition is dropped: the inserted text replaces it.
                if isComposing { self.session?.clearComposition() }
                client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                sync(client: client)
            case let .openSettings(pane):
                closeMenu()
                openSettings(pane: pane)
            case let .text(kind):
                // The result list takes the menu's place; closing must not flash the draft hint.
                quickMenu = nil
                // Chosen while composing: the highlighted candidate is put in first and
                // becomes what the action works on.
                if kind == .convertScript {
                    startConversion(client: client, committed: commitForAction(client: client))
                    return true
                }
                guard let action = textAction(for: kind) else { closeMenu(); return true }
                startAction(action, client: client, committed: commitForAction(client: client))
            case let .notice(message):
                InputEngine.shared.showStatus(message)
            }
            return true
        }
    }
}
