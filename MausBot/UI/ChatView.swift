import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ChatView: View {
    let chat: OpenChat
    @EnvironmentObject private var store: AppStore
    @State private var draft = ""
    @State private var attachment: Attachment?
    @State private var uploading = false
    @State private var showImporter = false
    @State private var preview: Attachment?
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool

    private let bottomID = "conversation-bottom"

    private var bot: Bot? {
        guard case .bot(let id) = chat.target else { return nil }
        return store.bots.first { $0.id == id }
    }

    private var group: ChatGroup? {
        guard case .group(let id) = chat.target else { return nil }
        return store.groups.first { $0.id == id }
    }

    private var thread: ThreadState {
        store.threads[chat.threadId] ?? ThreadState()
    }

    private var messages: [Message] { thread.messages.filter { !$0.isDigest } }

    private var busy: Bool {
        if let bot { return bot.busy }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .background(Theme.windowBackground)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let bot {
                    modelMenu(bot)
                    tasksMenu(bot)
                }
                if busy {
                    IconAction(systemName: "stop.circle.fill", help: "停止本轮", tint: .secondary) {
                        store.interrupt()
                    }
                }
                moreMenu
            }
        }
        .sheet(item: $preview) { attachment in
            AttachmentPreview(attachment: attachment)
        }
    }

    // MARK: - Toolbar

    private func modelMenu(_ bot: Bot) -> some View {
        Menu {
            if store.instances.isEmpty {
                Text("没有可用的模型")
            }
            ForEach(store.instances.filter(\.enabled)) { instance in
                Section(instance.name) {
                    ForEach(instance.models) { model in
                        Button {
                            store.setModel(
                                botId: bot.id,
                                selection: ModelSelection(
                                    instanceId: instance.instanceId,
                                    model: model.id,
                                    effort: bot.modelSelection?.effort
                                )
                            )
                        } label: {
                            if bot.modelSelection?.instanceId == instance.instanceId,
                               bot.modelSelection?.model == model.id {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("刷新模型列表") {
                Task { await store.loadInstances() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .medium))
                Text(shortModelName(bot))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换这个 Bot 的模型")
    }

    private func tasksMenu(_ bot: Bot) -> some View {
        Menu {
            ForEach(bot.tasks) { task in
                Button {
                    store.open(bot: bot, threadId: task.threadId)
                } label: {
                    if task.threadId == chat.threadId {
                        Label(task.title.isEmpty ? "未命名对话" : task.title, systemImage: "checkmark")
                    } else {
                        Text(task.title.isEmpty ? "未命名对话" : task.title)
                    }
                }
            }
            Divider()
            Button("新对话") {
                Task { await store.newThread(botId: bot.id) }
            }
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换对话")
    }

    private func shortModelName(_ bot: Bot) -> String {
        guard let selection = bot.modelSelection else { return "模型" }
        let instance = store.instances.first { $0.instanceId == selection.instanceId }
        return instance?.models.first { $0.id == selection.model }?.label ?? selection.model
    }

    private var moreMenu: some View {
        Menu {
            if let bot {
                Button("Bot 设置…") { store.settingsBotId = bot.id }
                Button(bot.pinned ? "取消置顶" : "置顶") {
                    store.patchBot(botId: bot.id, fields: ["pinned": !bot.pinned])
                }
            }
            Button("标记已读") { store.markRead(chat.threadId) }
            Button("导出对话…") {
                Task {
                    do {
                        let data = try await store.exportThread(chat.threadId)
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.plainText]
                        panel.nameFieldStringValue = "对话.md"
                        guard await panel.begin() == .OK, let url = panel.url else { return }
                        try data.write(to: url, options: .atomic)
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if thread.hasMore, !messages.isEmpty {
                        Button {
                            Task { await store.loadOlder(chat.threadId) }
                        } label: {
                            HStack(spacing: 5) {
                                if thread.loading { ProgressView().controlSize(.mini) }
                                Text("加载更早的消息")
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                    }

                    if messages.isEmpty {
                        if thread.loading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else {
                            emptyConversation
                        }
                    } else {
                        TranscriptMessages(
                            messages: messages,
                            threadId: chat.threadId,
                            isRoom: group != nil,
                            onPreview: { preview = $0 }
                        )
                    }

                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 96
            } action: { _, nearBottom in
                atBottom = nearBottom
            }
            .onChange(of: messages.last?.id) { _, _ in
                guard atBottom else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: chat.threadId) { _, _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(bot == nil ? "房间还没有消息" : "和 \(bot?.name ?? "Bot") 说点什么")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                if let attachment {
                    attachmentChip(attachment)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    IconAction(systemName: "paperclip", help: group == nil ? "附加图片" : "房间里只发送文字", tint: Color.secondary.opacity(group == nil ? 1 : 0.4)) {
                        guard group == nil else { return }
                        showImporter = true
                    }
                    .disabled(group != nil || uploading)

                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(group == nil ? "发消息给 \(chat.title)" : "发消息到房间")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 7)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draft)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .frame(height: editorHeight)
                            .focused($composerFocused)
                    }

                    if uploading {
                        ProgressView().controlSize(.small)
                    }

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(canSend ? Theme.accent : Color.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("发送（⌘↩）")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.bar)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            uploading = true
            Task {
                defer { uploading = false }
                do {
                    attachment = try await store.uploadImage(from: url)
                } catch {
                    store.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .onKeyPress(phases: .down) { press in
            guard press.key == .return, composerFocused else { return .ignored }
            if press.modifiers.contains(.shift) { return .ignored }
            send()
            return .handled
        }
    }

    private var editorHeight: CGFloat {
        let lines = max(1, draft.components(separatedBy: "\n").count)
        return min(132, CGFloat(lines) * 17 + 18)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil
    }

    private func attachmentChip(_ attachment: Attachment) -> some View {
        HStack(spacing: 8) {
            RemoteImage(path: attachment.path)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(attachment.name ?? "图片")
                .font(.system(size: 11.5))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Button {
                self.attachment = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func send() {
        guard canSend else { return }
        let attached = attachment.map { [$0] } ?? []
        store.send(text: draft, attachments: attached)
        draft = ""
        attachment = nil
        atBottom = true
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attachment.name ?? "图片")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            RemoteImage(path: attachment.path, contentMode: .fit)
                .frame(minWidth: 420, minHeight: 320)
                .padding(12)
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}
