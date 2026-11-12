import AppKit
import SwiftUI

/// Renders one screen to a PNG without a window, for checking layout where
/// screen capture is unavailable. One render per process: mutating the store
/// after a render trips SwiftUI's "no current update" assertion.
@MainActor
enum Render {
    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mausbot-render", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = AppStore.shared
            let screen = value(for: "--render") ?? "onboarding"

            if let url = value(for: "--url"), let credential = value(for: "--credential"),
               let route = CompanionEndpoint.make(url: url, kind: .lan, priority: 0) {
                let invite = PairingInvite(
                    routes: [route],
                    token: PairingInvite.isValidToken(credential) ? credential : nil,
                    code: PairingInvite.isValidCode(credential) ? credential : nil,
                    serverName: "Render Studio"
                )
                _ = try? await store.pair(with: invite)
            }

            var content: AnyView
            var size = CGSize(width: 1120, height: 740)
            switch screen {
            case "emoji-picker":
                content = AnyView(
                    BotEmojiPicker(selection: "🤖") { _ in }
                        .background(Theme.windowBackground)
                        .preferredColorScheme(store.appearance.colorScheme ?? .light)
                )
                size = CGSize(width: 404, height: 380)
            case "pairing":
                content = AnyView(PairingView(onboarding: false).environmentObject(store))
                size = CGSize(width: 520, height: 540)
            case "settings":
                content = AnyView(SettingsView().environmentObject(store))
                size = CGSize(width: 580, height: 460)
            case "computer-edit":
                let route = CompanionEndpoint.direct(host: "192.168.1.8", port: 8787, priority: 0)!
                let saved = SavedComputer(
                    id: "render-computer", serverName: "ariza's computer", routes: [route], activeURL: route.url,
                    hosts: [route.host], allowedKinds: [.lan], allowedLocalURLs: [route.url],
                    lastUsedAt: Date(), pairedAt: Date(), localName: "工作电脑"
                )
                content = AnyView(ComputerEditSheet(computer: saved).environmentObject(store))
                size = CGSize(width: 520, height: 540)
            case "bot-settings":
                guard store.computer != nil, let bot = await botToShow(store) else { fail("no computer") }
                store.settingsBotId = bot.id
                content = AnyView(BotSettingsSheet(botId: bot.id).environmentObject(store))
                size = CGSize(width: 460, height: 620)
            case "chat":
                guard store.computer != nil else { fail("no computer paired; pass --url and --credential") }
                _ = await waitOnline(store)
                if let bot = store.bots.first {
                    store.open(bot: bot)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
                // NavigationSplitView only renders inside a window; compose the
                // same columns here so layout can still be inspected.
                if let chat = store.open {
                    content = AnyView(
                        HStack(spacing: 0) {
                            SidebarView(search: .constant(""))
                                .frame(width: 282)
                            Rectangle().fill(Theme.hairline).frame(width: 1)
                            ChatView(chat: chat)
                        }
                        .environmentObject(store)
                    )
                } else {
                    fail("no conversation open")
                }
            case "gallery":
                let now = Date()
                let samples: [Message] = [
                    Message(id: "u1", role: "user", text: "帮我检查一下构建，然后总结失败原因。", createdAt: now.addingTimeInterval(-600)),
                    Message(id: "b1", role: "bot", text: "先看错误。**两个编译错误**都在 `AppStore.swift`：\n\n1. `NSApp` 在无窗口进程里是 nil\n2. SSE 空行被异步序列吞掉\n\n```swift\nguard NSApp?.isActive == true else { return }\n```\n\n> 修复后再跑一次自检。\n\n| 检查 | 结果 |\n| --- | --- |\n| protocol | PASS |\n| app | PASS |", createdAt: now.addingTimeInterval(-540)),
                    Message(id: "t1", role: "bot", kind: "activity", text: "", createdAt: now.addingTimeInterval(-480), tool: ToolRow(json: ["name": "Bash", "label": "swift build", "ok": true, "detail": "Build complete in 12.4s"])!),
                    Message(id: "t2", role: "bot", kind: "activity", text: "", createdAt: now.addingTimeInterval(-470), tool: ToolRow(json: ["name": "Bash", "label": "git diff --check", "ok": true, "detail": "No whitespace errors"])!),
                    Message(id: "t3", role: "bot", kind: "activity", text: "", createdAt: now.addingTimeInterval(-460), tool: ToolRow(json: ["name": "Read", "label": "读取构建日志", "ok": true, "detail": "构建通过。"])!),
                    Message(id: "c1", role: "bot", kind: "options", text: "", createdAt: now.addingTimeInterval(-420), card: Card(json: [
                        "title": "运行 rm -rf build？",
                        "subtitle": "这个操作会删除构建目录，之后的构建会更慢。",
                        "options": ["允许", "拒绝"],
                        "requestId": "req-9",
                        "requestType": "permission",
                        "tool": "Bash",
                        "allowKey": "bash:rm",
                    ])),
                    Message(id: "c2", role: "bot", kind: "options", text: "", createdAt: now.addingTimeInterval(-360), card: Card(json: [
                        "title": "用哪个模型跑这一轮？",
                        "options": ["Sonnet 4.5", "Opus 4.1"],
                        "requestId": "req-10",
                        "requestType": "question",
                    ])),
                    Message(id: "u2", role: "user", text: "谢谢，继续。", createdAt: now.addingTimeInterval(-300), pending: true),
                ]
                content = AnyView(
                    VStack(alignment: .leading, spacing: 12) {
                        TranscriptMessages(messages: samples, threadId: "thread-main")
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .environmentObject(store)
                )
                size = CGSize(width: 760, height: 900)
            default:
                content = AnyView(PairingView(onboarding: true).environmentObject(store))
            }

            content = AnyView(content.environment(\.locale, AppLanguage.current.locale))
            let url = folder.appendingPathComponent("\(screen).png")
            if screen == "computer-edit" || screen == "emoji-picker" || screen == "settings" {
                saveHosted(content, size: size, to: url)
            } else {
                save(content, size: size, to: url)
            }
            print(url.path)
            exit(0)
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func botToShow(_ store: AppStore) async -> Bot? {
        _ = await waitOnline(store)
        return store.bots.first
    }

    private static func waitOnline(_ store: AppStore) async -> Bool {
        for _ in 0..<100 {
            if store.connection.isOnline { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static func fail(_ message: String) -> Never {
        print(message)
        exit(2)
    }

    private static func saveHosted(_ view: AnyView, size: CGSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("could not create bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode bitmap") }
        do {
            try png.write(to: url)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func save(_ view: AnyView, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .background(Theme.windowBackground)
                .preferredColorScheme(AppStore.shared.appearance.colorScheme ?? .light)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            print("could not render \(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url)
            print("rendered \(url.lastPathComponent)")
        } catch {
            print("could not write \(url.lastPathComponent): \(error)")
        }
    }

    private static func value(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
