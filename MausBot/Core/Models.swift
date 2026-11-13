import Foundation

struct ModelSelection: Codable, Equatable, Hashable, Sendable {
    var instanceId: String
    var model: String
    var effort: String?
    var variant: String?

    init(instanceId: String, model: String, effort: String? = nil, variant: String? = nil) {
        self.instanceId = instanceId
        self.model = model
        self.effort = effort
        self.variant = variant
    }

    init?(json: JSON?) {
        guard let json, let instanceId = json.nonEmpty("instanceId"), let model = json.nonEmpty("model") else { return nil }
        self.init(
            instanceId: instanceId,
            model: model,
            effort: json.nonEmpty("effort"),
            variant: json.nonEmpty("variant")
        )
    }

    var json: JSON {
        var body: JSON = ["instanceId": instanceId, "model": model]
        if let effort { body["effort"] = effort }
        if let variant { body["variant"] = variant }
        return body
    }
}

enum WorkLocation: String, CaseIterable, Sendable {
    case auto, cloud, vm, local, browser, off, unknown

    static let choices: [WorkLocation] = [.cloud, .vm, .local, .browser]

    static func from(_ value: String?) -> WorkLocation? {
        guard let value, !value.isEmpty else { return nil }
        return WorkLocation(rawValue: value) ?? .unknown
    }
}

struct WorkLocationConfig: Equatable {
    var cloudConfigured: Bool?
    var browserEnabled: Bool?
    var browserAvailable: Bool?
    var cloudHome: Bool
    var policy: [String: Bool]

    init(json: JSON) {
        let box = json.obj("box")
        cloudConfigured = box?.bool("included") == true ? true : box?["configured"] as? Bool
        browserEnabled = json.obj("features")?["browser"] as? Bool
        switch json.obj("browserEngine")?.str("kind") {
        case "engine": browserAvailable = true
        case "unavailable": browserAvailable = false
        default: browserAvailable = nil
        }
        cloudHome = json.bool("cloudHome")
        policy = json.obj("managedPolicy")?.obj("computers") as? [String: Bool] ?? [:]
    }

    func unavailableReason(for location: WorkLocation, bot: Bot, instance: ProviderInstance?) -> String? {
        if cloudHome && (location == .vm || location == .local) {
            return localized("此位置在远程服务中不可用")
        }
        let policyKey: String
        switch location {
        case .cloud: policyKey = bot.cloudBackend == "vps" ? "vps" : "box"
        case .vm: policyKey = "localVm"
        case .local: policyKey = "thisComputer"
        default: policyKey = ""
        }
        if policy[policyKey] == false { return localized("此位置受到远程电脑策略限制") }
        if location == .browser {
            if instance?.browserMcp == false { return localized("当前模型不支持浏览器") }
            if browserEnabled == false || browserAvailable == false { return localized("请先在配对电脑启用浏览器") }
        } else {
            if instance?.computerMcp == false { return localized("当前模型不支持桌面") }
            if location == .cloud && bot.cloudBackend != "vps" && cloudConfigured == false {
                return localized("请先在配对电脑连接 Boat")
            }
        }
        return nil
    }
}

struct BotTask: Identifiable, Equatable, Sendable {
    var threadId: String
    var title: String
    var unread: Bool
    var busy: Bool
    var activity: String?
    var pinned: Bool
    var updatedAt: Date?
    var createdAt: Date?
    var lastReadMessageId: String?
    var modelSelection: ModelSelection?
    var surface: WorkLocation?
    var surfaceAuto: Bool

    var pinnedLocation: WorkLocation? { surfaceAuto ? nil : surface }

    var id: String { threadId }

    init?(json: JSON) {
        guard let threadId = json.nonEmpty("threadId") else { return nil }
        self.threadId = threadId
        title = json.str("title") ?? ""
        unread = json.bool("unread")
        busy = json.bool("busy")
        activity = json.nonEmpty("activity")
        pinned = json.bool("pinned")
        updatedAt = wireDate(json.int("updatedAt"))
        createdAt = wireDate(json.int("createdAt"))
        lastReadMessageId = json.nonEmpty("lastReadMessageId")
        modelSelection = ModelSelection(json: json.obj("modelSelection"))
        surface = WorkLocation.from(json.nonEmpty("surface"))
        surfaceAuto = json.bool("surfaceAuto")
    }
}

