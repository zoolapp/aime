import Foundation
import Testing
@testable import AIMECore

struct DraftBufferTests {
    @Test func collectsCommitsAndOverflowsOldText() {
        var draft = DraftBuffer()
        let first = draft.append("今天")
        let second = draft.append("开会")
        #expect(first == nil && second == nil && draft.text == "今天开会")
        let removed = draft.deleteBackward()
        #expect(removed && draft.text == "今天开")
        let long = String(repeating: "字", count: DraftBuffer.maxLength)
        let overflow = draft.append(long)
        #expect(overflow == "今天开" && draft.text == long)
        let taken = draft.take()
        #expect(taken == long && draft.isEmpty)
        let nothing = draft.deleteBackward()
        #expect(!nothing)
    }

    @Test func keysCommitPassOrGoToTheEngine() {
        #expect(DraftBuffer.decision(keyCode: 36, command: false, control: false) == .commit)          // Return
        #expect(DraftBuffer.decision(keyCode: 53, command: false, control: false) == .commit)          // Esc never discards
        #expect(DraftBuffer.decision(keyCode: 51, command: false, control: false) == .deleteBackward)
        #expect(DraftBuffer.decision(keyCode: 123, command: false, control: false) == .commitAndPass)  // ←
        #expect(DraftBuffer.decision(keyCode: 9, command: true, control: false) == .commitAndPass)     // ⌘V
        #expect(DraftBuffer.decision(keyCode: 0, command: false, control: false) == .toEngine)         // a
    }

    @Test func exemptsEnglishFirstAppsPasswordManagersAndSecureFields() {
        #expect(DraftBuffer.isExempt(appStartsInEnglish: true, bundleID: "com.mitchellh.ghostty", secureInput: false))
        #expect(DraftBuffer.isExempt(appStartsInEnglish: false, bundleID: "com.1password.1password", secureInput: false))
        #expect(DraftBuffer.isExempt(appStartsInEnglish: false, bundleID: "com.apple.Notes", secureInput: true))
        #expect(!DraftBuffer.isExempt(appStartsInEnglish: false, bundleID: "com.apple.Notes", secureInput: false))
    }

    @Test func recentTextTracksWhatWasTypedAndWhereItShouldBe() {
        var recent = RecentText()
        recent.append("明天下午")
        recent.append("开会")
        recent.deleteBackward()
        #expect(recent.text == "明天下午开")
        #expect(recent.range(caretAt: 20) == NSRange(location: 15, length: 5))
        #expect(recent.range(caretAt: 3) == nil)             // caret before the text could start
        recent.append(String(repeating: "长", count: 600))
        #expect(recent.text.utf16.count == RecentText.maxLength)
        recent.reset()
        #expect(recent.range(caretAt: 10) == nil)
    }
}

extension DraftBufferTests {
    @Test func pastePreservesTextAndCanOpenWithNonWords() {
        for text in ["123", "，", "😀", "\t第一行\r\n第二行\n 👨‍👩‍👧‍👦🇨🇳e\u{301}☀️"] {
            var draft = DraftBuffer()
            let inserted = draft.paste(text)
            #expect(inserted)
            #expect(draft.text == text)
            let empty = draft.paste("")
            #expect(empty)
            #expect(draft.text == text)
            let appended = draft.paste("后续")
            #expect(appended)
            #expect(draft.text == text + "后续")
        }
    }

    @Test func pasteRejectsOverflowWithoutChangingTheDraft() {
        var draft = DraftBuffer()
        draft.replace(with: String(repeating: "字", count: DraftBuffer.maxLength - 2))
        let before = draft
        let overflow = draft.paste("🇨🇳") // four UTF-16 units, one grapheme
        #expect(!overflow)
        #expect(draft == before)
        let exact = draft.paste("😀") // two UTF-16 units, reaches the exact limit
        #expect(exact)
        #expect(draft.text.utf16.count == DraftBuffer.maxLength)
        let full = draft
        let extra = draft.paste(" ")
        #expect(!extra)
        #expect(draft == full)
        var empty = DraftBuffer()
        let tooLong = empty.paste(String(repeating: "长", count: DraftBuffer.maxLength + 1))
        #expect(!tooLong)
        #expect(empty.isEmpty)
    }

    @Test func pastePreflightsCompositionAndRechecksFormatterOutput() {
        var draft = DraftBuffer()
        draft.replace(with: String(repeating: "字", count: DraftBuffer.maxLength - 4))
        #expect(draft.canPaste("😀", afterComposition: "你好"))
        #expect(!draft.canPaste("😀", afterComposition: "你好啊"))
        // Actual formatter output can exceed the preview. Keep that commit local,
        // then reject the addition as a whole, without overflow or truncation.
        draft.replace(with: draft.text + "你好啊")
        let committed = draft
        let addition = draft.paste("😀")
        #expect(!addition)
        #expect(draft == committed)
        draft.replace(with: String(repeating: "字", count: DraftBuffer.maxLength + 10))
        let oversized = draft
        let oversizedAddition = draft.paste("a")
        #expect(!oversizedAddition)
        #expect(draft == oversized)
    }

    @Test func onlyWordsOpenADraft() {
        #expect(DraftBuffer.opensDraft("你好"))
        #expect(DraftBuffer.opensDraft("a"))
        #expect(DraftBuffer.opensDraft("GPT-5"))
        #expect(!DraftBuffer.opensDraft(" "))
        #expect(!DraftBuffer.opensDraft("，"))
        #expect(!DraftBuffer.opensDraft("123"))
        #expect(!DraftBuffer.opensDraft("😀"))
    }
}
