public import Foundation

/// How far the Chinese/English (ascii_mode) state is shared, like fcitx5's
/// ShareInputState or Weasel's global_ascii. Configured as `ascii_state/scope` in the
/// frontend config (aime.yaml).
public enum AsciiStateScope: String, Sendable, CaseIterable {
    /// One state for all apps (default). Apps with a configured initial state
    /// (`app_options/<app>/ascii_mode: true` for terminals and editors, `false` for
    /// chat apps) keep their own state: that state on first entry, then whatever was
    /// last used there.
    case global
    /// Every app remembers its own state; unseen apps start from their app default.
    case app
    /// Every text field has its own session state (librime's default behaviour).
    case window
}

/// Decides which Chinese/English state a text field gets when it becomes active and
/// where a change made there is remembered. Pure logic, no engine access.
public struct AsciiStatePolicy: Sendable {
    public var scope: AsciiStateScope
    /// Shared state for `.global` (false = Chinese).
    public private(set) var global = false
    /// Remembered state per app (bundle id).
    public private(set) var perApp: [String: Bool] = [:]

    public init(scope: AsciiStateScope = .global) { self.scope = scope }

    /// Apps with their own state under the current scope.
    func keepsOwnState(appDefault: Bool?) -> Bool {
        scope == .app || appDefault != nil
    }

    /// The state to apply on activation, or nil to leave the session as it is.
    /// - Parameters:
    ///   - appDefault: `app_options/<app>/ascii_mode` (true = English, false = Chinese),
    ///     nil when the app has no configured initial state.
    ///   - newSession: the text field just got a fresh librime session.
    public func state(for app: String?, appDefault: Bool?, newSession: Bool) -> Bool? {
        switch scope {
        case .window:
            return newSession ? (appDefault ?? false) : nil
        case .app, .global:
            if keepsOwnState(appDefault: appDefault) {
                return app.flatMap { perApp[$0] } ?? appDefault ?? false
            }
            return global
        }
    }

    /// Records a state the user now has in `app` (after a key, or when leaving it).
    public mutating func record(_ ascii: Bool, app: String?, appDefault: Bool?) {
        switch scope {
        case .window:
            return
        case .app, .global:
            if keepsOwnState(appDefault: appDefault) {
                if let app { perApp[app] = ascii }
            } else {
                global = ascii
            }
        }
    }
}
