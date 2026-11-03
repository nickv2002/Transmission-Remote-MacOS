import Foundation
import Testing

/// The app-wide sign-in runner: which URL it signs in against, its phases, the
/// one-line status Settings shows, and signing out.
@Suite("Cloudflare Access: sign-in controller", .serialized)
@MainActor
struct AccessSignInControllerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    private func server(_ d: AccessStub.Deployment) -> ServerConfig {
        ServerConfig(name: "Proxied", host: d.appHost, port: 443, useHTTPS: true,
                     rpcPath: "/transmission/rpc", useCloudflareAccess: true)
    }

    // MARK: - Sign-in URL

    @Test func signInUsesTheFirstHTTPSHost() {
        func url(_ host: String, https: Bool = false, port: Int = 9091, path: String = "/transmission/rpc") -> String? {
            AccessSignInController.appURL(for: ServerConfig(name: "s", host: host, port: port, useHTTPS: https,
                                                            rpcPath: path))?.absoluteString
        }
        // A host token without a port inherits the server's, as the client does.
        #expect(url("10.0.1.2, https://t.example.com") == "https://t.example.com:9091/transmission/rpc")
        #expect(url("10.0.1.2, https://t.example.com:443") == "https://t.example.com/transmission/rpc")
        #expect(url("t.example.com", https: true, port: 443) == "https://t.example.com/transmission/rpc")
        #expect(url("t.example.com", https: true, port: 8443, path: "rpc") == "https://t.example.com:8443/rpc")
        #expect(url("10.0.1.2, n5.local") == nil)
    }

    // MARK: - Status text

    @Test func statusTextCoversEachState() {
        let d = AccessStub.Deployment()
        let status = { (s: AccessSession?, p: AccessSignInController.Phase) in
            AccessSignInController.statusText(session: s, phase: p, now: self.now, locale: Locale(identifier: "en_US"),
                                              timeZone: TimeZone(identifier: "UTC")!)
        }
        let signedIn = d.session(expiresAt: now.addingTimeInterval(600), signedInAt: now.addingTimeInterval(-60))
        #expect(status(nil, .idle) == "Not signed in.")
        #expect(status(signedIn.signedOut, .idle) == "Not signed in.")
        #expect(status(signedIn, .waiting(nil)) == "Waiting for you to sign in in your browser…")
        #expect(status(nil, .failed("Boom.")) == "Boom.")
        let text = status(signedIn, .idle)
        #expect(text.hasPrefix("Signed in · "))
        #expect(text.hasSuffix("Access renews the session automatically until it ends."))
    }

    // MARK: - Running a sign-in

    @Test func aSuccessfulSignInStoresTheSessionAndGoesIdle() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [.init(status: 201, body: #"{"client_id":"client-1"}"#), .init(body: AccessStub.tokenJSON)])
        let sessions = AccessSessions(store: InMemoryAccessSessionStore())
        let now = self.now
        let controller = AccessSignInController(sessions: sessions, environment: { AccessStub.environment(now: now) })
        let s = server(d)
        controller.signIn(server: s)
        guard case .waiting = controller.phase(for: s.id) else { Issue.record("not waiting"); return }
        try await waitUntil { sessions.session(for: s.id)?.isSignedIn == true && controller.phase(for: s.id) == .idle }
        #expect(sessions.session(for: s.id)?.accessToken == "oauth:access-1")
    }

    @Test func failuresAreShownAndAnHTTPOnlyServerIsExplained() async throws {
        let d = AccessStub.Deployment()
        d.install(app: [.init(status: 409)], team: [])   // answers, but isn't behind Access
        let now = self.now
        let controller = AccessSignInController(sessions: AccessSessions(store: InMemoryAccessSessionStore()),
                                                environment: { AccessStub.environment(now: now) })
        let s = server(d)
        controller.signIn(server: s)
        try await waitUntil { if case .failed = controller.phase(for: s.id) { true } else { false } }
        #expect(controller.phase(for: s.id) == .failed(AccessError.notProtected.localizedDescription))

        let lanOnly = ServerConfig(name: "b", host: "10.0.1.2", port: 9091, useHTTPS: false, rpcPath: "/rpc")
        controller.signIn(server: lanOnly)
        guard case .failed(let message) = controller.phase(for: lanOnly.id) else { Issue.record("no failure"); return }
        #expect(message.contains("HTTPS"))
    }

    @Test func cancelReturnsToIdleAndSignOutRevokesButKeepsTheRegistration() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [.init(status: 201, body: #"{"client_id":"client-1"}"#)])
        let sessions = AccessSessions(store: InMemoryAccessSessionStore())
        let now = self.now
        let controller = AccessSignInController(sessions: sessions, environment: {
            AccessStub.environment(now: now, browser: .never, callbackTimeout: 60)
        })
        let s = server(d)
        controller.signIn(server: s)
        try await waitUntil { if case .waiting(let url) = controller.phase(for: s.id) { url != nil } else { false } }
        controller.cancel(server: s.id)
        try await waitUntil { controller.phase(for: s.id) == .idle }
        #expect(sessions.session(for: s.id) == nil)

        StubURLProtocol.set([.init(), .init()], for: d.teamHost)
        try sessions.setSession(d.session(expiresAt: now.addingTimeInterval(600)), for: s.id)
        controller.signOut(server: s.id)
        let after = try #require(sessions.session(for: s.id))
        #expect(!after.isSignedIn)
        #expect(after.registration.clientID == "client-0")
        try await waitUntil { StubURLProtocol.requests(for: d.teamHost).count == 2 }
        #expect(StubURLProtocol.requests(for: d.teamHost).allSatisfy { $0.url?.path == "/cdn-cgi/access/oauth/revoke" })
    }
}
