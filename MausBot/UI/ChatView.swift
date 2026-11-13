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
    @State private var userScrolling = false
    @State private var scrollRequest = 0
    @State private var showLocationPicker = false
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
        guard let bot else { return false }
        return bot.busy || messages.contains { $0.role == "user" && $0.pending }
    }

    var body: some View {
        transcript
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .background(Theme.windowBackground)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let bot {
                    modelMenu(bot)
                        .padding(.leading, 8)
                    tasksMenu(bot)
                }
                moreMenu
                    .padding(.trailing, 8)
            }
        }
        .sheet(item: $preview) { attachment in
            AttachmentPreview(attachment: attachment)
        }
    }

    // MARK: - Toolbar

    private func modelMenu(_ bot: Bot) -> some View {
        let selection = bot.task(threadId: chat.threadId)?.modelSelection ?? bot.modelSelection
        return Menu {
            if store.instances.isEmpty {
                Text("没有可用的模型")
            }
            ForEach(store.instances.filter(\.enabled)) { instance in
                Section(instance.name) {
                    ForEach(instance.models) { model in
                        Button {
                            store.setModel(
                                botId: bot.id,
                                threadId: chat.threadId,
                                selection: ModelSelection(
                                    instanceId: instance.instanceId,
                                    model: model.id,
                                    effort: selection?.effort
                                )
                            )
                        } label: {
                            if selection?.instanceId == instance.instanceId,
                               selection?.model == model.id {
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
                ProviderIcon(selection: selection, instances: store.instances)
                Text(shortModelName(selection))
                    .appFont(size: 11.5, weight: .medium)
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
        .help("切换当前对话的模型")
    }

    private func tasksMenu(_ bot: Bot) -> some View {
        Menu {
            ForEach(bot.tasks) { task in
                Button {
                    store.open(bot: bot, threadId: task.threadId)
                } label: {
                    if task.threadId == chat.threadId {
                        Label(task.title.isEmpty ? localized("未命名对话") : task.title, systemImage: "checkmark")
                    } else {
                        Text(task.title.isEmpty ? localized("未命名对话") : task.title)
                    }
                }
            }
            Divider()
            Button("新对话") {
                Task { await store.newThread(botId: bot.id) }
            }
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换对话")
    }

    private func shortModelName(_ selection: ModelSelection?) -> String {
        guard let selection else { return localized("模型") }
        let instance = store.instances.first { $0.instanceId == selection.instanceId }
        return instance?.models.first { $0.id == selection.model }?.label ?? selection.model
    }

    private var moreMenu: some View {
        Menu {
            if let bot {
                Button("Bot 设置…") { store.settingsBotId = bot.id }
                Button(localized(bot.pinned ? "取消置顶" : "置顶")) {
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
                        panel.nameFieldStringValue = localized("对话.md")
                        guard await panel.begin() == .OK, let url = panel.url else { return }
                        try data.write(to: url, options: .atomic)
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .appFont(size: 12, weight: .semibold)
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
                            .appFont(size: 11.5)
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
                            bot: bot,
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
                .background(SlimScrollbar())
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 96
            } action: { _, nearBottom in
                if userScrolling { atBottom = nearBottom }
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .idle {
                    if userScrolling {
                        let geometry = context.geometry
                        atBottom = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 96
                    }
                    userScrolling = false
                } else if phase == .tracking || phase == .interacting || phase == .decelerating {
                    userScrolling = true
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                guard atBottom, !userScrolling else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: messages.last?.id) { _, _ in
                guard atBottom, !userScrolling else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: scrollRequest) { _, _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: chat.threadId) { _, _ in
                atBottom = true
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
                .appFont(size: 22, weight: .light)
                .foregroundStyle(.tertiary)
            Text(bot == nil ? localized("房间还没有消息") : localized("和 %@ 说点什么", bot?.name ?? "Bot"))
                .appFont(size: 12.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let attachment {
                    attachmentChip(attachment)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "paperclip")
                            .appFont(size: 17, weight: .regular)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(group != nil || uploading)
                    .opacity(group == nil && !uploading ? 1 : 0.4)
                    .help(localized(group == nil ? "附加图片" : "房间里只发送文字"))
                    .accessibilityLabel("附加图片")

                    if let bot {
                        workLocationPicker(bot)
                    }

                    TextField(
                        "",
                        text: $draft,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .appFont(size: 14)
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .focused($composerFocused)
                    .accessibilityLabel("消息输入框")

                    if uploading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 36)
                    }

                    if busy {
                        Button {
                            store.interrupt()
                        } label: {
                            Image(systemName: "stop.fill")
                                .appFont(size: 13, weight: .semibold)
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.accent))
                                .frame(height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("打断本轮回复")
                        .accessibilityLabel("打断本轮回复")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .appFont(size: 14, weight: .semibold)
                                .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.5))
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(canSend ? Theme.accent : Color.primary.opacity(0.06)))
                                .frame(height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("发送（⌘↩）")
                        .accessibilityLabel("发送消息")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(ComposerSurface())
            .overlay(alignment: .topLeading) {
                if busy {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(localized(bot?.busy == true ? "正在想办法…" : "正在发送…"))
                            .appFont(size: 11.5, weight: .medium)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    .offset(x: 12, y: -32)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
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
            if let input = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
               input.hasMarkedText() {
                return .ignored
            }
            if press.modifiers.contains(.shift) {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return .handled
            }
            send()
            return .handled
        }
    }

    private var canSend: Bool {
        !store.updatingLocations.contains(chat.threadId)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
    }

    private func workLocationPicker(_ bot: Bot) -> some View {
        let task = bot.task(threadId: chat.threadId)
        let location = bot.computer == .off ? WorkLocation.off : (task?.surface ?? bot.computer ?? .auto)
        let updating = store.updatingLocations.contains(chat.threadId)
        let busy = task?.busy == true || messages.contains { $0.isUser && $0.pending }
        return Button {
            showLocationPicker = true
        } label: {
            HStack(spacing: 5) {
                if updating {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: locationIcon(location))
                }
                Text(locationLabel(location))
                    .lineLimit(1)
            }
            .appFont(size: 11.5, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.connection.isOnline || task == nil || busy || updating || bot.computer == .off)
        .help(localized(busy ? "请等待当前对话完成后切换运行位置" : "选择此对话的运行位置"))
        .accessibilityLabel(localized("运行位置：%@", locationLabel(location)))
        .popover(isPresented: $showLocationPicker, arrowEdge: .bottom) {
            workLocationMenu(bot)
        }
    }

    private func workLocationMenu(_ bot: Bot) -> some View {
        let task = bot.task(threadId: chat.threadId)
        let pin = task?.pinnedLocation
        let defaultLocation = bot.computer ?? .auto
        let selection = task?.modelSelection ?? bot.modelSelection
        let instance = store.instances.first { $0.instanceId == selection?.instanceId }
        let config = store.workLocationConfig ?? WorkLocationConfig(json: [:])
        return VStack(alignment: .leading, spacing: 3) {
            Text("此对话的运行位置")
                .appFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            workLocationRow(
                bot: bot,
                location: nil,
                title: defaultLocation == .auto ? localized("自动") : localized("跟随 Bot 设置"),
                detail: defaultLocation == .auto ? localized("为每项任务选择合适的位置") : localized("当前：%@", locationLabel(defaultLocation)),
                icon: locationIcon(defaultLocation),
                selected: pin == nil
            )
            ForEach(WorkLocation.choices, id: \.rawValue) { location in
                let reason = config.unavailableReason(for: location, bot: bot, instance: instance)
                workLocationRow(
                    bot: bot,
                    location: location,
                    title: locationLabel(location),
                    detail: reason ?? locationDetail(location),
                    icon: locationIcon(location),
                    selected: pin == location,
                    disabled: reason != nil
                )
            }
        }
        .padding(8)
        .frame(width: 300)
    }

    private func workLocationRow(bot: Bot, location: WorkLocation?, title: String, detail: String,
                                 icon: String, selected: Bool, disabled: Bool = false) -> some View {
        Button {
            showLocationPicker = false
            guard bot.task(threadId: chat.threadId)?.pinnedLocation != location else { return }
            store.setWorkLocation(botId: bot.id, threadId: chat.threadId, location: location)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(size: 12.5, weight: .medium)
                    Text(detail).appFont(size: 11).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func locationLabel(_ location: WorkLocation) -> String {
        switch location {
        case .auto: return localized("自动")
        case .cloud: return localized("云端桌面")
        case .vm: return localized("私有桌面")
        case .local: return localized("配对电脑")
        case .browser: return localized("浏览器")
        case .off: return localized("已关闭")
        case .unknown: return localized("未知位置")
        }
    }

    private func locationIcon(_ location: WorkLocation) -> String {
        switch location {
        case .auto: return "sparkles"
        case .cloud: return "cloud"
        case .vm: return "shippingbox"
        case .local: return "desktopcomputer"
        case .browser: return "globe"
        case .off: return "display.slash"
        case .unknown: return "questionmark.circle"
        }
    }

    private func locationDetail(_ location: WorkLocation) -> String {
        switch location {
        case .cloud: return localized("云端中的桌面")
        case .vm: return localized("配对电脑上隔离的桌面")
        case .local: return localized("配对电脑的屏幕和应用")
        case .browser: return localized("仅限网页")
        default: return ""
        }
    }

    private func attachmentChip(_ attachment: Attachment) -> some View {
        HStack(spacing: 8) {
            RemoteImage(path: attachment.path)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(attachment.name ?? localized("图片"))
                .appFont(size: 11.5)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Button {
                self.attachment = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .appFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func send() {
        guard canSend, !busy else { return }
        let attached = attachment.map { [$0] } ?? []
        atBottom = true
        store.send(text: draft, attachments: attached)
        draft = ""
        attachment = nil
        scrollRequest += 1
    }
}

private struct ComposerSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attachment.name ?? localized("图片"))
                    .appFont(size: 13, weight: .medium)
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
