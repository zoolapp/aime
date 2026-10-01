import AIMECore
import Foundation

/// Finds installed applications for 智能配置. Reads bundle metadata only.
enum AppScanner {
    static let roots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// App bundles directly in the roots and one folder down (Utilities, vendor folders).
    static func applicationURLs() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        func children(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        for root in roots {
            for item in children(root) {
                if item.pathExtension == "app" {
                    result.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    result += children(item).filter { $0.pathExtension == "app" }
                }
            }
        }
        return result
    }

    static func describe(_ url: URL) -> AppRecommendations.InstalledApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return .init(bundleID: bundleID, name: name,
                     category: bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String, url: url)
    }

    /// Scans off the main actor, reporting each app so the UI can show progress. A short
    /// pause per app keeps the progress readable (a full scan still takes about a second).
    static func scan(progress: @escaping @MainActor (_ fraction: Double, _ app: AppRecommendations.InstalledApp) -> Void) async -> [AppRecommendations.InstalledApp] {
        await Task.detached(priority: .userInitiated) {
            let urls = applicationURLs()
            var apps: [AppRecommendations.InstalledApp] = []
            var seen = Set<String>()
            for (index, url) in urls.enumerated() {
                guard let app = describe(url), seen.insert(app.bundleID).inserted else { continue }
                apps.append(app)
                let fraction = Double(index + 1) / Double(max(1, urls.count))
                await progress(fraction, app)
                try? await Task.sleep(for: .milliseconds(6))
            }
            return apps
        }.value
    }
}
