public import Foundation

/// Which punctuation a new input method process starts with (#33).
///
/// Settings › 输入习惯 › 标点 decides, unless 记忆的开关 includes English punctuation:
/// then the last state (⌃⇧3 or Settings) carries over. The input method keeps that state
/// itself — librime writes `var/option/ascii_punct` only from its schema menu, and only
/// flushes it when the session ends — together with the setting it was recorded under,
/// so a setting changed while the input method was not running still wins.
public struct PunctMemory {
    static let valueKey = "rememberedAsciiPunct"
    static let settingKey = "rememberedAsciiPunctSetting"

    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func launchValue(setting: Bool, remembers: Bool, saved: Bool?, savedUnderSetting: Bool?) -> Bool {
        guard remembers, let saved, savedUnderSetting == setting else { return setting }
        return saved
    }

    public func launchValue(setting: Bool, remembers: Bool) -> Bool {
        let saved = defaults.object(forKey: Self.valueKey) as? Bool
        let savedUnderSetting = defaults.object(forKey: Self.settingKey) as? Bool
        // Recorded under another setting: the setting won. Forget the old state, or it would
        // come back once the setting is switched back.
        if saved != nil, savedUnderSetting != setting { record(setting, setting: setting) }
        return Self.launchValue(setting: setting, remembers: remembers, saved: saved, savedUnderSetting: savedUnderSetting)
    }

    public func record(_ value: Bool, setting: Bool) {
        defaults.set(value, forKey: Self.valueKey)
        defaults.set(setting, forKey: Self.settingKey)
    }
}
