import Foundation

final class CompanionSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct APIError: Error, LocalizedError, Equatable {
    var status: Int
    var message: String
    var body: String?

    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
    var isRouteFailure: Bool { (502...504).contains(status) || (520...530).contains(status) }
}

struct PairResult {
    var token: String
    var deviceId: String
    var serverName: String
    var hosts: [String]
    var endpoints: [CompanionEndpoint]
    var e2e: E2EDescriptor? = nil
}

struct ConnectionMetadata {
    var serverName: String?
    var hosts: [String]?
    var endpoints: [CompanionEndpoint]
    var e2e: E2EDescriptor? = nil
}

/// One computer's companion API. The device token rides on every request
/// except health and pairing; the stream resumes from a stored cursor.
struct ApiClient {
    let baseURL: String
    let token: String?
    let e2e: E2EDescriptor?
    let handshakeCredential: String?

    init(baseURL: String, token: String?, e2e: E2EDescriptor? = nil, handshakeCredential: String? = nil) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.token = token
        self.e2e = e2e
        self.handshakeCredential = handshakeCredential
    }

    func prepare(_ request: URLRequest) async throws -> URLRequest {
        guard let e2e else { return request }
        guard let credential = token ?? handshakeCredential else { throw E2EError.verification }
        let origin = try await E2EConnection.localOrigin(baseURL: baseURL, descriptor: e2e, credential: credential)
        guard let original = request.url, let local = URL(string: origin.baseURL),
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { throw E2EError.framing }
        components.scheme = local.scheme; components.host = local.host; components.port = local.port
        var next = request
        next.url = components.url
        next.setValue(origin.secret, forHTTPHeaderField: "X-OMB-Loopback")
        return next
    }

    static let deviceName: String = {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? "Mac" : String(name.prefix(80))
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "MausBot-macOS/\(AppInfo.version)"]
        return URLSession(configuration: configuration, delegate: CompanionSessionDelegate(), delegateQueue: nil)
    }()

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration, delegate: CompanionSessionDelegate(), delegateQueue: nil)
    }()

    static let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The desktop sends a keepalive comment every ~20 seconds; silence
        // beyond this is a dead route, not an idle one.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.httpAdditionalHeaders = ["User-Agent": "MausBot-macOS/\(AppInfo.version)"]
        return URLSession(configuration: configuration, delegate: CompanionSessionDelegate(), delegateQueue: nil)
    }()

    func health() async throws -> JSON {
        try await get("/api/health", authenticated: false, timeout: 8)
    }

    func botsAndGroups(limit: Int = 50) async throws -> JSON {
        try await get("/api/bots?messages=\(limit)")
    }

    func instances() async throws -> JSON {
        try await get("/api/instances")
    }

    func threadMessages(threadId: String, limit: Int = 50, before: String? = nil) async throws -> JSON {
        var path = "/api/threads/\(threadId)/messages?limit=\(limit)"
        if let before { path += "&before=\(before)" }
        return try await get(path)
    }

    func search(_ query: String) async throws -> JSON {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return try await get("/api/search?q=\(encoded)&limit=40")
    }

    func get(_ path: String, authenticated: Bool = true, timeout: TimeInterval = 30) async throws -> JSON {
        try await send("GET", path, body: nil, authenticated: authenticated, timeout: timeout)
    }

    func request(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        try await send(method, path, body: body, authenticated: true)
    }

    func post(_ path: String, body: JSON = [:]) async throws -> JSON {
        try await send("POST", path, body: body, authenticated: true)
    }

    func patch(_ path: String, body: JSON) async throws -> JSON {
        try await send("PATCH", path, body: body, authenticated: true)
    }

    func put(_ path: String, body: JSON) async throws -> JSON {
        try await send("PUT", path, body: body, authenticated: true)
    }

    func delete(_ path: String) async throws -> JSON {
        try await send("DELETE", path, body: nil, authenticated: true)
    }

    /// Raw bytes for an attachment or avatar. Both sit behind the device token,
    /// so they are read through this client, never a bare URL.
    func bytes(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> Data {
        let full = path.hasPrefix("http://") || path.hasPrefix("https://")
            ? path
            : path.hasPrefix("/") ? baseURL + path : baseURL + "/api/attachments/" + path
        guard let url = URL(string: full) else { throw APIError(status: 0, message: "附件地址无效", body: nil) }
        guard let origin = URL(string: baseURL),
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
            throw APIError(status: 0, message: "附件必须来自已配对的电脑。", body: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = jsonData(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("MausBot-macOS/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let prepared = try await prepare(request)
        let (data, response) = try await Self.session.data(for: prepared)
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "没有响应", body: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: errorMessage(data, status: http.statusCode), body: String(data: data, encoding: .utf8))
        }
        return data
    }

    /// Multipart image upload. The harness stores images under a generated
    /// filename and answers with the reference path.
    func uploadImage(data: Data, mime: String, filename: String) async throws -> JSON {
        guard let url = URL(string: baseURL + "/api/attachments") else {
            throw APIError(status: 0, message: "上传地址无效", body: nil)
        }
        let boundary = "omb-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("MausBot-macOS/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let prepared = try await prepare(request)
        let (responseData, response) = try await Self.session.upload(for: prepared, from: body)
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "没有响应", body: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: errorMessage(responseData, status: http.statusCode), body: String(data: responseData, encoding: .utf8))
        }
        return jsonObject(responseData) ?? [:]
    }

    /// Redeems a one-time pairing credential. New links use the explicit
    /// `credential` field; a six-digit legacy code keeps `code`.
    func pair(credential: String, serverNameHint: String?, pairRequestId: String, timeout: TimeInterval) async throws -> PairResult {
        var body: JSON = ["deviceName": Self.deviceName, "pairRequestId": pairRequestId]
        if credential.count == 6, credential.allSatisfy(\.isNumber) {
            body["code"] = credential
        } else {
            body["credential"] = credential
        }
        let answer = try await send("POST", "/api/pair", body: body, authenticated: false, timeout: timeout)
        guard let deviceToken = answer.nonEmpty("token") else {
            throw APIError(status: 401, message: "电脑没有返回设备令牌", body: nil)
        }
        let device = answer.obj("device")
        let endpoints = parseEndpoints(answer.array("endpoints"))
        let hosts = answer.strArray("hosts")
        let name = answer.nonEmpty("serverName") ?? serverNameHint ?? CompanionEndpoint.host(of: baseURL)
        let advertised = try answer.obj("e2e").map { try E2EDescriptor(json: $0) }
        let pinned = try e2e?.accepting(advertised) ?? advertised
        return PairResult(
            token: deviceToken,
            deviceId: device?.nonEmpty("id") ?? name,
            serverName: name,
            hosts: hosts,
            endpoints: endpoints,
            e2e: pinned
        )
    }

    func connectionMetadata() async throws -> ConnectionMetadata {
        let answer = try await get("/api/companion/endpoints")
        let advertised = try answer.obj("e2e").map { try E2EDescriptor(json: $0) }
        let pinned = try e2e?.accepting(advertised) ?? advertised
        return ConnectionMetadata(
            serverName: answer.nonEmpty("serverName"),
            hosts: answer.array("hosts") == nil ? nil : answer.strArray("hosts"),
            endpoints: parseEndpoints(answer.array("endpoints")),
            e2e: pinned
        )
    }

    private func parseEndpoints(_ array: [Any]?) -> [CompanionEndpoint] {
        guard let array else { return [] }
        let parsed: [CompanionEndpoint] = array.enumerated().compactMap { index, item in
            if let object = item as? JSON { return CompanionEndpoint.from(object) }
            if let url = item as? String, !url.isEmpty {
                return CompanionEndpoint.make(url: url, kind: CompanionEndpoint.kind(forOrigin: url), priority: index)
            }
            return nil
        }
        return CompanionEndpoint.ordered(parsed)
    }

    /// A health check that fails fast, used while walking an invite's routes.
    func probeHealth() async -> (ok: Bool, name: String?) {
        let client = ApiClient(baseURL: baseURL, token: nil)
        guard let url = URL(string: client.baseURL + "/api/health") else { return (false, nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await Self.probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = jsonObject(data)
            else { return (false, nil) }
            let app = json.str("app") ?? ""
            return (app == "openmausbot" || app == "mausbot", json.nonEmpty("name"))
        } catch {
            return (false, nil)
        }
    }

    private func send(_ method: String, _ path: String, body: JSON?, authenticated: Bool, timeout: TimeInterval = 30) async throws -> JSON {
        guard let url = URL(string: baseURL + path) else {
            throw APIError(status: 0, message: "地址无效：\(baseURL + path)", body: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MausBot-macOS/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if authenticated, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            guard let data = jsonData(body) else {
                throw APIError(status: 0, message: "请求内容无法编码", body: nil)
            }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let prepared = try await prepare(request)
        let (data, response) = try await Self.session.data(for: prepared)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "没有响应", body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: errorMessage(data, status: http.statusCode), body: String(data: data, encoding: .utf8))
        }
        if data.isEmpty { return [:] }
        return jsonObject(data) ?? [:]
    }

    private func errorMessage(_ data: Data, status: Int) -> String {
        if let json = jsonObject(data), let message = json.nonEmpty("error") ?? json.nonEmpty("message") {
            return message
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty, text.count < 300 {
            return text
        }
        switch status {
        case 426: return "远程电脑要求端到端加密连接。请使用 0.1.1 或更新版本，并在电脑上生成新的配对链接。"
        case 401: return "这台电脑不再信任本设备，请在电脑上重新配对。"
        case 404: return "电脑上没有这个接口（HTTP 404）。"
        default: return "请求失败（HTTP \(status)）"
        }
    }
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
}
