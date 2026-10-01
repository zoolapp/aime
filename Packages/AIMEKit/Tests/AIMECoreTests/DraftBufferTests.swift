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
