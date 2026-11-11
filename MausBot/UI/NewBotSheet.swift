import SwiftUI

struct NewBotSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建 Bot")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Bot 会运行在远程电脑上，这里只负责对话。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            TextField("名字，例如 编译器", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
                .focused($focused)
                .onSubmit(create)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if busy {
                        ProgressView().controlSize(.small).frame(width: 44)
                    } else {
                        Text("创建")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || busy)
            }
        }
        .padding(22)
        .onAppear { focused = true }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if await store.createBot(name: trimmed) != nil {
                dismiss()
            }
        }
    }
}
