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
