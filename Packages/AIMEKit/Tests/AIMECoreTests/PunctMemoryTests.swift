import Foundation
import Testing
@testable import AIMECore

/// #33: which punctuation a new input method process starts with.
struct PunctMemoryTests {
    @Test func settingDecidesUnlessRemembered() {
        // Nothing recorded, or 记忆的开关 without English punctuation: the setting.
        #expect(PunctMemory.launchValue(setting: true, remembers: true, saved: nil, savedUnderSetting: nil))
        #expect(PunctMemory.launchValue(setting: true, remembers: false, saved: false, savedUnderSetting: true))
        // ⌃⇧3 switched to Chinese under the English setting, remembered: carries over.
        #expect(!PunctMemory.launchValue(setting: true, remembers: true, saved: false, savedUnderSetting: true))
        // The setting changed since (input method not running then): the setting wins.
        #expect(PunctMemory.launchValue(setting: true, remembers: true, saved: false, savedUnderSetting: false))
    }

    @Test func recordsRoundTripThroughDefaults() throws {
        let suite = "aime-punct-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = PunctMemory(defaults: defaults)
        #expect(memory.launchValue(setting: false, remembers: true) == false)
        memory.record(true, setting: false)          // ⌃⇧3 to English under the Chinese setting
        #expect(memory.launchValue(setting: false, remembers: true) == true)
        #expect(memory.launchValue(setting: false, remembers: false) == false)
        memory.record(false, setting: false)         // Settings switched: recorded as the setting
        #expect(memory.launchValue(setting: false, remembers: true) == false)
    }

    /// A state recorded under another setting is dropped once the setting wins, so switching
    /// the setting back later does not revive it.
    @Test func settingWinOverwritesStaleState() throws {
        let suite = "aime-punct-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = PunctMemory(defaults: defaults)
        memory.record(true, setting: false)          // ⌃⇧3 to English under the Chinese setting
        #expect(memory.launchValue(setting: true, remembers: true) == true)   // setting changed meanwhile
        #expect(memory.launchValue(setting: false, remembers: true) == false) // back: no revival
    }
}
