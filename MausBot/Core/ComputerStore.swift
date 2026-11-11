import Foundation

/// One paired computer: its routes, the consent recorded at pairing time, and
/// the stream cursor. The bearer token is not here; it lives in the Keychain.
struct SavedComputer: Codable, Identifiable, Equatable {
    var id: String
    var serverName: String
    var routes: [CompanionEndpoint]
    var activeURL: String?
    var hosts: [String]
    var allowedKinds: [EndpointKind]
    var allowedLocalURLs: [String]
    var lastCursor: String?
    var deviceId: String?
    var lastUsedAt: Date
    var pairedAt: Date
    var e2e: E2EDescriptor? = nil
    var localName: String? = nil

    var displayName: String {
        guard let localName, !localName.isEmpty else { return serverName }
        return localName
    }

    var activeEndpoint: CompanionEndpoint? {
        routes.first { $0.url == activeURL }
    }

    var baseURL: String {
        activeURL ?? routes.first?.url ?? ""
    }

    var displayAddress: String {
        activeEndpoint?.displayAddress ?? CompanionEndpoint.host(of: baseURL)
    }

    func allows(_ endpoint: CompanionEndpoint) -> Bool {
        // The transport key, rather than the network address, authenticates an
        // encrypted route. No HTTP request goes onto these carriers directly.
        if e2e != nil { return true }
        if endpoint.kind == .hosted { return true }
        guard allowedKinds.contains(endpoint.kind) else { return false }
        if endpoint.kind.isProtected { return true }
        return allowedLocalURLs.contains(endpoint.url)
    }

    /// Every stored route in dial order, restricted to the recorded consent.
    var orderedRoutes: [CompanionEndpoint] {
        var routes = CompanionEndpoint.ordered(self.routes.filter(allows))
        if let active = activeEndpoint, active.kind.isProtected {
            routes = [active] + routes.filter { $0.url != active.url }
        }
        if let active = activeEndpoint, allows(active), !routes.contains(where: { $0.url == active.url }) {
            routes.insert(active, at: 0)
        }
        return routes
    }

    /// The subset an automatic reconnect may walk.
    var automaticRoutes: [CompanionEndpoint] {
        if e2e != nil {
            let direct = orderedRoutes.filter { $0.kind != .hosted }
            if !direct.isEmpty { return direct }
            if e2e?.routes != "local", e2e?.r?.isEmpty == false { return Array(orderedRoutes.prefix(1)) }
            return []
        }
        return CompanionEndpoint.automaticCandidates(orderedRoutes)
    }

    func promoting(_ endpoint: CompanionEndpoint) -> SavedComputer {
        guard allows(endpoint) else { return self }
        var next = self
        next.activeURL = endpoint.url
        next.routes = CompanionEndpoint.ordered([endpoint] + routes)
        if endpoint.kind != .hosted {
            next.hosts = Array(([endpoint.host] + hosts).prefix(CompanionEndpoint.maxRoutes))
        }
        next.lastUsedAt = Date()
        return next
    }

    /// Apply an authenticated endpoint snapshot. It chooses what a future
    /// launch may dial; the live stream keeps whatever route it already has.
    func applying(_ metadata: ConnectionMetadata) -> SavedComputer {
        var next = self
        next.e2e = metadata.e2e ?? e2e
        if let name = metadata.serverName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            next.serverName = String(name.prefix(80))
        }
        let refreshed = CompanionEndpoint.ordered(metadata.endpoints.filter(next.allows))
        if !refreshed.isEmpty {
            next.routes = refreshed
        }
        if let active = activeURL, refreshed.contains(where: { $0.url == active }) == false,
           let protected = refreshed.first(where: { $0.kind.isProtected }) {
            next.activeURL = protected.url
        }
        if let active = next.activeEndpoint {
            next.activeURL = active.url
        } else {
            next.activeURL = next.routes.first?.url
        }
        return next
    }

    /// Bind a pairing to the address that actually answered, keeping the
    /// invite's other consented routes as fallbacks.
    static func from(pairResult result: PairResult, invite: PairingInvite, winner: CompanionEndpoint) -> SavedComputer {
        var kinds = Set<EndpointKind>([winner.kind, .hosted])
        var localURLs = Set<String>()
        if !winner.kind.isProtected {
            localURLs.insert(winner.url)
            for route in invite.routes where !route.kind.isProtected {
                localURLs.insert(route.url)
                kinds.insert(route.kind)
            }
        }
        var candidates = invite.routes + result.endpoints
        let port = winner.port
        for host in result.hosts {
            if let route = CompanionEndpoint.direct(host: host, port: port, priority: candidates.count) {
                candidates.append(route)
            }
        }
        var seen = Set<String>()
        let allowed = candidates.filter { route in
            guard seen.insert(route.url).inserted else { return false }
            if result.e2e != nil || invite.e2e != nil { return true }
            if route.kind == .hosted { return true }
            guard kinds.contains(route.kind) else { return false }
            return route.kind.isProtected || localURLs.contains(route.url)
        }
        let routes = CompanionEndpoint.ordered(allowed)
        return SavedComputer(
            id: result.deviceId,
            serverName: result.serverName,
            routes: routes,
            activeURL: winner.url,
            hosts: Array(result.hosts.prefix(CompanionEndpoint.maxRoutes)),
            allowedKinds: Array(kinds),
            allowedLocalURLs: Array(localURLs),
            lastCursor: nil,
            deviceId: result.deviceId,
            lastUsedAt: Date(),
            pairedAt: Date(),
            e2e: result.e2e ?? invite.e2e
        )
    }
}

@MainActor
final class ComputerStore {
    static let shared = ComputerStore()

    private(set) var computers: [SavedComputer] = []
    var selectedId: String? {
        didSet { UserDefaults.standard.set(selectedId, forKey: "selectedComputerId") }
    }

    private let fileURL: URL

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("MausBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("computers.json")
        selectedId = UserDefaults.standard.string(forKey: "selectedComputerId")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([SavedComputer].self, from: data) {
            computers = saved
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(computers)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func upsert(_ computer: SavedComputer) -> SavedComputer {
        var computer = computer
        if let index = computers.firstIndex(where: { $0.id == computer.id }) {
            computer.localName = computers[index].localName
            computers[index] = computer
        } else {
            computers.append(computer)
        }
        try? save()
        return computer
    }

    func rename(_ id: String, localName: String) throws {
        guard let index = computers.firstIndex(where: { $0.id == id }) else { return }
        let previous = computers[index]
        let name = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        computers[index].localName = name.isEmpty ? nil : name
        do {
            try save()
        } catch {
            computers[index] = previous
            throw error
        }
    }

    func remove(_ id: String) {
        computers.removeAll { $0.id == id }
        Keychain.removeToken(for: id)
        if selectedId == id { selectedId = computers.first?.id }
        try? save()
    }

    func token(for id: String) -> String? {
        Keychain.token(for: id)
    }

    @discardableResult
    func setToken(_ token: String, for id: String) -> Bool {
        Keychain.setToken(token, for: id)
    }
}
