import Foundation
internal import CRime

/// Read-only view on a deployed (fully merged) librime config.
@MainActor
public final class RimeConfigReader {
    private var config: RimeConfig
    private unowned let engine: RimeEngine
    private var api: UnsafeMutablePointer<RimeApi_stdbool> { engine.api }

    init(config: RimeConfig, engine: RimeEngine) {
        self.config = config
        self.engine = engine
    }

    isolated deinit {
        _ = api.pointee.config_close(&config)
    }

    public func bool(_ key: String) -> Bool? {
        var value = false
        return api.pointee.config_get_bool(&config, key, &value) ? value : nil
    }

    public func int(_ key: String) -> Int? {
        var value: Int32 = 0
        return api.pointee.config_get_int(&config, key, &value) ? Int(value) : nil
    }

    public func double(_ key: String) -> Double? {
        var value = 0.0
        return api.pointee.config_get_double(&config, key, &value) ? value : nil
    }

    public func string(_ key: String) -> String? {
        api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
    }

    public func listSize(_ key: String) -> Int { Int(api.pointee.config_list_size(&config, key)) }

    /// String values of a list node, skipping non-scalar entries.
    public func stringList(_ key: String) -> [String] {
        (0..<listSize(key)).compactMap { string("\(key)/@\($0)") }
    }

    /// Keys of a map node, in document order.
    public func mapKeys(_ key: String) -> [String] {
        var iterator = RimeConfigIterator()
        guard api.pointee.config_begin_map(&iterator, &config, key) else { return [] }
        defer { api.pointee.config_end(&iterator) }
        var keys: [String] = []
        while api.pointee.config_next(&iterator) {
            if let raw = iterator.key { keys.append(String(cString: raw)) }
        }
        return keys
    }
}

extension String {
    /// Decodes a fixed-size, NUL-terminated C buffer.
    init(nullTerminated buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
