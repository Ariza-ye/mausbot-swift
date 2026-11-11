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
                .padding(.horizontal, isUser ? 12 : 0)
                .padding(.vertical, isUser ? 8 : 0)
                .background(
                    Group {
                        if isUser {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.accent.opacity(0.11))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                                )
                        }
                    }
                )
                .frame(maxWidth: isUser ? 560 : 620, alignment: .leading)

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
                    .lineLimit(3)
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
                        RemoteImage(path: attachment.path)
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
