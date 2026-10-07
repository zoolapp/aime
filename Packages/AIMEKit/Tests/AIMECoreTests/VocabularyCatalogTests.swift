import Foundation
import Testing
@testable import AIMECore

struct VocabularyCatalogTests {
    private let feed = VocabularyCatalog.Feed(id: "ai-terms", name: "AI 术语", description: "专题词库", category: "ai", entries: 160,
                                              url: URL(string: "https://example.invalid/v2/terms.txt")!, version: "2", updated: nil, sha256: nil, size: nil)

    private func subscription(url: String, feedID: String? = nil) -> VocabularySubscription {
        .init(id: "saved", name: "AI 术语", url: URL(string: url)!, addedAt: Date(timeIntervalSince1970: 0), feedID: feedID)
    }

    private var catalog: VocabularyCatalog {
        .init(version: 1, name: "目录", homepage: nil, updated: nil, feeds: [feed])
    }

    @Test func versionedSourceKeepsAddedFeedHiddenEvenWhenUpdateFails() {
        var saved = subscription(url: "https://example.invalid/v1/terms.txt", feedID: feed.id)
        saved.lastError = "网络不可用"
        saved.interval = .weekly
        #expect(catalog.availableFeeds(subscriptions: [saved]).isEmpty)
        #expect(saved.lastError != nil && saved.updateInterval == .weekly)
    }

    @Test func legacyExactURLMatchesWithoutGuessingNamesOrFilenames() {
        let legacy = subscription(url: feed.url.absoluteString)
        #expect(catalog.availableFeeds(subscriptions: [legacy]).isEmpty)
        let sameName = subscription(url: "https://other.invalid/v2/terms.txt")
        #expect(catalog.availableFeeds(subscriptions: [sameName]) == [feed])
    }

    @Test func sameURLCannotBeAddedAgainButDoesNotOverwriteExplicitIdentity() {
        let other = subscription(url: feed.url.absoluteString, feedID: "another-feed")
        #expect(!feed.matches(other))
        #expect(catalog.availableFeeds(subscriptions: [other]).isEmpty)
    }

    @Test func removedSubscriptionMakesFeedAvailableAgainAndDownlistingKeepsSavedState() {
        let saved = subscription(url: feed.url.absoluteString, feedID: feed.id)
        #expect(catalog.availableFeeds(subscriptions: [saved]).isEmpty)
        #expect(catalog.availableFeeds(subscriptions: []) == [feed])
        let empty = VocabularyCatalog(version: 2, name: "目录", homepage: nil, updated: nil, feeds: [])
        #expect(empty.availableFeeds(subscriptions: [saved]).isEmpty)
        #expect(saved.feedID == feed.id && saved.url == feed.url)
    }
}
