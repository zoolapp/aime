public import Foundation
internal import CRime

/// Directories and identity handed to librime on setup / initialize.
public struct RimeTraits: Sendable, Equatable {
    public var sharedDataDir: URL
    public var userDataDir: URL
    public var logDir: URL?
    public var stagingDir: URL?
    public var prebuiltDataDir: URL?
    public var appName: String
    public var distributionName: String
    public var distributionCodeName: String
    public var distributionVersion: String
    /// 0 = INFO, 1 = WARNING, 2 = ERROR, 3 = FATAL. AIME defaults to WARNING so
    /// that nothing resembling user input ends up in log files.
    public var minLogLevel: Int32

    public init(
        sharedDataDir: URL,
        userDataDir: URL,
        logDir: URL? = nil,
        stagingDir: URL? = nil,
        prebuiltDataDir: URL? = nil,
        appName: String = "rime.aime",
        distributionName: String = "AIME",
        distributionCodeName: String = "AIME",
        distributionVersion: String = "0.1.0",
        minLogLevel: Int32 = 1
    ) {
        self.sharedDataDir = sharedDataDir
        self.userDataDir = userDataDir
        self.logDir = logDir
        self.stagingDir = stagingDir
        self.prebuiltDataDir = prebuiltDataDir
        self.appName = appName
        self.distributionName = distributionName
        self.distributionCodeName = distributionCodeName
        self.distributionVersion = distributionVersion
        self.minLogLevel = minLogLevel
    }
}

/// Messages librime posts through its notification handler.
public enum RimeNotification: Sendable, Equatable {
    case deployStarted
    case deploySucceeded
    case deployFailed
    case schemaChanged(id: String, name: String)
    case optionChanged(name: String, enabled: Bool)
    case propertyChanged(name: String, value: String)
    case other(type: String, value: String)

    init(type: String, value: String) {
        switch (type, value) {
        case ("deploy", "start"): self = .deployStarted
        case ("deploy", "success"): self = .deploySucceeded
        case ("deploy", "failure"): self = .deployFailed
        case ("schema", _):
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            self = .schemaChanged(id: parts.first ?? value, name: parts.count > 1 ? parts[1] : "")
        case ("option", _):
            let enabled = !value.hasPrefix("!")
            self = .optionChanged(name: enabled ? value : String(value.dropFirst()), enabled: enabled)
        case ("property", _):
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            self = .propertyChanged(name: parts.first ?? value, value: parts.count > 1 ? parts[1] : "")
        default: self = .other(type: type, value: value)
        }
    }
}

public struct RimeSchemaInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
}

public enum RimeError: Error, Equatable, CustomStringConvertible {
    case notInitialized
    case sessionCreationFailed
    case deployFailed
    case configNotFound(String)

    public var description: String {
        switch self {
        case .notInitialized: "librime is not initialized"
        case .sessionCreationFailed: "failed to create a librime session"
        case .deployFailed: "deployment failed; see the librime log for details"
        case let .configNotFound(id): "config '\(id)' could not be opened"
        }
    }
}

/// Process-wide handle on librime.
///
/// librime keeps global state (one set of directories, one deployer, one session
/// table), so there is exactly one engine per process. All calls are confined to the
/// main actor: InputMethodKit delivers key events on the main thread and a single
/// confinement domain keeps session access race-free without locks on the hot path.
@MainActor
public final class RimeEngine {
    public static let shared = RimeEngine()

    public private(set) var isSetUp = false
    public private(set) var isInitialized = false
    public private(set) var traits: RimeTraits?

    /// Invoked on the main actor for every librime notification.
    public var notificationHandler: ((RimeNotification) -> Void)?

    let api: UnsafeMutablePointer<RimeApi_stdbool>
    private var retainedCStrings: [UnsafeMutablePointer<CChar>] = []
    private let sessions = NSHashTable<RimeSession>.weakObjects()

    private init() {
        guard let api = rime_get_api_stdbool() else {
            fatalError("librime did not return an API table")
        }
        self.api = api
    }

    /// Location of the loaded librime dylib. librime loads plugins from the
    /// `rime-plugins` directory next to it.
    public var libraryURL: URL? {
        var info = Dl_info()
        guard let symbol = unsafeBitCast(api.pointee.get_version, to: UnsafeRawPointer?.self),
              dladdr(symbol, &info) != 0, let name = info.dli_fname
        else { return nil }
        return URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
    }

