import Foundation

/// The editing model behind the Settings window: a working copy of `AppConfig`,
/// the last-saved baseline (for dirty detection / revert), and all the mutations
/// the UI performs (add / remove / edit servers, default server, refresh). Pure
/// (Foundation-only) so the add/remove/change/save behaviors are unit-tested
/// without any AppKit.
///
/// Saving is per server: each server row has its own Apply (`applyServer(id:)`)
/// and Revert (`revertServer(id:)`), which never persist or discard another
/// row's pending edits. List-level changes (reorder, remove, default server)
/// and the General settings apply immediately: they write through to the
/// baseline as well, so they never leave a pending edit behind.
struct SettingsEditor: Equatable {
    /// The in-progress edits.
    private(set) var working: AppConfig
    /// The last saved state (what `working` is compared against / reverts to).
    private(set) var savedBaseline: AppConfig

    init(_ config: AppConfig) {
        // Normalize once so a freshly opened editor isn't spuriously "dirty".
        let normalized = AppConfig(servers: config.servers,
                                   refreshSeconds: config.refreshSeconds,
                                   currentServer: config.currentServer,
                                   autoCheckForUpdates: config.autoCheckForUpdates,
                                   removeTorrentFileMethod: config.removeTorrentFileMethod,
                                   showAddOptions: config.showAddOptions,
                                   addLinksFromClipboard: config.addLinksFromClipboard,
                                   filesFoldersFirst: config.filesFoldersFirst,
                                   showPieceMap: config.showPieceMap,
                                   toolbarLayout: config.toolbarLayout)
        self.working = normalized
        self.savedBaseline = normalized
    }

    // MARK: - Reads

    var servers: [ServerConfig] { working.servers }
    var serverCount: Int { working.servers.count }
    var serverNames: [String] { working.serverNames }
    var currentServer: String? { working.currentServer }
    var refreshSeconds: Double { working.refreshSeconds }
    var autoCheckForUpdates: Bool { working.autoCheckForUpdates }
    var removeTorrentFileMethod: TorrentFileRemoval { working.removeTorrentFileMethod }
    var showAddOptions: Bool { working.showAddOptions }
    var addLinksFromClipboard: Bool { working.addLinksFromClipboard }
    var filesFoldersFirst: Bool { working.filesFoldersFirst }
    var showPieceMap: Bool { working.showPieceMap }
    var toolbarLayout: ToolbarLayout { working.toolbarLayout }

    func server(at index: Int) -> ServerConfig? {
        working.servers.indices.contains(index) ? working.servers[index] : nil
    }

    /// The working copy normalized through `AppConfig.init` (clamps + fallbacks).
    func normalized() -> AppConfig {
        AppConfig(servers: working.servers,
                  refreshSeconds: working.refreshSeconds,
                  currentServer: working.currentServer,
                  autoCheckForUpdates: working.autoCheckForUpdates,
                  removeTorrentFileMethod: working.removeTorrentFileMethod,
                  showAddOptions: working.showAddOptions,
                  addLinksFromClipboard: working.addLinksFromClipboard,
                  filesFoldersFirst: working.filesFoldersFirst,
                  showPieceMap: working.showPieceMap,
                  toolbarLayout: working.toolbarLayout)
    }

    /// True when any server has changes not yet saved.
    var isDirty: Bool { normalized() != savedBaseline }

    // MARK: - Per-server state

    func index(of id: UUID) -> Int? { working.servers.firstIndex { $0.id == id } }

    /// False for a server added in this window and not applied yet.
    func isSaved(_ id: UUID) -> Bool { savedBaseline.server(id: id) != nil }

    /// The last applied version of a server (nil while it's unsaved).
    func savedServer(_ id: UUID) -> ServerConfig? { savedBaseline.server(id: id) }

    /// True when this server's connection details or presets differ from what's saved.
    func isServerDirty(_ id: UUID) -> Bool {
        guard let current = working.server(id: id) else { return false }
        return current != savedBaseline.server(id: id)
    }

    /// Ids of servers with pending edits, in list order.
    var dirtyServerIDs: [UUID] { working.servers.map(\.id).filter(isServerDirty) }

    /// The config as saved, for persistence (General settings + applied servers).
    var savedConfig: AppConfig { Self.normalize(savedBaseline) }

