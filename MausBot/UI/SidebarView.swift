import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @Binding var search: String
    @State private var newItem: SidebarNewItem?
    @State private var expandedBotIds: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            computerHeader
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    chiefCards
                    VStack(alignment: .leading, spacing: 1) {
                        if isSearching {
                            searchResults
                        } else {
                            botList
                            roomList
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.bottom, 12)
                .background(SlimScrollbar())
            }
            footer
        }
        .background(Theme.sidebarBackground)
        .sheet(item: $newItem) { item in
            SidebarNewItemSheet(item: item)
                .frame(width: 380)
        }
        .onChange(of: store.computer?.id) { _, _ in
            expandedBotIds.removeAll()
        }
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Header

    private var computerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.computer?.displayName ?? "MausBot")
                    .appFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                ConnectionPill(state: store.connection)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(store.computers) { saved in
                    Button {
                        store.select(saved.id)
                    } label: {
                        if saved.id == store.computer?.id {
                            Label(saved.displayName, systemImage: "checkmark")
                        } else {
                            Text(saved.displayName)
                        }
                    }
                }
                Divider()
                Button("配对新的电脑…") { store.showPairingSheet = true }
                if store.computer != nil {
                    Button("重新连接") { store.connect() }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .appFont(size: 11, weight: .medium)
                .foregroundStyle(.tertiary)
            TextField("搜索消息", text: $search)
                .textFieldStyle(.plain)
                .appFont(size: 12.5)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .appFont(size: 11)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onChange(of: search) { _, value in
            store.search(value)
        }
    }

    // MARK: - Lists

    private var visibleBots: [Bot] {
        store.bots.filter { !$0.hidden && !$0.chiefOfStaff }
    }

    private var chiefs: [Bot] {
        store.bots.filter { !$0.hidden && $0.chiefOfStaff }
    }

    @ViewBuilder
    private var chiefCards: some View {
        if !chiefs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                LazyVGrid(
                    columns: [chiefs.count == 1 ? GridItem(.fixed(96)) : GridItem(.adaptive(minimum: 96))],
                    alignment: .center,
                    spacing: 8
                ) {
                    ForEach(chiefs) { bot in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                search = ""
                                store.open(bot: bot)
                            } label: {
                                HoverRow(selected: store.open?.target == .bot(bot.id)) {
                                    VStack(spacing: 4) {
                                        AvatarView(name: bot.name, color: bot.color, url: bot.avatarUrl, size: 34, emoji: store.emoji(for: bot.id))
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "star.fill")
                                                    .appFont(size: 10)
                                                    .foregroundStyle(.orange)
                                                    .padding(2)
                                                    .background(Circle().fill(Theme.sidebarBackground))
                                            }
                                        HStack(spacing: 5) {
                                            Text(bot.name)
                                                .appFont(size: 12, weight: .medium)
                                                .lineLimit(1)
                                            if bot.busy || bot.tasks.contains(where: \.busy) {
                                                BusySpinner()
                                            } else if bot.unread || bot.tasks.contains(where: \.unread) {
                                                UnreadDot()
                                            }
                                        }
                                        Text(bot.title.isEmpty ? localized("管理员") : bot.title)
                                            .appFont(size: 10)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.plain)
                            disclosureButton(bot)
                        }
                        .contextMenu {
                            Button("设置…") { store.settingsBotId = bot.id }
                            Button(localized(bot.notifications ? "关闭通知" : "开启通知")) {
                                store.patchBot(botId: bot.id, fields: ["notifications": !bot.notifications])
                            }
                        }
                    }
                }
                if !isSearching, let bot = chiefs.first(where: { expandedBotIds.contains($0.id) }) {
                    if chiefs.count > 1 {
                        Text(bot.name)
                            .appFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.top, 4)
                    }
                    conversationList(bot)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var botList: some View {
        let loose = visibleBots.filter { $0.section == nil }
        if !loose.isEmpty || sectionNames.isEmpty {
            SectionLabel(text: "BOTS")
            ForEach(loose) { bot in
                botRow(bot)
            }
        }
        ForEach(sectionNames, id: \.self) { section in
            SectionLabel(text: section.uppercased())
            ForEach(visibleBots.filter { $0.section == section }) { bot in
                botRow(bot)
            }
        }
        if visibleBots.isEmpty && chiefs.isEmpty {
            emptyNote("还没有 Bot")
        }
    }

    private var sectionNames: [String] {
        var names = store.sections
        for bot in visibleBots {
            if let section = bot.section, !names.contains(section) { names.append(section) }
        }
        return names
    }

    private func botRow(_ bot: Bot) -> some View {
        let selected = store.open?.target == .bot(bot.id)
        return VStack(alignment: .leading, spacing: 1) {
            HoverRow(selected: selected && !expandedBotIds.contains(bot.id)) {
                HStack(spacing: 4) {
                    disclosureButton(bot)
                    Button {
                        store.open(bot: bot)
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(name: bot.name, color: bot.color, url: bot.avatarUrl, size: 30, emoji: store.emoji(for: bot.id))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(bot.name)
                                        .appFont(size: 13, weight: .medium)
                                        .lineLimit(1)
                                    if bot.pinned {
                                        Image(systemName: "pin.fill")
                                            .appFont(size: 8)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Text(bot.subtitle)
                                    .appFont(size: 11)
                                    .foregroundStyle(bot.busy ? Theme.accent : .secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if bot.busy || bot.tasks.contains(where: \.busy) {
                                BusySpinner()
                            } else if bot.unread || bot.tasks.contains(where: \.unread) {
                                UnreadDot()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .contextMenu {
                Button("设置…") { store.settingsBotId = bot.id }
                if !sectionNames.isEmpty || bot.section != nil {
                    Menu("移动到区段") {
                        if bot.section != nil {
                            Button("未分组") { move(bot, to: "") }
                        }
                        ForEach(sectionNames.filter { $0 != bot.section }, id: \.self) { section in
                            Button(section) { move(bot, to: section) }
                        }
                    }
                }
                Button(localized(bot.pinned ? "取消置顶" : "置顶")) {
                    store.patchBot(botId: bot.id, fields: ["pinned": !bot.pinned])
                }
                Button(localized(bot.notifications ? "关闭通知" : "开启通知")) {
                    store.patchBot(botId: bot.id, fields: ["notifications": !bot.notifications])
                }
            }
            if expandedBotIds.contains(bot.id) {
                conversationList(bot)
                    .padding(.leading, 28)
            }
        }
    }

    private func disclosureButton(_ bot: Bot) -> some View {
        let expanded = expandedBotIds.contains(bot.id) && !isSearching
        let label = localized(expanded ? "收起 %@ 的对话" : "展开 %@ 的对话", bot.name)
        return Button {
            if isSearching {
                search = ""
                expandBot(bot.id)
            } else if expanded {
                expandedBotIds.remove(bot.id)
            } else {
                expandBot(bot.id)
            }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .appFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(localized(expanded ? "已展开" : "已收起"))
    }

    private func expandBot(_ botId: String) {
        if chiefs.contains(where: { $0.id == botId }) {
            expandedBotIds.subtract(chiefs.map(\.id))
        }
        expandedBotIds.insert(botId)
    }

    private func conversationList(_ bot: Bot) -> some View {
        let taskIds = Set(bot.tasks.map(\.threadId))
        let defaultThread = !bot.threadId.isEmpty && !taskIds.contains(bot.threadId)
        let current = store.open?.target == .bot(bot.id) ? store.open : nil
        let currentThread = current.map { !$0.threadId.isEmpty && $0.threadId != bot.threadId && !taskIds.contains($0.threadId) } ?? false
        return VStack(alignment: .leading, spacing: 1) {
            if defaultThread {
                let title = current?.threadId == bot.threadId && current?.title != bot.name ? current?.title : nil
                conversationRow(bot, threadId: bot.threadId, title: title, busy: bot.busy, unread: bot.unread)
            }
            ForEach(bot.tasks) { task in
                conversationRow(bot, threadId: task.threadId, title: task.title, busy: task.busy, unread: task.unread)
            }
            if currentThread, let current {
                conversationRow(bot, threadId: current.threadId, title: current.title, busy: false, unread: false)
            }
            if !defaultThread && bot.tasks.isEmpty && !currentThread {
                emptyNote("暂无对话")
            }
        }
    }

    private func conversationRow(_ bot: Bot, threadId: String, title: String?, busy: Bool, unread: Bool) -> some View {
        let selected = store.open?.target == .bot(bot.id) && store.open?.threadId == threadId
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = name.isEmpty ? localized("未命名对话") : name
        return Button {
            store.open(bot: bot, threadId: threadId, title: name.isEmpty ? nil : name)
        } label: {
            HoverRow(selected: selected) {
                HStack(spacing: 7) {
                    Text(displayName)
                        .appFont(size: 12, weight: selected ? .medium : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if busy {
                        BusySpinner()
                    } else if unread {
                        UnreadDot()
                    }
                    if selected {
                        Image(systemName: "checkmark")
                            .appFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(displayName)
    }

    private func move(_ bot: Bot, to section: String) {
        Task {
            do {
                try await store.createSection(name: section, botIds: [bot.id])
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var roomList: some View {
        if !store.groups.isEmpty {
            SectionLabel(text: "房间")
            ForEach(store.groups) { group in
                roomRow(group)
            }
        }
    }

    private func roomRow(_ group: ChatGroup) -> some View {
        let selected = store.open?.target == .group(group.id)
        return Button {
            store.open(group: group)
        } label: {
            HoverRow(selected: selected) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.botColor("teal").opacity(0.16))
                            .frame(width: 30, height: 30)
                        Image(systemName: "person.2.fill")
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.botColor("teal"))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .appFont(size: 13, weight: .medium)
                            .lineLimit(1)
                        Text(group.subtitle)
                            .appFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if group.unread { UnreadDot() }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchResults: some View {
        SectionLabel(text: "搜索结果")
        if store.searching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在搜索…").appFont(size: 12).foregroundStyle(.secondary)
            }
            .padding(12)
        } else if store.searchHits.isEmpty {
            emptyNote("没有找到消息")
        } else {
            ForEach(store.searchHits) { hit in
                Button {
                    store.openByThreadId(hit.threadId)
                } label: {
                    HoverRow {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(hit.name)
                                    .appFont(size: 12.5, weight: .medium)
                                    .lineLimit(1)
                                if let task = hit.taskTitle, !task.isEmpty {
                                    Text("· \(task)")
                                        .appFont(size: 11)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Text(hit.text)
                                .appFont(size: 11.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(localized(text))
            .appFont(size: 12)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                Button { search = ""; store.showNewBotSheet = true } label: {
                    Label("新建机器人", systemImage: "person.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
                Button { search = ""; newItem = .section } label: {
                    Label("添加区段", systemImage: "rectangle.split.3x1")
                        .labelStyle(.titleAndIcon)
                }
                Button { search = ""; newItem = .group } label: {
                    Label("新建群组", systemImage: "person.2.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
            } label: {
                Image(systemName: "plus")
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("新建")
            .accessibilityLabel("新建")
            if let version = updateChecker.latestVersion {
                Link(destination: UpdateChecker.releasesURL) {
                    Label(localized("发现新版本 %@", version), systemImage: "arrow.down.circle.fill")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                .help("前往 GitHub 下载最新版本")
            }
            Spacer()

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            Rectangle()
                .fill(Theme.sidebarBackground)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
        )
    }
}
