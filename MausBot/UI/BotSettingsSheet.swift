import SwiftUI

struct BotSettingsSheet: View {
    let botId: String
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loadedName = ""
    @State private var showIconPicker = false

    private var bot: Bot? {
        store.bots.first { $0.id == botId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let bot {
                    AvatarView(name: bot.name, color: bot.color, url: bot.avatarUrl, size: 36, emoji: store.emoji(for: bot.id))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot?.name ?? "Bot")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("运行在 \(store.computer?.displayName ?? "远程电脑")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("图标") {
                        HStack(spacing: 12) {
                            if let bot {
                                AvatarView(name: bot.name, color: bot.color, url: bot.avatarUrl, size: 40, emoji: store.emoji(for: botId))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Button("更换图标…") { showIconPicker = true }
                                    .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                                        BotEmojiPicker(selection: store.emoji(for: botId)) { emoji in
                                            store.setEmoji(emoji, for: botId)
                                            showIconPicker = false
                                        }
                                    }
                                Text("\(store.emoji(for: botId) == nil ? "默认头像" : "Emoji 图标") · 仅在本机显示")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.emoji(for: botId) != nil {
                                Button("恢复默认") { store.setEmoji(nil, for: botId) }
                                    .controlSize(.small)
                            }
                        }
                    }

                    field("名字") {
                        HStack(spacing: 8) {
                            TextField("名字", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.subtleFill))
                            Button("保存") { saveName() }
                                .disabled(trimmedName.isEmpty || trimmedName == loadedName)
                        }
                    }

                    field("状态") {
                        VStack(spacing: 8) {
                            toggle("置顶", systemName: "pin", on: bot?.pinned ?? false) { value in
                                store.patchBot(botId: botId, fields: ["pinned": value])
                            }
                            toggle("在侧栏隐藏", systemName: "eye.slash", on: bot?.hidden ?? false) { value in
                                store.patchBot(botId: botId, fields: ["hidden": value])
                            }
                            toggle("回复时通知", systemName: "bell", on: bot?.notifications ?? true) { value in
                                store.patchBot(botId: botId, fields: ["notifications": value])
                            }
                        }
                    }

                    field("模型") {
                        Menu {
                            ForEach(store.instances.filter(\.enabled)) { instance in
                                Section(instance.name) {
                                    ForEach(instance.models) { model in
                                        Button {
                                            store.setModel(
                                                botId: botId,
                                                selection: ModelSelection(
                                                    instanceId: instance.instanceId,
                                                    model: model.id,
                                                    effort: bot?.modelSelection?.effort
                                                )
                                            )
                                        } label: {
                                            if bot?.modelSelection?.instanceId == instance.instanceId,
                                               bot?.modelSelection?.model == model.id {
                                                Label(model.label, systemImage: "checkmark")
                                            } else {
                                                Text(model.label)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(bot?.modelSelection?.model ?? "未设置")
                                    .font(.system(size: 12.5))
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.subtleFill))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }

                    field("对话") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(bot?.tasks ?? []) { task in
                                Button {
                                    if let bot {
                                        store.open(bot: bot, threadId: task.threadId)
                                    }
                                    dismiss()
                                } label: {
                                    HStack(spacing: 7) {
                                        Text(task.title.isEmpty ? "未命名对话" : task.title)
                                            .font(.system(size: 12.5))
                                            .lineLimit(1)
                                        if task.threadId == bot?.threadId {
                                            Text("当前")
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .foregroundStyle(Theme.accent)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                                        }
                                        Spacer()
                                        if task.unread { UnreadDot() }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.001)))
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                Task { await store.newThread(botId: botId) }
                                dismiss()
                            } label: {
                                Label("新对话", systemImage: "plus")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }

                    Text("Bot ID \(botId)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(18)
            }
        }
        .onAppear {
            name = bot?.name ?? ""
            loadedName = name
        }
        .onChange(of: bot?.name) { _, value in
            if let value, loadedName != value, trimmedName == loadedName {
                name = value
                loadedName = value
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveName() {
        guard !trimmedName.isEmpty else { return }
        store.patchBot(botId: botId, fields: ["name": trimmedName])
        loadedName = trimmedName
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func toggle(_ title: String, systemName: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct BotEmojiPicker: View {
    let selection: String?
    let select: (String?) -> Void
    @State private var search = ""
    @State private var category = "常用"
    @State private var customEmoji = ""

    private struct Entry: Identifiable {
        let emoji: String
        let keywords: String
        var id: String { emoji }
    }

    private struct Category: Identifiable {
        let name: String
        let entries: [Entry]
        var id: String { name }

        init(_ name: String, _ items: [(String, String)]) {
            self.name = name
            entries = items.map { Entry(emoji: $0.0, keywords: $0.1) }
        }
    }

    private static let categories: [Category] = [
        Category("常用", [
            ("🤖", "机器人 助手 robot bot"), ("🧠", "大脑 智慧 brain"), ("✨", "闪光 灵感 sparkles"),
            ("⭐️", "星星 收藏 star"), ("🚀", "火箭 效率 rocket"), ("💡", "灯泡 创意 idea"),
            ("📝", "写作 笔记 writing memo"), ("📰", "新闻 报纸 news"), ("🎯", "目标 target"),
            ("💻", "电脑 编程 computer code"), ("📚", "书籍 学习 books"), ("☕️", "咖啡 coffee")
        ]),
        Category("表情", [
            ("😀", "开心 笑脸 smile happy"), ("😎", "酷 墨镜 cool"), ("🥳", "庆祝 party"),
            ("🤔", "思考 thinking"), ("🧐", "研究 monocle"), ("🤓", "学霸 nerd"),
            ("🥰", "喜爱 love"), ("😴", "睡觉 sleep"), ("👻", "幽灵 ghost"),
            ("👽", "外星人 alien"), ("🎃", "南瓜 pumpkin"), ("💪", "加油 力量 muscle")
        ]),
        Category("动物", [
            ("🐱", "猫 cat"), ("🐶", "狗 dog"), ("🦊", "狐狸 fox"),
            ("🐼", "熊猫 panda"), ("🐻", "熊 bear"), ("🐨", "考拉 koala"),
            ("🦁", "狮子 lion"), ("🐯", "老虎 tiger"), ("🐰", "兔子 rabbit"),
            ("🦉", "猫头鹰 owl"), ("🐧", "企鹅 penguin"), ("🦄", "独角兽 unicorn")
        ]),
        Category("自然", [
            ("🌱", "幼苗 成长 seedling"), ("🌿", "植物 草 herb"), ("🌳", "树 tree"),
            ("🌻", "向日葵 sunflower"), ("🌸", "樱花 blossom"), ("🍀", "幸运 四叶草 clover"),
            ("☀️", "太阳 sun"), ("🌙", "月亮 moon"), ("🌈", "彩虹 rainbow"),
            ("🔥", "火 热门 fire"), ("🌊", "海浪 wave"), ("🌍", "地球 世界 earth")
        ]),
        Category("工作", [
            ("📊", "图表 数据 分析 chart analytics"), ("📈", "增长 股票 趋势 growth"), ("💼", "公文包 商务 工作 briefcase"),
            ("📋", "任务 清单 clipboard"), ("📅", "日历 日程 calendar"), ("📌", "图钉 pin"),
            ("📎", "附件 回形针 paperclip"), ("📁", "文件夹 folder"), ("✏️", "铅笔 写作 pencil"),
            ("🔍", "搜索 研究 search"), ("🛠️", "工具 tools"), ("⚙️", "设置 齿轮 gear")
        ]),
        Category("生活", [
            ("🍎", "苹果 apple"), ("🍋", "柠檬 lemon"), ("🥑", "牛油果 avocado"),
            ("🍕", "披萨 pizza"), ("🍰", "蛋糕 cake"), ("🧋", "奶茶 bubble tea"),
            ("🏠", "房屋 家 home"), ("✈️", "飞机 旅行 airplane travel"), ("🚲", "自行车 bicycle"),
            ("🎒", "背包 backpack"), ("🏖️", "沙滩 度假 beach"), ("🏋️", "健身 运动 gym")
        ]),
        Category("创作", [
            ("🎨", "艺术 绘画 调色盘 art palette"), ("🎬", "电影 视频 movie video"), ("📷", "相机 摄影 camera"),
            ("🎵", "音乐 music"), ("🎧", "耳机 播客 headphones podcast"), ("🎮", "游戏 game"),
            ("🎤", "麦克风 唱歌 microphone"), ("🎹", "钢琴 piano"), ("🧩", "拼图 puzzle"),
            ("🪄", "魔法 magic"), ("🧵", "线 手工 thread"), ("💎", "钻石 diamond")
        ]),
        Category("符号", [
            ("❤️", "红心 爱 heart love"), ("🧡", "橙心 orange heart"), ("💛", "黄心 yellow heart"),
            ("💚", "绿心 green heart"), ("💙", "蓝心 blue heart"), ("💜", "紫心 purple heart"),
            ("✅", "完成 对勾 check"), ("💬", "聊天 对话 chat"), ("🔔", "提醒 铃铛 bell"),
            ("🔑", "钥匙 key"), ("🏆", "奖杯 trophy"), ("⚡️", "闪电 快速 lightning")
        ])
    ]

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var customValue: String { customEmoji.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var entries: [Entry] {
        if query.isEmpty {
            return Self.categories.first { $0.name == category }?.entries ?? []
        }
        return Self.categories.flatMap(\.entries).filter {
            $0.emoji.contains(query) || $0.keywords.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择图标").font(.headline)
                Spacer()
                Button("恢复默认") { select(nil) }
                    .disabled(selection == nil)
                    .controlSize(.small)
            }

            TextField("搜索 Emoji，例如：机器人、新闻、cat", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索 Emoji")

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Self.categories) { item in
                        Button {
                            category = item.name
                            search = ""
                        } label: {
                            Text(item.name)
                                .font(.system(size: 11, weight: category == item.name ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(category == item.name ? Theme.accent.opacity(0.12) : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == item.name ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)

            ScrollView {
                if entries.isEmpty {
                    Text("没有找到匹配的表情，可在下方粘贴其他 Emoji。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                        ForEach(entries) { entry in
                            Button { select(entry.emoji) } label: {
                                Text(entry.emoji)
                                    .font(.system(size: 27))
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(selection == entry.emoji ? Theme.accent.opacity(0.12) : Theme.subtleFill))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(selection == entry.emoji ? Theme.accent : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help(entry.keywords)
                            .accessibilityLabel(entry.keywords)
                            .accessibilityAddTraits(selection == entry.emoji ? .isSelected : [])
                        }
                    }
                }
            }
            .frame(height: 144)

            Divider()
            Text("自定义 Emoji").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("输入或粘贴一个 Emoji", text: $customEmoji)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyCustomEmoji() }
                Button("使用") { applyCustomEmoji() }
                    .disabled(!AppStore.isValidEmoji(customValue))
            }
            if !customValue.isEmpty && !AppStore.isValidEmoji(customValue) {
                Text("请输入一个 Emoji，支持肤色和组合表情。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 372)
    }

    private func applyCustomEmoji() {
        guard AppStore.isValidEmoji(customValue) else { return }
        select(customValue)
    }
}
