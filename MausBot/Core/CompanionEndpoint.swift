import Foundation

/// Why an address exists. The kind is policy metadata; the URL stays the
/// complete dialing authority, so hosted HTTPS and local HTTP can share one
/// fallback list without guessing a scheme from a hostname.
enum EndpointKind: String, Codable, CaseIterable, Sendable {
    case hosted
    case tailnet
    case lan
    case bonjour

    /// A route whose transport hides the bearer token from the local network.
    var isProtected: Bool { self == .hosted || self == .tailnet }
}

struct CompanionEndpoint: Codable, Hashable, Identifiable, Sendable {
    var url: String
    var kind: EndpointKind
    var priority: Int

    var id: String { url }
    var isSecure: Bool { url.hasPrefix("https://") }

    var host: String { CompanionEndpoint.host(of: url) }

    var port: Int {
        guard let components = URLComponents(string: url) else { return 0 }
        return components.port ?? CompanionEndpoint.defaultPort(components.scheme ?? "")
    }

    /// Host and port for direct routes, the full origin for hosted ones. Only
    /// used in status copy, never for dialing.
    var displayAddress: String {
        if kind == .hosted || isSecure { return url }
        return "\(host):\(port)"
    }

    func toJSON() -> JSON {
        ["url": url, "kind": kind.rawValue, "priority": priority]
    }

    static func from(_ json: JSON) -> CompanionEndpoint? {
        guard let url = json.nonEmpty("url"),
              let kind = EndpointKind(rawValue: json.str("kind") ?? ""),
              let priority = json.int("priority") else { return nil }
        return make(url: url, kind: kind, priority: priority)
    }

    static let maxRoutes = 8

    /// Canonicalize one route. Hosted routes need HTTPS; tailnet routes an
    /// HTTP `.ts.net` name; direct routes plain HTTP. A public URL carrying
    /// credentials, a path, a query or a fragment is never a companion origin.
    static func make(url raw: String, kind: EndpointKind, priority: Int) -> CompanionEndpoint? {
        guard (0...1_000_000).contains(priority) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              (components.path.isEmpty || components.path == "/"),
              let host = components.host.map(canonicalHost),
              isValid(host: host)
        else { return nil }
        switch kind {
        case .hosted:
            guard scheme == "https" else { return nil }
        case .tailnet:
            guard scheme == "http", isTailnet(host: host) else { return nil }
        case .lan, .bonjour:
            guard scheme == "http" else { return nil }
        }
        let port = components.port ?? defaultPort(scheme)
        guard (1...65_535).contains(port) else { return nil }
        return CompanionEndpoint(url: buildURL(scheme: scheme, host: host, port: port), kind: kind, priority: priority)
    }

    static func direct(host rawHost: String, port: Int, kind: EndpointKind? = nil, priority: Int) -> CompanionEndpoint? {
        let host = canonicalHost(rawHost)
        guard !host.isEmpty, (1...65_535).contains(port) else { return nil }
        let resolved = kind ?? inferredDirectKind(host: host)
        return make(url: buildURL(scheme: "http", host: host, port: port), kind: resolved, priority: priority)
    }

    static func inferredDirectKind(host: String) -> EndpointKind {
        let canonical = canonicalHost(host)
        if isTailnet(host: canonical) { return .tailnet }
        if canonical.hasSuffix(".local") { return .bonjour }
        return .lan
    }

    static func kind(forOrigin url: String) -> EndpointKind {
        if URLComponents(string: url)?.scheme?.lowercased() == "https" { return .hosted }
        return inferredDirectKind(host: host(of: url))
    }

    /// Unpadded base64url JSON typed array from a QR link. A present but
    /// invalid value rejects the whole invite instead of quietly downgrading a
    /// hosted HTTPS QR to its cleartext address.
    static func decodeList(_ encoded: String) -> [CompanionEndpoint]? {
        guard !encoded.isEmpty, encoded.utf8.count <= 8192,
              encoded.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        let parsed = raw.compactMap { item -> CompanionEndpoint? in
            guard let object = item as? JSON else { return nil }
            return from(object)
        }
        guard !parsed.isEmpty, parsed.count <= maxRoutes, parsed.count == raw.count else { return nil }
        var seen = Set<String>()
        return parsed.sorted { $0.priority < $1.priority }.filter { seen.insert($0.url).inserted }
    }

    /// Routes an automatic reconnect may try, in advertised order. When the
    /// preferred route is protected, every cleartext fallback is dropped; when
    /// it is local, that exact route is the person's choice and only routes
    /// that strengthen the transport may follow.
    static func automaticCandidates(_ routes: [CompanionEndpoint]) -> [CompanionEndpoint] {
        guard let preferred = routes.first else { return [] }
        var seen = Set<String>()
        return routes.filter { route in
            guard seen.insert(route.url).inserted else { return false }
            if preferred.kind.isProtected { return route.kind.isProtected }
            return route.url == preferred.url || route.kind.isProtected
        }
    }

    /// Sort by priority, keeping the caller's order for equal priorities.
    static func ordered(_ routes: [CompanionEndpoint]) -> [CompanionEndpoint] {
        var seen = Set<String>()
        return routes.enumerated()
            .sorted { lhs, rhs in
                lhs.element.priority == rhs.element.priority
                    ? lhs.offset < rhs.offset
                    : lhs.element.priority < rhs.element.priority
            }
            .map(\.element)
            .filter { seen.insert($0.url).inserted }
            .prefix(maxRoutes)
            .map { $0 }
    }

    static func host(of url: String) -> String {
        guard let host = URLComponents(string: url)?.host else { return "" }
        return canonicalHost(host)
    }

    static func canonicalHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        return host
    }

    static func isValid(host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(":") {
            return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }
        }
        guard !host.contains(where: { $0.isWhitespace || "/?#[]@".contains($0) }) else { return false }
        return host.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private static func isTailnet(host: String) -> Bool {
        host.count > ".ts.net".count && host.hasSuffix(".ts.net")
    }

    private static func defaultPort(_ scheme: String) -> Int {
        scheme.lowercased() == "https" ? 443 : 80
    }

    private static func buildURL(scheme: String, host: String, port: Int) -> String {
        let authority = host.contains(":") ? "[\(host)]" : host
        let suffix = port == defaultPort(scheme) ? "" : ":\(port)"
        return "\(scheme)://\(authority)\(suffix)"
    }
}
