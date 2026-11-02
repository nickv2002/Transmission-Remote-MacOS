import Foundation
import Testing

/// The Managed OAuth sign-in against stubs: discovery, registration, the
/// browser round trip, token exchange, refresh and revocation.
@Suite("Cloudflare Access: sign-in flow")
struct AccessSignInTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func registered(_ d: AccessStub.Deployment) -> StubURLProtocol.Reply {
        .init(status: 201, body: #"{"client_id":"client-1","redirect_uris":["http://127.0.0.1:51001/callback"]}"#)
    }

    private func token(_ json: String = AccessStub.tokenJSON) -> StubURLProtocol.Reply { .init(body: json) }

    // MARK: - Sign-in

    @Test func aFullSignInRegistersAuthorizesAndExchanges() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [registered(d), token()])
        let factory = ReceiverFactory(), opened = OpenedURLs()
        let session = try await AccessSignIn.signIn(
            appURL: d.appURL, existing: nil,
            environment: AccessStub.environment(now: now, factory: factory, opened: opened))

        #expect(session.accessToken == "oauth:access-1" && session.refreshToken == "oauth:refresh-1")
        #expect(session.expiresAt == now.addingTimeInterval(900))
        #expect(session.signedInAt == now)
        #expect(session.registration == AccessRegistration(clientID: "client-1", port: 51_001, issuer: d.issuer,
                                                           resource: d.resource))
        #expect(session.discovery == d.discovery)

        // Discovery: a token-less, cookie-less probe, then the resource metadata.
        let app = StubURLProtocol.requests(for: d.appHost)
        #expect(app.count == 2)
        #expect(app[0].httpMethod == "POST" && app[0].value(forHTTPHeaderField: "cf-access-token") == nil)
        #expect(app[1].url?.path == "/.well-known/cloudflare-access-protected-resource/transmission/rpc")
        #expect(app.allSatisfy { !$0.httpShouldHandleCookies })

        let team = StubURLProtocol.requests(for: d.teamHost)
        #expect(team.map { $0.url?.path ?? "" } == ["/.well-known/oauth-authorization-server",
                                                     "/cdn-cgi/access/oauth/registration", "/cdn-cgi/access/oauth/token"])
        let registration = AccessStub.jsonBody(team[1])
        #expect(registration["redirect_uris"] as? [String] == ["http://127.0.0.1:51001/callback"])
        #expect(registration["token_endpoint_auth_method"] as? String == "none")

        // The browser got PKCE, state and resource; the exchange proves the verifier.
        let url = try #require(opened.all.first)
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(url.host == d.teamHost && url.path == "/cdn-cgi/access/oauth/authorization")
        #expect(query["client_id"] == "client-1" && query["resource"] == d.resource)
        #expect(query["code_challenge_method"] == "S256" && query["redirect_uri"] == "http://127.0.0.1:51001/callback")
        let exchange = AccessStub.form(team[2])
        #expect(exchange["grant_type"] == "authorization_code" && exchange["code"] == "code-1")
        #expect(AccessOAuth.PKCE.challenge(for: exchange["code_verifier"] ?? "") == query["code_challenge"])
        #expect(exchange["redirect_uri"] == "http://127.0.0.1:51001/callback" && exchange["resource"] == d.resource)
        #expect(factory.receivers.allSatisfy { $0.isClosed })
    }

    @Test func anEarlierRegistrationIsReusedWithItsPort() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [token()])   // no registration request expected
        let factory = ReceiverFactory()
        let previous = d.session(accessToken: nil, refreshToken: nil, expiresAt: nil, port: 52_000)
        let session = try await AccessSignIn.signIn(appURL: d.appURL, existing: previous,
                                                    environment: AccessStub.environment(now: now, factory: factory))
        #expect(factory.requestedPorts == [52_000])
        #expect(session.registration.clientID == "client-0")
        #expect(!StubURLProtocol.requests(for: d.teamHost).contains { $0.url?.path.hasSuffix("/registration") == true })
    }

    @Test func aBusyPortMeansANewPortAndANewRegistration() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [registered(d), token()])
        let factory = ReceiverFactory(busy: [52_000])
        let previous = d.session(accessToken: nil, refreshToken: nil, expiresAt: nil, port: 52_000)
        let session = try await AccessSignIn.signIn(appURL: d.appURL, existing: previous,
                                                    environment: AccessStub.environment(now: now, factory: factory))
        #expect(factory.requestedPorts == [52_000, nil])
        #expect(session.registration.clientID == "client-1" && session.registration.port == 51_001)
    }

    // MARK: - Discovery failures

    @Test func aLoginRedirectMeansManagedOAuthIsOff() async throws {
        let d = AccessStub.Deployment()
        d.install(app: [.init(status: 302, headers: ["Location": "https://\(d.teamHost)/cdn-cgi/access/login/\(d.appHost)"])],
                  team: [])
        await #expect(throws: AccessError.managedOAuthOff) {
            _ = try await AccessSignIn.signIn(appURL: d.appURL, existing: nil, environment: AccessStub.environment(now: now))
        }
        #expect(StubURLProtocol.requests(for: d.teamHost).isEmpty)
    }

    @Test func aServerWithoutAChallengeIsNotProtectedAndPlainHTTPIsNeverTried() async throws {
        let d = AccessStub.Deployment()
        d.install(app: [.init(status: 409)], team: [])
        await #expect(throws: AccessError.notProtected) {
            _ = try await AccessSignIn.discover(appURL: d.appURL, environment: AccessStub.environment(now: now))
        }
        let host = StubURLProtocol.uniqueHost()
        await #expect(throws: AccessError.notProtected) {
            _ = try await AccessSignIn.discover(appURL: URL(string: "http://\(host)/rpc")!,
                                                environment: AccessStub.environment(now: now))
        }
        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }

    @Test func untrustedMetadataIsRejected() async throws {
        let d = AccessStub.Deployment()
        // The resource metadata names a sign-in server that isn't a Cloudflare Access team domain.
        d.install(app: [d.challenge, .init(body: #"{"resource":"\#(d.resource)","authorization_servers":["https://login.evil.example"]}"#)],
                  team: [])
        await #expect(throws: AccessError.self) {
            _ = try await AccessSignIn.discover(appURL: d.appURL, environment: AccessStub.environment(now: now))
        }
        // …or describes a resource on another host.
        let e = AccessStub.Deployment()
        e.install(app: [e.challenge, .init(body: #"{"resource":"https://elsewhere.example/rpc","authorization_servers":["https://\#(e.teamHost)"]}"#)],
                  team: [])
        await #expect(throws: AccessError.self) {
            _ = try await AccessSignIn.discover(appURL: e.appURL, environment: AccessStub.environment(now: now))
        }
    }

    // MARK: - Browser round trip

    @Test func aDeniedOrForgedCallbackFailsWithoutAToken() async throws {
        for browser in [AccessStub.Browser.deny("access_denied"), .wrongState] {
            let d = AccessStub.Deployment()
            d.install(team: [registered(d), token()])
            await #expect(throws: AccessError.self) {
                _ = try await AccessSignIn.signIn(appURL: d.appURL, existing: nil,
                                                  environment: AccessStub.environment(now: now, browser: browser))
            }
            #expect(!StubURLProtocol.requests(for: d.teamHost).contains { $0.url?.path.hasSuffix("/token") == true })
        }
    }

    @Test func aBrowserThatNeverReturnsTimesOut() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [registered(d)])
        await #expect(throws: AccessError.timedOut) {
            _ = try await AccessSignIn.signIn(appURL: d.appURL, existing: nil,
                                              environment: AccessStub.environment(now: now, browser: .never, callbackTimeout: 0.2))
        }
    }

    @Test func cancellingWhileWaitingStops() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [registered(d)])
        let opened = OpenedURLs()
        let env = AccessStub.environment(now: now, browser: .never, opened: opened, callbackTimeout: 60)
        let appURL = d.appURL
        let task = Task { try await AccessSignIn.signIn(appURL: appURL, existing: nil, environment: env) }
        for _ in 0..<400 where opened.all.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: AccessError.cancelled) { _ = try await task.value }
    }

    @Test func registrationAndTokenErrorsAreReported() async throws {
        let d = AccessStub.Deployment()
        d.install(team: [.init(status: 400, body: #"{"error":"invalid_redirect_uri","error_description":"Loopback not allowed"}"#)])
        do {
            _ = try await AccessSignIn.signIn(appURL: d.appURL, existing: nil, environment: AccessStub.environment(now: now))
            Issue.record("expected a registration error")
        } catch let error as AccessError {
            #expect(error == .registration("Loopback not allowed (invalid_redirect_uri)"))
        }
        let e = AccessStub.Deployment()
        e.install(team: [registered(e), .init(status: 400, body: #"{"error":"invalid_grant"}"#)])
        await #expect(throws: AccessError.token("invalid_grant")) {
            _ = try await AccessSignIn.signIn(appURL: e.appURL, existing: nil, environment: AccessStub.environment(now: now))
        }
    }

    // MARK: - Refresh and revoke

    @Test func refreshRotatesTokensAndKeepsTheSignInTime() async throws {
        let d = AccessStub.Deployment()
        StubURLProtocol.set([token(#"{"access_token":"oauth:access-2","expires_in":60,"refresh_token":"oauth:refresh-2"}"#)],
                            for: d.teamHost)
        let old = d.session(expiresAt: now, signedInAt: now.addingTimeInterval(-3600))
        let renewed = try await AccessSignIn.refresh(old, environment: AccessStub.environment(now: now))
        #expect(renewed.accessToken == "oauth:access-2" && renewed.refreshToken == "oauth:refresh-2")
        #expect(renewed.expiresAt == now.addingTimeInterval(60))
        #expect(renewed.signedInAt == now.addingTimeInterval(-3600))
        let body = AccessStub.form(try #require(StubURLProtocol.requests(for: d.teamHost).first))
        #expect(body == ["grant_type": "refresh_token", "refresh_token": "oauth:refresh-0", "client_id": "client-0",
                         "resource": d.resource])
    }

    @Test func aRefreshWithoutARotatedTokenKeepsTheOldOne() async throws {
        let d = AccessStub.Deployment()
        StubURLProtocol.set([token(#"{"access_token":"oauth:access-2","expires_in":60}"#)], for: d.teamHost)
        let renewed = try await AccessSignIn.refresh(d.session(expiresAt: now), environment: AccessStub.environment(now: now))
        #expect(renewed.refreshToken == "oauth:refresh-0")
    }

    @Test func anEndedGrantFailsTheRefresh() async throws {
        let d = AccessStub.Deployment()
        StubURLProtocol.set([.init(status: 400, body: #"{"error":"invalid_grant","error_description":"Grant expired"}"#)],
                            for: d.teamHost)
        await #expect(throws: AccessError.token("Grant expired (invalid_grant)")) {
            _ = try await AccessSignIn.refresh(d.session(expiresAt: now), environment: AccessStub.environment(now: now))
        }
    }

    @Test func revokeSendsBothTokens() async throws {
        let d = AccessStub.Deployment()
        StubURLProtocol.set([.init(), .init()], for: d.teamHost)
        await AccessSignIn.revoke(d.session(expiresAt: now), environment: AccessStub.environment(now: now))
        let bodies = StubURLProtocol.requests(for: d.teamHost).map(AccessStub.form)
        #expect(bodies.map { $0["token_type_hint"] } == ["refresh_token", "access_token"])
        #expect(bodies.map { $0["token"] } == ["oauth:refresh-0", "oauth:access-0"])
    }

    // MARK: - Loopback parsing

    @Test func onlyACallbackRequestLineYieldsAQuery() {
        #expect(LoopbackCallbackServer.callbackQuery(fromRequest: "GET /callback?code=abc&state=s%2B1 HTTP/1.1\r\nHost: x\r\n\r\n")
            == ["code": "abc", "state": "s+1"])
        #expect(LoopbackCallbackServer.callbackQuery(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackCallbackServer.callbackQuery(fromRequest: "POST /callback?code=a HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackCallbackServer.callbackQuery(fromRequest: "") == nil)
    }

    @Test func theResultPageIsBrandedAndEchoesNothing() {
        let icon = Data([0x89, 0x50, 0x4E, 0x47])
        let signedIn = LoopbackCallbackServer.page(for: ["code": "c", "state": "s"], icon: icon)
        #expect(signedIn.contains("<span>Transmission Remote</span>"))
        #expect(signedIn.contains("data:image/png;base64,\(icon.base64EncodedString())"))
        #expect(signedIn.contains("<h1>Signed in</h1>"))
        #expect(!signedIn.contains("<script"), "no script: browsers won't let it close the tab anyway")

        let denied = LoopbackCallbackServer.page(for: ["error": "access_denied", "state": "<b>x</b>"], icon: nil)
        #expect(denied.contains("<h1>Sign-in didn’t complete</h1>"))
        #expect(!denied.contains("<img"), "no icon outside the app bundle")
        #expect(!denied.contains("access_denied") && !denied.contains("<b>x"), "nothing from the query is echoed")

        #expect(LoopbackCallbackServer.page(for: nil, icon: nil).contains("<h1>Not found</h1>"))
    }
}
