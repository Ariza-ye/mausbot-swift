import SwiftUI

enum SidebarNewItem: String, Identifiable {
    case section, group
    var id: String { rawValue }
}

struct SidebarNewItemSheet: View {
    let item: SidebarNewItem
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var bots: [Bot] { store.bots.filter { !$0.hidden } }
    private var canCreate: Bool {
        !busy && (item == .section ? !trimmed.isEmpty && trimmed.utf16.count <= 60 : !selected.isEmpty && trimmed.utf16.count <= 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized(item == .section ? "添加区段" : "新建群组"))
                .appFont(size: 18, weight: .semibold, design: .rounded)
            TextField(localized(item == .section ? "区段名称" : "群组名称（选填）"), text: $name)
                .textFieldStyle(.plain)
                .appFont(size: 13)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
                .focused($focused)

            Text(localized(item == .section ? "选择机器人（选填）" : "选择群组中的机器人"))
                .appFont(size: 12, weight: .medium)
            if bots.isEmpty {
                Text("还没有可选择的机器人")
                    .appFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(bots) { bot in
                            Toggle(isOn: Binding(
                                get: { selected.contains(bot.id) },
                                set: { checked in
                                    if checked { selected.insert(bot.id) } else { selected.remove(bot.id) }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    AvatarView(name: bot.name, color: bot.color, url: bot.avatarUrl, size: 28, emoji: store.emoji(for: bot.id))
                                    Text(bot.name).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SlimScrollbar())
                }
                .frame(height: min(CGFloat(bots.count) * 36, 180))
            }
            if let error {
                Text(error).appFont(size: 11.5).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if busy { ProgressView().controlSize(.small).frame(width: 44) }
                    else { Text("创建") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(22)
        .onAppear { focused = true }
    }

    private func create() {
        guard canCreate else { return }
        busy = true
        error = nil
        let ids = bots.filter { selected.contains($0.id) }.map(\.id)
        Task {
            defer { busy = false }
            do {
                if item == .section {
                    try await store.createSection(name: trimmed, botIds: ids)
                } else {
                    try await store.createGroup(name: trimmed, memberIds: ids)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
