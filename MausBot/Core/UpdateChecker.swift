import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let releasesURL = URL(string: "https://github.com/Ariza-ye/mausbot-swift/releases/latest")!

    @Published private(set) var latestVersion: String?

    private struct Release: Decodable {
        let tag_name: String
    }

    func check() async {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Ariza-ye/mausbot-swift/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let newer = Self.isNewer(release.tag_name, than: current) else { return }
            latestVersion = newer ? release.tag_name : nil
        } catch {
            return
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
