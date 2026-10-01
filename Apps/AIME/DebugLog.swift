import Foundation

/// Opt-in diagnostics for the input path, off by default:
///   defaults write app.zool.inputmethod.aime AIMEDebugLog -bool YES
/// Writes to ~/Library/Logs/AIME/ime-debug.log. Records event kinds, flags and text
/// *lengths* only — never the characters typed (see docs/privacy.md).
@MainActor
enum DebugLog {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "AIMEDebugLog")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AIME/ime-debug.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds, .withColonSeparatorInTime]
        return formatter
    }()

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(formatter.string(from: Date())) \(message())\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
