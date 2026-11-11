import AppKit
import UserNotifications

/// Banners while MausBot is open. A closed app cannot receive a push in this
/// client; the desktop remains the machine that runs the work.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var bootstrapped = false
    private var seen = Set<String>()

    func bootstrap() {
        guard !bootstrapped, Bundle.main.bundleIdentifier != nil else { return }
        bootstrapped = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, threadId: String?, id: String?) {
        guard bootstrapped else { return }
        if let id {
            guard seen.insert(id).inserted else { return }
            if seen.count > 500 { seen.removeAll() }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        if let threadId { content.userInfo = ["threadId": threadId] }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let threadId = response.notification.request.content.userInfo["threadId"] as? String
        if let threadId {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                AppStore.shared.openByThreadId(threadId)
            }
        }
        completionHandler()
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 200
    }

    func value(for path: String) -> Data? {
        cache.object(forKey: path as NSString) as Data?
    }

    func store(_ data: Data, for path: String) {
        cache.setObject(data as NSData, forKey: path as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
