import SwiftUI
import AppKit

struct MessageRow: View {
    let message: Message
    let threadId: String
    var showTime = false
    var isRoom = false
    var onPreview: (Attachment) -> Void = { _ in }

    @EnvironmentObject private var store: AppStore

    private var isUser: Bool { message.isUser }
    private var hasBubble: Bool {
        isUser || (message.isBot && message.tool == nil && message.card == nil)
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            if showTime {
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 2)
            }

            HStack(alignment: .top, spacing: 8) {
                if isUser { Spacer(minLength: 60) }

                VStack(alignment: .leading, spacing: 6) {
                    if isRoom, !isUser, let from = message.fromName {
                        Text(from)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.botColor(message.fromColor ?? "green"))
                    }

                    if let card = message.card, message.kind == "options" || card.needsAnswer || card.settled {
                        CardView(card: card, threadId: threadId)
                    } else if let tool = message.tool {
                        toolRow(tool)
                    } else if !message.text.isEmpty {
                        if isUser {
                            Text(message.text)
                                .font(.system(size: 13.5))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            MarkdownText(text: message.text)
                                .font(.system(size: 13.5))
                        }
                    }

                    if !message.attachments.isEmpty {
                        attachmentGrid
                    }

                    if message.pending {
                        Label("发送中…", systemImage: "clock")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    } else if message.failed {
                        Label("发送失败", systemImage: "exclamationmark.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, hasBubble ? 12 : 0)
                .padding(.vertical, hasBubble ? 8 : 0)
                .background(
                    Group {
                        if hasBubble {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isUser ? Theme.accent.opacity(0.11) : Theme.subtleFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isUser ? Theme.accent.opacity(0.18) : Theme.hairline, lineWidth: 1)
                                )
                        }
                    }
                )
                .frame(maxWidth: isUser ? 560 : 620, alignment: isUser ? .trailing : .leading)

                if !isUser { Spacer(minLength: 40) }
            }
        }
        .opacity(message.pending ? 0.75 : 1)
    }

    private func toolRow(_ tool: ToolRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: tool.ok ? "wrench.and.screwdriver" : "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
                Text(tool.label ?? tool.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
            }
            .foregroundStyle(tool.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            if let detail = tool.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var attachmentGrid: some View {
        let images = message.attachments.filter(\.isImage)
        let files = message.attachments.filter { !$0.isImage }
        return VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images) { attachment in
                        RemoteImage(path: attachment.path, contentMode: .fit)
                            .frame(width: 180, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Theme.hairline, lineWidth: 1)
                            )
                            .onTapGesture { onPreview(attachment) }
                    }
                }
            }
            ForEach(files) { attachment in
                Button {
                    Task {
                        do {
                            let data = try await store.download(attachment, threadId: threadId, messageId: message.id)
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = attachment.name ?? URL(fileURLWithPath: attachment.path).lastPathComponent
                            guard await panel.begin() == .OK, let url = panel.url else { return }
                            try data.write(to: url, options: .atomic)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isAudio ? "waveform" : "arrow.down.document")
                        Text(attachment.name ?? URL(fileURLWithPath: attachment.path).lastPathComponent)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

struct TranscriptEntry: Identifiable {
    var messages: [Message]
    let showTime: Bool
    var id: String { messages[0].id }

    static func group(_ messages: [Message]) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        for (index, message) in messages.enumerated() {
            let showTime = index == 0 || message.createdAt.timeIntervalSince(messages[index - 1].createdAt) > 300
            if isActivity(message), !showTime,
               let previous = entries.last?.messages.last,
               isActivity(previous), previous.turnId == message.turnId,
               previous.fromName == message.fromName, previous.fromColor == message.fromColor {
                entries[entries.count - 1].messages.append(message)
            } else {
                entries.append(TranscriptEntry(messages: [message], showTime: showTime))
            }
        }
        return entries
    }

    static func isActivity(_ message: Message) -> Bool {
        !message.isUser && message.tool != nil && message.card == nil && message.attachments.isEmpty
    }
}

struct TranscriptMessages: View {
    let messages: [Message]
    let threadId: String
    var isRoom = false
    var onPreview: (Attachment) -> Void = { _ in }

    var body: some View {
        ForEach(TranscriptEntry.group(messages)) { entry in
            if TranscriptEntry.isActivity(entry.messages[0]) {
                ToolActivityGroup(messages: entry.messages, threadId: threadId, showTime: entry.showTime, isRoom: isRoom)
            } else {
                MessageRow(message: entry.messages[0], threadId: threadId, showTime: entry.showTime, isRoom: isRoom, onPreview: onPreview)
            }
        }
    }
}

private struct ToolActivityGroup: View {
    let messages: [Message]
    let threadId: String
    let showTime: Bool
    let isRoom: Bool
    @State private var expanded = false

    private var summary: String {
        var names: [String] = []
        var counts: [String: Int] = [:]
        for message in messages {
            guard let tool = message.tool else { continue }
            let name = tool.name.isEmpty ? (tool.label ?? "工具") : tool.name
            if counts[name] == nil { names.append(name) }
            counts[name, default: 0] += 1
        }
        return names.map { "\($0) ×\(counts[$0, default: 0])" }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showTime, let first = messages.first {
                Text(first.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            if isRoom, let from = messages.first?.fromName {
                Text(from)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.botColor(messages.first?.fromColor ?? "green"))
            }
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.3.layers.3d")
                    Text("活动").fontWeight(.medium)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    let failures = messages.filter { $0.tool?.ok == false }.count
                    if failures > 0 {
                        Text("\(failures) 项失败").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("活动，\(messages.count) 次工具调用")
            .accessibilityValue(expanded ? "已展开" : "已收起")

            if expanded {
                ForEach(messages) { message in
                    MessageRow(message: message, threadId: threadId)
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardView: View {
    let card: Card
    let threadId: String
    @EnvironmentObject private var store: AppStore
    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(card.isApproval ? .orange : Theme.accent)
                Text(card.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tool = card.tool, !tool.isEmpty {
                Text(tool)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let held = card.held, !held.isEmpty {
                Text(held)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if card.needsAnswer {
                if !card.options.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(card.options, id: \.self) { option in
                            optionButton(option)
                        }
                    }
                }
                if card.isQuestion {
                    HStack(spacing: 6) {
                        TextField("或直接输入回答", text: $freeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                            .onSubmit(submitFreeText)
                        Button("发送", action: submitFreeText)
                            .font(.system(size: 11.5, weight: .medium))
                            .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if card.allowKey != nil, canAlwaysAllow {
                    Button {
                        store.alwaysAllow(threadId: threadId, card: card)
                    } label: {
                        Label("始终允许", systemImage: "checkmark.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: settledIcon)
                        .font(.system(size: 10))
                    Text(settledText)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(card.needsAnswer ? (card.isApproval ? Color.orange.opacity(0.35) : Theme.accent.opacity(0.32)) : Theme.hairline, lineWidth: 1)
        )
    }

    private var icon: String {
        if card.isApproval { return "checkmark.shield" }
        if card.isQuestion { return "questionmark.bubble" }
        return "list.bullet.rectangle"
    }

    private var settledIcon: String {
        if card.expired || card.stopped { return "clock.badge.xmark" }
        return "checkmark.circle"
    }

    private var settledText: String {
        if card.expired { return "已过期" }
        if card.stopped { return "已停止" }
        if card.dismissed { return "已忽略" }
        if let text = card.answeredText, !text.isEmpty { return "已回复：\(text)" }
        if let answered = card.answered, !answered.isEmpty {
            switch answered {
            case "allow": return "已允许"
            case "deny": return "已拒绝"
            case "answer": return "已回答"
            default: return "已处理：\(answered)"
            }
        }
        return "已处理"
    }

    private func optionButton(_ option: String) -> some View {
        let behavior = Card.behavior(for: option)
        let primary = behavior == "allow"
        return Button {
            store.respond(threadId: threadId, card: card, answer: option)
        } label: {
            Text(option)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(primary ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(primary ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func submitFreeText() {
        let answer = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        store.respond(threadId: threadId, card: card, answer: answer)
        freeText = ""
    }

    /// Remembered grants are per bot; a room card without a matching bot has
    /// no door to offer them through.
    private var canAlwaysAllow: Bool {
        store.bots.contains { $0.threadId == threadId || $0.tasks.contains { $0.threadId == threadId } }
    }
}