    /// Plugin dylibs librime will pick up (lua, octagram, predict…).
    public var availablePlugins: [String] {
        guard let dir = libraryURL?.deletingLastPathComponent().appendingPathComponent("rime-plugins") else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".dylib") }.map {
            $0.replacingOccurrences(of: "librime-", with: "").replacingOccurrences(of: ".dylib", with: "")
        }.sorted()
    }

    public var version: String {
        api.pointee.get_version().map { String(cString: $0) } ?? "unknown"
    }

    /// Performs one-time process setup (logging, deployer directories). Safe to call
    /// repeatedly; only the first call configures logging.
    public func setup(_ traits: RimeTraits) {
        var raw = makeRawTraits(traits)
        if !isSetUp {
            api.pointee.setup(&raw)
            let context = Unmanaged.passUnretained(self).toOpaque()
            api.pointee.set_notification_handler(rimeNotificationTrampoline, context)
            isSetUp = true
        }
        self.traits = traits
    }

    /// Loads modules (including plugins) and opens the deployer against `traits`.
    /// Call `finalize()` before re-initializing with different directories.
    public func initialize(_ traits: RimeTraits) {
        if !isSetUp { setup(traits) }
        if isInitialized { finalize() }
        var raw = makeRawTraits(traits)
        api.pointee.initialize(&raw)
        self.traits = traits
        isInitialized = true
        deployerLoaded = false
    }

    /// Initializes only when not already running against exactly these traits.
    public func ensureInitialized(_ traits: RimeTraits) {
        if isInitialized, self.traits == traits { return }
        initialize(traits)
    }

    public func finalize() {
        guard isInitialized else { return }
        invalidateSessions()
        api.pointee.finalize()
        isInitialized = false
    }

    /// Starts background maintenance (deploys changed files). Returns false when no
    /// maintenance was needed or it could not start.
    @discardableResult
    public func startMaintenance(fullCheck: Bool) -> Bool {
        api.pointee.start_maintenance(fullCheck)
    }

    public var isMaintaining: Bool { api.pointee.is_maintenance_mode() }

    public func joinMaintenance() { api.pointee.join_maintenance_thread() }

    /// Synchronously deploys everything under the current traits (blocking).
    /// Intended for the CLI and tests; the input method uses `startMaintenance`.
    public func deploySynchronously() throws {
        guard isInitialized else { throw RimeError.notInitialized }
        var raw = makeRawTraits(traits!)
        api.pointee.deployer_initialize(&raw)
        guard api.pointee.deploy() else { throw RimeError.deployFailed }
    }

    /// Runs a full workspace update in the maintenance thread and waits for it.
    /// Unlike `deploySynchronously` this goes through the same code path the input
    /// method uses at startup, so it also reports per-schema failures via notifications.
    public func deployAndWait(fullCheck: Bool = true) {
        if startMaintenance(fullCheck: fullCheck) {
            joinMaintenance()
        }
    }

    /// Compiles a frontend config (plus its `.custom.yaml`) into the staging dir.
    /// librime's workspace update only covers default.yaml and schemas; frontends deploy
    /// their own config file this way (Squirrel does the same for squirrel.yaml).
    @discardableResult
    public func deployConfigFile(_ fileName: String, versionKey: String = "config_version") -> Bool {
        ensureDeployerLoaded()
        return api.pointee.deploy_config_file(fileName, versionKey)
    }

    /// Deployment tasks (config_file_update, user_dict_sync…) live in librime's
    /// "deployer" module, which `initialize` does not load.
    private func ensureDeployerLoaded() {
        guard !deployerLoaded, let traits else { return }
        var raw = makeRawTraits(traits)
        api.pointee.deployer_initialize(&raw)
        deployerLoaded = true
    }

    private var deployerLoaded = false

    /// Exports user dictionary snapshots to the sync dir and merges other devices'
    /// snapshots (runs in librime's maintenance thread; `joinMaintenance` to wait).
    @discardableResult
    public func syncUserData() -> Bool {
        ensureDeployerLoaded()
        return api.pointee.sync_user_data()
    }

    public func createSession() throws -> RimeSession {
        guard isInitialized else { throw RimeError.notInitialized }
        let id = api.pointee.create_session()
        guard id != 0 else { throw RimeError.sessionCreationFailed }
        let session = RimeSession(id: id, engine: self)
        sessions.add(session)
        return session
    }

    public func cleanupAllSessions() {
        invalidateSessions()
        api.pointee.cleanup_all_sessions()
    }

    private func invalidateSessions() {
        for session in sessions.allObjects { session.invalidate() }
        sessions.removeAllObjects()
    }

    public func schemaList() -> [RimeSchemaInfo] {
        var list = RimeSchemaList(size: 0, list: nil)
        guard api.pointee.get_schema_list(&list) else { return [] }
        defer { api.pointee.free_schema_list(&list) }
        return (0..<list.size).compactMap { index in
            let item = list.list[index]
            guard let id = item.schema_id else { return nil }
            return RimeSchemaInfo(id: String(cString: id), name: item.name.map { String(cString: $0) } ?? "")
        }
    }

    /// Opens a deployed config from the staging dir (e.g. "default", "aime").
    public func openConfig(_ configID: String) throws -> RimeConfigReader {
        var config = RimeConfig(ptr: nil)
        guard api.pointee.config_open(configID, &config) else { throw RimeError.configNotFound(configID) }
        return RimeConfigReader(config: config, engine: self)
    }

    /// Opens a deployed schema (build/<schema>.schema.yaml).
    public func openSchema(_ schemaID: String) throws -> RimeConfigReader {
        var config = RimeConfig(ptr: nil)
        guard api.pointee.schema_open(schemaID, &config) else { throw RimeError.configNotFound(schemaID) }
        return RimeConfigReader(config: config, engine: self)
    }

    /// Opens a user-directory config such as `user` or `installation`.
    public func openUserConfig(_ configID: String) throws -> RimeConfigReader {
        var config = RimeConfig(ptr: nil)
        guard api.pointee.user_config_open(configID, &config) else { throw RimeError.configNotFound(configID) }
        return RimeConfigReader(config: config, engine: self)
    }

    /// Records `schemaID` as the schema new sessions start with (`user.yaml`
    /// `var/previously_selected_schema`) — what librime's own switcher writes when the
    /// user picks a schema. `select_schema` alone does not record it.
    @discardableResult
    public func rememberSelectedSchema(_ schemaID: String) -> Bool {
        var config = RimeConfig(ptr: nil)
        guard api.pointee.user_config_open("user", &config) else { return false }
        defer { _ = api.pointee.config_close(&config) }
        return api.pointee.config_set_string(&config, "var/previously_selected_schema", schemaID)
    }

    public var userDataSyncDir: String {
        var buffer = [CChar](repeating: 0, count: 4096)
        api.pointee.get_user_data_sync_dir(&buffer, buffer.count)
        return String(nullTerminated: buffer)
    }

    // MARK: - Notifications

    fileprivate nonisolated static func deliver(type: String, value: String, to engine: RimeEngine) {
        let notification = RimeNotification(type: type, value: value)
        // Always asynchronous, even when librime notifies on the main thread: librime
        // calls this from inside process_key / set_option, and a handler that reached
        // back into the client app (e.g. to ask for the cursor rect) from there would
        // re-enter InputMethodKit while the client is blocked waiting for our reply —
        // a cross-process deadlock that freezes the app.
        DispatchQueue.main.async { MainActor.assumeIsolated { engine.notificationHandler?(notification) } }
    }

    // MARK: - Traits marshalling

    private func retain(_ string: String?) -> UnsafePointer<CChar>? {
        guard let string else { return nil }
        let copy = strdup(string)!
        retainedCStrings.append(copy)
        return UnsafePointer(copy)
    }

    private func makeRawTraits(_ traits: RimeTraits) -> CRime.RimeTraits {
        var raw = CRime.RimeTraits()
        raw.data_size = Int32(MemoryLayout<CRime.RimeTraits>.size - MemoryLayout<Int32>.size)
        raw.shared_data_dir = retain(traits.sharedDataDir.path)
        raw.user_data_dir = retain(traits.userDataDir.path)
        raw.distribution_name = retain(traits.distributionName)
        raw.distribution_code_name = retain(traits.distributionCodeName)
        raw.distribution_version = retain(traits.distributionVersion)
        raw.app_name = retain(traits.appName)
        raw.min_log_level = traits.minLogLevel
        raw.log_dir = retain(traits.logDir?.path ?? "")
        raw.staging_dir = retain(traits.stagingDir?.path)
        raw.prebuilt_data_dir = retain(traits.prebuiltDataDir?.path)
        return raw
    }
}

private func rimeNotificationTrampoline(
    context: UnsafeMutableRawPointer?,
    session: RimeSessionId,
    type: UnsafePointer<CChar>?,
    value: UnsafePointer<CChar>?
) {
    guard let context, let type else { return }
    let engine = Unmanaged<RimeEngine>.fromOpaque(context).takeUnretainedValue()
    RimeEngine.deliver(
        type: String(cString: type),
        value: value.map { String(cString: $0) } ?? "",
        to: engine
    )
}
