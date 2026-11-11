import SwiftUI

struct BotSettingsSheet: View {
    let botId: String
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loadedName = ""

    private var bot: Bot? {
        store.bots.first { $0.id == botId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let bot {
                    AvatarView(name: bot.name, color: bot.color, url: bot.avatarUrl, size: 36)
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
