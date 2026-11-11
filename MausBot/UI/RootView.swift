import SwiftUI

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
                if let error = store.lastError {
                    VStack {
                        Spacer()
                        ErrorBanner(message: error) { store.lastError = nil }
                    }
                    .padding(.bottom, 18)
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
                    .font(.system(size: 12))
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
                    .font(.system(size: 12))
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
                .font(.system(size: 15, weight: .medium))
            Text("对话、审批和房间都在左侧。可以在左上角切换已配对的电脑。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showPairing = false
    @State private var forgetId: String?

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "slider.horizontal.3") }
            computers
                .tabItem { Label("电脑", systemImage: "desktopcomputer") }
            about
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 460)
        .sheet(isPresented: $showPairing) {
            PairingView(onboarding: false)
                .frame(width: 520, height: 540)
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
            Section("外观") {
                Picker("主题", selection: $store.appearance) {
                    ForEach(AppAppearance.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Bot 回复时显示通知", isOn: $store.notificationBanners)
            }
            Section("连接") {
                HStack {
                    ConnectionPill(state: store.connection)
                    Spacer()
                    Text(store.connection.detail.isEmpty ? (store.computer?.serverName ?? "") : store.connection.detail)
                        .font(.system(size: 11.5))
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
                            .font(.system(size: 12.5))
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
                    .font(.system(size: 11))
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
                .font(.system(size: 14))
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(saved.serverName)
                        .font(.system(size: 13, weight: .medium))
                    if active {
                        Text("当前")
                            .font(.system(size: 9.5, weight: .semibold))
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
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !active {
                Button("连接") { store.select(saved.id) }
                    .controlSize(.small)
            }
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

    private var about: some View {
        VStack(spacing: 12) {
            MascotMark(size: 62)
            Text("MausBot for macOS")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("版本 \(AppInfo.version)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Text("连接另一台电脑上的 OpenMausBot。智脑、工具和文件都留在那台电脑上，这里只负责配对、对话与审批。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 14) {
                Link("协议参考", destination: URL(string: "https://github.com/johnson020202/OpenMausBot/blob/android/native-companion-client/apps/android/docs/companion-protocol.md")!)
                Link("OpenMausBot", destination: URL(string: "https://github.com/johnson020202/OpenMausBot")!)
            }
            .font(.system(size: 11.5))
            .padding(.top, 4)
            Text("配对凭证保存在登录钥匙串；所有请求走本机直连，不经过第三方。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
