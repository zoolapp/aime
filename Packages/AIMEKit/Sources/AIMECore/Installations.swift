public import Foundation

/// The two places an AIME input method can be installed, and which one is in charge.
///
/// The `.pkg` (and Homebrew, and the in-app updater) install to `/Library/Input Methods`;
/// `scripts/install-dev.sh` and hand copies use `~/Library/Input Methods`. Both carry the
/// same bundle ID, so with both present macOS lists AIME twice per kind in Input Sources
/// (#32), and code that blindly preferred the per-user copy talked to a stale version.
public struct AIMEInstallations: Sendable, Equatable {
    public static let bundleID = "app.zool.inputmethod.aime"
    public static let systemURL = URL(fileURLWithPath: "/Library/Input Methods/AIME.app")
    public static func userURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Input Methods/AIME.app")
    }

    public struct Install: Sendable, Equatable {
        public let url: URL
        public let version: String
        /// `CFBundleVersion` as a number; 0 when missing or not numeric.
        public let build: Int
    }

    public let user: Install?
    public let system: Install?

    public init(userURL: URL = AIMEInstallations.userURL(), systemURL: URL = AIMEInstallations.systemURL) {
        user = Self.read(userURL)
        system = Self.read(systemURL)
    }

    /// Both copies exist with AIME's bundle ID.
    public var isDuplicate: Bool { user != nil && system != nil }

    /// The copy to use: the higher build; on a tie the system-wide one (what the
    /// installer just put there). `nil` when AIME is not installed.
    public var preferred: Install? {
        switch (user, system) {
        case let (user?, system?): user.build > system.build ? user : system
        case let (user?, nil): user
        case let (nil, system?): system
        case (nil, nil): nil
        }
    }

    /// With two copies, the one not in charge.
    public var stale: Install? {
        guard isDuplicate, let preferred else { return nil }
        return preferred == system ? user : system
    }

    /// Reads Info.plist directly: `Bundle(url:)` caches, and a bundle replaced by an
    /// upgrade would keep reporting the old version.
    static func read(_ url: URL) -> Install? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        return Install(url: url, version: version, build: build)
    }
}
