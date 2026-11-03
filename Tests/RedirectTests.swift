import Foundation
import Testing

/// RPC requests never follow redirects: a 3xx becomes `TransmissionError.redirected`
/// naming where it pointed, and `ConnectionDiagnostics` explains it.
@Suite("Refused redirects")
struct RedirectTests {
    private func server(_ host: String, https: Bool = false) -> ServerConfig {
        ServerConfig(name: "Stub", host: host, port: 9091, useHTTPS: https, rpcPath: "/transmission/rpc")
    }

    private func fetch(_ server: ServerConfig) async -> Error? {
        do {
            let client = try TransmissionClient(server: server, configuration: StubURLProtocol.configuration())
            _ = try await client.fetchSession()
            return nil
        } catch {
            return error
        }
    }

    @Test func redirectToAnotherHostIsRefusedAndNamed() async throws {
        let host = StubURLProtocol.uniqueHost(), login = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([.init(status: 302, body: "<html>sign in</html>",
                                   headers: ["Location": "https://\(login)/login?return_to=/rpc"])], for: host)
        StubURLProtocol.set([.init(body: "<html>sign in</html>")], for: login)

        let error = try #require(await fetch(server(host)) as? TransmissionError)
        guard case .redirected(let status, let location) = error else {
            Issue.record("Expected .redirected, got \(error)")
            return
        }
        #expect(status == 302)
        #expect(location?.absoluteString == "https://\(login)/login?return_to=/rpc")
        #expect(error.redirectHost == login)
        #expect(error.localizedDescription.contains(login))
        #expect(StubURLProtocol.requests(for: host).count == 1)
        #expect(StubURLProtocol.requests(for: login).isEmpty, "the redirect must not be followed")
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func everyRedirectStatusIsRefused(status: Int) async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([.init(status: status, headers: ["Location": "https://elsewhere.invalid/"])], for: host)
        let error = await fetch(server(host)) as? TransmissionError
        #expect(error?.redirectHost == "elsewhere.invalid")
    }

    @Test func relativeLocationResolvesAgainstTheEndpoint() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([.init(status: 302, headers: ["Location": "/login"])], for: host)
        let error = try #require(await fetch(server(host)) as? TransmissionError)
        guard case .redirected(_, let location) = error else {
            Issue.record("Expected .redirected, got \(error)")
            return
        }
        #expect(location?.absoluteString == "http://\(host):9091/login")
    }

    // MARK: - Diagnostics

    private let base = ServerConfig(name: "N5", host: "n5.local", port: 9091, useHTTPS: false,
                                    rpcPath: "/transmission/rpc")

    @Test func redirectKindClassifiesTheTarget() {
        #expect(ConnectionDiagnostics.redirectKind(URL(string: "https://N5.local:9091/transmission/rpc"), server: base) == .toHTTPS)
        #expect(ConnectionDiagnostics.redirectKind(URL(string: "https://team.example.com/login"), server: base)
            == .otherHost("team.example.com"))
        #expect(ConnectionDiagnostics.redirectKind(URL(string: "http://n5.local:9091/transmission/web/"), server: base)
            == .sameHost(path: "/transmission/web/"))
        var https = base
        https.useHTTPS = true
        #expect(ConnectionDiagnostics.redirectKind(URL(string: "https://n5.local/other"), server: https)
            == .sameHost(path: "/other"))
        #expect(ConnectionDiagnostics.redirectKind(nil, server: base) == .unknown)
    }

    @Test func messagesPointAtTheRightSetting() {
        func message(_ location: String?) -> String {
            ConnectionDiagnostics.message(
                for: TransmissionError.redirected(status: 302, location: location.flatMap(URL.init(string:))),
                server: base)
        }
        #expect(message("https://n5.local/transmission/rpc").contains("Turn on Use HTTPS"))
        let proxy = message("https://team.example.com/login")
        #expect(proxy.contains("team.example.com"))
        #expect(proxy.contains("Custom Headers"))
        #expect(message("http://n5.local/elsewhere").contains("RPC Path"))
        #expect(message(nil).contains("HTTP 302"))
    }

    /// Custom headers that a plain-HTTP host doesn't get can't be the fix, so the
    /// advice for a sign-in redirect turns to Use HTTPS.
    @Test @MainActor func heldBackHeadersPointAtUseHTTPS() {
        var plain = base
        plain.headers = [CustomHeader(name: "X-Token", value: "t")]
        plain.useCustomHeaders = true
        #expect(plain.holdsBackCustomHeaders)
        let proxy = TransmissionError.redirected(status: 302, location: URL(string: "https://team.example.com/login"))
        let message = ConnectionDiagnostics.message(for: proxy, server: plain)
        #expect(message.contains("weren’t sent") && message.contains("Use HTTPS"))
        #expect(SettingsConnectionPane.shortError(proxy, server: plain).contains("need Use HTTPS"))

        var https = plain
        https.useHTTPS = true
        #expect(!https.holdsBackCustomHeaders)
        #expect(ConnectionDiagnostics.message(for: proxy, server: https).contains("check that they’re still valid"))
        plain.useCustomHeaders = false
        #expect(!plain.holdsBackCustomHeaders, "turned-off headers aren't held back")
    }

    @Test @MainActor func shortReasonsForThePerHostList() {
        let proxy = TransmissionError.redirected(status: 302, location: URL(string: "https://team.example.com/login"))
        #expect(SettingsConnectionPane.shortError(proxy, server: base).contains("team.example.com"))
        #expect(SettingsConnectionPane.shortError(proxy).contains("team.example.com"))
        let upgrade = TransmissionError.redirected(status: 301, location: URL(string: "https://n5.local/transmission/rpc"))
        #expect(SettingsConnectionPane.shortError(upgrade, server: base) == "redirects to HTTPS (turn on Use HTTPS)")
        #expect(SettingsConnectionPane.shortError(TransmissionError.redirected(status: 307, location: nil)) == "redirected (HTTP 307)")
    }
}
