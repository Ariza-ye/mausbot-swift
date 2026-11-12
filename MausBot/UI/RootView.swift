import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.computers.isEmpty {
                PairingView(onboarding: true)
            } else {
                MainView()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .background(Theme.windowBackground)
        .appFont()
        .sheet(isPresented: $store.showPairingSheet) {
            PairingView(onboarding: false)
                .frame(width: 520, height: 520)
        }
        .onChange(of: store.pendingInvite) { _, invite in
            if invite != nil, !store.computers.isEmpty { store.showPairingSheet = true }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.12, green: 0.53, blue: 0.24)
    static let accentBright = Color(red: 0.49, green: 0.91, blue: 0.53)
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var sidebarBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var cardBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var subtleFill: Color { Color.primary.opacity(0.05) }
    static var hairline: Color { Color.primary.opacity(0.09) }

    static func botColor(_ name: String) -> Color {
        switch name {
        case "blue": return Color(red: 0.22, green: 0.42, blue: 0.75)
        case "red": return Color(red: 0.72, green: 0.18, blue: 0.15)
        case "orange": return Color(red: 0.78, green: 0.43, blue: 0.06)
        case "purple": return Color(red: 0.43, green: 0.27, blue: 0.72)
        case "cyan": return Color(red: 0.02, green: 0.47, blue: 0.53)
        case "pink": return Color(red: 0.69, green: 0.16, blue: 0.45)
        case "yellow": return Color(red: 0.55, green: 0.44, blue: 0.02)
        case "teal": return Color(red: 0.04, green: 0.47, blue: 0.39)
        case "coral": return Color(red: 0.72, green: 0.30, blue: 0.20)
        case "silver": return Color(red: 0.42, green: 0.47, blue: 0.52)
        case "chrome": return Color(red: 0.28, green: 0.34, blue: 0.42)
        default: return Color(red: 0.12, green: 0.53, blue: 0.24)
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(search: $search)
                .navigationSplitViewColumnWidth(min: 248, ideal: 282, max: 360)
                .overlay(alignment: .trailing) {
                    SidebarResizeHandle(minWidth: 248, maxWidth: 360)
                        .frame(width: 12)
                }
        } detail: {
            VStack(spacing: 0) {
                noticeBar
                ZStack {
                    Theme.windowBackground
                    if let chat = store.open {
                        ChatView(chat: chat)
                            .id(chat.threadId)
                    } else {
                        emptyState
                    }
                }
                .overlay(alignment: .top) {
                    if let error = store.lastError {
                        ErrorBanner(message: error) { store.lastError = nil }
                            .padding(.top, 18)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $store.showNewBotSheet) {
            NewBotSheet()
                .frame(width: 380)
        }
        .sheet(isPresented: Binding(
            get: { store.settingsBotId != nil },
            set: { if !$0 { store.settingsBotId = nil } }
        )) {
            if let id = store.settingsBotId {
                BotSettingsSheet(botId: id)
                    .frame(width: 460)
            }
        }
    }

    @ViewBuilder
    private var noticeBar: some View {
        switch store.connection.phase {
        case .unauthorized:
            HStack(spacing: 10) {
                Image(systemName: "key.slash").foregroundStyle(.red)
                Text("这台电脑不再信任本设备。请在电脑上重新生成配对码。")
                    .appFont(size: 12)
                Spacer()
                Button("重新配对…") { store.showPairingSheet = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.red.opacity(0.08))
        case .error:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(store.connection.detail)
                    .appFont(size: 12)
                    .lineLimit(2)
                Spacer()
                Button("重新连接") { store.connect() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.08))
        default:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            MascotMark(size: 64)
                .opacity(0.9)
            Text("选择一个 Bot 开始")
                .appFont(size: 15, weight: .medium)
            Text("对话、审批和房间都在左侧。可以在左上角切换已配对的电脑。")
                .appFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}

struct ComputerEditSheet: View {
    let computer: SavedComputer
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var localName: String
    @State private var saveError: String?

    init(computer: SavedComputer) {
        self.computer = computer
        _localName = State(initialValue: computer.localName ?? "")
    }

    private var saved: SavedComputer {
        store.computers.first { $0.id == computer.id } ?? computer
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑电脑").appFont(size: 16, weight: .semibold)
                Spacer()
            }
            .padding(20)

            Form {
                Section {
                    TextField("本机备注", text: $localName, prompt: Text(saved.serverName))
                    LabeledContent("远程名称", value: saved.serverName)
                        .textSelection(.enabled)
                } header: {
                    Text("电脑名称")
                } footer: {
                    Text("备注仅在此 App 中显示，不会修改远程 OpenMausBot 的名称或配置。留空后使用远程名称。")
                }

                Section("已保存的连接方式") {
                    LabeledContent("通信方式", value: saved.e2e == nil ? "HTTP / HTTPS" : localized("端到端加密"))
                    ForEach(saved.routes) { route in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(routeName(route.kind))
                                Spacer()
                                if route.url == saved.activeURL {
                                    Text("上次使用")
                                        .appFont(size: 10.5)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(route.url)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let e2e = saved.e2e, e2e.routes != "local", let relays = e2e.r, !relays.isEmpty {
                        LabeledContent("中继服务") {
                            Text(relays.joined(separator: "\n"))
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let saveError {
                Text(saveError)
                    .appFont(size: 11.5)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try store.renameComputer(computer.id, localName: localName)
                        dismiss()
                    } catch {
                        saveError = localized("保存失败：%@", error.localizedDescription)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 540)
    }

    private func routeName(_ kind: EndpointKind) -> String {
        switch kind {
        case .lan: return localized("局域网直连")
        case .tailnet: return localized("Tailscale 直连")
        case .bonjour: return localized("Bonjour 本地发现")
        case .hosted: return localized("公网地址")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @AppStorage(AppFont.preferenceKey) private var fontFamily = ""
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.chinese.rawValue
    @State private var fontFamilies = AppFont.availableFamilies
    @State private var showPairing = false
    @State private var forgetId: String?
    @State private var editingComputer: SavedComputer?

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "slider.horizontal.3") }
            computers
                .tabItem { Label("电脑", systemImage: "desktopcomputer") }
            updates
                .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
            about
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 460)
        .appFont()
        .sheet(isPresented: $showPairing) {
            PairingView(onboarding: false)
                .frame(width: 520, height: 540)
        }
        .sheet(item: $editingComputer) { saved in
            ComputerEditSheet(computer: saved)
        }
        .confirmationDialog(
            "忘记这台电脑？",
            isPresented: Binding(get: { forgetId != nil }, set: { if !$0 { forgetId = nil } }),
            titleVisibility: .visible
        ) {
            Button("忘记并删除凭证", role: .destructive) {
                if let forgetId { store.forget(forgetId) }
                forgetId = nil
            }
            Button("取消", role: .cancel) { forgetId = nil }
        } message: {
            Text("钥匙串里的设备令牌会被删除；电脑上的设备列表仍保留这一项，可以在电脑上撤销。")
        }
    }

    private var general: some View {
        Form {
            Section("语言") {
                Picker("语言", selection: $language) {
                    ForEach(AppLanguage.allCases) { item in
                        Text(verbatim: item.label).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("外观") {
                Picker("主题", selection: $store.appearance) {
                    ForEach(AppAppearance.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Picker("字体", selection: $fontFamily) {
                        Text("系统默认").tag("")
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                        if !fontFamily.isEmpty, !fontFamilies.contains(fontFamily) {
                            Text("\(fontFamily)（不可用）").tag(fontFamily)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("还原字体") { fontFamily = "" }
                        .disabled(fontFamily.isEmpty)
                }
                Text("字体预览 · MausBot 0123456789")
                    .appFont(size: 13)
                    .foregroundStyle(.secondary)
                Toggle("Bot 回复时显示通知", isOn: $store.notificationBanners)
            }
            Section("连接状态") {
                HStack {
                    ConnectionPill(state: store.connection)
                    Spacer()
                    Text(store.connection.detail.isEmpty ? (store.computer?.displayName ?? "") : store.connection.detail)
                        .appFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Button("重新连接") { store.connect() }
                        .disabled(store.computer == nil)
                    Button("断开") { store.disconnect() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .onReceive(NotificationCenter.default.publisher(for: NSFont.fontSetChangedNotification)) { _ in
            fontFamilies = AppFont.availableFamilies
        }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.computers) { saved in
                        computerCard(saved)
                    }
                    if store.computers.isEmpty {
                        Text("还没有配对的电脑。")
                            .appFont(size: 12.5)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(14)
            }
            HStack {
                Button {
                    showPairing = true
                } label: {
                    Label("配对新的电脑…", systemImage: "plus")
                }
                Spacer()
                Text("\(store.computers.count) 台")
                    .appFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Rectangle().fill(.bar).overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            })
        }
    }

    private func computerCard(_ saved: SavedComputer) -> some View {
        let active = saved.id == store.computer?.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: active ? "desktopcomputer" : "externaldrive.connected.to.line.below")
                .appFont(size: 14)
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(saved.displayName)
                        .appFont(size: 13, weight: .medium)
                    if active {
                        Text("当前")
                            .appFont(size: 9.5, weight: .semibold)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                }
                Text(saved.displayAddress)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(saved.routes.count) 个地址 · 上次使用 \(relativeTime(saved.lastUsedAt))")
                    .appFont(size: 10.5)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !active {
                Button("连接") { store.select(saved.id) }
                    .controlSize(.small)
            }
            Button("编辑") { editingComputer = saved }
                .controlSize(.small)
            Button("忘记") { forgetId = saved.id }
                .controlSize(.small)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(active ? Theme.accent.opacity(0.28) : Theme.hairline, lineWidth: 1)
        )
    }

    private var updates: some View {
        Form {
            Section("软件更新") {
                Text("当前版本：\(AppInfo.version)")
                Toggle("自动检查更新", isOn: $updateChecker.automaticallyChecks)
                Picker("检查频率", selection: $updateChecker.interval) {
                    Text("每天").tag(UpdateChecker.Interval.daily)
                    Text("每周").tag(UpdateChecker.Interval.weekly)
                    Text("每 30 天").tag(UpdateChecker.Interval.monthly)
                }
                .disabled(!updateChecker.automaticallyChecks)
                HStack {
                    Button("检查更新") { Task { await updateChecker.check() } }
                        .disabled(updateChecker.isChecking)
                    if updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                        Text("正在检查更新…").foregroundStyle(.secondary)
                    } else if let result = updateChecker.result {
                        switch result {
                        case .upToDate:
                            Text("已是最新版本").foregroundStyle(.secondary)
                        case .available(let version):
                            Link(localized("发现新版本 %@", version), destination: UpdateChecker.releasesURL)
                        case .failed:
                            Text("检查更新失败，请稍后重试。").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private var about: some View {
        VStack(spacing: 12) {
            MascotMark(size: 62)
            Text("MausBot for macOS")
                .appFont(size: 17, weight: .semibold, design: .rounded)
            Text("版本 \(AppInfo.version)")
                .appFont(size: 11.5)
                .foregroundStyle(.secondary)
            Text("连接另一台电脑上的 OpenMausBot。智脑、工具和文件都留在那台电脑上，这里只负责配对、对话与审批。")
                .appFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 14) {
                Link("协议参考", destination: URL(string: "https://github.com/johnson020202/OpenMausBot/blob/android/native-companion-client/apps/android/docs/companion-protocol.md")!)
                Link("OpenMausBot", destination: URL(string: "https://github.com/johnson020202/OpenMausBot")!)
            }
            .appFont(size: 11.5)
            .padding(.top, 4)
            Text("配对凭证保存在登录钥匙串；所有请求走本机直连，不经过第三方。")
                .appFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
