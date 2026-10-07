import AIMEAI
import AIMECore
import AIMEPanel
import AppKit
import InputMethodKit

/// State of one AI action: the text it works on and the model's variants.
struct PolishSession {
    enum Target: Equatable {
        /// The pending draft (输入图层).
        case draft(String)
        /// Text already in the app: a selection, or what was just typed (read back first).
        case range(NSRange, String)

        var text: String {
            switch self {
            case let .draft(text), let .range(_, text): text
            }
        }
    }

    let target: Target
    let title: String
    var variants: [TextPolisher.Variant] = []
    var highlighted = 0
    var task: Task<Void, Never>?
}

/// AI actions (润色 / 翻译 / the user's own prompts) on explicit request only. They work on,
/// in this order: the pending draft, the candidate just put in (an action chosen while
/// composing), the selection, or the text just typed into this field. That text is held in memory for the request and never logged; nothing else —
/// not the composition, not learned frequencies — is involved.
extension AIMEInputController {
    func isPolishHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return event.keyCode == 35 && flags == [.control, .option] // ⌃⌥P
    }

    /// Maps a quick-menu choice to the action (custom ones come from features.json).
    func textAction(for kind: QuickMenu.TextActionKind) -> TextAction? {
        switch kind {
        case .polish: return .polish
        case .translate: return .translate
        case let .custom(index):
            let actions = InputEngine.shared.features.aiActions
            guard actions.indices.contains(index) else { return nil }
            return .custom(name: actions[index].name, prompt: actions[index].prompt)
        case .convertScript:
            return nil // local, see startConversion
        }
    }

    /// 简繁转换 of the same target an AI action would use, done on the Mac (no request):
    /// the results list appears right away and applies like any other result.
    func startConversion(client: (any IMKTextInput)?, committed: String?) {
        let engine = InputEngine.shared
        guard let client = client ?? (self.client() as? (any IMKTextInput)) else { return }
        guard let target = actionTarget(client: client, committed: committed) else {
            return engine.showStatus("没有可处理的文字：先打一段字，或选中一段文字")
        }
        let variants = ScriptConverter.variants(for: target.text)
        guard !variants.isEmpty else { return engine.showStatus("没有需要转换的简繁字") }
        engine.cancelStatus()
        polish = PolishSession(target: target, title: "简繁转换",
                               variants: variants.map { TextPolisher.Variant(label: $0.label, text: $0.text) })
        showPolish(client: client, transition: .push)
    }

    /// What the action should work on, or nil when there is nothing suitable.
    private func actionTarget(client: any IMKTextInput, committed: String?) -> PolishSession.Target? {
        if !draft.isEmpty { return .draft(draft.text) }
        let selected = client.selectedRange()
        // The candidate that was put in for this action: only that word or phrase.
        if let committed, selected.location != NSNotFound, selected.length == 0, selected.location >= committed.utf16.count {
            let range = NSRange(location: selected.location - committed.utf16.count, length: committed.utf16.count)
            if client.attributedSubstring(from: range)?.string == committed { return .range(range, committed) }
        }
        if selected.location != NSNotFound, selected.length > 0,
           let text = client.attributedSubstring(from: selected)?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .range(selected, text)
        }
        // No selection: what was just typed here, if the app still has it right before the caret.
        if let range = recentText.range(caretAt: selected.location),
           client.attributedSubstring(from: range)?.string == recentText.text,
           !recentText.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .range(range, recentText.text)
        }
        return nil
    }

    /// Whether an action would have something to work on right now.
    func hasActionTarget(client: (any IMKTextInput)?) -> Bool {
        if isComposing || !draft.isEmpty { return true }
        guard let client = client ?? (self.client() as? (any IMKTextInput)) else { return false }
        return actionTarget(client: client, committed: nil) != nil
    }

    func startAction(_ action: TextAction, client: (any IMKTextInput)?, committed: String? = nil) {
        let engine = InputEngine.shared
        let features = engine.features
        guard features.aiPolish else { return engine.showStatus("AI 动作未开启：设置 › AI 助手") }
        guard let client = client ?? (self.client() as? (any IMKTextInput)) else { return }
        guard let target = actionTarget(client: client, committed: committed) else {
            return engine.showStatus("没有可处理的文字：先打一段字，或选中一段文字")
        }
        let text = target.text
        guard text.utf16.count <= TextPolisher.maxLength else {
            return engine.showStatus("文字太长（上限 \(TextPolisher.maxLength) 字）")
        }

        let provider: any AIProvider
        if features.aiProvider == "openai" {
            guard features.aiRemoteAllowed, let url = URL(string: features.aiBaseURL) else {
                return engine.showStatus("未允许把文字发送到自备接口：设置 › AI 助手")
            }
            provider = OpenAICompatibleProvider(baseURL: url, model: features.aiModel)
        } else {
            provider = FoundationModelsProvider()
        }

        engine.cancelStatus()
        var working = PanelState(status: "正在\(action.title)")
        working.busy = true
        working.statusHint = "Esc 取消"
        engine.panel.show(working, at: cursorRect(client: client), transition: .push)
        var request = PolishSession(target: target, title: action.title)
        request.task = Task { @MainActor [weak self] in
            if case let .unavailable(reason) = await provider.availability() {
                self?.cancelPolish(message: reason)
                return
            }
            do {
                let variants = try await TextActionRunner(provider: provider).run(action, on: text)
                guard !Task.isCancelled, let self, self.polish?.target == target else { return }
                guard !variants.isEmpty else { return self.cancelPolish(message: "没有可用的结果") }
                self.polish?.variants = variants
                self.showPolish(client: client, transition: .push)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? AIError)?.description ?? "\(action.title)失败"
                self?.cancelPolish(message: message.count > 60 ? String(message.prefix(60)) + "…" : message)
            }
        }
        polish = request
    }

    /// Keys while a request is open. The request owns the keyboard until it is applied or
    /// cancelled: digits / ↩ / Space apply, arrows move, C copies, Esc cancels. Nothing
    /// else reaches the app — a Return pressed a moment too early must not send the
    /// message, and a stray key must not overwrite the selection. Only ⌘ shortcuts end
    /// the request and go through.
    func handlePolishKey(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        guard let request = polish else { return false }
        if event.keyCode == 53 { // Esc
            cancelPolish()
            return true
        }
        if event.modifierFlags.contains(.command) {
            cancelPolish()
            return false
        }
        // Still working: keys wait for the result.
        guard !request.variants.isEmpty else { return true }
        switch event.keyCode {
        case 36, 76, 49: // Return, Enter, Space
            applyPolish(request.highlighted, client: client)
            return true
        case 125, 124: // ↓ →
            polish?.highlighted = (request.highlighted + 1) % request.variants.count
            showPolish(client: client)
            return true
        case 126, 123: // ↑ ←
            polish?.highlighted = (request.highlighted + request.variants.count - 1) % request.variants.count
            showPolish(client: client)
            return true
        default:
            let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let digit = Int(character), (1...request.variants.count).contains(digit) {
                applyPolish(digit - 1, client: client)
                return true
            }
            if character == "c", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                copyPolish(request.highlighted)
                return true
            }
            return true
        }
    }

    func cancelPolish(message: String? = nil) {
        guard let request = polish else { return }
        request.task?.cancel()
        polish = nil
        guard ownsPanel else { return }
        if let message {
            InputEngine.shared.showStatus(message)
        } else if !draft.isEmpty || isComposing {
            sync(client: self.client() as? (any IMKTextInput)) // back to the draft / candidates
        } else {
            InputEngine.shared.panel.hide()
        }
    }

    private func showPolish(client: (any IMKTextInput)?, transition: CandidatePanel.Transition = .none) {
        guard let request = polish else { return }
        let candidates = request.variants.enumerated().map {
            PanelState.Candidate(label: "\($0.offset + 1)", text: $0.element.text, comment: $0.element.label)
        }
        let panel = InputEngine.shared.panel
        panel.view.onSelect = { [weak self] index in self?.applyPolish(index, client: nil) }
        panel.view.onPage = { _ in }
        let verb: String = if case .draft = request.target { "上屏" } else { "替换" }
        var state = PanelState(candidates: candidates, highlightedIndex: request.highlighted,
                               title: "\(request.title)   ↩ \(verb) · C 复制 · Esc 取消", presentation: .paragraphs)
        state.glow = true
        panel.show(state, at: cursorRect(client: client), transition: transition)
    }

    /// Copies the highlighted result and leaves the text as it is.
    private func copyPolish(_ index: Int) {
        guard let request = polish, request.variants.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.variants[index].text, forType: .string)
        cancelPolish(message: "已复制到剪贴板")
    }

    /// Applies a result: the draft is replaced and committed; text already in the app is
    /// replaced only if it is still exactly what was sent.
    private func applyPolish(_ index: Int, client: (any IMKTextInput)?) {
        guard let request = polish, request.variants.indices.contains(index),
              let client = client ?? (self.client() as? (any IMKTextInput)) else { return }
        let result = request.variants[index].text
        switch request.target {
        case .draft:
            polish = nil
            draft.replace(with: result)
            flushDraft(client: client)
            InputEngine.shared.panel.hide()
        case let .range(range, original):
            guard client.attributedSubstring(from: range)?.string == original else {
                return cancelPolish(message: "文字已变化，未替换")
            }
            polish = nil
            InputEngine.shared.panel.hide()
            client.insertText(result, replacementRange: range)
            recentText.reset()
            recentText.append(result)
        }
    }
}
