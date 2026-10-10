public import Foundation
import Security

/// Any OpenAI-compatible `/chat/completions` endpoint with a user-supplied key.
public struct OpenAICompatibleProvider: AIProvider {
    public let id = "openai-compatible"
    public var displayName: String { "OpenAI 兼容接口（\(model)）" }
    public var baseURL: URL
    public var model: String
    /// User-supplied JSON object merged into every request body (top-level keys
    /// only; `model` and `messages` are never overridden). Invalid JSON is ignored.
    public let extraFieldsJSON: String
    let credentials: CredentialStore
    let session: URLSession

    public init(baseURL: URL, model: String, keychainAccount: String = "openai-compatible",
                credentials: CredentialStore? = nil, session: URLSession = .shared, extraFieldsJSON: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.extraFieldsJSON = extraFieldsJSON
        self.credentials = credentials ?? CredentialStore(account: keychainAccount)
        self.session = session
    }

    public func availability() async -> AIAvailability {
        credentials.read() == nil ? .unavailable(reason: "尚未配置 API Key") : .available
    }

    public func complete(instructions: String, prompt: String) async throws -> String {
        try await send(messages: [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
                       temperature: 0.2, maxTokens: nil, timeout: 45).content
    }

    /// What a successful check found.
    public struct Verification: Sendable, Equatable {
        /// Model name the endpoint reports (a router may answer with a different one).
        public var model: String
        public var seconds: Double
        public var reply: String
    }

    /// One tiny request to confirm the address, key and model work together.
    public func verify() async throws -> Verification {
        let start = Date()
        let result = try await send(messages: [["role": "user", "content": "只回复两个字母：OK"]], temperature: 0, maxTokens: 16, timeout: 25)
        return Verification(model: result.model ?? model, seconds: Date().timeIntervalSince(start),
                            reply: String(result.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))
    }

    private func send(messages: [[String: String]], temperature: Double, maxTokens: Int?, timeout: TimeInterval) async throws
        -> (content: String, model: String?) {
        guard let key = credentials.read(), !key.isEmpty else { throw AIError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": model, "temperature": temperature, "messages": messages]
        if let maxTokens { body["max_tokens"] = maxTokens }
        for (key, value) in Self.extraFields(from: extraFieldsJSON) where key != "model" && key != "messages" {
            body[key] = value
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw AIError.unavailable(Self.explain(error, host: baseURL.host() ?? baseURL.absoluteString))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIError.http(status, Self.explain(status: status, body: String(decoding: data.prefix(400), as: UTF8.self)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw AIError.badResponse("接口返回的不是 chat/completions 格式") }
        return (content, json["model"] as? String)
    }

    /// Parses the user's extra-fields JSON. Anything that is not a JSON object
    /// (or is invalid) contributes nothing.
    static func extraFields(from json: String) -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Plain-language reason for an HTTP error, so "524" is not all the user sees.
    static func explain(status: Int, body: String) -> String {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401, 403: return "API Key 无效或没有权限"
        case 404: return "接口地址或模型名不对（地址应以 /v1 结尾，不含 /chat/completions）"
        case 408, 504, 522, 524: return "服务端超时：接口在限定时间内没有响应，稍后再试或换一个模型"
        case 429: return "请求过于频繁或额度不足"
        case 500...599: return "服务端出错" + (detail.isEmpty ? "" : "：\(detail.prefix(80))")
        default: return detail.isEmpty ? "请求被拒绝" : String(detail.prefix(120))
        }
    }

    static func explain(_ error: URLError, host: String) -> String {
        switch error.code {
        case .timedOut: "连接 \(host) 超时"
        case .cannotFindHost, .dnsLookupFailed: "找不到主机 \(host)，检查接口地址"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet: "无法连接 \(host)，检查网络"
        case .secureConnectionFailed, .serverCertificateUntrusted: "与 \(host) 的安全连接失败"
        case .cancelled: "已取消"
        default: "网络错误（\(error.code.rawValue)）"
        }
    }
}

/// Where the user's API key lives: a small owner-only file shared by AIME Settings
/// (writes) and the input method (reads). Not the system Keychain — an item written by
/// one app makes macOS ask for the login password when the other app reads it.
public struct CredentialStore: Sendable {
    public let account: String
    let fileURL: URL

    public init(account: String, fileURL: URL = CredentialStore.defaultURL) {
        self.account = account
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["AIME_CREDENTIALS_FILE"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIME/credentials.json")
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func read() -> String? {
        let value = load()[account]
        return value?.isEmpty == false ? value : nil
    }

    /// Saves (or, with nil / empty, removes) the key. Directory 0700, file 0600.
    @discardableResult
    public func write(_ value: String?) -> Bool {
        var all = load()
        if let value, !value.isEmpty { all[account] = value } else { all[account] = nil }
        let fm = FileManager.default
        do {
            let directory = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    /// Moves a key saved by an earlier version from the login Keychain into the file
    /// and removes the Keychain item. Call from AIME Settings only: it wrote the item,
    /// so reading it there does not prompt.
    @discardableResult
    public func migrateFromKeychain() -> Bool {
        guard read() == nil else { return false }
        for service in ["app.zool.aime.ai", "dev.luolei.aime.ai"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { continue }
            guard write(value) else { return false }
            SecItemDelete(query as CFDictionary)
            return true
        }
        return false
    }
}
