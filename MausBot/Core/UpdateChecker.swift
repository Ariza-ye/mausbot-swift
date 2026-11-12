import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let releasesURL = URL(string: "https://github.com/Ariza-ye/mausbot-swift/releases/latest")!
    private static let enabledKey = "automaticallyChecksForUpdates"
    private static let intervalKey = "updateCheckInterval"
    private static let lastCheckKey = "lastUpdateCheck"

    enum Interval: Int, CaseIterable, Identifiable {
        case daily = 86400, weekly = 604800, monthly = 2592000
        var id: Int { rawValue }
    }

    enum Result {
        case upToDate, available(String), failed
    }

    @Published private(set) var latestVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var result: Result?
    @Published var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: Self.enabledKey)
            scheduleAutomaticCheck()
        }
    }
    @Published var interval: Interval {
        didSet {
            UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey)
            scheduleAutomaticCheck()
        }
    }

    private var automaticTask: Task<Void, Never>?
    private var automaticChecksStarted = false

    private init() {
        let defaults = UserDefaults.standard
        automaticallyChecks = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        interval = Interval(rawValue: defaults.integer(forKey: Self.intervalKey)) ?? .daily
    }

    func startAutomaticChecks() {
        guard !automaticChecksStarted else { return }
        automaticChecksStarted = true
        scheduleAutomaticCheck()
    }

    private func scheduleAutomaticCheck() {
        automaticTask?.cancel()
        guard automaticChecksStarted, automaticallyChecks else { return }
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        let delay = max(0, lastCheck.addingTimeInterval(TimeInterval(interval.rawValue)).timeIntervalSinceNow)
        automaticTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            Task { await self.check() }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        result = nil
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        defer {
            isChecking = false
            scheduleAutomaticCheck()
        }
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            result = .failed
            return
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Ariza-ye/mausbot-swift/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                result = .failed
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let newer = Self.isNewer(release.tag_name, than: current) else {
                result = .failed
                return
            }
            latestVersion = newer ? release.tag_name : nil
            result = newer ? .available(release.tag_name) : .upToDate
        } catch {
            result = .failed
        }
    }

    static func isNewer(_ tag: String, than current: String) -> Bool? {
        func components(_ version: String) -> [Int]? {
            let value = version.hasPrefix("v") ? String(version.dropFirst()) : version
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count ? numbers : nil
        }

        guard let latest = components(tag), let installed = components(current) else { return nil }
        for index in 0..<max(latest.count, installed.count) {
            let lhs = index < latest.count ? latest[index] : 0
            let rhs = index < installed.count ? installed[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
