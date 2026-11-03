import Foundation
import Synchronization
import Testing

/// The Access token on the wire: only to the host it was issued for, renewed
/// before it expires and when Access refuses it, and how Access's refusals are
/// told apart and explained.
@Suite("Cloudflare Access: token header and renewal")
struct AccessHeaderSourceTests {
    private static let ok = StubURLProtocol.Reply(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func server(_ host: String, https: Bool = true, access: Bool = true) -> ServerConfig {
        ServerConfig(name: "Proxied", host: host, port: 443, useHTTPS: https, rpcPath: "/transmission/rpc",
                     username: "user", password: "pass", useCloudflareAccess: access)
    }

    /// Sessions holding `session` for `server`, with a counter of change notifications.
    private func sessions(_ session: AccessSession?, for server: ServerConfig) throws -> AccessSessions {
        let sessions = AccessSessions(store: InMemoryAccessSessionStore())
        if let session { try sessions.setSession(session, for: server.id, announce: false) }
        return sessions
    }

    private func source(_ server: ServerConfig, _ sessions: AccessSessions,
                        refresher: AccessTokenRefresher = AccessTokenRefresher()) -> AccessTokenHeaderSource {
        var source = AccessTokenHeaderSource(serverID: server.id, host: server.host, sessions: sessions)
        source.environment = { [now] in AccessStub.environment(now: now) }
        source.refresher = refresher
        return source
    }

    // MARK: - When the token is added

    @Test func onlyHTTPSServersUsingAccessGetASource() {
        let sessions = AccessSessions(store: InMemoryAccessSessionStore())
        #expect(AccessTokenHeaderSource.source(for: server("t.example.com"), sessions: sessions) != nil)
        #expect(AccessTokenHeaderSource.source(for: server("t.example.com", https: false), sessions: sessions) == nil)
        #expect(AccessTokenHeaderSource.source(for: server("t.example.com", access: false), sessions: sessions) == nil)
    }

    @Test func aValidTokenIsSentAsCfAccessToken() async throws {
        let d = AccessStub.Deployment()
        let s = server(d.appHost)
        let src = source(s, try sessions(d.session(expiresAt: now.addingTimeInterval(600)), for: s))
        #expect(try await src.headers() == [CustomHeader(name: "cf-access-token", value: "oauth:access-0")])
    }

    @Test func nothingIsAddedSignedOutOrForAnotherHost() async throws {
        let d = AccessStub.Deployment()
        let s = server(d.appHost)
        #expect(try await source(s, try sessions(nil, for: s)).headers().isEmpty)
        #expect(try await source(s, try sessions(d.session(accessToken: nil, refreshToken: nil, expiresAt: nil), for: s))
            .headers().isEmpty)
        var lan = s
        lan.host = "10.0.1.2"
        let valid = try sessions(d.session(expiresAt: now.addingTimeInterval(600)), for: s)
        let lanSource = AccessTokenHeaderSource(serverID: s.id, host: lan.host, sessions: valid)
        #expect(try await lanSource.headers().isEmpty)
    }

    // MARK: - Renewal

