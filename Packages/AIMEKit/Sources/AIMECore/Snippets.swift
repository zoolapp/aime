public import Foundation

/// 常用语: the user's own text snippets in named categories (证件, 手机号, 地址…), picked
/// from the quick menu. Stored locally in `aime/snippets.json` (owner-only), never sent
/// anywhere and not part of the engine's dictionaries.
public struct Snippets: Sendable, Codable, Equatable {
    public struct Category: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var items: [String]

        public init(id: UUID = UUID(), name: String, items: [String] = []) {
            self.id = id
            self.name = name
            self.items = items
        }
    }

    public var categories: [Category]

    public init(categories: [Category] = []) { self.categories = categories }

    /// Names offered when adding a category.
    public static let presetNames = ["证件", "手机号", "地址", "邮箱", "银行卡", "公司信息", "常用回复"]

    static func url(_ paths: AIMEPaths) -> URL { paths.aimeDir.appendingPathComponent("snippets.json") }

    public static func load(_ paths: AIMEPaths) -> Snippets {
        guard let data = try? Data(contentsOf: url(paths)) else { return Snippets() }
        return (try? JSONDecoder().decode(Snippets.self, from: data)) ?? Snippets()
    }

    public func save(_ paths: AIMEPaths) throws {
        try FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.url(paths)
        try encoder.encode(self).write(to: url, options: .atomic)
        // May hold ID numbers, phone numbers, addresses: owner-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Categories for the quick menu (blank items dropped).
    public var menuCategories: [QuickMenu.Symbols.Category] {
        categories.map { category in
            .init(id: category.id.uuidString, title: category.name.isEmpty ? "未命名" : category.name, symbol: nil,
                  items: category.items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
    }
}
