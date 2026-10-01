import Foundation

/// Locates AIMECore's bundled resources without trapping.
///
/// `Bundle.module` calls `fatalError` when the resource bundle is not where SwiftPM put
/// it at build time — which is exactly the case for a CLI copied into an app bundle.
enum CoreResources {
    static let bundleName = "AIMEKit_AIMECore.bundle"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(bundleName)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(executableDir.appendingPathComponent(bundleName))
        candidates.append(executableDir.appendingPathComponent("../Resources/\(bundleName)").standardizedFileURL)
        for bundleURL in candidates {
            if let bundle = Bundle(url: bundleURL), let url = bundle.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }
}
