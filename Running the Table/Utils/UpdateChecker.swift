import Combine
import Foundation

// GitHub release check: silent at launch (throttled to once a day), chatty
// when the user picks the menu item. Probes inject the fetch, clock, and store.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Prompt: Equatable {
        case available(version: String, url: URL)
        case upToDate
        case checkFailed
    }

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    // Unauthenticated GitHub API limits are per-IP-per-hour, so the daily
    // throttle keeps launch checks invisible even with many users on one network.
    static let releasesURL = URL(string: "https://api.github.com/repos/thomsirveaux01/running-the-table/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private static let lastCheckKey = "UpdateChecker.lastCheck"
    private static let skippedVersionKey = "UpdateChecker.skippedVersion"

    @Published var prompt: Prompt?

    var latestRelease: () async throws -> Release = { try await fetch() }

    let currentVersion: String
    private let defaults: UserDefaults
    private let now: () -> Date

    init(currentVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0",
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
    }

    func check(userInitiated: Bool) async {
        // Persisted before the await so two windows launched together cannot
        // both fetch, and a failed check still buys the next 24 hours of quiet.
        let date = now()
        if !userInitiated, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           date.timeIntervalSince(last) < Self.checkInterval { return }
        defaults.set(date, forKey: Self.lastCheckKey)

        let release: Release
        do {
            release = try await latestRelease()
        } catch {
            if userInitiated { prompt = .checkFailed }
            return
        }

        let tag = Self.normalizedTag(release.tagName)
        guard !tag.isEmpty, Self.isNewer(tag, than: currentVersion) else {
            if userInitiated { prompt = .upToDate }
            return
        }
        // "Skip This Version" silences that tag only; a newer one re-prompts.
        if !userInitiated, tag == defaults.string(forKey: Self.skippedVersionKey) { return }
        prompt = .available(version: tag, url: release.htmlURL)
    }

    func skipPromptedVersion() {
        if case let .available(version, _) = prompt {
            defaults.set(version, forKey: Self.skippedVersionKey)
        }
        prompt = nil
    }

    static func normalizedTag(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // Numeric per-component so "1.10" does not read as older than "1.9".
    static func isNewer(_ tag: String, than version: String) -> Bool {
        let a = components(tag), b = components(version)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func fetch() async throws -> Release {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }
}
