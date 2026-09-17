import Foundation

/// Remembers recently-used destination folders across launches, **shared**
/// between the Add-torrent sheet and the Move/Set-Location dialog — mirrors the
/// legacy Pascal app's single per-connection folder history
/// (`TMainForm.FillDownloadDirs`/`SaveDownloadDirs`), which both of its callers
/// (add-torrent and move-torrent) read from and write to in common. Uses the
/// same `UserDefaults` key the Move dialog already wrote to
/// (`RecentMoveDirs`), so existing history carries over rather than starting
/// blank for either feature.
///
/// Foundation-only and store-injectable (mirrors `PreferencesStore`'s
/// testable-core pattern) so it's unit-testable without touching the real
/// `UserDefaults.standard`.
enum RecentFolders {
    static let defaultsKey = "RecentMoveDirs"
    static let maxEntries = 20

    /// Most-recent-first list of remembered destination folders, normalized so
    /// entries that differ only by trailing/doubled slashes collapse into one.
    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    /// Records a folder as most-recently-used: moves it to the front if already
    /// present (no duplicate entries), otherwise inserts it at the front, then
    /// trims to `maxEntries`. A blank folder is ignored.
    static func record(_ folder: String, in defaults: UserDefaults = .standard) {
        let normalized = Torrent.normalizeDownloadDir(folder.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalized.isEmpty else { return }
        var list = load(from: defaults)
        list.removeAll { Torrent.normalizeDownloadDir($0) == normalized }
        list.insert(normalized, at: 0)
        if list.count > maxEntries { list.removeLast(list.count - maxEntries) }
        defaults.set(list, forKey: defaultsKey)
    }

    /// The full set of folders worth offering in a destination picker: recorded
    /// history plus any `extra` folders (e.g. torrents' current download dirs),
    /// deduplicated (by normalized path) and sorted alphabetically — the same
    /// combination the Move dialog already builds from recent + in-use folders.
    static func candidates(extra: [String] = [], from defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        return (load(from: defaults) + extra)
            .compactMap { dir -> String? in
                let normalized = Torrent.normalizeDownloadDir(dir.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !normalized.isEmpty else { return nil }
                return seen.insert(normalized).inserted ? normalized : nil
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
