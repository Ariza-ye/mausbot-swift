import Foundation
import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct RouteProbe: Identifiable, Equatable {
    enum State: Equatable { case waiting, connecting, ok, failed }
    var url: String
    var address: String
    var state: State = .waiting
    var id: String { url }
}

struct PairingProgress: Equatable {
    var running = false
    var step = ""
    var routes: [RouteProbe] = []
    static let idle = PairingProgress()
}

/// One process-wide state holder: a single event stream folds into it, the way
/// the desktop app folds its own stream into one store.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var computers: [SavedComputer] = []
    @Published private(set) var computer: SavedComputer?
    @Published private(set) var connection = ConnectionState()
    @Published private(set) var bots: [Bot] = []
    @Published private(set) var groups: [ChatGroup] = []
    @Published private(set) var instances: [ProviderInstance] = []
    @Published private(set) var open: OpenChat?
    @Published private(set) var threads: [String: ThreadState] = [:]
    @Published private(set) var searchHits: [SearchHit] = []
    @Published private(set) var searching = false
    @Published var lastError: String?
    @Published var pairing = PairingProgress.idle
    @Published var pendingInvite: PairingInvite?
    @Published var showPairingSheet = false
    @Published var showNewBotSheet = false
    @Published var settingsBotId: String?
    @Published private var botEmojis: [String: [String: String]] = [:] {
        didSet { UserDefaults.standard.set(botEmojis, forKey: Keys.botEmojis) }
    }
    @Published var notificationBanners: Bool {
        didSet { UserDefaults.standard.set(notificationBanners, forKey: Keys.notifications) }
    }
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    private enum Keys {
        static let notifications = "notificationBanners"
        static let appearance = "appearance"
        static let botEmojis = "botEmojis"
    }

    private let store = ComputerStore.shared
    private var client: ApiClient?
    private var connectionTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastCursorWrite = Date.distantPast
    private var lastReadWrite: [String: Date] = [:]
    private var generation = 0
    private var serverOrder: [String] = []

    private init() {
        let storage = ComputerStore.shared
        let saved = storage.computers
        let chosen = saved.first { $0.id == storage.selectedId } ?? saved.first
        computers = saved
        computer = chosen
        var initial = ConnectionState()
        initial.serverName = chosen?.serverName ?? ""
        connection = initial
        notificationBanners = UserDefaults.standard.object(forKey: Keys.notifications) as? Bool ?? true
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
        botEmojis = UserDefaults.standard.dictionary(forKey: Keys.botEmojis) as? [String: [String: String]] ?? [:]
    }

    func emoji(for botId: String) -> String? {
        guard let computer else { return nil }
        return botEmojis[computer.id]?[botId]
    }

    func setEmoji(_ emoji: String?, for botId: String) {
        guard let computer else { return }
        if let emoji, !Self.isValidEmoji(emoji) { return }
        var icons = botEmojis[computer.id] ?? [:]
        icons[botId] = emoji
        botEmojis[computer.id] = icons.isEmpty ? nil : icons
    }

    static func isValidEmoji(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.contains {
            $0.properties.isEmoji && ($0.value > 0x7F || value.unicodeScalars.contains { $0.value == 0x20E3 })
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard computer != nil, connection.phase == .idle, connectionTask == nil else { return }
        connect()
    }

    // MARK: - Pairing

    func pair(with invite: PairingInvite) async throws -> SavedComputer {
        guard let credential = invite.credential else {
            throw PairingError.missingCredential
        }
        let routes: [CompanionEndpoint]
        if invite.e2e != nil {
            routes = invite.routes.filter { $0.kind != .hosted } + invite.routes.filter { $0.kind == .hosted }
        } else {
            routes = invite.routes.first?.kind.isProtected == true
                ? CompanionEndpoint.automaticCandidates(invite.routes) : invite.routes
        }
        guard !routes.isEmpty else { throw PairingError.invalidAddress }
        pairing = PairingProgress(
            running: true,
            step: "正在探测 \(invite.serverName)…",
            routes: routes.map { RouteProbe(url: $0.url, address: $0.displayAddress) }
        )
        let pairRequestId = UUID().uuidString
        var attempted: [String] = []

        for (index, route) in routes.enumerated() {
            if Task.isCancelled { break }
            setProbe(index, .connecting)
            let probe = invite.e2e == nil
                ? await ApiClient(baseURL: route.url, token: nil).probeHealth()
                : (ok: true, name: Optional<String>.none)
            guard probe.ok else {
                setProbe(index, .failed)
                attempted.append(route.displayAddress)
                continue
            }
            setProbe(index, .ok)
            do {
                let result = try await ApiClient(baseURL: route.url, token: nil, e2e: invite.e2e, handshakeCredential: credential)
                    .pair(credential: credential, serverNameHint: invite.serverName, pairRequestId: pairRequestId, timeout: 12)
                var saved = SavedComputer.from(pairResult: result, invite: invite, winner: route)
                if saved.serverName.isEmpty { saved.serverName = invite.serverName }
                guard store.setToken(result.token, for: saved.id) else {
                    throw APIError(status: 500, message: "设备令牌无法保存到钥匙串，配对尚未完成。", body: nil)
                }
                saved = store.upsert(saved)
                store.selectedId = saved.id
                computers = store.computers
                pairing = .idle
                computer = saved
                connect()
                return saved
            } catch let error as APIError where error.status != 0 && !error.isRouteFailure {
                setProbe(index, .failed)
                pairing = .idle
                throw PairingError.rejected(error.message)
            } catch E2EError.verification {
                pairing = .idle
                throw E2EError.verification
            } catch {
                setProbe(index, .failed)
                attempted.append(route.displayAddress)
            }
        }
        pairing = .idle
        throw PairingError.noRoute(attempted.isEmpty ? routes.map(\.displayAddress) : attempted)
    }

    func pair(link: String) async throws -> SavedComputer {
        guard let invite = PairingInvite.parse(link) else {
            throw PairingError.rejected("链接格式不对。请粘贴电脑上生成的 openmausbot:// 配对链接。")
        }
        return try await pair(with: invite)
    }

    private func setProbe(_ index: Int, _ state: RouteProbe.State) {
        guard pairing.routes.indices.contains(index) else { return }
        pairing.routes[index].state = state
    }

    // MARK: - Computers

    func select(_ id: String) {
        guard let target = computers.first(where: { $0.id == id }) else { return }
        disconnect()
        store.selectedId = id
        computer = target
        connect()
    }

    func forget(_ id: String) {
        if computer?.id == id { disconnect() }
        store.remove(id)
        computers = store.computers
        if computer?.id == id {
            computer = computers.first { $0.id == store.selectedId } ?? computers.first
        }
    }

    func renameComputer(_ id: String, localName: String) throws {
        try store.rename(id, localName: localName)
        computers = store.computers
        if computer?.id == id {
            computer?.localName = computers.first { $0.id == id }?.localName
        }
    }

    var tokenPresent: Bool {
        guard let id = computer?.id else { return false }
        return store.token(for: id) != nil
    }

    // MARK: - Connection

    func connect() {
        guard let target = computer ?? computers.first else {
            connection = ConnectionState()
            return
        }
        connectionTask?.cancel()
        E2EConnection.closeAll()
        searchTask?.cancel()
        generation += 1
        let token = generation
        computer = target
        client = nil
        bots = []
        groups = []
        threads = [:]
        instances = []
        searchHits = []
        searching = false
        lastReadWrite = [:]
        lastCursorWrite = .distantPast
        open = nil
        ImageCache.shared.clear()
        connection = ConnectionState(phase: .connecting, detail: "正在连接 \(target.serverName)…", serverName: target.serverName)
        lastError = nil
        connectionTask = Task { [weak self] in
            await self?.runConnection(target, token)
        }
    }

    func disconnect() {
        if let current = computer, current.lastCursor != nil {
            store.upsert(current)
        }
        generation += 1
        connectionTask?.cancel()
        E2EConnection.closeAll()
        connectionTask = nil
        client = nil
        searchTask?.cancel()
        instances = []
        searchHits = []
        ImageCache.shared.clear()
        connection = ConnectionState(phase: .idle, serverName: computer?.serverName ?? "")
        bots = []
        groups = []
        threads = [:]
        open = nil
    }

    private func runConnection(_ target: SavedComputer, _ token: Int) async {
        guard let deviceToken = store.token(for: target.id) else {
            connection = ConnectionState(phase: .unauthorized, detail: "这台电脑的凭证已丢失，请重新配对。", serverName: target.serverName)
            return
        }
        var routes = target.automaticRoutes
        guard !routes.isEmpty else {
            connection = ConnectionState(phase: .error, detail: "这台电脑没有可用的地址。", serverName: target.serverName)
            return
        }
        var routeIndex = 0
        var current = target
        var attempt = 0

        while token == generation, !Task.isCancelled {
            let route = routes[min(routeIndex, routes.count - 1)]
            connection = ConnectionState(
                phase: attempt == 0 ? .connecting : .offline,
                detail: "正在连接 \(route.displayAddress)…",
                serverName: current.serverName
            )
            do {
                var api = ApiClient(baseURL: route.url, token: deviceToken, e2e: current.e2e)
                // Upgrade legacy saved pairings over their already trusted route
                // before fetching bots. Once pinned, all requests are encrypted.
                if current.e2e == nil {
                    do {
                        let metadata = try await api.connectionMetadata()
                        guard token == generation, !Task.isCancelled else { return }
                        if metadata.e2e != nil {
                            current = persist(current.applying(metadata))
                            api = ApiClient(baseURL: route.url, token: deviceToken, e2e: current.e2e)
                        }
                    } catch let error as APIError where error.status == 404 {
                        // Older companions don't expose endpoint metadata.
                    }
                }
                let health = try await api.health()
                guard token == generation, !Task.isCancelled else { return }
                let app = health.str("app") ?? ""
                guard app == "openmausbot" || app == "mausbot" else {
                    throw APIError(status: 400, message: "这个地址不是 OpenMausBot。", body: nil)
                }
                client = api
                connection = ConnectionState(
                    phase: .connecting,
                    detail: health.nonEmpty("name") ?? current.serverName,
                    serverName: current.serverName
                )
                try await refreshAll(api)
                guard token == generation, !Task.isCancelled else { return }
                current = persist(current.promoting(route))
                if route.kind.isProtected {
                    routes = routes.filter { $0.kind.isProtected }
                    routeIndex = routes.firstIndex { $0.url == route.url } ?? 0
                }
                do {
                    let metadata = try await api.connectionMetadata()
                    guard token == generation, !Task.isCancelled else { return }
                    current = persist(current.applying(metadata))
                    let refreshed = current.automaticRoutes
                    if !refreshed.isEmpty {
                        routes = route.kind.isProtected ? refreshed.filter { $0.kind.isProtected } : refreshed
                        routeIndex = routes.firstIndex { $0.url == route.url } ?? 0
                    }
                } catch let error as E2EError {
                    throw error
                } catch {
                    // Metadata is optional for older servers.
                }
                try await streamLoop(api, token, serverName: current.serverName)
            } catch is CancellationError {
                return
            } catch {
                if token != generation { return }
                if let error = error as? E2EError {
                    switch error {
                    case .verification, .invalidDescriptor, .updateRequired, .removed:
                        connection = ConnectionState(phase: .error, detail: error.localizedDescription, serverName: current.serverName)
                        return
                    default: break
                    }
                }
                if let apiError = error as? APIError {
                    if apiError.isUnauthorized {
                        connection = ConnectionState(phase: .unauthorized, detail: apiError.message, serverName: current.serverName)
                        return
                    }
                    if !apiError.isRouteFailure, apiError.status != 0 {
                        connection = ConnectionState(phase: .error, detail: apiError.message, serverName: current.serverName)
                        return
                    }
                }
                attempt += 1
                connection = ConnectionState(
                    phase: .offline,
                    detail: "连不上 \(route.displayAddress)，正在重试…",
                    serverName: current.serverName
                )
                if routes.count > 1 { routeIndex = (routeIndex + 1) % routes.count }
                await sleep(backoff(attempt))
            }
        }
    }

    private func streamLoop(_ api: ApiClient, _ token: Int, serverName: String) async throws {
        var everConnected = false
        var attempt = 0
        while token == generation, !Task.isCancelled {
            var opened = false
            var failure: Error?
            do {
                for try await frame in api.eventStream(lastEventId: computer?.lastCursor) {
                    if Task.isCancelled || token != generation { return }
                    if frame.json.str("kind") == "hello" {
                        opened = true
                        everConnected = true
                        attempt = 0
                        connection = ConnectionState(phase: .online, detail: "", serverName: serverName)
                        if !frame.json.bool("resumed") {
                            Task { [weak self] in await self?.refreshAfterGap() }
                        }
                    }
                    if let id = frame.id { saveCursor(id) }
                    handle(frame.json)
                }
            } catch {
                failure = error
            }
            if !opened, !everConnected {
                throw failure ?? MissingStreamHello()
            }
            if let error = failure as? E2EError {
                switch error {
                case .verification, .removed, .invalidDescriptor, .updateRequired: throw error
                default: break
                }
            }
            if let error = failure as? APIError, error.isUnauthorized { throw error }
            if token != generation { return }
            attempt += 1
            connection = ConnectionState(phase: .offline, detail: "连接断开，正在重连…", serverName: serverName)
            await sleep(backoff(attempt))
        }
    }

    private func backoff(_ attempt: Int) -> UInt64 {
        let base = min(15.0, 1.0 + Double(attempt))
        let jitter = Double.random(in: 0...1)
        return UInt64((base + jitter) * 1_000_000_000)
    }

    private func sleep(_ nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func persist(_ next: SavedComputer) -> SavedComputer {
        guard next != computer else { return next }
        let next = store.upsert(next)
        computers = store.computers
        computer = next
        return next
    }

    private func saveCursor(_ id: String) {
        guard var current = computer else { return }
        current.lastCursor = id
        computer = current
        // A busy stream sends many frames; the cursor only needs to survive a
        // restart, not every frame.
        guard Date().timeIntervalSince(lastCursorWrite) > 3 else { return }
        lastCursorWrite = Date()
        store.upsert(current)
    }

    private func refreshAfterGap() async {
        let expected = generation
        guard let client else { return }
        try? await refreshAll(client)
        guard expected == generation, !Task.isCancelled else { return }
        if let threadId = open?.threadId {
            await loadThread(threadId, force: true)
        }
    }

    // MARK: - Reads

    func refreshAll() async throws {
        guard let client else { return }
        try await refreshAll(client)
    }

    private func refreshAll(_ api: ApiClient) async throws {
        let expectedGeneration = generation
        let answer = try await api.botsAndGroups()
        guard expectedGeneration == generation, !Task.isCancelled else { throw CancellationError() }
        let botJSON = answer.objArray("bots")
        let groupJSON = answer.objArray("groups")
        let parsedBots = botJSON.compactMap(Bot.init(json:))
        let parsedGroups = groupJSON.compactMap(ChatGroup.init(json:))
        if parsedBots.isEmpty, parsedGroups.isEmpty, let message = answer.nonEmpty("error") {
            throw APIError(status: 200, message: message, body: nil)
        }
        bots = parsedBots
        groups = parsedGroups
        applyOrder()
        seed(botJSON: botJSON, groupJSON: groupJSON)
        if instances.isEmpty { await loadInstances() }
        if open == nil {
            openFirstConversation()
        }
    }

    private func applyOrder() {
        func rank(_ bot: Bot) -> Int {
            serverOrder.firstIndex(of: bot.id) ?? Int.max
        }
        bots.sort { lhs, rhs in
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `/api/bots` already carries the newest page for each bot's selected
    /// thread; use it so a launch shows words before the first fetch lands.
    private func seed(botJSON: [JSON], groupJSON: [JSON]) {
        for raw in botJSON {
            guard let threadId = raw.nonEmpty("threadId"), raw.array("messages") != nil else { continue }
            if threads[threadId]?.messages.isEmpty ?? true {
                var state = threads[threadId] ?? ThreadState()
                state.messages = raw.objArray("messages").compactMap { Message(json: $0) }.sorted { $0.createdAt < $1.createdAt }
                state.hasMore = raw.bool("hasMore", false)
                threads[threadId] = state
            }
        }
        for raw in groupJSON {
            guard let threadId = raw.nonEmpty("threadId"), raw.array("messages") != nil else { continue }
            if threads[threadId]?.messages.isEmpty ?? true {
                var state = threads[threadId] ?? ThreadState()
                state.messages = raw.objArray("messages").compactMap { Message(json: $0) }.sorted { $0.createdAt < $1.createdAt }
                state.hasMore = raw.bool("hasMore", false)
                threads[threadId] = state
            }
        }
    }

    func loadInstances() async {
        guard let client else { return }
        let expectedGeneration = generation
        guard let answer = try? await client.instances() else { return }
        guard generation == expectedGeneration, !Task.isCancelled else { return }
        instances = answer.objArray("instances").compactMap(ProviderInstance.init(json:))
    }

    func openFirstConversation() {
        if let bot = bots.first(where: { !$0.hidden }) {
            open = OpenChat(target: .bot(bot.id), threadId: bot.threadId, title: firstLine(of: bot.activeTask?.title) ?? bot.name)
        } else if let group = groups.first {
            open = OpenChat(target: .group(group.id), threadId: group.threadId, title: group.name)
        }
    }

    func open(bot: Bot, threadId: String? = nil, title: String? = nil) {
        let thread = threadId ?? bot.threadId
        var chat = OpenChat(target: .bot(bot.id), threadId: thread, title: bot.name)
        if let task = bot.task(threadId: thread), !task.title.isEmpty {
            chat.title = task.title
        }
        if let title { chat.title = title }
        openChat(chat)
    }

    func open(group: ChatGroup) {
        openChat(OpenChat(target: .group(group.id), threadId: group.threadId, title: group.name))
    }

    func openChat(_ chat: OpenChat) {
        open = chat
        Task { [weak self] in
            await self?.loadThread(chat.threadId, force: false)
            self?.markRead(chat.threadId)
        }
    }

    func openByThreadId(_ threadId: String) {
        if let bot = bots.first(where: { $0.tasks.contains { $0.threadId == threadId } || $0.threadId == threadId }) {
            open(bot: bot, threadId: threadId)
            return
        }
        if let group = groups.first(where: { $0.threadId == threadId }) {
            open(group: group)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            try? await self.refreshAll()
            if let bot = self.bots.first(where: { $0.tasks.contains { $0.threadId == threadId } || $0.threadId == threadId }) {
                self.open(bot: bot, threadId: threadId)
            } else if let group = self.groups.first(where: { $0.threadId == threadId }) {
                self.open(group: group)
            } else {
                self.lastError = "找不到这个会话。"
            }
        }
    }

    func messages(_ threadId: String) -> [Message] {
        threads[threadId]?.messages ?? []
    }

    @discardableResult
    func loadThread(_ threadId: String, force: Bool = false) async -> [Message] {
        guard !threadId.isEmpty, let client else { return [] }
        let expectedGeneration = generation
        if !force, !(threads[threadId]?.messages.isEmpty ?? true) { return messages(threadId) }
        guard threads[threadId]?.loading != true else { return messages(threadId) }
        threads[threadId, default: ThreadState()].loading = true
        defer { if generation == expectedGeneration { threads[threadId]?.loading = false } }
        do {
            let answer = try await client.threadMessages(threadId: threadId, limit: 50)
            guard generation == expectedGeneration else { return [] }
            let page = answer.objArray("messages").compactMap { Message(json: $0) }
            var state = threads[threadId] ?? ThreadState()
            let optimistic = state.messages.filter(\.pending)
            var merged = page
            for message in optimistic where !merged.contains(where: { $0.id == message.id || ($0.clientId != nil && $0.clientId == message.clientId) }) {
                merged.append(message)
            }
            state.messages = merged.sorted { $0.createdAt < $1.createdAt }
            state.hasMore = answer.bool("hasMore", false)
            state.activeLeafId = answer.nonEmpty("activeLeafId")
            threads[threadId] = state
            return state.messages
        } catch let error as APIError {
            lastError = error.message
            return messages(threadId)
        } catch {
            lastError = error.localizedDescription
            return messages(threadId)
        }
    }

    func loadOlder(_ threadId: String) async {
        guard let client, threads[threadId]?.loading != true else { return }
        let expectedGeneration = generation
        let current = messages(threadId)
        guard let oldest = current.first(where: { !$0.pending })?.id else { return }
        threads[threadId, default: ThreadState()].loading = true
        defer { if generation == expectedGeneration { threads[threadId]?.loading = false } }
        do {
            let answer = try await client.threadMessages(threadId: threadId, limit: 50, before: oldest)
            guard generation == expectedGeneration else { return }
            let page = answer.objArray("messages").compactMap { Message(json: $0) }
            var state = threads[threadId] ?? ThreadState()
            var seen = Set(state.messages.map(\.id))
            let older = page.filter { seen.insert($0.id).inserted }
            state.messages = (older + state.messages).sorted { $0.createdAt < $1.createdAt }
            state.hasMore = !page.isEmpty && answer.bool("hasMore", false)
            threads[threadId] = state
        } catch let error as APIError {
            lastError = error.message
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Search

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else {
            searchHits = []
            searching = false
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            do {
                let answer = try await client.search(trimmed)
                guard !Task.isCancelled else { return }
                self?.searchHits = answer.objArray("hits").compactMap(SearchHit.init(json:))
                self?.searching = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchHits = []
                self?.searching = false
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchHits = []
        searching = false
    }
}

// MARK: - Stream frames

extension AppStore {
    func handle(_ frame: JSON) {
        switch frame.str("kind") {
        case "hello":
            break
        case "bot":
            guard let json = frame.obj("bot"), let bot = Bot(json: json) else { return }
            upsert(bot)
        case "bots.order":
            guard frame.array("botIds") != nil else { return }
            serverOrder = frame.strArray("botIds")
            applyOrder()
        case "group":
            guard let json = frame.obj("group"), let group = ChatGroup(json: json) else { return }
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index] = group
            } else {
                groups.append(group)
            }
        case "group.deleted":
            if let id = frame.nonEmpty("groupId") {
                groups.removeAll { $0.id == id }
            }
        case "message":
            guard let threadId = frame.nonEmpty("threadId"),
                  let json = frame.obj("message"),
                  let message = Message(json: json) else { return }
            append(threadId: threadId, message: message)
            notifyIfNeeded(message, threadId: threadId)
        case "message.patch":
            guard let threadId = frame.nonEmpty("threadId"),
                  let json = frame.obj("message"),
                  let message = Message(json: json) else { return }
            patch(threadId: threadId, message: message, raw: json)
        case "thread":
            if let threadId = frame.nonEmpty("threadId"), threadId == open?.threadId {
                markRead(threadId)
            }
        case "notify":
            guard let payload = frame.obj("notification") else { return }
            Notifier.shared.post(
                title: payload.nonEmpty("title") ?? "OpenMausBot",
                body: payload.nonEmpty("body") ?? payload.nonEmpty("text") ?? "",
                threadId: payload.nonEmpty("threadId"),
                id: payload.nonEmpty("id")
            )
        case "companion.endpoints":
            guard let current = computer else { return }
            do {
                let advertised = try frame.obj("e2e").map { try E2EDescriptor(json: $0) }
                let pinned = try current.e2e?.accepting(advertised) ?? advertised
                let routes = frame.objArray("endpoints").compactMap(CompanionEndpoint.from)
                let metadata = ConnectionMetadata(serverName: frame.str("serverName"), hosts: frame.strArray("hosts"), endpoints: routes, e2e: pinned)
                let updated = current.applying(metadata)
                if updated != current {
                    _ = persist(updated)
                    connect()
                }
            } catch {
                disconnect()
                connection = ConnectionState(phase: .error, detail: error.localizedDescription, serverName: current.serverName)
            }
        default:
            break
        }
    }

    private func upsert(_ bot: Bot) {
        if let index = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[index] = bot
        } else {
            bots.append(bot)
        }
        applyOrder()
    }

    private func append(threadId: String, message: Message) {
        var state = threads[threadId] ?? ThreadState()
        if message.isUser {
            // Replace the local bubble this echo belongs to.
            if let index = state.messages.firstIndex(where: { local in
                local.id.hasPrefix("pending-") && (
                    message.clientId != nil ? local.clientId == message.clientId : local.text == message.text
                )
            }) {
                state.messages.remove(at: index)
            }
        }
        if let index = state.messages.firstIndex(where: { existing in
            existing.id == message.id
                || (message.clientId != nil && existing.clientId == message.clientId && existing.isUser)
        }) {
            state.messages[index] = message
        } else {
            state.messages.append(message)
        }
        state.messages.sort { $0.createdAt < $1.createdAt }
        threads[threadId] = state
        if threadId == open?.threadId, !message.isUser {
            markReadLocally(threadId, messageId: message.id)
        }
    }

    private func patch(threadId: String, message: Message, raw: JSON) {
        var state = threads[threadId] ?? ThreadState()
        if let index = state.messages.firstIndex(where: { $0.id == message.id }) {
            var next = state.messages[index]
            if raw["text"] != nil { next.text = message.text }
            if raw["card"] != nil { next.card = message.card }
            if raw["tool"] != nil { next.tool = message.tool }
            if raw["attachments"] != nil { next.attachments = message.attachments }
            if raw["role"] != nil { next.role = message.role }
            if raw["kind"] != nil { next.kind = message.kind }
            if raw["createdAt"] != nil { next.createdAt = message.createdAt }
            next.pending = false
            state.messages[index] = next
        } else {
            state.messages.append(message)
            state.messages.sort { $0.createdAt < $1.createdAt }
        }
        threads[threadId] = state
    }

    private func notifyIfNeeded(_ message: Message, threadId: String) {
        guard notificationBanners, message.isBot, message.kind == "text", !message.isDigest else { return }
        if open?.threadId == threadId, NSApp?.isActive == true { return }
        guard let bot = bots.first(where: { $0.threadId == threadId || $0.tasks.contains { $0.threadId == threadId } }) else { return }
        guard bot.notifications else { return }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Notifier.shared.post(title: bot.name, body: String(text.prefix(220)), threadId: threadId, id: message.id)
    }
}

// MARK: - Actions

extension AppStore {
    func send(text: String, attachments: [Attachment] = []) {
        guard let chat = open else { return }
        guard let client else {
            lastError = "还没有连上电脑，消息没有发送。"
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let optimisticId = "pending-" + UUID().uuidString
        let optimistic = Message(
            id: optimisticId,
            role: "user",
            text: trimmed,
            createdAt: Date(),
            attachments: attachments,
            clientId: optimisticId,
            pending: true
        )
        var state = threads[chat.threadId] ?? ThreadState()
        state.messages.append(optimistic)
        threads[chat.threadId] = state

        Task { [weak self] in
            guard let self else { return }
            do {
                var body: JSON = ["threadId": chat.threadId, "text": trimmed, "clientId": optimisticId]
                if !attachments.isEmpty { body["attachments"] = attachments.map(\.json) }
                switch chat.target {
                case .bot(let botId):
                    _ = try await client.post("/api/bots/\(botId)/messages", body: body)
                case .group(let groupId):
                    _ = try await client.post("/api/groups/\(groupId)/messages", body: ["threadId": chat.threadId, "text": trimmed, "clientId": optimisticId])
                }
                self.markSent(optimisticId, threadId: chat.threadId)
            } catch let error as APIError {
                self.markFailed(optimisticId, threadId: chat.threadId, error: error.message)
            } catch {
                self.markFailed(optimisticId, threadId: chat.threadId, error: error.localizedDescription)
            }
        }
    }

    private func markSent(_ id: String, threadId: String) {
        guard var state = threads[threadId], let index = state.messages.firstIndex(where: { $0.id == id }) else { return }
        state.messages[index].pending = false
        threads[threadId] = state
    }

    private func markFailed(_ id: String, threadId: String, error message: String) {
        guard var state = threads[threadId], let index = state.messages.firstIndex(where: { $0.id == id }) else { return }
        state.messages[index].pending = false
        state.messages[index].failed = true
        threads[threadId] = state
        lastError = message
    }

    func interrupt() {
        guard let chat = open else { return }
        guard let client else {
            lastError = "还没有连上电脑，停止请求没有发送。"
            return
        }
        Task { [weak self] in
            do {
                switch chat.target {
                case .bot(let botId):
                    _ = try await client.post("/api/bots/\(botId)/interrupt", body: ["threadId": chat.threadId])
                case .group(let groupId):
                    _ = try await client.post("/api/groups/\(groupId)/interrupt", body: ["threadId": chat.threadId])
                }
            } catch let error as APIError {
                self?.lastError = error.message
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// The harness takes one verdict per pending request, addressed by thread,
    /// so a room and a bot chat answer through the same door.
    func respond(threadId: String, card: Card, answer: String) {
        guard let requestId = card.requestId else { return }
        guard let client else {
            lastError = "还没有连上电脑，回复没有发送。"
            return
        }
        let behavior = card.isApproval ? Card.behavior(for: answer) : "answer"
        var body: JSON = ["requestId": requestId, "behavior": behavior]
        if behavior == "answer" { body["message"] = answer }
        Task { [weak self] in
            do {
                _ = try await client.post("/api/threads/\(threadId)/respond", body: body)
            } catch let error as APIError {
                self?.lastError = error.message
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func alwaysAllow(threadId: String, card: Card) {
        guard let requestId = card.requestId, let client,
              let bot = bots.first(where: { $0.threadId == threadId || $0.tasks.contains { $0.threadId == threadId } })
        else { return }
        Task { [weak self] in
            do {
                _ = try await client.post("/api/bots/\(bot.id)/always-allow", body: ["threadId": threadId, "requestId": requestId])
            } catch let error as APIError {
                self?.lastError = error.message
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func markRead(_ threadId: String) {
        if let last = lastReadWrite[threadId], Date().timeIntervalSince(last) < 2 { return }
        lastReadWrite[threadId] = Date()
        if let bot = bots.first(where: { $0.threadId == threadId || $0.tasks.contains { $0.threadId == threadId } }) {
            markReadLocally(threadId, messageId: nil)
            guard let client else { return }
            Task { _ = try? await client.post("/api/bots/\(bot.id)/read", body: ["threadId": threadId]) }
            return
        }
        if let group = groups.first(where: { $0.threadId == threadId }), let client {
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index].unread = false
            }
            Task { _ = try? await client.post("/api/groups/\(group.id)/read", body: ["threadId": threadId]) }
        }
    }

    private func markReadLocally(_ threadId: String, messageId: String?) {
        guard let botIndex = bots.firstIndex(where: { $0.threadId == threadId || $0.tasks.contains { $0.threadId == threadId } }) else { return }
        bots[botIndex].unread = false
        for index in bots[botIndex].tasks.indices where bots[botIndex].tasks[index].threadId == threadId {
            bots[botIndex].tasks[index].unread = false
            if let messageId {
                bots[botIndex].tasks[index].lastReadMessageId = messageId
            }
        }
    }

    func patchBot(botId: String, fields: JSON) {
        guard let client else { return }
        Task { [weak self] in
            do {
                let answer = try await client.patch("/api/bots/\(botId)", body: fields)
                if let json = answer.obj("bot"), let bot = Bot(json: json) {
                    self?.upsert(bot)
                }
            } catch let error as APIError {
                self?.lastError = error.message
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func setModel(botId: String, selection: ModelSelection) {
        guard let client else { return }
        Task { [weak self] in
            let path = "/api/bots/\(botId)/model"
            // Current harness builds take the selection flat; earlier ones wrap
            // it as {modelSelection} and some accept it as POST.
            let forms: [(String, JSON)] = [
                ("PATCH", selection.json),
                ("PATCH", ["modelSelection": selection.json]),
                ("POST", ["modelSelection": selection.json]),
            ]
            var lastError: APIError?
            for (method, body) in forms {
                do {
                    _ = try await client.request(method, path, body: body)
                    try? await self?.refreshAll()
                    return
                } catch let error as APIError {
                    lastError = error
                    if error.isUnauthorized { break }
                } catch {
                    self?.lastError = error.localizedDescription
                    return
                }
            }
            if let lastError { self?.lastError = lastError.message }
        }
    }

    func newThread(botId: String) async {
        guard let client else { return }
        do {
            let answer = try await client.post("/api/bots/\(botId)/tasks", body: ["title": "新对话"])
            try? await refreshAll(client)
            if let json = answer.obj("task"), let task = BotTask(json: json), let bot = bots.first(where: { $0.id == botId }) {
                open(bot: bot, threadId: task.threadId, title: task.title)
            }
        } catch let error as APIError {
            lastError = error.message
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createBot(name: String) async -> Bot? {
        guard let client else { return nil }
        do {
            let answer = try await client.post("/api/bots", body: ["name": name])
            try? await refreshAll(client)
            guard let json = answer.obj("bot"), let bot = Bot(json: json) else { return nil }
            open(bot: bot)
            return bot
        } catch let error as APIError {
            lastError = error.message
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func deleteQueued(threadId: String, queueId: String) {
        guard let client,
              let bot = bots.first(where: { $0.threadId == threadId || $0.tasks.contains { $0.threadId == threadId } })
        else { return }
        Task { _ = try? await client.delete("/api/bots/\(bot.id)/queue/\(queueId)") }
    }

    func uploadImage(from url: URL) async throws -> Attachment {
        guard let client else { throw APIError(status: 0, message: "尚未连接电脑", body: nil) }
        let gaining = url.startAccessingSecurityScopedResource()
        defer { if gaining { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else {
            throw APIError(status: 0, message: "图片超过 20 MB", body: nil)
        }
        let mime = Self.mimeType(for: url)
        let answer = try await client.uploadImage(data: data, mime: mime, filename: url.lastPathComponent)
        guard let path = answer.nonEmpty("url") ?? answer.nonEmpty("path") else {
            throw APIError(status: 0, message: "上传没有返回附件路径", body: nil)
        }
        return Attachment(kind: "image", path: path, mime: mime, name: url.lastPathComponent)
    }

    func imageData(path: String) async throws -> Data {
        if let cached = ImageCache.shared.value(for: path) { return cached }
        guard let client else { throw APIError(status: 0, message: "尚未连接电脑", body: nil) }
        let data = try await client.bytes(path)
        ImageCache.shared.store(data, for: path)
        return data
    }

    func download(_ attachment: Attachment, threadId: String, messageId: String) async throws -> Data {
        guard let client else { throw APIError(status: 0, message: "尚未连接电脑", body: nil) }
        if attachment.isImage || attachment.isAudio {
            return try await client.bytes(attachment.path)
        }
        return try await client.bytes("/api/threads/\(threadId)/messages/\(messageId)/file",
                                      method: "POST", body: ["path": attachment.path])
    }

    func exportThread(_ threadId: String) async throws -> Data {
        guard let client else { throw APIError(status: 0, message: "尚未连接电脑", body: nil) }
        return try await client.bytes("/api/threads/\(threadId)/export?format=markdown")
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/jpeg"
        }
    }

    private func firstLine(of text: String?) -> String? {
        guard let line = text?.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return String(line)
    }
}
