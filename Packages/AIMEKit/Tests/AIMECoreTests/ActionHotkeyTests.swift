import Foundation
import Testing
@testable import AIMECore

struct ActionHotkeyTests {
    typealias Key = AIMEFeatures.ActionHotkey

    @Test func oldFeaturesFileHasNoShortcuts() throws {
        let features = try JSONDecoder().decode(AIMEFeatures.self, from: Data(#"{"aiPolish":true}"#.utf8))
        #expect(features.actionHotkeys.isEmpty)
        #expect(features.action(forHotkey: "Control+Alt+t") == nil)
    }

    @Test func shortcutsRoundTrip() throws {
        var features = AIMEFeatures()
        features.setActionHotkey("Control+Alt+t", for: Key.translate)
        let decoded = try JSONDecoder().decode(AIMEFeatures.self, from: JSONEncoder().encode(features))
        #expect(decoded.action(forHotkey: "Control+Alt+t") == Key.translate)
    }

    @Test func onlyNonTypingKeysAreUsable() {
        #expect(Key.isUsable("Control+Alt+t"))
        #expect(Key.isUsable("Alt+1"))
        #expect(Key.isUsable("Super+Shift+y"))
        #expect(Key.isUsable("F5"))
        #expect(Key.isUsable("Shift+F12"))
        #expect(!Key.isUsable(""))
        #expect(!Key.isUsable("t"))
        #expect(!Key.isUsable("Shift+t"))
        #expect(!Key.isUsable("space"))
        #expect(!Key.isUsable("Control+Alt+p")) // ⌃⌥P opens the AI menu
        #expect(!Key.isUsable("Control+Alt+m")) // ⌃⌥M opens the quick menu
    }

    @Test func bindingTakesTheShortcutFromOtherActions() {
        var features = AIMEFeatures()
        features.setActionHotkey("Control+Alt+t", for: Key.translate)
        features.setActionHotkey("Control+Alt+t", for: Key.polish)
        #expect(features.actionHotkeys == [Key.polish: "Control+Alt+t"])
        features.setActionHotkey(nil, for: Key.polish)
        #expect(features.actionHotkeys.isEmpty)
    }

    @Test func deletedCustomActionNoLongerMatches() {
        var features = AIMEFeatures()
        let action = AIMEFeatures.AIAction(name: "粤语", prompt: "改成粤语")
        features.aiActions = [action]
        features.setActionHotkey("Control+Alt+y", for: action.id.uuidString)
        #expect(features.action(forHotkey: "Control+Alt+y") == action.id.uuidString)
        features.aiActions = []
        #expect(features.action(forHotkey: "Control+Alt+y") == nil)
        #expect(features.action(forHotkey: "Control+Alt+x") == nil)
    }
}

struct DraftAutoActionTests {
    @Test func offUnlessChosenAndBothFeaturesAreOn() throws {
        var features = try JSONDecoder().decode(AIMEFeatures.self, from: Data(#"{"aiPolish":true,"draftLayer":true}"#.utf8))
        #expect(features.activeDraftAutoAction == nil)
        features.draftAutoAction = AIMEFeatures.ActionHotkey.translate
        #expect(features.activeDraftAutoAction == AIMEFeatures.ActionHotkey.translate)
        let decoded = try JSONDecoder().decode(AIMEFeatures.self, from: JSONEncoder().encode(features))
        #expect(decoded.activeDraftAutoAction == AIMEFeatures.ActionHotkey.translate)
        features.aiPolish = false
        #expect(features.activeDraftAutoAction == nil)
        features.aiPolish = true
        features.draftLayer = false
        #expect(features.activeDraftAutoAction == nil)
    }

    @Test func deletedCustomActionTurnsItOff() {
        var features = AIMEFeatures()
        features.aiPolish = true
        features.draftLayer = true
        let action = AIMEFeatures.AIAction(name: "粤语", prompt: "改成粤语")
        features.aiActions = [action]
        features.draftAutoAction = action.id.uuidString
        #expect(features.activeDraftAutoAction == action.id.uuidString)
        features.aiActions = []
        #expect(features.activeDraftAutoAction == nil)
        // 简繁转换 is not an AI action and cannot be chosen here.
        features.draftAutoAction = AIMEFeatures.ActionHotkey.convertScript
        #expect(features.activeDraftAutoAction == nil)
    }
}

extension DraftAutoActionTests {
    @Test func triggerKeyIsReturnOrSpace() throws {
        var features = AIMEFeatures()
        features.aiPolish = true
        features.draftLayer = true
        #expect(!features.runsDraftAutoAction(keyCode: 36, modified: false, draft: "你好")) // no action chosen
        features.draftAutoAction = AIMEFeatures.ActionHotkey.translate
        #expect(features.runsDraftAutoAction(keyCode: 36, modified: false, draft: "你好"))
        #expect(!features.runsDraftAutoAction(keyCode: 36, modified: true, draft: "你好"))
        #expect(!features.runsDraftAutoAction(keyCode: 49, modified: false, draft: "你好"))
        #expect(!features.runsDraftAutoAction(keyCode: 53, modified: false, draft: "你好")) // Esc commits as typed
        features.draftAutoActionKey = .space
        #expect(features.runsDraftAutoAction(keyCode: 49, modified: false, draft: "你好"))
        #expect(features.runsDraftAutoAction(keyCode: 49, modified: false, draft: "你好。"))
        #expect(!features.runsDraftAutoAction(keyCode: 36, modified: false, draft: "你好"))
        // English in the draft: Space still types a space.
        #expect(!features.runsDraftAutoAction(keyCode: 49, modified: false, draft: "你好 hello"))
        #expect(!features.runsDraftAutoAction(keyCode: 49, modified: false, draft: "v2"))
        let decoded = try JSONDecoder().decode(AIMEFeatures.self, from: JSONEncoder().encode(features))
        #expect(decoded.draftAutoActionKey == .space)
        let odd = try JSONDecoder().decode(AIMEFeatures.self, from: Data(#"{"draftAutoActionKey":"tab"}"#.utf8))
        #expect(odd.draftAutoActionKey == .return)
    }
}

extension DraftAutoActionTests {
    @Test func spaceCanCommitAsTypedWhenReturnRunsTheAction() throws {
        var features = AIMEFeatures()
        features.aiPolish = true
        features.draftLayer = true
        features.draftAutoAction = AIMEFeatures.ActionHotkey.translate
        #expect(!features.spaceCommitsDraft(keyCode: 49, modified: false, draft: "你好")) // off by default
        features.draftSpaceCommits = true
        #expect(features.spaceCommitsDraft(keyCode: 49, modified: false, draft: "你好"))
        #expect(!features.spaceCommitsDraft(keyCode: 49, modified: false, draft: "hello"))
        #expect(!features.spaceCommitsDraft(keyCode: 49, modified: true, draft: "你好"))
        #expect(!features.spaceCommitsDraft(keyCode: 36, modified: false, draft: "你好"))
        #expect(try JSONDecoder().decode(AIMEFeatures.self, from: JSONEncoder().encode(features)).draftSpaceCommits)
        // Space cannot do both: as the action's key it never commits as typed.
        features.draftAutoActionKey = .space
        #expect(!features.spaceCommitsDraft(keyCode: 49, modified: false, draft: "你好"))
        features.draftAutoActionKey = .return
        features.draftAutoAction = ""
        #expect(!features.spaceCommitsDraft(keyCode: 49, modified: false, draft: "你好"))
    }
}
