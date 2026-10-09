import AIMECore
import AIMEPanel
import AppKit
import Carbon
import InputMethodKit
import RimeKit

/// One controller per client input context. Translates key events into librime calls
/// and mirrors librime's state back into the client (marked text, commits) and the panel.
@objc(AIMEInputController)
@MainActor
final class AIMEInputController: IMKInputController {
    private(set) var session: RimeSession?
    private var sessionGeneration = -1
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var appOptions = InputEngine.AppOptions()
    private var bundleID: String?
    private var hasMarkedText = false
    private(set) var isComposing = false
    /// Active ⌃⌥P rewrite of the selected text (see AIMEInputController+Polish.swift).
    var polish: PolishSession?
    /// Open quick menu (see AIMEInputController+Menu.swift).
    var quickMenu: QuickMenu?
    /// Holding one modifier on its own opens the quick menu (keyboard-only entry).
    var menuHold = ModifierHold()
    /// 输入图层: committed text waiting at the cursor (underlined) until it is confirmed.
    var draft = DraftBuffer()
    /// Read only on an explicit paste; tests can supply synthetic text without the
    /// user's pasteboard. No clipboard polling or text logging.
    var clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) }
    /// What was just inserted into this field, so AI actions can work on "what I just
    /// typed" without a selection. Memory only; verified against the app before use.
    var recentText = RecentText()
    /// Text of the latest commit (see `commitForAction`).
    private var lastCommitted = ""
    private var draftTimer: Task<Void, Never>?
    /// Page depth and symbol category last drawn, to pick the menu's transition direction.
    var menuShown: (depth: Int, category: Int) = (0, 0)

    private var engine: InputEngine { InputEngine.shared }
    private var textClient: (any IMKTextInput)? { client() as? any IMKTextInput }
    var ownsPanel: Bool { engine.activeController === self }

    // MARK: - Session

    @discardableResult
    private func ensureSession() -> RimeSession? {
        let rime = RimeEngine.shared
        guard rime.isInitialized, !rime.isMaintaining else { return nil }
        if let session, sessionGeneration == engine.generation, session.isAlive { return session }
        session = try? rime.createSession()
        sessionGeneration = engine.generation
        applyAppOptions(newSession: true)
        applyScriptOption()
        return session
    }

    /// The session if it belongs to the current engine generation.
    private var liveSession: RimeSession? {
        guard let session, sessionGeneration == engine.generation, session.isAlive else { return nil }
        return session
    }

    /// Commits whatever is being composed before the engine drops all sessions.
    func flushBeforeEngineRestart() {
        if let session = liveSession, isComposing {
            session.commitComposition()
            sync(client: textClient)
            isComposing = false
        }
        flushDraft(client: textClient)
    }

    /// Chinese/English state for this client, per `AsciiStatePolicy`: by default the
    /// state shared by all apps, or the app's own state for apps that start in English.
    private func applyAppOptions(newSession: Bool) {
        guard let session,
              let desired = engine.asciiState.state(for: bundleID, appDefault: appOptions.asciiMode, newSession: newSession)
        else { return }
        DebugLog.write("ascii apply app=\(bundleID ?? "?") appDefault=\(appOptions.asciiMode.map(String.init) ?? "nil") new=\(newSession) scope=\(engine.asciiState.scope.rawValue) was=\(session.option("ascii_mode")) now=\(desired)")
        // Only write when it changes: every set_option makes librime post a notification.
        if session.option("ascii_mode") != desired { session.setOption("ascii_mode", desired) }
    }

    /// 简体 / 繁体 output as chosen in Settings (⌃⇧4 toggles it until the next session).
    func applyScriptOption() {
        guard let session = liveSession else { return }
        let traditional = engine.features.traditional
        if session.option("traditionalization") != traditional { session.setOption("traditionalization", traditional) }
    }

    /// Records the current Chinese/English state (shared, or this app's own).
    private func rememberAsciiMode() {
        guard let session = liveSession else { return }
        DebugLog.write("ascii record app=\(bundleID ?? "?") appDefault=\(appOptions.asciiMode.map(String.init) ?? "nil") ascii=\(session.option("ascii_mode"))")
        engine.asciiState.record(session.option("ascii_mode"), app: bundleID, appDefault: appOptions.asciiMode,
                                 isActive: engine.activeController === self)
    }

    // MARK: - IMKStateSetting

    nonisolated override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // IMK always calls on the main thread; the unsafe captures only cross the
        // compiler's isolation boundary, not a thread boundary.
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput
        MainActor.assumeIsolated { this.activate(client: client) }
    }

    private func activate(client: (any IMKTextInput)?) {
        DebugLog.write("activate client=\(client?.bundleIdentifier() ?? "?")")
        engine.activeController = self
        engine.refreshTheme()
        bundleID = client?.bundleIdentifier()
        appOptions = engine.appOptions(for: bundleID)
        lastModifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Nothing here may call back into the client: it is blocked until activateServer
        // returns. A reused session may be stale if another window of the same app
        // switched Chinese/English meanwhile, so re-apply the remembered state.
        if ensureSession() != nil { applyAppOptions(newSession: false) }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput
        MainActor.assumeIsolated {
            DebugLog.write("deactivate app=\(this.bundleID ?? "?")")
            this.rememberAsciiMode()
            this.menuHold.cancel()
            this.liveSession?.cancelModifierTap()
            this.recentText.reset()
            this.lastModifiers = []
            this.closeMenu()
            this.cancelPolish()
            this.commitPending(client)
            if this.ownsPanel { this.engine.panel.hide() }
            this.engine.usage.flush()
            if this.engine.activeController === this { this.engine.activeController = nil }
        }
        super.deactivateServer(sender)
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput
        MainActor.assumeIsolated { this.commitPending(client) }
    }

    /// An AI action chosen while composing: the highlighted candidate goes into the field
    /// first (as Space would put it), and the action then works on that text. The raw
    /// composition and the candidate list are never handed to the action.
    func commitForAction(client: (any IMKTextInput)?) -> String? {
        guard let session = liveSession, isComposing else { return nil }
        lastCommitted = ""
        session.commitComposition()
        sync(client: client ?? textClient)
        return lastCommitted.isEmpty ? nil : lastCommitted
    }

    private func commitPending(_ client: (any IMKTextInput)?) {
        if let session = liveSession, isComposing {
            session.commitComposition()
            sync(client: client ?? textClient)
        }
        // Leaving the field (click elsewhere, app switch): the draft goes into the app.
        if !draft.isEmpty {
            flushDraft(client: client ?? textClient)
        } else if hasMarkedText, !isComposing {
            clearMarkedText(client ?? textClient)
        }
    }

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    // MARK: - Key handling

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let received = event else { return false }
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput, keyEvent = received
        return MainActor.assumeIsolated { this.handle(keyEvent, client: client) }
    }

    private func handle(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        // Event type and session state only — never the characters typed.
        engine.activeController = self
        guard let session = ensureSession() else {
            DebugLog.write("event type=\(event.type.rawValue) no-session maintaining=\(RimeEngine.shared.isMaintaining) initialized=\(RimeEngine.shared.isInitialized)")
            // Deploying (first run ≈ 10 s): keys pass through; say why once per deploy.
            if RimeEngine.shared.isMaintaining, event.type == .keyDown { engine.noteKeyDuringDeploy() }
            return false
        }
        engine.activeController = self
        var handled = false

        switch event.type {
        case .keyDown:
            // Menu/draft keys may return before reaching RIME. Its ascii_composer
            // still saw the modifier press; clear that tap latch so the release
            // cannot turn a consumed Shift+key into an accidental mode switch.
            var forwardedToRime = false
            defer { if !forwardedToRime { session.cancelModifierTap() } }
            engine.lastUserKeyAt = Date()
            if menuHold.isArmed { engine.panel.hideHoldCue(animated: true) }
            menuHold.keyPressed() // a key while the modifier is down is a shortcut, not a hold
            if quickMenu != nil, handleMenuKey(event, client: client) { return true }
            if isMenuHotkey(event) {
                openMenu(client: client)
                return true
            }
            // Keys the polish flow does not consume go on to librime as usual.
            if polish != nil, handlePolishKey(event, client: client) { return true }
            if isPolishHotkey(event) { // AI actions, and 简繁转换 which needs no AI
                // Choose: translate, polish or one of the user's own. With nothing to work on, say so.
                if hasActionTarget(client: client) { openMenu(client: client, page: .ai) }
                else { engine.showStatus("没有可处理的文字：先打一段字，或选中一段文字") }
                return true
            }
            // Paste joins the local draft before the generic shortcut path can flush
            // it. Menu/AI shortcuts keep their existing priority.
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               pasteIntoDraft(client: client, session: session) {
                return true
            }
            // A pending draft (nothing being composed): Return / Esc confirm it, ⌫ edits
            // it, navigation and shortcuts confirm it and then reach the app.
            if !draft.isEmpty, !isComposing {
                let flags = event.modifierFlags
                switch DraftBuffer.decision(keyCode: event.keyCode, command: flags.contains(.command), control: flags.contains(.control)) {
                case .commit:
                    flushDraft(client: client)
                    return true
                case .commitAndPass:
                    flushDraft(client: client)
                    recentText.reset()
                    return false
                case .deleteBackward:
                    _ = draft.deleteBackward()
                    sync(client: client)
                    return true
                case .toEngine:
                    break
                }
            }
            guard let (keysym, mask) = RimeKey.translate(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                characters: event.characters,
                flags: event.modifierFlags.rawValue
            ) else { return false }
            if keysym == RimeKey.escape, appOptions.vimMode, !isComposing {
                session.setOption("ascii_mode", true)
                rememberAsciiMode()
                return false
            }
            engine.cancelStatus()
            forwardedToRime = true
            handled = session.processKey(keysym, modifiers: mask)
            // IMK never delivers key-ups. Report the release of each real press (not
            // auto-repeats), as Weasel and fcitx do, so schemas can tell taps from a held
            // key: 万象's backspace limit otherwise swallows every ⌫ once the
            // composition is empty (zoolapp/aime#2).
            if !event.isARepeat { session.processKey(keysym, modifiers: mask | RimeKey.releaseMask) }
            DebugLog.write("keyDown kind=\(keysym < 0x80 ? "ascii" : "special") mask=\(mask) handled=\(handled) ascii=\(session.option("ascii_mode"))")
            if !handled {
                // Keys librime leaves alone (English mode, spaces, punctuation): with the
                // layer on they join the draft; otherwise they go to the app and are
                // remembered as recently typed text.
                let typed = Self.printableText(event)
                // A draft opens on words only (letters typed in English mode); a space,
                // digits or punctuation join an open draft and otherwise go to the app.
                if let typed, draftLayerActive, !draft.isEmpty || DraftBuffer.opensDraft(typed) {
                    appendToDraft(typed, client: client)
                    sync(client: client)
                    rememberAsciiMode()
                    return true
                }
                if let typed { recentText.append(typed) }
                else if event.keyCode == 51 { recentText.deleteBackward() }
                else { recentText.reset() }
            }

        case .flagsChanged:
            engine.lastUserKeyAt = Date()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Modifier transitions only (never character keys): safe to log for diagnosis.
            engine.logger.debug("flagsChanged keyCode=\(event.keyCode, privacy: .public) flags=\(flags.rawValue, privacy: .public) last=\(self.lastModifiers.rawValue, privacy: .public)")
            defer { lastModifiers = flags }
            DebugLog.write("flagsChanged keyCode=\(event.keyCode) flags=\(flags.rawValue) last=\(lastModifiers.rawValue) ascii=\(session.option("ascii_mode"))")
            // Mac Catalyst apps (Messages) deliver every modifier event twice. A repeat
            // has the same flags as the last one and would read as "released", toggling
            // Chinese/English the moment Shift goes down.
            guard flags != lastModifiers else { return false }
            // Hold-to-open for the quick menu. The release after a fired hold is kept from
            // librime, where a lone modifier tap can switch Chinese/English.
            menuHold.key = engine.features.menuHoldKey
            if menuHold.consumeRelease(flags.rawValue) { return true }
            if let token = menuHold.modifiersChanged(flags.rawValue) {
                scheduleMenuHold(token: token)
            } else if !menuHold.isArmed {
                engine.panel.hideHoldCue(animated: true) // let go early, or another modifier joined
            }
            guard let keysym = RimeKey.keysym(forVirtualKey: event.keyCode) else { return false }
            if keysym == RimeKey.capsLock {
                // Caps Lock toggles on a single event; report press + release.
                let mask = RimeKey.mask(fromCocoaFlags: flags.rawValue)
                handled = session.processKey(keysym, modifiers: mask)
                session.processKey(keysym, modifiers: mask | RimeKey.releaseMask)
            } else {
                let pressed = flags.rawValue & ~lastModifiers.rawValue != 0
                let mask = pressed
                    ? RimeKey.mask(fromCocoaFlags: lastModifiers.rawValue)
                    : RimeKey.mask(fromCocoaFlags: lastModifiers.rawValue) | RimeKey.releaseMask
                handled = session.processKey(keysym, modifiers: mask)
            }

        default:
            return false
        }

        sync(client: client)
        rememberAsciiMode()
        return handled
    }

    // MARK: - Draft layer (输入图层)

    /// The layer is on for this field: enabled in Settings, and the app is not one where
    /// keys must reach it at once (terminals, editors, launchers, password managers).
    var draftLayerActive: Bool {
        engine.features.draftLayer && !DraftBuffer.isExempt(
            appStartsInEnglish: appOptions.asciiMode == true, bundleID: bundleID, secureInput: IsSecureEventInputEnabled())
    }

    /// The hint under a pending draft, led by a 中 / 英 chip: in English mode keys join
    /// the draft as letters, which must not look like a composition that lost its candidates.
    private var draftHint: PanelState {
        let hold: String = switch engine.features.menuHoldKey {
        case .option: "长按 ⌥ 动作"
        case .control: "长按 ⌃ 动作"
        case .command: "长按 ⌘ 动作"
        case .off: "⌃⌥M 动作"
        }
        var state = PanelState(status: "↩ 上屏   \(hold)")
        state.statusBadge = liveSession?.option("ascii_mode") == true ? "英" : "中"
        return state
    }

    /// After a short status (中 / 英…) the panel goes back to what it showed: the draft
    /// hint while a draft is pending, nothing otherwise.
    func restorePanelAfterStatus() {
        guard ownsPanel, !isComposing else { return }
        if !draft.isEmpty, quickMenu == nil, polish == nil {
            engine.panel.show(draftHint, at: cursorRect(client: textClient))
        } else if draft.isEmpty {
            engine.panel.hide()
        }
    }

    /// Text a key event types on its own (no ⌘ / ⌃), or nil for control and function keys.
    static func printableText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7f, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return characters
    }

    private func appendToDraft(_ text: String, client: (any IMKTextInput)?) {
        if let overflow = draft.append(text) {
            // Too long for one marked run: the older part goes into the app.
            client?.insertText(overflow, replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = false
            recentText.append(overflow)
        }
    }

    /// ⌘V appends plain text without inserting into the host. Return/Esc and the
    /// user's auto-commit preference still confirm the draft in the usual way.
    private func pasteIntoDraft(client: (any IMKTextInput)?, session: RimeSession) -> Bool {
        guard draftLayerActive, let client else { return false }
        defer { rememberAsciiMode() }
        guard let pasted = clipboardText() else {
            engine.showStatus("输入图层支持纯文本粘贴")
            return true
        }
        guard !pasted.isEmpty else { return true }
        let context = session.context()
        if context.isComposing, context.candidates.isEmpty || context.commitTextPreview == nil {
            engine.showStatus("请先选词或取消组字，再粘贴")
            return true
        }
        // A previous client-less callback may have left a real commit queued. Keep
        // it before the pasted text and include it in the capacity check.
        if !context.isComposing { sync(client: client, commitToDraft: true) }
        let preview = context.isComposing ? context.commitTextPreview ?? "" : ""
        guard draft.canPaste(pasted, afterComposition: preview) else {
            engine.showStatus("文字过长，请先上屏后在应用中粘贴")
            return true
        }
        draftTimer?.cancel()
        if context.isComposing {
            let accepted = session.commitComposition()
            let committed = session.consumeCommit()
            if let committed {
                // Keep the actual formatter output, even if it exceeds the preview.
                // Normal append/sync could overflow or insert pure punctuation.
                engine.usage.record(committed, app: bundleID)
                lastCommitted = committed
                draft.replace(with: draft.text + committed)
            }
            sync(client: client, commitToDraft: true)
            guard accepted, committed != nil, !isComposing else {
                engine.showStatus("请先选词或取消组字，再粘贴")
                return true
            }
        }
        guard draft.paste(pasted) else {
            engine.showStatus("文字过长，请先上屏后在应用中粘贴")
            return true
        }
        sync(client: client, commitToDraft: true)
        return true
    }

    /// Puts the draft into the app (replacing the marked text that showed it).
    func flushDraft(client: (any IMKTextInput)?) {
        draftTimer?.cancel()
        guard !draft.isEmpty else { return }
        let text = draft.take()
        (client ?? textClient)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
        recentText.append(text)
        if ownsPanel, !isComposing, quickMenu == nil, polish == nil { engine.panel.hide() }
    }

    /// Restarts the auto-commit countdown; it only runs while a draft is pending and
    /// nothing is being composed, picked from a menu, or processed by AI.
    private func scheduleDraftAutoCommit() {
        draftTimer?.cancel()
        let delay = engine.features.draftAutoCommit
        guard delay > 0, !draft.isEmpty, !isComposing, quickMenu == nil, polish == nil else { return }
        draftTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isComposing, self.quickMenu == nil, self.polish == nil else { return }
            self.flushDraft(client: nil)
        }
    }

    // MARK: - Output

    /// Menu text replaces unconfirmed composition, after preserving an existing draft.
    /// Both continuous and closing insertions must leave no old preedit to restore.
    func insertMenuText(_ text: String, client: (any IMKTextInput)?) {
        guard let client = client ?? textClient else { return }
        if isComposing { liveSession?.clearComposition() }
        isComposing = false
        flushDraft(client: client)
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
    }

    /// Marked text with InputMethodKit's own highlight attributes. Hand-made attributes
    /// (e.g. a raw underline style) do not survive the IMK XPC bridge on macOS 26+, and
    /// clients then insert the preedit as ordinary text — the raw pinyin stays in the
    /// document next to the committed characters.
    private func markedText(_ text: String, converted: Int, selectedEnd: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let length = (text as NSString).length
        guard length > 0 else { return result }
        let convertedEnd = max(0, min(converted, length))
        let selectionEnd = max(convertedEnd, min(selectedEnd, length))
        func apply(_ style: Int, _ range: NSRange) {
            guard range.length > 0,
                  let attributes = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any] else { return }
            result.addAttributes(attributes, range: range)
        }
        apply(kTSMHiliteConvertedText, NSRange(location: 0, length: convertedEnd))
        apply(kTSMHiliteSelectedRawText, NSRange(location: convertedEnd, length: selectionEnd - convertedEnd))
        apply(kTSMHiliteRawText, NSRange(location: selectionEnd, length: length - selectionEnd))
        return result
    }

    private func clearMarkedText(_ client: (any IMKTextInput)?) {
        client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
        isComposing = false
        if ownsPanel { engine.panel.hide() }
    }

    func sync(client: (any IMKTextInput)?, commitToDraft: Bool = false) {
        guard let session = liveSession, let client else { return }

        if let text = session.consumeCommit() {
            DebugLog.write("commit length=\(text.count) hadMarked=\(hasMarkedText) draft=\(draftLayerActive)")
            engine.usage.record(text, app: bundleID)
            lastCommitted = text
            // A commit of only punctuation or digits does not open a draft.
            if commitToDraft {
                draft.replace(with: draft.text + text)
            } else if draftLayerActive, !draft.isEmpty || DraftBuffer.opensDraft(text) {
                appendToDraft(text, client: client)
            } else {
                // The layer was switched off with a draft pending: it goes first.
                let pending = draft.take()
                client.insertText(pending + text, replacementRange: NSRange(location: NSNotFound, length: 0))
                hasMarkedText = false
                recentText.append(pending + text)
            }
        }

        let context = session.context()
        isComposing = context.isComposing
        let theme = engine.panel.theme
        let inline = appOptions.inline ?? theme.inlinePreedit

        // Marked text: the client shows the composition inline, or a placeholder
        // space when the panel carries the preedit (keeps cursor tracking alive).
        // A pending draft comes first, styled as converted text.
        let draftPrefix = draft.text
        let draftLength = draftPrefix.utf16.count
        if !isComposing, !draftPrefix.isEmpty {
            client.setMarkedText(markedText(draftPrefix, converted: draftLength, selectedEnd: draftLength),
                                 selectionRange: NSRange(location: draftLength, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = true
        } else if isComposing {
            let showsPreview = theme.inlineCandidate && context.commitTextPreview != nil
            let preedit = showsPreview ? context.commitTextPreview! : context.composition.preedit
            // Never hand the client an empty marked string while composing: terminals
            // (Ghostty, iTerm2…) then think no composition is active and print the raw
            // keys, so pinyin letters end up interleaved with committed characters.
            // Without inline preedit a single space stands in for the composition.
            let body = inline ? preedit : " "
            let display = draftPrefix + body
            // The caret must index the string actually shown: the librime cursor is a
            // byte offset into the preedit, meaningless for the candidate preview.
            let caret = draftLength + (!inline ? 0
                : showsPreview ? body.utf16.count
                : min(context.composition.utf16Offset(ofUTF8: context.composition.cursorPosition), body.utf16.count))
            let attributed = markedText(display, converted: draftLength + (showsPreview ? body.utf16.count
                : context.composition.utf16Offset(ofUTF8: context.composition.selectionStart)),
                selectedEnd: draftLength + (showsPreview ? body.utf16.count
                : context.composition.utf16Offset(ofUTF8: context.composition.selectionEnd)))
            DebugLog.write("marked length=\(display.count) inline=\(inline) caret=\(caret) attrs=\(attributed.length > 0 ? attributed.attributes(at: 0, effectiveRange: nil).count : 0)")
            client.setMarkedText(attributed, selectionRange: NSRange(location: caret, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = true
        } else if hasMarkedText {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = false
        }

        // A delayed old-context commit still reaches that client, but cannot replace
        // the shared panel belonging to the newly active field.
        guard ownsPanel else { return }
        scheduleDraftAutoCommit()
        guard isComposing else {
            // A pending draft shows a small hint under it (what the layer is waiting for).
            if draft.isEmpty {
                engine.panel.hide()
            } else if quickMenu == nil, polish == nil {
                engine.panel.show(draftHint, at: cursorRect(client: client))
            }
            return
        }

        let composition = context.composition
        let start = composition.utf16Offset(ofUTF8: composition.selectionStart)
        let end = composition.utf16Offset(ofUTF8: composition.selectionEnd)
        let state = PanelState(
            preedit: composition.preedit,
            preeditSelection: NSRange(location: start, length: max(0, end - start)),
            candidates: context.candidates.enumerated().map { index, candidate in
                PanelState.Candidate(label: context.labels[safe: index] ?? "\(index + 1)", text: candidate.text, comment: candidate.comment)
            },
            highlightedIndex: context.highlightedIndex,
            pageNumber: context.pageNumber,
            isLastPage: context.isLastPage,
            showsMenuButton: engine.features.panelMenuButton
        )
        engine.panel.view.onMenu = { [weak self] in self?.openMenu(client: nil) }
        engine.panel.view.onSelect = { [weak self] index in self?.select(index) }
        engine.panel.view.onPage = { [weak self] backward in self?.page(backward: backward) }
        engine.panel.view.forcePreedit = !inline
        engine.panel.show(state, at: cursorRect(client: client))
    }

    private func select(_ index: Int) {
        guard let session = liveSession else { return }
        session.selectCandidate(onCurrentPage: index)
        sync(client: textClient)
    }

    private func page(backward: Bool) {
        guard let session = liveSession else { return }
        session.changePage(backward: backward)
        sync(client: textClient)
    }

    /// Cursor rectangle in screen coordinates.
    func cursorRect(client: (any IMKTextInput)? = nil) -> NSRect {
        guard let client = client ?? textClient else { return .zero }
        // With a pending draft the panel follows where typing continues — its end — not
        // its first character: a draft that wraps over several lines would otherwise be
        // covered by the panel sitting under its first line.
        let anchor = draft.isEmpty ? 0 : draft.text.utf16.count
        for index in Set([anchor, max(0, anchor - 1), 0]).sorted(by: >) {
            var rect = NSRect.zero
            client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
            // Some apps answer an index they cannot place with an empty rect at the
            // screen origin: try the next candidate then.
            if rect != .zero, rect.origin != .zero { return rect }
        }
        return .zero
    }

    // MARK: - Menu

    nonisolated override func menu() -> NSMenu! {
        // NSMenu is not Sendable; IMK asks for it on the main thread.
        nonisolated(unsafe) var menu: NSMenu?
        nonisolated(unsafe) let this = self
        MainActor.assumeIsolated { menu = this.buildMenu() }
        return menu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "AIME")
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        // No key equivalent: input menu shortcuts are live in every app, so ⌘, here would
        // shadow each app's own Settings shortcut (#6).
        menu.addItem(item(String(localized: "艾么输入法设置…"), #selector(openSettings(_:))))
        if let update = engine.pendingUpdate {
            menu.addItem(item(String(localized: "更新到 \(update.version)…"), #selector(openUpdate(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "重新部署"), #selector(deploy(_:))))
        menu.addItem(item(String(localized: "同步用户数据"), #selector(syncUserData(_:))))
        menu.addItem(item(String(localized: "打开用户文件夹"), #selector(openUserFolder(_:))))
        menu.addItem(item(String(localized: "打开日志文件夹"), #selector(openLogFolder(_:))))
        return menu
    }

    @objc func openSettings(_ sender: Any?) { openSettings(pane: nil) }

    /// Opens AIME Settings, optionally on a pane ("stats", "ai", …). A running
    /// Settings app is told to switch through a distributed notification.
    func openSettings(pane: String?) { Self.openSettings(pane: pane) }

    static func openSettings(pane: String?) {
        let configuration = NSWorkspace.OpenConfiguration()
        if let pane { configuration.arguments = ["--pane", pane] }
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/AIME Settings.app")
        let url = FileManager.default.fileExists(atPath: embedded.path) ? embedded
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.zool.aime.settings")
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        if let pane {
            DistributedNotificationCenter.default().postNotificationName(
                .init("app.zool.aime.settings.showPane"), object: nil, userInfo: ["pane": pane], deliverImmediately: true)
        }
    }

    @objc func openUpdate(_ sender: Any?) { openSettings(pane: "overview") }
    @objc func deploy(_ sender: Any?) { engine.redeploy() }
    @objc func syncUserData(_ sender: Any?) { engine.syncUserData() }
    @objc func openUserFolder(_ sender: Any?) { NSWorkspace.shared.open(engine.paths.userDataDir) }
    @objc func openLogFolder(_ sender: Any?) { NSWorkspace.shared.open(engine.paths.logDir) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