struct Bot: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var title: String
    var description: String
    var soul: String
    var color: String
    var avatarUrl: String?
    var unread: Bool
    var pinned: Bool
    var hidden: Bool
    var busy: Bool
    var activity: String?
    var threadId: String
    var mainThreadId: String?
    var tasks: [BotTask]
    var modelSelection: ModelSelection?
    var computer: WorkLocation?
    var cloudBackend: String?
    var notifications: Bool
    var section: String?
    var chiefOfStaff: Bool
    var speakReplies: Bool

    var latestTask: BotTask? {
        tasks.reduce(nil) { latest, task in
            guard let latest else { return task }
            let latestDate = latest.updatedAt ?? latest.createdAt ?? .distantPast
            let taskDate = task.updatedAt ?? task.createdAt ?? .distantPast
            return taskDate > latestDate ? task : latest
        }
    }

    var subtitle: String {
        if busy { return localized("正在工作") }
        switch activity {
        case "waiting-on-you": return localized("等待你处理")
        case "parked.computer": return localized("已暂停")
        case "dead", "no-signal": return localized("无信号")
        default: return title.isEmpty ? description : title
        }
    }

    func task(threadId: String) -> BotTask? {
        tasks.first { $0.threadId == threadId }
    }

    init?(json: JSON) {
        guard let id = json.nonEmpty("id") else { return nil }
        self.id = id
        name = json.str("name") ?? "Bot"
        title = json.str("title") ?? ""
        description = json.str("description") ?? ""
        soul = json.str("soul") ?? ""
        color = json.str("color") ?? "green"
        avatarUrl = json.nonEmpty("avatarUrl")
        unread = json.bool("unread")
        pinned = json.bool("pinned")
        hidden = json.bool("hidden")
        busy = json.bool("busy")
        activity = json.nonEmpty("activity")
        threadId = json.str("threadId") ?? ""
        mainThreadId = json.nonEmpty("mainThreadId")
        tasks = json.objArray("tasks").compactMap(BotTask.init(json:))
        modelSelection = ModelSelection(json: json.obj("modelSelection"))
        computer = WorkLocation.from(json.nonEmpty("computer"))
        cloudBackend = json.nonEmpty("cloudBackend")
        notifications = json.bool("notifications", true)
        section = json.nonEmpty("section")
        chiefOfStaff = json.bool("chiefOfStaff")
        speakReplies = json.bool("speakReplies")
    }
}

struct ChatGroup: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var unread: Bool
    var threadId: String
    var memberIds: [String]

    var subtitle: String {
        if !description.isEmpty { return description }
        return localized("%lld 个 Bot", Int64(memberIds.count))
    }

    init?(json: JSON) {
        guard let id = json.nonEmpty("id") else { return nil }
        self.id = id
        name = json.str("name") ?? localized("房间")
        description = json.str("description") ?? ""
        unread = json.bool("unread")
        threadId = json.str("threadId") ?? ""
        if !json.objArray("members").isEmpty {
            memberIds = json.objArray("members").compactMap { $0.nonEmpty("botId") ?? $0.nonEmpty("id") }
        } else {
            memberIds = json.strArray("memberIds")
        }
    }
}

struct Attachment: Identifiable, Equatable, Sendable {
    var kind: String
    var path: String
    var mime: String
    var name: String?
    var durationMs: Int?

    var id: String { path }
    var isImage: Bool { kind == "image" }
    var isAudio: Bool { kind == "audio" }

    init(kind: String, path: String, mime: String, name: String? = nil, durationMs: Int? = nil) {
        self.kind = kind
        self.path = path
        self.mime = mime
        self.name = name
        self.durationMs = durationMs
    }

    init?(json: JSON) {
        guard let path = json.nonEmpty("path") else { return nil }
        self.init(
            kind: json.str("kind") ?? "file",
            path: path,
            mime: json.str("mime") ?? "application/octet-stream",
            name: json.nonEmpty("name"),
            durationMs: json.int("durationMs")
        )
    }

