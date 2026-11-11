import AppKit
import Combine
import Foundation

// The library defaults to the sandboxed container Documents (no prompts);
// Settings can move it anywhere via a security-scoped bookmark that keeps
// autosave legal there. Templates live inside the library, so a synced folder
// syncs them too.

/// Folder picking behind a protocol so headless probes script the result
/// instead of raising a panel on the user's screen. Presented as a window-
/// modal sheet (anchored to the titlebar) via the documented beginSheetModal.
protocol FolderChoosing {
    func chooseDirectory(prompt: String, suggestedName: String?, defaultURL: URL?,
                         into window: NSWindow?, completion: @escaping (URL?) -> Void)
}

struct SystemFolderChooser: FolderChoosing {
    func chooseDirectory(prompt: String, suggestedName: String?, defaultURL: URL?,
                         into window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        if let suggestedName { panel.nameFieldStringValue = suggestedName }
        panel.directoryURL = defaultURL
        // Anchored to the key window when there is one; the panel then slides
        // down from its titlebar instead of floating as a separate window.
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

enum LibraryError: Error, LocalizedError {
    case verification(String)

    var errorDescription: String? {
        switch self {
        case let .verification(path):
            "Couldn't verify the copy of \(path). Nothing was removed from the old folder."
        }
    }
}

enum LibraryLocation {
    static let bookmarkKey = "LibraryFolderBookmark"
    static let grantedPathKey = "LibraryFolderGrantedPath"

    // Injectable seams: probes swap the store, the panel, and the codec — a
    // non-sandboxed probe process cannot mint security-scoped bookmarks.
    static var defaults: UserDefaults = .standard
    static var chooser: FolderChoosing = SystemFolderChooser()
    static var writeBookmarkData: (URL) -> Data? = {
        try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static var readBookmarkURL: (Data) -> URL? = { data in
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    static var beginAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    static var endAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    static var copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    static var realDocumentsOverride: URL?

    private(set) static var granted: URL?
    private static var accessing: URL?

    /// The literal ~/Documents Finder shows — the sandbox redirects
    /// NSHomeDirectory, so the passwd entry is the only way to name it.
    static var realDocuments: URL? {
        if let override = realDocumentsOverride { return override }
        guard let entry = getpwuid(getuid()) else { return nil }
        return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Default library: the sandboxed container's Documents. Probes override
    /// because a bare executable's Documents is the user's real ~/Documents.
    static var containerOverride: URL?
    static var containerDefault: URL {
        if let override = containerOverride { return override }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return base.appendingPathComponent("Running the Table", isDirectory: true)
    }

    static var directory: URL { granted ?? containerDefault }

    /// One resolution per launch: a live bookmark wins; a dead one is reported
    /// (the stored path survives for the recovery alert) never silently dropped.
    @discardableResult
    static func resolveGrant() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        guard let url = readBookmarkURL(data),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if accessing != url { stopAccess() }
        // Revoked access behaves like a dead bookmark: the loud recovery path
        // (re-grant the same folder) is the only honest way back.
        guard beginAccess(url) else { return nil }
        accessing = url
        granted = url
        defaults.set(url.path, forKey: grantedPathKey)
        return url
    }

    static func setGrant(_ url: URL) {
        stopAccess()
        if let data = writeBookmarkData(url) { defaults.set(data, forKey: bookmarkKey) }
        defaults.set(url.path, forKey: grantedPathKey)
        if beginAccess(url) { accessing = url }
        granted = url
    }

    static func revokeGrant() {
        stopAccess()
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: grantedPathKey)
        granted = nil
    }

    private static func stopAccess() {
        if let url = accessing { endAccess(url) }
        accessing = nil
    }

    static func tableFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "html" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copy tables + Templates into dest, never clobbering (collisions land as
    /// "Name 2.html"), and throw unless every byte that left arrived.
    static func copyLibrary(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var pairs: [(src: URL, dst: URL)] = tableFiles(in: source).map {
            ($0, uniqueCopyURL(named: $0.lastPathComponent, in: dest))
        }
        let templates = source.appendingPathComponent("Templates", isDirectory: true)
        if fm.fileExists(atPath: templates.path) {
            pairs.append((templates, uniqueCopyURL(named: "Templates", in: dest)))
        }
        for pair in pairs { try copyItem(pair.src, pair.dst) }
        for pair in pairs where byteTotal(of: pair.src) != byteTotal(of: pair.dst) {
            throw LibraryError.verification(pair.dst.path)
        }
    }

    /// After a verified move: remove only what was copied — stray files in the
    /// old folder are not ours to delete.
    static func removeMovedLibrary(from source: URL) throws {
        let fm = FileManager.default
        for url in tableFiles(in: source) { try fm.removeItem(at: url) }
        let templates = source.appendingPathComponent("Templates", isDirectory: true)
        if fm.fileExists(atPath: templates.path) { try fm.removeItem(at: templates) }
    }

    private static func uniqueCopyURL(named name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 2
        while true {
            let next = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)")
            if !fm.fileExists(atPath: next.path) { return next }
            suffix += 1
        }
    }

    // Logical bytes for verify — allocated size varies with fragmentation and
    // would false-alarm between two identical copies.
    private static func byteTotal(of url: URL) -> Int? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { return -1 }
            return size
        }
        var total = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            }
        }
        return total
    }
}

