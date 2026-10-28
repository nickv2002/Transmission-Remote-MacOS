import Foundation
import Testing

/// Kept out of ServerSettingsScopeTests so scripts/test-server-options.sh, which
/// doesn't compile RefreshController, still builds.
@Suite("Active server follows a rename")
@MainActor
struct ActiveServerRenameTests {
    @Test func renamingTheActiveServerKeepsItActive() {
        func s(_ n: String) -> ServerConfig { ServerConfig(name: n, host: "127.0.0.1", port: 1, useHTTPS: false, rpcPath: "/r") }
        let a = s("Rename-test A"), b = s("Rename-test B")
        let refresh = RefreshController(config: AppConfig(servers: [a, b], refreshSeconds: 60, currentServer: b.name))
        defer { refresh.stop() }
        refresh.selectServer(named: a.name)
        var renamed = a
        renamed.name = "Rename-test A2"
        refresh.updateConfig(AppConfig(servers: [renamed, b], refreshSeconds: 60, currentServer: b.name))
        #expect(refresh.currentServerName == "Rename-test A2")
        #expect(refresh.activeServerConfig.id == a.id)
    }
}