    /// Commit one server: its working copy joins the baseline (in list order),
    /// while every other server keeps its saved version. A rename of the default
    /// server carries the default along. Returns the config to persist.
    @discardableResult
    mutating func applyServer(_ id: UUID) -> AppConfig {
        guard let edited = working.server(id: id) else { return savedConfig }
        let previous = savedBaseline.server(id: id)
        savedBaseline.servers = working.servers.compactMap { s in
            s.id == id ? edited : savedBaseline.server(id: s.id)
        }
        if let previous, savedBaseline.currentServer == previous.name {
            savedBaseline.currentServer = edited.name
        }
        savedBaseline = Self.normalize(savedBaseline)
        return savedBaseline
    }

    /// Discard one server's pending edits. An unsaved new server is removed.
    mutating func revertServer(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if let saved = savedBaseline.server(id: id) {
            if working.currentServer == working.servers[i].name { working.currentServer = saved.name }
            working.servers[i] = saved
        } else {
            working.servers.remove(at: i)
        }
    }

    private static func normalize(_ c: AppConfig) -> AppConfig {
        AppConfig(servers: c.servers, refreshSeconds: c.refreshSeconds, currentServer: c.currentServer,
                  autoCheckForUpdates: c.autoCheckForUpdates, removeTorrentFileMethod: c.removeTorrentFileMethod,
                  showAddOptions: c.showAddOptions, addLinksFromClipboard: c.addLinksFromClipboard,
                  filesFoldersFirst: c.filesFoldersFirst, showPieceMap: c.showPieceMap,
                  toolbarLayout: c.toolbarLayout)
    }

    /// Keep the baseline's order in step with the working list (reorders apply at once).
    private mutating func syncBaselineOrder() {
        let saved = working.servers.compactMap { savedBaseline.server(id: $0.id) }
        // Saved servers not in the working list (never happens via the UI) keep their place at the end.
        savedBaseline.servers = saved + savedBaseline.servers.filter { s in !saved.contains { $0.id == s.id } }
    }

    // MARK: - Mutations

