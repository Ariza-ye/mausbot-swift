import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Binding var search: String

    var body: some View {
        VStack(spacing: 0) {
            computerHeader
            searchField
            chiefCards
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if isSearching {
                        searchResults
                    } else {
                        botList
                        roomList
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            footer
        }
        .background(Theme.sidebarBackground)
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
            LazyVGrid(
                columns: [chiefs.count == 1 ? GridItem(.fixed(96)) : GridItem(.adaptive(minimum: 96))],
                alignment: .center,
                spacing: 8
            ) {
                ForEach(chiefs) { bot in
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
                                    if bot.busy {
                                        BusySpinner()
                                    } else if bot.unread {
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
                    .contextMenu {
                        Button("设置…") { store.settingsBotId = bot.id }
                        Button(localized(bot.notifications ? "关闭通知" : "开启通知")) {
                            store.patchBot(botId: bot.id, fields: ["notifications": !bot.notifications])
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var botList: some View {
        let sections = sectionGroups
        if sections.isEmpty {
            SectionLabel(text: "BOTS")
            ForEach(visibleBots) { bot in
                botRow(bot)
            }
        } else {
            ForEach(sections, id: \.title) { section in
                SectionLabel(text: section.title.uppercased())
                ForEach(section.bots) { bot in
                    botRow(bot)
                }
            }
        }
        if visibleBots.isEmpty && chiefs.isEmpty {
            emptyNote("还没有 Bot")
        }
    }

    private struct BotSection {
        var title: String
        var bots: [Bot]
    }

    private var sectionGroups: [BotSection] {
        var order: [String] = []
        var grouped: [String: [Bot]] = [:]
        for bot in visibleBots {
            let key = bot.section ?? ""
            if grouped[key] == nil {
                grouped[key] = []
                if !key.isEmpty { order.append(key) }
            }
            grouped[key]?.append(bot)
        }
        var result = order.map { BotSection(title: $0, bots: grouped[$0] ?? []) }
        if let loose = grouped[""], !loose.isEmpty {
            result.insert(BotSection(title: "Bots", bots: loose), at: 0)
        }
        return result.count > 1 ? result : []
    }

    private func botRow(_ bot: Bot) -> some View {
        let selected = store.open?.target == .bot(bot.id)
        return Button {
            store.open(bot: bot)
        } label: {
            HoverRow(selected: selected) {
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
                    if bot.busy {
                        BusySpinner()
                    } else if bot.unread {
                        UnreadDot()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("设置…") { store.settingsBotId = bot.id }
            Button(localized(bot.pinned ? "取消置顶" : "置顶")) {
                store.patchBot(botId: bot.id, fields: ["pinned": !bot.pinned])
            }
            Button(localized(bot.notifications ? "关闭通知" : "开启通知")) {
                store.patchBot(botId: bot.id, fields: ["notifications": !bot.notifications])
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
