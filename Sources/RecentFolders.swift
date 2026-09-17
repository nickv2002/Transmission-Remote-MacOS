import Foundation

/// Remembers recently-used torrent destination folders across launches, so the
/// Add-torrent sheet can offer them instead of always resetting to the server's
/// default download dir. Foundation-only and path/store-injectable (mirrors
/// `PreferencesStore`'s testable-core pattern) so it's unit-testable without
/// touching the real `UserDefaults.standard`.
enum RecentFolders {
    static let defaultsKey = "RecentDestinationFolders"
    static let maxEntries = 5

    /// Most-recent-first list of remembered destination folders.
    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    /// Records a folder as most-recently-used: moves it to the front if already
    /// present (no duplicate entries), otherwise inserts it at the front, then
    /// trims to `maxEntries`. A blank folder is ignored.
    static func record(_ folder: String, in defaults: UserDefaults = .standard) {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load(from: defaults)
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxEntries { list.removeLast(list.count - maxEntries) }
        defaults.set(list, forKey: defaultsKey)
    }
}
