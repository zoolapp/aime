public import Foundation

/// Build-time counts of the enabled base dictionary. The app reads only this small
/// manifest, never the dictionary records. Raw rows are not a count of unique words.
public struct DictionaryMetadata: Sendable, Codable, Equatable {
    public struct SourceFile: Sendable, Codable, Equatable {
        public var path: String
        public var dictionary: String
        public var version: String
        public var sha256: String
        public var rawRows: Int
        public var importTables: [String]
    }

    public var version: Int
    public var schema: String
    public var dictionary: String
    public var packageID: String
    public var sourceVersion: String
    public var sourceURL: URL
    public var sourceSHA256: String
    public var license: String
    public var rawRows: Int
    public var rawRowsDescription: String
    public var sourceFiles: [SourceFile]

    /// Counts describe AIME's shipped baseline, not overrides in the live user data.
    /// Missing, malformed, unsupported or inconsistent metadata is unavailable.
    public static func load(_ paths: AIMEPaths) -> DictionaryMetadata? {
        guard let url = paths.sharedDataDir?.appendingPathComponent("aime/dictionary-metadata.json"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size < 256 * 1024,
              let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(Self.self, from: data),
              metadata.isValid else { return nil }
        return metadata
    }

    private var isValid: Bool {
        guard version == 1, !schema.isEmpty, !dictionary.isEmpty, !packageID.isEmpty,
              !sourceVersion.isEmpty, sourceURL.scheme == "https", sourceURL.host != nil,
              Self.isSHA256(sourceSHA256), !license.isEmpty, !rawRowsDescription.isEmpty,
              rawRows >= 0, !sourceFiles.isEmpty, sourceFiles.count <= 64,
              Set(sourceFiles.map(\.path)).count == sourceFiles.count else { return false }
        var total = 0
        for file in sourceFiles {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.hasPrefix("/"), !file.path.contains("\\"), file.path.hasSuffix(".dict.yaml"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !file.dictionary.isEmpty, !file.version.isEmpty, Self.isSHA256(file.sha256), file.rawRows >= 0 else { return false }
            let addition = total.addingReportingOverflow(file.rawRows)
            guard !addition.overflow else { return false }
            total = addition.partialValue
        }
        return total == rawRows && sourceFiles.first?.path == "\(dictionary).dict.yaml"
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
