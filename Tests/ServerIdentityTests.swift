import Foundation
import Testing

/// The reconnect rule (`ServerConfig.requiresReconnect`), per-server UserDefaults
/// keys that survive a rename (`LastGoodHostStore`, `SelectedServerStore`), and
/// the RefreshController behaviour built on them. Defaults use a throwaway suite.
@Suite("Server identity: reconnect rule and id-keyed state")
@MainActor
struct ServerIdentityTests {
    private func server(_ name: String = "Identity A") -> ServerConfig {
        ServerConfig(name: name, host: "192.0.2.1", port: 9091, useHTTPS: false, rpcPath: "/transmission/rpc",
                     username: "user", password: "pw")
    }

    /// A fresh defaults suite plus its cleanup.
    private func scratch() -> (defaults: UserDefaults, suite: String) {
        let suite = "ServerIdentityTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - requiresReconnect

    @Test func presetAndPathMappingChangesDoNotReconnect() {
        let a = server()
        var b = a
        b.downSpeedPresets = [1, 2]
        b.upSpeedPresets = [3]
        b.pathMappings = [PathMapping(remote: "/video", local: "/Volumes/Video")]
        #expect(!b.requiresReconnect(from: a))
    }

    @Test func renameDoesNotReconnect() {
        let a = server()
        var b = a
        b.name = "Renamed"
        #expect(!b.requiresReconnect(from: a))
    }

    @Test func connectionFieldChangesReconnect() {
        let a = server()
        let changes: [(String, (inout ServerConfig) -> Void)] = [
            ("host", { $0.host = "192.0.2.2" }),
            ("port", { $0.port = 9092 }),
            ("useHTTPS", { $0.useHTTPS = true }),
            ("rpcPath", { $0.rpcPath = "/other/rpc" }),
            ("username", { $0.username = "someone" }),
            ("username cleared", { $0.username = nil }),
            ("password", { $0.password = "changed" }),
            ("id", { $0.id = UUID() }),
        ]
        for (label, change) in changes {
            var b = a
            change(&b)
            #expect(b.requiresReconnect(from: a), "\(label) should reconnect")
        }
    }

    @Test func identicalConfigDoesNotReconnect() {
        let a = server()
        #expect(!a.requiresReconnect(from: a))
    }

    // MARK: - LastGoodHostStore

    @Test func lastGoodHostRoundTripsAndSurvivesRename() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = server("Before")
        #expect(LastGoodHostStore.read(for: a, defaults: defaults) == nil)
        LastGoodHostStore.write("http://192.0.2.1:9091/transmission/rpc", for: a, defaults: defaults)
        var renamed = a
        renamed.name = "After"
        #expect(LastGoodHostStore.read(for: renamed, defaults: defaults) == "http://192.0.2.1:9091/transmission/rpc")
    }

    @Test func lastGoodHostMigratesNameKeyOnFirstRead() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = server("Legacy")
        defaults.set("https://legacy.example:443/rpc", forKey: LastGoodHostStore.legacyKey(forName: "Legacy"))
        #expect(LastGoodHostStore.read(for: a, defaults: defaults) == "https://legacy.example:443/rpc")
        #expect(defaults.string(forKey: LastGoodHostStore.key(for: a.id)) == "https://legacy.example:443/rpc")
        #expect(defaults.string(forKey: LastGoodHostStore.legacyKey(forName: "Legacy")) == nil)
        // A second read comes from the id key.
        #expect(LastGoodHostStore.read(for: a, defaults: defaults) == "https://legacy.example:443/rpc")
    }

    @Test func idKeyWinsOverLegacyNameKey() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = server("Both")
        defaults.set("http://old", forKey: LastGoodHostStore.legacyKey(forName: "Both"))
        LastGoodHostStore.write("http://new", for: a, defaults: defaults)
        #expect(LastGoodHostStore.read(for: a, defaults: defaults) == "http://new")
    }

    @Test func keysAreDistinctPerServerId() {
        let a = server("Same name")
        let b = server("Same name")
        #expect(LastGoodHostStore.key(for: a.id) != LastGoodHostStore.key(for: b.id))
    }

    // MARK: - SelectedServerStore

    @Test func selectionRestoresByIdAcrossRename() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = server("Pick me")
        let other = server("Other")
        SelectedServerStore.save(a.id, defaults: defaults)
        var renamed = a
        renamed.name = "Picked after rename"
        let config = AppConfig(servers: [renamed, other], refreshSeconds: 4, currentServer: other.name)
        #expect(SelectedServerStore.restore(in: config, defaults: defaults) == a.id)
    }

    @Test func staleSelectedIdIsIgnored() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        SelectedServerStore.save(UUID(), defaults: defaults)
        let config = AppConfig(servers: [server("Only")], refreshSeconds: 4, currentServer: nil)
        #expect(SelectedServerStore.restore(in: config, defaults: defaults) == nil)
    }

    @Test func legacyNameSelectionMigratesToId() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = server("Old pick")
        defaults.set("Old pick", forKey: SelectedServerStore.legacyNameKey)
        let config = AppConfig(servers: [a], refreshSeconds: 4, currentServer: nil)
        #expect(SelectedServerStore.restore(in: config, defaults: defaults) == a.id)
        #expect(defaults.string(forKey: SelectedServerStore.idKey) == a.id.uuidString)
        #expect(defaults.string(forKey: SelectedServerStore.legacyNameKey) == nil)
    }

    @Test func legacyNameForMissingServerRestoresNothing() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Gone", forKey: SelectedServerStore.legacyNameKey)
        let config = AppConfig(servers: [server("Here")], refreshSeconds: 4, currentServer: nil)
        #expect(SelectedServerStore.restore(in: config, defaults: defaults) == nil)
    }

    // MARK: - RefreshController reconnect behaviour

    @Test func presetOnlyUpdateKeepsConnectionState() {
        let a = ServerConfig(name: "Identity refresh A", host: "127.0.0.1", port: 1, useHTTPS: false, rpcPath: "/r")
        let refresh = RefreshController(config: AppConfig(servers: [a], refreshSeconds: 60, currentServer: a.name))
        defer { refresh.stop() }
        #expect(refresh.state == .idle)
        var edited = a
        edited.downSpeedPresets = [7]
        refresh.updateConfig(AppConfig(servers: [edited], refreshSeconds: 60, currentServer: a.name))
        #expect(refresh.state == .idle)   // no restart: a restart would move to .connecting
        #expect(refresh.activeServerConfig.downSpeedPresets == [7])
    }

    @Test func connectionChangeRestartsAndRenameDoesNot() {
        let a = ServerConfig(name: "Identity refresh B", host: "127.0.0.1", port: 1, useHTTPS: false, rpcPath: "/r")
        let refresh = RefreshController(config: AppConfig(servers: [a], refreshSeconds: 60, currentServer: a.name))
        defer { refresh.stop() }
        var renamed = a
        renamed.name = "Identity refresh B2"
        refresh.updateConfig(AppConfig(servers: [renamed], refreshSeconds: 60, currentServer: renamed.name))
        #expect(refresh.state == .idle)
        #expect(refresh.currentServerName == "Identity refresh B2")
        var moved = renamed
        moved.port = 2
        refresh.updateConfig(AppConfig(servers: [moved], refreshSeconds: 60, currentServer: moved.name))
        #expect(refresh.state == .connecting)
    }
}
