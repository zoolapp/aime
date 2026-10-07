public import Foundation

/// The official online vocabularies, read from the website's catalog
/// (`https://aime.zool.app/api/vocabulary.json`, cached), with a copy shipped in
/// SharedSupport for offline first runs. Each feed names its version and SHA-256, so a
/// subscription from the catalog downloads exactly the file the catalog describes.
public struct VocabularyCatalog: Sendable, Codable, Equatable {
    public struct Feed: Sendable, Codable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var description: String
        public var category: String?
        public var entries: Int?
        public var url: URL
        public var version: String?
        /// ISO date of the feed's current version.
        public var updated: String?
        public var sha256: String?
        public var size: Int?

        /// Identity survives versioned URL changes. Older custom subscriptions have
        /// no feed ID, so only their exact source URL can establish a match.
        public func matches(_ subscription: VocabularySubscription) -> Bool {
            if let feedID = subscription.feedID { return id == feedID }
            return url == subscription.url
        }
    }

    public var version: Int
    public var name: String
    public var homepage: URL?
    /// ISO date the catalog was last published.
    public var updated: String?
    public var feeds: [Feed]

    public func availableFeeds(subscriptions: [VocabularySubscription]) -> [Feed] {
        // add() also identifies existing subscriptions by URL; offering that source
        // again would just return the old subscription without changing its feed ID.
        feeds.filter { feed in
            !subscriptions.contains { feed.matches($0) || feed.url == $0.url }
        }
    }

    public static let remoteURL = URL(string: "https://aime.zool.app/api/vocabulary.json")!

    static func cacheURL(_ paths: AIMEPaths) -> URL { paths.aimeDir.appendingPathComponent("subscriptions/catalog.json") }

    /// Cached remote catalog, else the shipped one, else empty.
    public static func load(_ paths: AIMEPaths) -> VocabularyCatalog? {
        let candidates = [cacheURL(paths), paths.sharedDataDir?.appendingPathComponent("aime/vocabulary-catalog.json")].compactMap(\.self)
        for url in candidates {
            if let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Self.self, from: data) { return catalog }
        }
        return nil
    }

    /// Fetches the latest catalog (one small request, user-initiated or with the hourly
    /// vocabulary check) and caches it.
    public static func refresh(_ paths: AIMEPaths, session: URLSession = .shared) async throws -> VocabularyCatalog {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1 << 20 else {
            throw SubscriptionError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try FileManager.default.createDirectory(at: cacheURL(paths).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL(paths), options: .atomic)
        return catalog
    }
}