// Launch-time and Settings driver: owns lost-access recovery and the
// change-folder move/copy, reloading the view model after every root change.
@MainActor
final class LibraryCoordinator: ObservableObject {
    enum Step: Equatable {
        case none
        case lostAccess(path: String)
        case moveOffer(count: Int, from: URL, to: URL)
    }

    @Published var step: Step = .none
    @Published var failure: String?
    @Published private(set) var currentPath: String = LibraryLocation.directory.path
    // Settings is a sheet on the main window, not a window of its own.
    @Published var showSettings = false

    weak var viewModel: TableViewModel?
    private var promptedThisLaunch = false

    /// First ContentView appearance per launch: a stored grant resolves; a dead
    /// one raises recovery. The container default needs no prompt, so launch is
    /// silent.
    func launchOnce() {
        guard !promptedThisLaunch else { return }
        promptedThisLaunch = true
        if LibraryLocation.defaults.data(forKey: LibraryLocation.bookmarkKey) != nil,
           LibraryLocation.resolveGrant() == nil {
            let path = LibraryLocation.defaults.string(forKey: LibraryLocation.grantedPathKey) ?? "your tables folder"
            step = .lostAccess(path: path)
        }
    }

    func changeFolder() {
        let current = LibraryLocation.directory
        LibraryLocation.chooser.chooseDirectory(
            prompt: "Choose",
            suggestedName: nil,
            defaultURL: current,
            into: nil
        ) { [weak self] chosen in
            guard let self, let chosen else { return }
            guard chosen.resolvingSymlinksInPath() != current.resolvingSymlinksInPath() else { return }
            let count = LibraryLocation.tableFiles(in: current).count
            guard count > 0 else {
                LibraryLocation.setGrant(chosen)
                self.refreshPath()
                self.viewModel?.reloadFromDisk()
                return
            }
            // The move sheet rides the same window as the Settings sheet, so
            // Settings steps aside first.
            self.showSettings = false
            self.step = .moveOffer(count: count, from: current, to: chosen)
        }
    }

    // The grant only lands once the files have, so a failed copy leaves the
    // user exactly where they started.
    func resolveMove(copy: Bool) {
        guard case let .moveOffer(_, from, to) = step else { return }
        step = .none
        viewModel?.saveAllDocuments()
        do {
            try LibraryLocation.copyLibrary(from: from, to: to)
            LibraryLocation.setGrant(to)
            refreshPath()
            TableViewModel.rekeyTitles(from: from, to: to)
            if !copy { try LibraryLocation.removeMovedLibrary(from: from) }
        } catch {
            failure = error.localizedDescription
        }
        viewModel?.reloadFromDisk()
    }

    func cancelMove() {
        guard case .moveOffer = step else { return }
        step = .none
    }

    func regrantAfterLoss() {
        let remembered = LibraryLocation.defaults.string(forKey: LibraryLocation.grantedPathKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        LibraryLocation.chooser.chooseDirectory(
            prompt: "Choose",
            suggestedName: nil,
            defaultURL: remembered ?? LibraryLocation.realDocuments,
            into: nil
        ) { [weak self] url in
            guard let self, let url else { return }
            LibraryLocation.setGrant(url)
            self.refreshPath()
            if let remembered { TableViewModel.rekeyTitles(from: remembered, to: url) }
            self.step = .none
            self.viewModel?.reloadFromDisk()
        }
    }

    func useContainerFallback() {
        LibraryLocation.revokeGrant()
        refreshPath()
        step = .none
        viewModel?.reloadFromDisk()
    }

    private func refreshPath() {
        currentPath = LibraryLocation.directory.path
    }
}
