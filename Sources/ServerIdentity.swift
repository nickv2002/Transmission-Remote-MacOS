import Foundation

// Foundation-only rules about a server's identity: what a config change means for
// the live connection, and how per-server UserDefaults entries are keyed so a
// rename doesn't orphan them. Pure logic; unit-tested in ServerIdentityTests.

extension ServerConfig {
    /// True when changing from `previous` to `self` alters what the client connects
    /// to: identity, endpoint, or credentials. Renames, speed presets and path
    /// mappings don't — the client ignores them, and the stored config is read live.
    func requiresReconnect(from previous: ServerConfig) -> Bool {
        id != previous.id
            || host != previous.host
            || port != previous.port
            || useHTTPS != previous.useHTTPS
            || rpcPath != previous.rpcPath
            || username != previous.username
            || password != previous.password
    }
}

/// The host that last answered for a server, so the next launch can try it first.
/// Keyed by the server's stable id; a value written under the old name key is moved
/// across on first read.
enum LastGoodHostStore {
    static func key(for id: UUID) -> String { "LastGoodHost.\(id.uuidString)" }

    /// The pre-id key, written by builds that keyed the host by server name.
    static func legacyKey(forName name: String) -> String { "LastGoodHost.\(name)" }

    static func read(for server: ServerConfig, defaults: UserDefaults) -> String? {
        let current = key(for: server.id)
        if let host = defaults.string(forKey: current) { return host }
        let legacy = legacyKey(forName: server.name)
        guard let host = defaults.string(forKey: legacy) else { return nil }
        defaults.set(host, forKey: current)
        defaults.removeObject(forKey: legacy)
        return host
    }

    static func write(_ connectionKey: String, for server: ServerConfig, defaults: UserDefaults) {
        defaults.set(connectionKey, forKey: key(for: server.id))
        defaults.removeObject(forKey: legacyKey(forName: server.name))
    }
}

/// The server the user selected, persisted by id so a rename keeps the selection.
enum SelectedServerStore {
    static let idKey = "SelectedServerID"

    /// The name-keyed selection written before ids existed.
    static let legacyNameKey = "SelectedServerName"

    /// The saved selection if it still names a configured server. Reads the id
    /// first; otherwise falls back to the old name key and migrates it to the id.
    static func restore(in config: AppConfig, defaults: UserDefaults) -> UUID? {
        if let raw = defaults.string(forKey: idKey), let id = UUID(uuidString: raw),
           config.server(id: id) != nil {
            return id
        }
        guard let name = defaults.string(forKey: legacyNameKey),
              let server = config.server(named: name) else { return nil }
        save(server.id, defaults: defaults)
        return server.id
    }

    static func save(_ id: UUID, defaults: UserDefaults) {
        defaults.set(id.uuidString, forKey: idKey)
        defaults.removeObject(forKey: legacyNameKey)
    }
}
