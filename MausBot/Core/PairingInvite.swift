import Foundation

/// A pairing window handed over by the desktop as a QR code or deep link. It
/// carries a short-lived, single-use credential; the long-lived device token
/// is created later by `/api/pair` and never appears in the link.
struct PairingInvite: Equatable {
    var routes: [CompanionEndpoint]
    var token: String?
    var code: String?
    var serverName: String
    var hosts: [String] = []
    /// P-256 public key a credential card would be sealed to. Accepted and
    /// carried along; this client does not send secrets back to the computer.
    var secretKey: String?
    var e2e: E2EDescriptor? = nil

    var credential: String? { token ?? code }
    var primary: CompanionEndpoint? { routes.first }

    /// A representative link for the form: the primary route plus its
    /// credential, enough to re-pair the same computer by hand.
    var shareLink: String {
        guard let primary else { return "" }
        var parts = ["address=\(primary.host)", "port=\(primary.port)"]
        if let token {
            parts.append("token=\(token)")
        } else if let code {
            parts.append("code=\(code)")
        }
        if !serverName.isEmpty {
            parts.append("name=\(serverName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? serverName)")
        }
        if let e2e { parts.append("e2e=\(e2e.encoded)") }
        if let data = jsonData(routes.map { $0.toJSON() }) { parts.append("endpoints=\(data.b64u)") }
        return "openmausbot://pair?" + parts.joined(separator: "&")
    }

    static func parse(_ raw: String) -> PairingInvite? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let isOrigin = (text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://"))
            && !text.contains("?")
        if isOrigin {
            // A bare origin has no credential; the address field handles it.
            return nil
        }

        let queryText: String
        if text.lowercased().hasPrefix("openmausbot://") {
            guard let mark = text.firstIndex(of: "?") else { return nil }
            queryText = String(text[text.index(after: mark)...])
        } else if let mark = text.firstIndex(of: "?") {
            queryText = String(text[text.index(after: mark)...])
        } else {
            queryText = text
        }
        let query = parseQuery(queryText)

        let pastedOrigin = (text.hasPrefix("https://") || text.hasPrefix("http://"))
            ? String(text.split(separator: "?", maxSplits: 1)[0]) : nil
        let addressRoutes: [CompanionEndpoint]
        if let address = query["address"], !address.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = routes(fromAddress: address, port: Int(query["port"] ?? "")) else { return nil }
            addressRoutes = parsed
        } else if let origin = pastedOrigin, let route = endpoint(fromOrigin: origin) {
            addressRoutes = [route]
        } else {
            return nil
        }

