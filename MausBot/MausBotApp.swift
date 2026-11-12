import AppKit
import SwiftUI

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--selfcheck") {
            SelfCheck.runAndExit(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        if CommandLine.arguments.contains("--render") {
            Render.runAndExit()
        }
        MausBotApp.main()
    }
}

struct MausBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore.shared
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.chinese.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.chinese.locale)
                .task {
                    Notifier.shared.bootstrap()
                    store.start()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button(localized("配对新的电脑…")) {
                    store.showPairingSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.chinese.locale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.appearance = AppStore.shared.appearance.nsAppearance
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let invite = PairingInvite.parse(url.absoluteString) else { continue }
            Task { @MainActor in
                AppStore.shared.pendingInvite = invite
                if !AppStore.shared.computers.isEmpty {
                    AppStore.shared.showPairingSheet = true
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
