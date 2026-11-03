import Foundation
import Security
import Synchronization

/// Where custom header values live, keyed by server id. `preferences.json` keeps
/// only the header names; the values are secrets (tokens), so they go here.
/// `PreferencesStore` fills them in on load and writes them back on save.
protocol HeaderSecretStore: Sendable {
    /// The stored name→value map for a server (empty when there is none).
    func values(for server: UUID) throws -> [String: String]
    /// Replace a server's values. An empty map deletes its entry.
    func setValues(_ values: [String: String], for server: UUID) throws
    /// Every server id that has stored values.
    func storedServerIDs() throws -> Set<UUID>
}

extension HeaderSecretStore {
    func removeValues(for server: UUID) throws { try setValues([:], for: server) }

    /// Fill each server's header values from the store. A header with no stored
    /// value gets an empty one.
    func hydrate(_ config: AppConfig) throws -> AppConfig {
        var config = config
        for i in config.servers.indices where !config.servers[i].headers.isEmpty {
            let stored = try values(for: config.servers[i].id)
            for j in config.servers[i].headers.indices {
                config.servers[i].headers[j].value = stored[config.servers[i].headers[j].name] ?? ""
            }
        }
        return config
    }

    /// Write each server's header values, skipping unchanged ones, and delete the
    /// values of servers no longer in `config` (a removed server, or one whose
    /// headers were all removed).
    func persist(_ config: AppConfig) throws {
        for server in config.servers {
            let wanted = Dictionary(server.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
            if try values(for: server.id) != wanted {
                try setValues(wanted, for: server.id)
            }
        }
        let live = Set(config.servers.map(\.id))
        for orphan in try storedServerIDs().subtracting(live) {
            try removeValues(for: orphan)
        }
    }
}

enum HeaderSecretError: LocalizedError {
    case keychain(OSStatus)
    case corrupt

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Couldn’t access the Keychain: \(detail)"
        case .corrupt:
            return "A value stored in the Keychain couldn’t be read."
        }
    }
}

/// Generic-password items in the login Keychain, one per server: account =
/// the server's UUID, data = whatever the caller stores. Shared by the custom
/// header values and the Cloudflare Access session.
struct KeychainItems: Sendable {
    let service: String
    let label: String

    private func query(for server: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.uuidString,
        ]
    }

    /// The item's data, or nil when there is none.
    func data(for server: UUID) throws -> Data? {
        var q = query(for: server)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HeaderSecretError.keychain(status) }
        guard let data = result as? Data else { throw HeaderSecretError.corrupt }
        return data
    }

    /// Stores `data`, or deletes the item when it is nil.
    func setData(_ data: Data?, for server: UUID) throws {
        guard let data else {
            let status = SecItemDelete(query(for: server) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HeaderSecretError.keychain(status)
            }
            return
        }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(for: server) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(for: server)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HeaderSecretError.keychain(status) }
    }

    /// Every server id with an item under this service.
    func serverIDs() throws -> Set<UUID> {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw HeaderSecretError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) })
    }
}

/// Header values in the login Keychain: one item per server, data = a JSON
/// name→value object.
struct KeychainHeaderStore: HeaderSecretStore {
    static let defaultService = "com.nickvance.transmission-remote-mac.custom-headers"

    let items: KeychainItems

    init(service: String = KeychainHeaderStore.defaultService) {
        items = KeychainItems(service: service, label: "Transmission Remote custom headers")
    }

    func values(for server: UUID) throws -> [String: String] {
        guard let data = try items.data(for: server) else { return [:] }
        guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw HeaderSecretError.corrupt
        }
        return values
    }

    func setValues(_ values: [String: String], for server: UUID) throws {
        try items.setData(values.isEmpty ? nil : JSONEncoder().encode(values), for: server)
    }

    func storedServerIDs() throws -> Set<UUID> { try items.serverIDs() }
}

/// An in-memory store for tests and `TestIsolation` runs, so neither reads nor
/// writes the real Keychain.
final class InMemoryHeaderStore: HeaderSecretStore {
    private let storage = Mutex<[UUID: [String: String]]>([:])

    init(_ initial: [UUID: [String: String]] = [:]) {
        storage.withLock { $0 = initial }
    }

    func values(for server: UUID) throws -> [String: String] {
        storage.withLock { $0[server] ?? [:] }
    }

    func setValues(_ values: [String: String], for server: UUID) throws {
        storage.withLock { $0[server] = values.isEmpty ? nil : values }
    }

    func storedServerIDs() throws -> Set<UUID> {
        storage.withLock { Set($0.keys) }
    }
}