    var json: JSON {
        var body: JSON = ["kind": kind, "path": path, "mime": mime]
        if let name { body["name"] = name }
        return body
    }
}

struct ToolRow: Equatable, Sendable {
    var name: String
    var label: String?
    var ok: Bool
    var detail: String?

    init?(json: JSON?) {
        guard let json else { return nil }
        name = json.str("name") ?? ""
        label = json.nonEmpty("label")
        ok = json.bool("ok", true)
        detail = json.nonEmpty("detail") ?? json.nonEmpty("summary") ?? json.nonEmpty("target")
    }
}

struct Card: Equatable, Sendable {
    var title: String
    var subtitle: String
    var options: [String]
    var answered: String?
    var answeredText: String?
    var requestId: String?
    var requestType: String?
    var tool: String?
    var allowKey: String?
    var allowSession: Bool
    var expired: Bool
    var stopped: Bool
    var dismissed: Bool
    var held: String?

    var settled: Bool {
        (answered?.isEmpty == false) || expired || stopped || dismissed
    }

    var needsAnswer: Bool {
        requestId != nil && !settled
    }

    var isApproval: Bool {
        if requestType == "permission" || tool != nil { return true }
        guard requestId != nil else { return false }
        return options.contains { Card.looksLikeVerdict($0) }
    }

    var isQuestion: Bool {
        requestType == "question" || (!isApproval && requestId != nil && !options.isEmpty)
    }

    static func looksLikeVerdict(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower == "allow" || lower == "deny" || lower == "reject"
            || lower.contains("allow once") || lower.contains("always allow")
            || lower.contains("don't allow") || lower.contains("deny")
    }

    /// The harness takes one verdict per pending request: `allow`, `deny`, or
    /// `answer` with the words a question needs.
    static func behavior(for option: String) -> String {
        let lower = option.lowercased()
        if ["允许", "允许一次", "始终允许", "同意"].contains(option) { return "allow" }
        if ["拒绝", "不允许", "不同意"].contains(option) { return "deny" }
        if lower == "allow" || lower == "always allow" || lower.contains("allow once") { return "allow" }
        if lower == "deny" || lower == "reject" || lower.contains("don't allow") || lower.contains("deny") { return "deny" }
        return "answer"
    }

    init?(json: JSON?) {
        guard let json, let title = json.nonEmpty("title") else { return nil }
        self.title = title
        subtitle = json.str("subtitle") ?? ""
        options = json.strArray("options")
        answered = json.nonEmpty("answered")
        answeredText = json.nonEmpty("answeredText")
        requestId = json.nonEmpty("requestId")
        requestType = json.nonEmpty("requestType")
        tool = json.nonEmpty("tool")
        allowKey = json.nonEmpty("allowKey")
        allowSession = json.bool("allowSession")
        expired = json.bool("expired")
        stopped = json.bool("stopped")
        dismissed = json.bool("dismissed")
        held = json.nonEmpty("held")
    }
}

struct Message: Identifiable, Equatable, Sendable {
    var id: String
    var role: String
    var kind: String
    var text: String
    var createdAt: Date
    var card: Card?
    var tool: ToolRow?
    var attachments: [Attachment]
    var turnId: String?
    var queueId: String?
    var fromName: String?
    var fromColor: String?
    var editedAt: Date?
    var clientId: String?
    var pending: Bool
    var failed: Bool