    /// Append a new server with a unique "New Server" name; returns its index.
    @discardableResult
    mutating func addServer() -> Int {
        let base = "New Server"
        var name = base
        var n = 2
        while working.servers.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"; n += 1
        }
        working.servers.append(ServerConfig(
            name: name, host: "", port: 9091,
            useHTTPS: false, rpcPath: "/transmission/rpc"))
        return working.servers.count - 1
    }

    /// Remove the server at `index`. No-op if it would empty the list or the
    /// index is invalid. If the removed server was the default, the default falls
    /// back to the first remaining server.
    /// Applies immediately: the server leaves the saved list too.
    @discardableResult
    mutating func removeServer(at index: Int) -> ServerConfig? {
        guard working.servers.count > 1, working.servers.indices.contains(index) else { return nil }
        let removed = working.servers.remove(at: index)
        if working.currentServer == removed.name {
            working.currentServer = working.servers.first?.name
        }
        if let saved = savedBaseline.server(id: removed.id) {
            savedBaseline.servers.removeAll { $0.id == removed.id }
            if savedBaseline.currentServer == saved.name {
                savedBaseline.currentServer = savedBaseline.servers.first?.name
            }
        }
        return removed
    }

    /// Put a removed server back (Undo). Applies immediately for a saved server.
    mutating func restoreServer(_ server: ServerConfig, at index: Int, saved: Bool, wasDefault: Bool) {
        guard working.server(id: server.id) == nil else { return }
        working.servers.insert(server, at: min(max(0, index), working.servers.count))
        if saved {
            savedBaseline.servers.append(server)
            syncBaselineOrder()
            if wasDefault { savedBaseline.currentServer = server.name }
        }
        if wasDefault { working.currentServer = server.name }
    }

    /// Move the server at `index` to sit before the server currently at
    /// `destination` (a drop position: 0...count, in pre-move indices). Returns
    /// the server's new index, or nil if either index is out of range.
    @discardableResult
    mutating func moveServer(from index: Int, to destination: Int) -> Int? {
        guard working.servers.indices.contains(index),
              (0...working.servers.count).contains(destination) else { return nil }
        let server = working.servers.remove(at: index)
        let newIndex = destination > index ? destination - 1 : destination
        working.servers.insert(server, at: newIndex)
        syncBaselineOrder()   // applies immediately
        return newIndex
    }

    /// Replace the server at `index` with `candidate`. When `normalizeName` is
    /// true (end-of-edit), the name is trimmed, kept non-empty, and kept unique —
    /// otherwise it's taken as-is (live per-keystroke). If the name changes and it
    /// was the default server, the default follows the rename. Returns the server
    /// actually stored (its `name` may differ from `candidate` after normalizing).
    @discardableResult
    mutating func updateServer(at index: Int, to candidate: ServerConfig,
                               normalizeName: Bool) -> ServerConfig {
        guard working.servers.indices.contains(index) else { return candidate }
        var s = candidate
        // The row keeps its identity: a candidate built from form fields has a fresh id.
        s.id = working.servers[index].id
        let oldName = working.servers[index].name
        if normalizeName {
            let trimmed = s.name.trimmingCharacters(in: .whitespaces)
            s.name = trimmed.isEmpty ? oldName : trimmed
            // Keep names unique (compare against the other rows).
            let clashesElsewhere = working.servers.enumerated().contains { i, other in
                i != index && other.name == s.name
            }
            if s.name != oldName && clashesElsewhere { s.name = oldName }
        }
        if s.name != oldName, working.currentServer == oldName {
            working.currentServer = s.name
        }
        working.servers[index] = s
        return s
    }

    /// Applies immediately. The baseline records the server's saved name, so a
    /// pending rename doesn't leave the saved default pointing nowhere.
    mutating func setDefaultServer(_ name: String?) {
        working.currentServer = name
        let id = name.flatMap { working.server(named: $0)?.id }
        savedBaseline.currentServer = id.flatMap { savedBaseline.server(id: $0)?.name } ?? name
    }

    // General-pane setters apply immediately: they write through to
    // `savedBaseline` as well as `working`, so they never register as a pending
    // server-pane edit (`isDirty` stays scoped to servers/currentServer). Each
    // returns the resulting config so the caller can persist + apply it right away.

    private mutating func applyImmediately<T>(_ keyPath: WritableKeyPath<AppConfig, T>,
                                              _ value: T) -> AppConfig {
        working[keyPath: keyPath] = value
        savedBaseline[keyPath: keyPath] = value
        return normalized()
    }

    @discardableResult
    mutating func setRefreshSeconds(_ seconds: Double) -> AppConfig {
        working.refreshSeconds = seconds
        let result = normalized()   // clamps to >= 1
        working.refreshSeconds = result.refreshSeconds
        savedBaseline.refreshSeconds = result.refreshSeconds
        return result
    }

    @discardableResult
    mutating func setAutoCheckForUpdates(_ enabled: Bool) -> AppConfig {
        applyImmediately(\.autoCheckForUpdates, enabled)
    }

    @discardableResult
    mutating func setRemoveTorrentFileMethod(_ method: TorrentFileRemoval) -> AppConfig {
        applyImmediately(\.removeTorrentFileMethod, method)
    }

    @discardableResult
    mutating func setShowAddOptions(_ enabled: Bool) -> AppConfig {
        applyImmediately(\.showAddOptions, enabled)
    }

    @discardableResult
    mutating func setAddLinksFromClipboard(_ enabled: Bool) -> AppConfig {
        applyImmediately(\.addLinksFromClipboard, enabled)
    }

    @discardableResult
    mutating func setFilesFoldersFirst(_ enabled: Bool) -> AppConfig {
        applyImmediately(\.filesFoldersFirst, enabled)
    }

    @discardableResult
    mutating func setShowPieceMap(_ enabled: Bool) -> AppConfig {
        applyImmediately(\.showPieceMap, enabled)
    }

    @discardableResult
    mutating func setToolbarLayout(_ layout: ToolbarLayout) -> AppConfig {
        applyImmediately(\.toolbarLayout, layout)
    }

    // MARK: - Save / reset

    /// Commit the working copy: the normalized config becomes the new baseline and
    /// working copy, and is returned for persistence.
    @discardableResult
    mutating func save() -> AppConfig {
        let normalized = normalized()
        savedBaseline = normalized
        working = normalized
        return normalized
    }

    /// Re-seed both working copy and baseline (e.g. when the window is reopened).
    mutating func reset(to config: AppConfig) {
        self = SettingsEditor(config)
    }
}
