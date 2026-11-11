import AppKit
import SwiftUI

struct SidebarResizeHandle: NSViewRepresentable {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        SidebarResizeHandleView(minWidth: minWidth, maxWidth: maxWidth)
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {}
}

final class SidebarResizeHandleView: NSView {
    private let minWidth: CGFloat
    private let maxWidth: CGFloat

    init(minWidth: CGFloat, maxWidth: CGFloat) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical, split.subviews.count > 1,
               let window {
                let startX = split.convert(event.locationInWindow, from: nil).x
                let startWidth = split.subviews[0].frame.width
                while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    if next.type == .leftMouseUp { break }
                    let delta = split.convert(next.locationInWindow, from: nil).x - startX
                    let width = min(maxWidth, max(minWidth, startWidth + delta))
                    split.setPosition(width, ofDividerAt: 0)
                }
                return
            }
            ancestor = view.superview
        }
        super.mouseDown(with: event)
    }
}

struct RemoteImage: View {
    let path: String
    var contentMode: ContentMode = .fill
    @EnvironmentObject private var store: AppStore
    @State private var image: NSImage?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let loadError {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06))
                }
                .buttonStyle(.plain)
                .help("图片加载失败：\(loadError)。点击重试")
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
        }
        .task(id: path) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        image = nil
        loadError = nil
        do {
            let data = try await store.imageData(path: path)
            try Task.checkCancellation()
            guard let decoded = NSImage(data: data) else {
                loadError = "无法识别图片格式"
                return
            }
            image = decoded
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct AvatarView: View {
    let name: String
    let color: String
    var url: String?
    var size: CGFloat = 34

    private var initial: String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.botColor(color), Theme.botColor(color).opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let url, !url.isEmpty {
                RemoteImage(path: url)
                    .clipShape(Circle())
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: Theme.botColor(color).opacity(0.22), radius: 2, y: 1)
    }
}

struct ConnectionPill: View {
    let state: ConnectionState

    private var tone: Color {
        switch state.phase {
        case .online: return .green
        case .connecting, .offline: return .orange
        case .error, .unauthorized: return .red
        case .idle: return .secondary
        }
    }

    private var label: String {
        switch state.phase {
        case .online: return "已连接"
        case .connecting: return "连接中"
        case .offline: return "重连中"
        case .error: return "出错"
        case .unauthorized: return "需重新配对"
        case .idle: return "未连接"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone)
                .frame(width: 7, height: 7)
                .shadow(color: tone.opacity(0.7), radius: 3)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .help(state.detail.isEmpty ? label : state.detail)
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .task(id: message) {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            onDismiss()
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

struct HoverRow<Content: View>: View {
    var selected = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
    }
}

struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 7, height: 7)
    }
}

struct BusySpinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.7)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct IconAction: View {
    let systemName: String
    var help = ""
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.001))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

func relativeTime(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "刚刚" }
    if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return formatter.string(from: date)
}