        if let encoded = query["endpoints"] {
            let typed: [CompanionEndpoint]
            if let decoded = CompanionEndpoint.decodeList(encoded) {
                typed = decoded
            } else if encoded.contains(":") {
                let parts = encoded.split(separator: ",", omittingEmptySubsequences: false)
                var legacy: [CompanionEndpoint] = []
                for (index, part) in parts.enumerated() {
                    guard let routes = routes(fromAddress: String(part), port: nil), routes.count == 1,
                          var route = routes.first else { return nil }
                    route.priority = index
                    legacy.append(route)
                }
                guard !legacy.isEmpty, legacy.count <= CompanionEndpoint.maxRoutes else { return nil }
                typed = legacy
            } else {
                return nil
            }
            guard let first = typed.first else { return nil }
            return build(first: first, routes: typed, query: query)
        }
        guard let first = addressRoutes.first else { return nil }
        return build(first: first, routes: addressRoutes, query: query)
    }

    private static func build(first: CompanionEndpoint, routes: [CompanionEndpoint], query: [String: String]) -> PairingInvite? {
        var token: String?
        if let value = query["token"] {
            guard isValidToken(value) else { return nil }
            token = value
        }
        var code: String?
        if let value = query["code"] {
            guard isValidCode(value) else { return nil }
            code = value
        }
        guard token != nil || code != nil else { return nil }

        let hosts = (query["hosts"] ?? "").split(separator: ",").compactMap { raw -> String? in
            let host = raw.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, host.count <= 253, !host.contains(where: { " /?#".contains($0) }) else { return nil }
            return host
        }.prefix(CompanionEndpoint.maxRoutes)

        var secretKey: String?
        if let value = query["secretKey"] {
            guard isValidSecretKey(value) else { return nil }
            secretKey = value
        }

        let name = sanitizeName(query["name"]) ?? first.host
        var descriptor: E2EDescriptor?
        if let encoded = query["e2e"] {
            guard let value = try? E2EDescriptor(encoded: encoded) else { return nil }
            descriptor = value
        }
        var allRoutes = routes.isEmpty ? [first] : routes
        if descriptor != nil {
            let directPort = allRoutes.first { $0.kind != .hosted }?.port ?? 8810
            for host in hosts {
                if let route = CompanionEndpoint.direct(host: host, port: directPort, priority: allRoutes.count) {
                    allRoutes.append(route)
                }
            }
        }
        return PairingInvite(
            routes: CompanionEndpoint.ordered(allRoutes),
            token: token,
            code: code,
            serverName: name,
            hosts: Array(hosts),
            secretKey: secretKey,
            e2e: descriptor
        )
    }

    /// The manual path: an address typed by the person plus the six-digit code
    /// shown on the computer.
    static func manual(address rawAddress: String, code rawCode: String, name: String? = nil) -> Result<PairingInvite, PairingError> {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .failure(.invalidAddress) }
        guard isValidCode(code) else { return .failure(.invalidCode) }
        guard let routes = routes(fromAddress: address, port: nil), let first = routes.first else {
            return .failure(.invalidAddress)
        }
        let cleaned = sanitizeName(name) ?? first.host
        return .success(PairingInvite(routes: CompanionEndpoint.ordered(routes), token: nil, code: code, serverName: cleaned))
    }

    static func isValidToken(_ value: String) -> Bool {
        guard value.hasPrefix("omb_pair_") else { return false }
        let tail = value.dropFirst("omb_pair_".count)
        return tail.count == 43 && tail.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    static func isValidCode(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy(\.isNumber)
    }

    static func isValidSecretKey(_ value: String) -> Bool {
        guard value.count == 87,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return false }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let bytes = Data(base64Encoded: base64), bytes.count == 65, bytes.first == 0x04 else { return false }
        return true
    }

    private static func parseQuery(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") where !pair.isEmpty {
            let key = String(pair.prefix(while: { $0 != "=" }))
            let raw = pair.contains("=") ? String(pair.dropFirst(key.count + 1)) : ""
            let value = raw.removingPercentEncoding ?? raw
            if !key.isEmpty { result[key.removingPercentEncoding ?? key] = value }
        }
        return result
    }

    private static func sanitizeName(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func endpoint(fromOrigin raw: String) -> CompanionEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return CompanionEndpoint.make(url: trimmed, kind: CompanionEndpoint.kind(forOrigin: trimmed), priority: 0)
    }

    /// Direct addresses default to the companion ports the desktop advertises;
    /// both are probed because a hand-typed address carries no port.
    private static func routes(fromAddress raw: String, port queryPort: Int?) -> [CompanionEndpoint]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            return endpoint(fromOrigin: value).map { [$0] }
        }
        var host = value
        var port = queryPort
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"), value.distance(from: value.startIndex, to: close) > 1 else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = String(value[value.index(after: close)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let parsed = Int(rest.dropFirst()) else { return nil }
                port = parsed
            }
        } else if value.filter({ $0 == ":" }).count == 1 {
            host = String(value[..<value.lastIndex(of: ":")!])
            guard let parsed = Int(value[value.index(after: value.lastIndex(of: ":")!)...]) else { return nil }
            port = parsed
        }
        if let port {
            guard let route = CompanionEndpoint.direct(host: host, port: port, priority: 0) else { return nil }
            return [route]
        }
        let routes = [8787, 8810].enumerated().compactMap { index, candidate in
            CompanionEndpoint.direct(host: host, port: candidate, priority: index)
        }
        return routes.isEmpty ? nil : routes
    }
}

enum PairingError: LocalizedError, Equatable {
    case invalidAddress
    case invalidCode
    case noRoute([String])
    case rejected(String)
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return localized("电脑地址无效。填写 IP 或主机名，例如 192.168.1.8:8787。")
        case .invalidCode:
            return localized("配对码是电脑上显示的 6 位数字。")
        case .noRoute(let addresses):
            let list = addresses.joined(separator: AppLanguage.current == .english ? ", " : "、")
            return localized("连不上这台电脑，请确认它已唤醒并打开 OpenMausBot，且与这台 Mac 在同一个网络。尝试过：%@", list)
        case .rejected(let message):
            return message
        case .missingCredential:
            return localized("这个配对链接没有配对码，请重新在电脑上生成。")
        }
    }
}