    @Test func anExpiringTokenIsRenewedQuietlyBeforeSending() async throws {
        let d = AccessStub.Deployment()
        let s = server(d.appHost)
        StubURLProtocol.set([.init(body: #"{"access_token":"oauth:access-2","expires_in":900,"refresh_token":"oauth:refresh-2"}"#)],
                            for: d.teamHost)
        let store = try sessions(d.session(expiresAt: now.addingTimeInterval(10)), for: s)
        let announced = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: AccessSessions.changedNotification, object: store,
                                                              queue: nil) { _ in announced.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(try await source(s, store).headers() == [CustomHeader(name: "cf-access-token", value: "oauth:access-2")])
        #expect(store.session(for: s.id)?.refreshToken == "oauth:refresh-2")
        #expect(announced.withLock { $0 } == 0, "a routine renewal must not restart the connection")
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let d = AccessStub.Deployment()
        let s = server(d.appHost)
        StubURLProtocol.set([.init(body: #"{"access_token":"oauth:access-2","expires_in":900,"refresh_token":"oauth:refresh-2"}"#)],
                            for: d.teamHost)
        let src = source(s, try sessions(d.session(expiresAt: now), for: s))
        async let a = src.headers()
        async let b = src.headers()
        async let c = src.headers()
        let all = try await [a, b, c]
        #expect(all.allSatisfy { $0.first?.value == "oauth:access-2" })
        #expect(StubURLProtocol.requests(for: d.teamHost).count == 1)
    }

    @Test func anEndedSessionFailsTheRequestAndSignsOut() async throws {
        let d = AccessStub.Deployment()
        let s = server(d.appHost)
        StubURLProtocol.set([.init(status: 400, body: #"{"error":"invalid_grant"}"#)], for: d.teamHost)
        let store = try sessions(d.session(expiresAt: now), for: s)
        do {
            _ = try await source(s, store).headers()
            Issue.record("expected a sign-in error")
        } catch {
            #expect(error.accessSignInReason == .expired)
        }
        let after = try #require(store.session(for: s.id))
        #expect(!after.isSignedIn)
        #expect(after.registration.clientID == "client-0", "the registration is kept for the next sign-in")
    }

    /// Access refusing a token mid-life (revoked, rotated elsewhere): the client
    /// renews it once and retries; Transmission's own login is untouched.
    @Test func aRefusedTokenIsRenewedAndTheRequestRetried() async throws {
        let d = AccessStub.Deployment()
        let s = server(d.appHost)
        StubURLProtocol.set([d.challenge, Self.ok], for: d.appHost)
        StubURLProtocol.set([.init(body: #"{"access_token":"oauth:access-2","expires_in":900}"#)], for: d.teamHost)
        let store = try sessions(d.session(expiresAt: now.addingTimeInterval(600)), for: s)
        var src = AccessTokenHeaderSource(serverID: s.id, host: s.host, sessions: store)
        src.environment = { [now] in AccessStub.environment(now: now) }
        src.refresher = AccessTokenRefresher()
        _ = try await TransmissionClient(server: s, configuration: StubURLProtocol.configuration(),
                                         headerSources: [src], accessSessions: AccessSessions(store: InMemoryAccessSessionStore()))
            .fetchTorrents()
        let sent = StubURLProtocol.requests(for: d.appHost)
        #expect(sent.map { $0.value(forHTTPHeaderField: "cf-access-token") } == ["oauth:access-0", "oauth:access-2"])
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz" })
    }

    // MARK: - Refusals

    @Test func accessRefusalsAreClassified() async throws {
        let d = AccessStub.Deployment()
        let login = StubURLProtocol.Reply(status: 302, headers: [
            "Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/t.example.com?kid=x"])
        let basic = StubURLProtocol.Reply(status: 401, headers: ["WWW-Authenticate": #"Basic realm="Transmission""#])
        for (reply, expected) in [(d.challenge, AccessSignInReason.signedOut), (login, .managedOAuthOff), (basic, nil)] {
            let host = StubURLProtocol.uniqueHost()
            StubURLProtocol.set([reply], for: host)
            let client = try TransmissionClient(server: server(host), configuration: StubURLProtocol.configuration(),
                                                accessSessions: AccessSessions(store: InMemoryAccessSessionStore()))
            do {
                _ = try await client.fetchSession()
                Issue.record("expected an error")
            } catch {
                #expect(error.accessSignInReason == expected)
                if expected == nil {
                    guard case TransmissionError.authenticationFailed = error else {
                        Issue.record("Transmission's own 401 must stay an auth failure: \(error)")
                        return
                    }
                }
            }
        }
    }

    // MARK: - Messages

    @Test func messagesDependOnWhetherSignInIsTurnedOn() {
        let on = server("t.example.com"), off = server("t.example.com", access: false)
        let signIn = TransmissionError.accessSignInRequired(.signedOut)
        #expect(ConnectionDiagnostics.message(for: signIn, server: off).contains("Sign in with Cloudflare Access"))
        #expect(ConnectionDiagnostics.message(for: signIn, server: on).contains("Click Sign In"))
        #expect(ConnectionDiagnostics.message(for: TransmissionError.accessSignInRequired(.expired), server: on)
            .contains("has ended"))
        let redirect = TransmissionError.redirected(status: 302,
            location: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login/t.example.com"))
        #expect(ConnectionDiagnostics.message(for: redirect, server: on).contains("Managed OAuth"))
        // A sign-in page that isn't Access keeps the Phase 1 message.
        let other = TransmissionError.redirected(status: 302, location: URL(string: "https://sso.example.org/login"))
        #expect(ConnectionDiagnostics.message(for: other, server: on).contains("Custom Headers"))
    }

    @Test @MainActor func shortReasonsForThePerHostList() {
        #expect(SettingsConnectionPane.shortError(TransmissionError.accessSignInRequired(.expired))
            == "Cloudflare Access session ended")
        #expect(SettingsConnectionPane.shortError(TransmissionError.accessSignInRequired(.signedOut))
            == "Cloudflare Access sign-in needed")
        let redirect = TransmissionError.redirected(status: 302,
            location: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login/x"))
        #expect(SettingsConnectionPane.shortError(redirect) == "Cloudflare Access Managed OAuth is off")
    }

    @Test func theMostActionableProbeFailureWins() {
        let failures = AccessFailures()
        #expect(failures.first == nil)
        failures.append(.signedOut)
        failures.append(.expired)
        #expect(failures.first == .expired)
        failures.append(.managedOAuthOff)
        #expect(failures.first == .managedOAuthOff)
    }

    // MARK: - Reconnect on sign-in

    @Test @MainActor func aSignInForTheActiveServerReconnects() async throws {
        let active = ServerConfig(name: "Access refresh A", host: "127.0.0.1", port: 1, useHTTPS: true,
                                  rpcPath: "/r", useCloudflareAccess: true)
        let other = ServerConfig(name: "Access refresh B", host: "127.0.0.2", port: 1, useHTTPS: true, rpcPath: "/r")
        let refresh = RefreshController(config: AppConfig(servers: [active, other], refreshSeconds: 60,
                                                          currentServer: active.name))
        defer { refresh.stop() }
        var restarts = 0
        refresh.onSessionChanged = { restarts += 1 }
        let post = { (id: UUID) in
            NotificationCenter.default.post(name: AccessSessions.changedNotification, object: nil,
                                            userInfo: [AccessSessions.serverIDKey: id])
        }
        post(active.id)
        #expect(restarts == 0, "not running yet")
        refresh.start()
        let afterStart = restarts
        post(other.id)
        #expect(restarts == afterStart)
        post(active.id)
        #expect(restarts == afterStart + 1)
        #expect(refresh.state == .connecting)
    }
}