    var isUser: Bool { role == "user" }
    var isBot: Bool { role == "bot" }
    var isDigest: Bool {
        isBot && card == nil && tool == nil && attachments.isEmpty
            && (kind == "digest" || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[digest]"))
    }

    init(
        id: String,
        role: String,
        kind: String = "text",
        text: String,
        createdAt: Date,
        card: Card? = nil,
        tool: ToolRow? = nil,
        attachments: [Attachment] = [],
        turnId: String? = nil,
        queueId: String? = nil,
        fromName: String? = nil,
        fromColor: String? = nil,
        editedAt: Date? = nil,
        clientId: String? = nil,
        pending: Bool = false,
        failed: Bool = false
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.card = card
        self.tool = tool
        self.attachments = attachments
        self.turnId = turnId
        self.queueId = queueId
        self.fromName = fromName
        self.fromColor = fromColor
        self.editedAt = editedAt
        self.clientId = clientId
        self.pending = pending
        self.failed = failed
    }

    init?(json: JSON, pending: Bool = false) {
        guard let id = json.nonEmpty("id") else { return nil }
        let from = json.obj("from")
        self.init(
            id: id,
            role: json.str("role") ?? "bot",
            kind: json.str("kind") ?? "text",
            text: json.str("text") ?? "",
            createdAt: wireDate(json.int("at") ?? json.int("createdAt")) ?? Date(),
            card: Card(json: json.obj("card")),
            tool: ToolRow(json: json.obj("tool")),
            attachments: json.objArray("attachments").compactMap(Attachment.init(json:)),
            turnId: json.nonEmpty("turnId"),
            queueId: json.nonEmpty("queueId"),
            fromName: from?.nonEmpty("name"),
            fromColor: from?.nonEmpty("color"),
            editedAt: wireDate(json.int("editedAt")),
            clientId: json.nonEmpty("clientId"),
            pending: pending,
            failed: false
        )
    }

}

struct InstanceModel: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var provider: String?
    var variants: [ModelVariant]
}

struct ModelVariant: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
}

struct ProviderInstance: Identifiable, Equatable, Sendable {
    var instanceId: String
    var displayName: String
    var driverKind: String
    var enabled: Bool
    var models: [InstanceModel]
    var effortLevels: [String]
    var modelVariants: Bool
    var computerMcp: Bool?
    var browserMcp: Bool?

    var id: String { instanceId }
    var name: String { displayName.isEmpty ? instanceId : displayName }

    init?(json: JSON) {
        guard let instanceId = json.nonEmpty("instanceId") else { return nil }
        self.instanceId = instanceId
        displayName = json.nonEmpty("displayName") ?? instanceId
        driverKind = json.str("driverKind") ?? ""
        enabled = json.bool("enabled", true)
        let capabilities = json.obj("capabilities")
        effortLevels = capabilities?.strArray("effortLevels") ?? []
        modelVariants = capabilities?.bool("modelVariants") ?? false
        computerMcp = capabilities?["computerMcp"] as? Bool
        browserMcp = capabilities?["browserMcp"] as? Bool
        let catalog = json.obj("models")
        models = (catalog?.objArray("options") ?? []).compactMap { option in
            guard let id = option.nonEmpty("id") else { return nil }
            let variants = option.objArray("variants").compactMap { variant -> ModelVariant? in
                guard let id = variant.nonEmpty("id") else { return nil }
                return ModelVariant(id: id, label: variant.nonEmpty("label") ?? id)
            }
            return InstanceModel(id: id, label: option.nonEmpty("label") ?? id, provider: option.nonEmpty("provider"), variants: variants)
        }
    }
}

struct SearchHit: Identifiable, Equatable, Sendable {
    var threadId: String
    var messageId: String
    var text: String
    var name: String
    var taskTitle: String?
    var botId: String?
    var groupId: String?

    var id: String { "\(threadId)-\(messageId)" }

    init?(json: JSON) {
        guard let threadId = json.nonEmpty("threadId"), let messageId = json.nonEmpty("messageId") else { return nil }
        self.threadId = threadId
        self.messageId = messageId
        text = json.nonEmpty("text") ?? json.nonEmpty("snippet") ?? ""
        name = json.nonEmpty("name") ?? ""
        taskTitle = json.nonEmpty("task")
        botId = json.nonEmpty("botId")
        groupId = json.nonEmpty("groupId")
    }
}

enum ChatTarget: Hashable, Sendable {
    case bot(String)
    case group(String)
}

struct OpenChat: Hashable, Sendable {
    var target: ChatTarget
    var threadId: String
    var title: String
}

struct ThreadState: Equatable, Sendable {
    var messages: [Message] = []
    var hasMore = true
    var loading = false
    var loaded = false
    var activeLeafId: String?
}

struct ConnectionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, connecting, online, offline, error, unauthorized
    }

    var phase: Phase = .idle
    var detail: String = ""
    var serverName: String = ""

    var isOnline: Bool { phase == .online }
}
