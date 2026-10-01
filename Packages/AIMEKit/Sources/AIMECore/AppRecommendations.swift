public import Foundation

/// Recommended per-app options (default English for terminals and editors, Vim mode for
/// Vim-like editors…). The rules are data — `aime/app-recommendations.json` in the user
/// directory overrides the shipped file — so nothing about specific apps lives in code.
public struct AppRecommendations: Sendable, Codable, Equatable {
    public struct Rule: Sendable, Codable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var reason: String
        public var options: [String: Bool]
        public var bundleIDs: [String]?
        public var bundleIDPrefixes: [String]?
        /// `LSApplicationCategoryType` values.
        public var categories: [String]?
        /// Recommended even when no app bundle is found (system services like Spotlight).
        public var systemBundleIDs: [String]?
        public var selectedByDefault: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, reason, options, categories
            case bundleIDs = "bundle_ids", bundleIDPrefixes = "bundle_id_prefixes"
            case systemBundleIDs = "system_bundle_ids", selectedByDefault = "selected_by_default"
        }

        func matches(bundleID: String, category: String?) -> Bool {
            if bundleIDs?.contains(bundleID) == true { return true }
            if bundleIDPrefixes?.contains(where: bundleID.hasPrefix) == true { return true }
            if let category, categories?.contains(category) == true { return true }
            return false
        }
    }

    /// An app found on this Mac (or a system service named by a rule).
    public struct InstalledApp: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        public var category: String?
        public var url: URL?

        public init(bundleID: String, name: String, category: String? = nil, url: URL? = nil) {
            self.bundleID = bundleID
            self.name = name
            self.category = category
            self.url = url
        }
    }

    public struct Suggestion: Sendable, Equatable, Identifiable {
        public var app: InstalledApp
        public var rule: Rule
        public var selected: Bool
        /// Starts as the rule's recommendation; the user may change it before applying.
        public var initialMode: SettingsStore.AppOption.InitialMode
        public var id: String { app.bundleID }

        public init(app: InstalledApp, rule: Rule, selected: Bool) {
            self.app = app
            self.rule = rule
            self.selected = selected
            initialMode = rule.options["ascii_mode"].map { $0 ? .english : .chinese } ?? .shared
        }

        public var option: SettingsStore.AppOption {
            SettingsStore.AppOption(bundleID: app.bundleID, initialMode: initialMode,
                                    noInline: rule.options["no_inline"] ?? false, vimMode: rule.options["vim_mode"] ?? false)
        }
    }

    public var version: Int
    public var rules: [Rule]

    public static func load(_ paths: AIMEPaths) -> AppRecommendations {
        let candidates = [paths.aimeDir.appendingPathComponent("app-recommendations.json"),
                          paths.sharedDataDir?.appendingPathComponent("aime/app-recommendations.json")].compactMap(\.self)
        for url in candidates {
            if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        }
        return AppRecommendations(version: 1, rules: [])
    }

    /// First matching rule per app, in rule order; apps that already have options are
    /// left alone.
    public func suggestions(for apps: [InstalledApp], existing: Set<String>) -> [Suggestion] {
        var seen = existing
        var result: [Suggestion] = []
        for rule in rules {
            for app in apps where rule.matches(bundleID: app.bundleID, category: app.category) && seen.insert(app.bundleID).inserted {
                result.append(Suggestion(app: app, rule: rule, selected: rule.selectedByDefault ?? true))
            }
            for bundleID in rule.systemBundleIDs ?? [] where seen.insert(bundleID).inserted {
                result.append(Suggestion(app: InstalledApp(bundleID: bundleID, name: bundleID.components(separatedBy: ".").last ?? bundleID),
                                         rule: rule, selected: rule.selectedByDefault ?? true))
            }
        }
        return result
    }
}
