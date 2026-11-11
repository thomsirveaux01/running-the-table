import AppKit
import Combine
import Foundation

// GitHub release check: silent at launch (throttled to once a day), chatty
// when the user picks the menu item. Probes inject the fetch, clock, and store.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Prompt: Equatable {
        case available(version: String, notes: String)
        case upToDate
        case checkFailed
    }

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        var body: String?
        var assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }

        init(tagName: String, htmlURL: URL, body: String? = nil, assets: [Asset]? = nil) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.body = body
            self.assets = assets
        }

        var notes: String { body ?? "" }

        // The DMG is the artifact; a release without one falls back to its page.
        var dmgURL: URL? { assets?.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL }
    }

    // Unauthenticated GitHub API limits are per-IP-per-hour, so the daily
    // throttle keeps launch checks invisible even with many users on one network.
    static let releasesURL = URL(string: "https://api.github.com/repos/thomsirveaux01/running-the-table/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private static let lastCheckKey = "UpdateChecker.lastCheck"
    private static let skippedVersionKey = "UpdateChecker.skippedVersion"

    @Published var prompt: Prompt?

    var latestRelease: () async throws -> Release = { try await fetch() }
    // Saves the DMG to ~/Downloads (system folder prompt on first use) and
    // returns the local file; probes inject both halves of the download.
    var downloadRelease: (URL, String) async throws -> URL = { url, name in
        try await defaultDownload(url, name)
    }
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private(set) var promptedRelease: Release?

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
            promptedRelease = nil
            if userInitiated { prompt = .checkFailed }
            return
        }

        let tag = Self.normalizedTag(release.tagName)
        guard !tag.isEmpty, Self.isNewer(tag, than: currentVersion) else {
            promptedRelease = nil
            if userInitiated { prompt = .upToDate }
            return
        }
        // "Skip This Version" silences that tag only; a newer one re-prompts.
        if !userInitiated, tag == defaults.string(forKey: Self.skippedVersionKey) { return }
        promptedRelease = release
        prompt = .available(version: tag, notes: release.notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func skipPromptedVersion() {
        if case let .available(version, _) = prompt {
            defaults.set(version, forKey: Self.skippedVersionKey)
        }
        prompt = nil
    }

    /// Downloads the prompted DMG to ~/Downloads and opens it (mounts, Finder
    /// window). Any failure falls back to the release page — never dead-end.
    func downloadPromptedUpdate() async {
        guard case .available = prompt, let release = promptedRelease else { return }
        prompt = nil
        guard let dmg = release.dmgURL else {
            openFile(release.htmlURL)
            return
        }
        do {
            openFile(try await downloadRelease(dmg, dmg.lastPathComponent))
        } catch {
            openFile(release.htmlURL)
        }
    }

    private static func defaultDownload(_ url: URL, _ name: String) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let fm = FileManager.default
        let dir = try fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Never clobber: an existing download lands as "Name 2.dmg".
        var dest = dir.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)")
            suffix += 1
        }
        try fm.moveItem(at: temp, to: dest)
        return dest
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
