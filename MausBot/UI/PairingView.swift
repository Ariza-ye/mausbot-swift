import SwiftUI

struct PairingView: View {
    let onboarding: Bool
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if onboarding {
            HStack(spacing: 0) {
                brandPanel
                    .frame(width: 330)
                formPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.windowBackground)
            }
        } else {
            formPanel
                .padding(26)
                .background(Theme.windowBackground)
        }
    }

    private var brandPanel: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.16, blue: 0.10),
                    Color(red: 0.03, green: 0.09, blue: 0.07),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Theme.accent.opacity(0.35), .clear],
                center: .init(x: 0.5, y: 0.32),
                startRadius: 10,
                endRadius: 260
            )
            VStack(alignment: .leading, spacing: 0) {
                MascotMark(size: 104)
                    .padding(.bottom, 26)
                Text("MausBot")
                    .appFont(size: 30, weight: .semibold, design: .rounded)
                    .foregroundStyle(.white)
                Text("macOS 桌面客户端")
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 4)
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    brandPoint("link", "直连你自己的电脑")
                    brandPoint("lock.shield", "配对凭证只保存在本机钥匙串")
                    brandPoint("bolt.horizontal", "对话、审批、房间全部可用")
                }
                .padding(.bottom, 8)
            }
            .padding(34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func brandPoint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.accentBright)
                .frame(width: 16)
            Text(text)
                .appFont(size: 12.5)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var formPanel: some View {
        PairingForm(onboarding: onboarding) {
            if onboarding {
                // The root view swaps to the conversation list by itself.
            } else {
                dismiss()
            }
        }
    }
}

private struct PairingForm: View {
    let onboarding: Bool
    let onPaired: () -> Void

    @EnvironmentObject private var store: AppStore
    @State private var mode: Mode = .link
    @State private var link = ""
    @State private var address = ""
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Mode: String, CaseIterable, Identifiable {
        case link, code
        var id: String { rawValue }
        var label: String { self == .link ? "配对链接" : "地址和配对码" }
    }

    private enum Field { case link, address, code }

    private var parsedInvite: PairingInvite? {
        PairingInvite.parse(link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !onboarding {
                HStack {
                    Text("配对一台电脑")
                        .appFont(size: 20, weight: .semibold, design: .rounded)
                    Spacer()
                    Button {
                        dismissSheet()
                    } label: {
                        Image(systemName: "xmark")
                            .appFont(size: 11, weight: .bold)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 18)
            } else {
                Text("连接你的电脑")
                    .appFont(size: 26, weight: .semibold, design: .rounded)
                Text("配对码由另一台电脑上的 OpenMausBot 生成。这台 Mac 只作为客户端。")
                    .appFont(size: 13)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 22)
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, _ in focus = mode == .link ? .link : .address }

            Group {
                if mode == .link {
                    linkFields
                } else {
                    codeFields
                }
            }
            .padding(.top, 16)

            if !store.pairing.routes.isEmpty {
                probeList
                    .padding(.top, 14)
            }

            if let error {
                Text(error)
                    .appFont(size: 12)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            if onboarding {
                pairButton
                    .padding(.top, 24)
                Text("电脑需要已登录并开启“远程访问”。")
                    .appFont(size: 11.5)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            } else {
                pairButton
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: 430, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onboarding ? .center : .topLeading)
        .padding(onboarding ? 40 : 0)
        .task {
            if let invite = store.pendingInvite {
                link = invite.shareLink
                mode = .link
            }
            focus = .link
        }
        .onChange(of: store.pendingInvite) { _, invite in
            if let invite {
                link = invite.shareLink
                mode = .link
            }
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("粘贴电脑上生成的 openmausbot:// 链接")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            TextField("openmausbot://pair?address=…", text: $link, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...4)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.subtleFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(focus == .link ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
                )
                .focused($focus, equals: .link)
                .onSubmit(submit)

            if let invite = parsedInvite {
                Label("\(invite.serverName) · \(invite.primary?.displayAddress ?? "")", systemImage: "checkmark.seal")
                    .appFont(size: 11.5)
                    .foregroundStyle(Theme.accent)
            } else if !link.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("还不能识别这个链接")
                    .appFont(size: 11.5)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var codeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("电脑地址")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                TextField("192.168.1.8:8787", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(focus == .address ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
                    )
                    .focused($focus, equals: .address)
                    .onSubmit { focus = .code }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("6 位配对码")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                TextField("123456", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(focus == .code ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
                    )
                    .focused($focus, equals: .code)
                    .onSubmit(submit)
            }
            Text("没写端口时，会依次尝试 8787 和 8810。")
                .appFont(size: 11)
                .foregroundStyle(.tertiary)
        }
    }

    private var probeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.pairing.routes) { route in
                HStack(spacing: 7) {
                    probeIcon(route.state)
                        .frame(width: 12)
                    Text(route.address)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(probeLabel(route.state))
                        .appFont(size: 11)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
    }

    @ViewBuilder
    private func probeIcon(_ state: RouteProbe.State) -> some View {
        switch state {
        case .waiting:
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
        case .connecting:
            BusySpinner()
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 11))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.8)).font(.system(size: 11))
        }
    }

    private func probeLabel(_ state: RouteProbe.State) -> String {
        switch state {
        case .waiting: return "等待"
        case .connecting: return "连接中"
        case .ok: return "可用"
        case .failed: return "失败"
        }
    }

    private var pairButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                }
                Text(busy ? "正在配对…" : "配对这台电脑")
                    .appFont(size: 13, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(canSubmit ? Theme.accent : Color.primary.opacity(0.12))
            )
            .foregroundStyle(canSubmit ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || busy)
    }

    private var canSubmit: Bool {
        if mode == .link {
            return parsedInvite != nil || store.pendingInvite != nil
        }
        return !address.trimmingCharacters(in: .whitespaces).isEmpty && PairingInvite.isValidCode(code)
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .link:
                    if let invite = store.pendingInvite, link == invite.shareLink {
                        _ = try await store.pair(with: invite)
                    } else {
                        _ = try await store.pair(link: link)
                    }
                case .code:
                    switch PairingInvite.manual(address: address, code: code) {
                    case .success(let invite):
                        _ = try await store.pair(with: invite)
                    case .failure(let failure):
                        throw failure
                    }
                }
                store.pendingInvite = nil
                onPaired()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func dismissSheet() {
        store.pendingInvite = nil
        dismiss()
    }
}

struct MascotMark: View {
    var size: CGFloat = 100

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: size * 1.32, height: size * 1.32)
            // ears
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: -size * 0.31, y: -size * 0.27)
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: size * 0.31, y: -size * 0.27)
            // head
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.83, green: 0.97, blue: 0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.78, height: size * 0.66)
            HStack(spacing: size * 0.14) {
                Capsule().fill(Color(red: 0.05, green: 0.20, blue: 0.11)).frame(width: size * 0.08, height: size * 0.13)
                Capsule().fill(Color(red: 0.05, green: 0.20, blue: 0.11)).frame(width: size * 0.08, height: size * 0.13)
            }
            // antenna
            Capsule()
                .fill(Color.white.opacity(0.8))
                .frame(width: size * 0.03, height: size * 0.16)
                .offset(y: -size * 0.40)
            Circle()
                .fill(Theme.accentBright)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(y: -size * 0.50)
        }
        .frame(width: size * 1.4, height: size * 1.4)
    }
}
