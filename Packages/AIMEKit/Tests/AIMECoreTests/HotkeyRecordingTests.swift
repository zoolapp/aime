import Testing
@testable import AIMECore

struct HotkeyRecordingTests {
    @Test func heldCombinationCommitsOnceAfterEveryKeyReleases() {
        var recorder = HotkeyRecording(); recorder.start()
        let control: HotkeyFormatter.Modifiers = .control
        let both: HotkeyFormatter.Modifiers = [.control, .shift]
        #expect(recorder.handle(.modifiers, modifiers: control) == .waiting)
        #expect(recorder.handle(.modifiers, modifiers: both) == .waiting)
        #expect(recorder.handle(.down, keyCode: 0x32, modifiers: both) == .waiting)
        for _ in 0..<3 { #expect(recorder.handle(.down, keyCode: 0x32, modifiers: both, repeatKey: true) == .waiting) }
        #expect(recorder.handle(.up, keyCode: 0x32, modifiers: both) == .waiting)
        #expect(recorder.handle(.modifiers, modifiers: control) == .waiting)
        #expect(recorder.handle(.modifiers) == .commit("Control+Shift+grave"))
        #expect(!recorder.active)
        #expect(recorder.handle(.modifiers) == .waiting)
    }
    @Test func reverseReleaseAndExtraKeyCannotFinishEarly() {
        var recorder = HotkeyRecording(); recorder.start()
        _ = recorder.handle(.down, keyCode: 0x32, modifiers: .control)
        _ = recorder.handle(.down, keyCode: 0, character: "a", modifiers: .control)
        #expect(recorder.handle(.modifiers) == .waiting)
        #expect(recorder.handle(.up, keyCode: 0x32) == .waiting)
        #expect(recorder.handle(.up, keyCode: 0) == .commit("Control+grave"))
    }
    @Test func modifierOnlyHoldDoesNotCreateAHotkey() {
        var recorder = HotkeyRecording(); recorder.start()
        for _ in 0..<4 { #expect(recorder.handle(.modifiers, modifiers: .alt) == .waiting) }
        #expect(recorder.handle(.modifiers) == .waiting)
        #expect(recorder.active)
        _ = recorder.handle(.down, keyCode: 0x76)
        #expect(recorder.handle(.up, keyCode: 0x76) == .commit("F4"))
    }
    @Test func escapeCancelsButModifiedEscapeRecords() {
        var recorder = HotkeyRecording(); recorder.start()
        _ = recorder.handle(.down, keyCode: 0x35)
        #expect(recorder.handle(.up, keyCode: 0x35) == .cancel)
        recorder.start()
        _ = recorder.handle(.down, keyCode: 0x35, modifiers: .control)
        _ = recorder.handle(.up, keyCode: 0x35, modifiers: .control)
        #expect(recorder.handle(.modifiers) == .commit("Control+Escape"))
    }
    @Test func unsupportedOrPreexistingKeysDrainAndAllowRetry() {
        var recorder = HotkeyRecording(); recorder.start(modifiers: .alt)
        #expect(recorder.waitingForRelease)
        #expect(recorder.handle(.modifiers) == .retry)
        #expect(recorder.handle(.down, keyCode: 0xffff) == .unsupported)
        #expect(recorder.handle(.down, keyCode: 0xffff, repeatKey: true) == .waiting)
        #expect(recorder.handle(.up, keyCode: 0xffff) == .retry)
        #expect(recorder.handle(.down, keyCode: 0, character: "a", repeatKey: true) == .waiting)
        #expect(recorder.handle(.up, keyCode: 0) == .retry)
        _ = recorder.handle(.down, keyCode: 0, character: "a", modifiers: .command)
        _ = recorder.handle(.modifiers)
        #expect(recorder.handle(.up, keyCode: 0) == .commit("Super+a"))
    }
    @Test func escapeOverridesPendingCommitOrRetryAndStillDrains() {
        for code: UInt16 in [0x32, 0xffff] {
            var recorder = HotkeyRecording(); recorder.start()
            _ = recorder.handle(.down, keyCode: code, modifiers: .control)
            _ = recorder.handle(.modifiers)
            _ = recorder.handle(.down, keyCode: 0x35)
            #expect(recorder.handle(.up, keyCode: 0x35) == .waiting)
            #expect(recorder.handle(.up, keyCode: code) == .cancel)
            #expect(!recorder.active)
        }
    }
    @Test func forcedStopDiscardsPendingAndBoundedKeysCancel() {
        var recorder = HotkeyRecording(); recorder.start()
        _ = recorder.handle(.down, keyCode: 0, character: "a")
        recorder.stop()
        #expect(recorder.handle(.up, keyCode: 0) == .waiting)
        recorder.start()
        for key in UInt16(0)..<32 { _ = recorder.handle(.down, keyCode: key, character: "a") }
        #expect(recorder.handle(.down, keyCode: 32, character: "a") == .cancel)
        #expect(!recorder.active)
        recorder.start()
        _ = recorder.handle(.down, keyCode: 0x76)
        #expect(recorder.handle(.up, keyCode: 0x76) == .commit("F4"))
    }
}
