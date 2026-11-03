import Foundation

/// Signs in to the Cloudflare Access application in front of a server with
/// Managed OAuth, in the user's default browser:
///
/// 1. Discover: a token-less `session-get` gets Access's `401` Bearer challenge;
///    its resource metadata names the authorization server, whose metadata gives
///    the endpoints. A redirect to the Access login page instead means Managed
///    OAuth is off for the application.
/// 2. Register this app (once per server; reused with its loopback port).
/// 3. Open the authorization URL (PKCE S256, state, resource) in the browser and
///    take the code on a 127.0.0.1 listener.
/// 4. Exchange it for an access token and a refresh token.
///
/// No request here sends or keeps cookies.
enum AccessSignIn {
    struct Environment: Sendable {
        var session: URLSession = AccessSignIn.cookielessSession
        /// Opens the URL in the default browser; false if it couldn't.
        var openBrowser: @Sendable (URL) async -> Bool
        var now: @Sendable () -> Date = { Date() }
        var userAgent: String = AccessSignIn.defaultUserAgent
        var requestTimeout: TimeInterval = 15
        /// How long to wait for the browser to come back.
        var callbackTimeout: TimeInterval = 300
        /// Starts the redirect listener on a port (nil = any free port).
        var makeReceiver: @Sendable (UInt16?) async throws -> any AuthorizationCallbackReceiver = {
            try await LoopbackCallbackServer.start(preferredPort: $0)
        }
    }

    /// Where to sign in, from discovery.
    struct Discovery: Codable, Sendable, Equatable {
        /// The protected resource (RFC 8707 `resource`), e.g. `https://host/transmission/rpc`.
        let resource: String
        let issuer: URL
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL
        let revocationEndpoint: URL?

        /// The host requests carrying the token may go to.
        var resourceHost: String { URL(string: resource)?.host?.lowercased() ?? "" }
    }

    static let cookielessSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "TransmissionRemote/\(version)"
    }

    // MARK: - Sign-in

    /// Signs in and returns the new session. `existing` is the server's previous
    /// session, whose registration (client id and loopback port) is reused when
    /// it still fits. `onSignInURL` gets the browser URL (for Copy Link).
    static func signIn(appURL: URL, existing: AccessSession?, environment env: Environment,
                       onSignInURL: @Sendable (URL) -> Void = { _ in }) async throws -> AccessSession {
        let discovery = try await discover(appURL: appURL, environment: env)
        var registration = existing?.registration
        if registration?.issuer != discovery.issuer || registration?.resource != discovery.resource {
            registration = nil
        }

        let receiver: any AuthorizationCallbackReceiver
        if let port = registration?.port, let reused = try? await env.makeReceiver(port) {
            receiver = reused
        } else {
            receiver = try await env.makeReceiver(nil)
            if registration?.port != receiver.port { registration = nil }
        }
        defer { receiver.close() }

        let client: AccessRegistration
        if let registration { client = registration } else {
            client = try await register(discovery, port: receiver.port, environment: env)
        }
        let pkce = AccessOAuth.PKCE.make()
        let state = AccessOAuth.randomState()
        let redirectURI = AccessOAuth.redirectURI(port: receiver.port)
        let url = AccessOAuth.authorizationURL(endpoint: discovery.authorizationEndpoint, clientID: client.clientID,
                                               redirectURI: redirectURI, pkce: pkce, state: state,
                                               resource: discovery.resource)
        receiver.expect(state: state)
        onSignInURL(url)
        _ = await env.openBrowser(url)   // if it fails, Copy Link still works

        let query = try await waitForCallback(receiver, timeout: env.callbackTimeout)
        guard query["state"] == state else { throw AccessError.authorization("the browser returned an unexpected response") }
        if let error = query["error"] {
            throw AccessError.authorization(query["error_description"].map { "\($0) (\(error))" } ?? error)
        }
        guard let code = query["code"], !code.isEmpty else { throw AccessError.authorization("no authorization code came back") }

        let tokens = try await tokenCall(AccessOAuth.codeExchangeRequest(
            endpoint: discovery.tokenEndpoint, code: code, clientID: client.clientID, redirectURI: redirectURI,
            verifier: pkce.verifier, resource: discovery.resource), environment: env)
        return AccessSession(discovery: discovery, registration: client, tokens: tokens, now: env.now())
    }

    private static func waitForCallback(_ receiver: any AuthorizationCallbackReceiver,
                                        timeout: TimeInterval) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await receiver.waitForCallback() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                if Task.isCancelled { throw AccessError.cancelled }
                throw AccessError.timedOut
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch is CancellationError {
                throw AccessError.cancelled
            }
        }
    }

    // MARK: - Discovery

    static func discover(appURL: URL, environment env: Environment) async throws -> Discovery {
        guard appURL.scheme?.lowercased() == "https", let host = appURL.host?.lowercased() else {
            throw AccessError.notProtected
        }
        var probe = request(appURL, env)
        probe.httpMethod = "POST"
        probe.httpBody = Data(#"{"method":"session-get"}"#.utf8)
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await send(probe, env, host: host)
        let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")
        guard let metadataURL = AccessOAuth.resourceMetadataURL(fromWWWAuthenticate: challenge) else {
            let location = response.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: appURL)?.absoluteURL }
            if CloudflareAccess.isLoginRedirect(location) { throw AccessError.managedOAuthOff }
            throw AccessError.notProtected
        }
        guard metadataURL.host?.lowercased() == host else {
            throw AccessError.discovery("the server pointed at metadata on another host")
        }

        let resource: AccessOAuth.ResourceMetadata = try await json(metadataURL, env, what: "the server’s sign-in details")
        guard URL(string: resource.resource)?.host?.lowercased() == host else {
            throw AccessError.discovery("the server described a different resource")
        }
        let issuer = try AccessOAuth.authorizationServer(from: resource)
        let server: AccessOAuth.ServerMetadata = try await json(AccessOAuth.serverMetadataURL(for: issuer), env,
                                                               what: "the sign-in server’s details")
        try AccessOAuth.validate(server, issuer: issuer)
        return Discovery(resource: resource.resource, issuer: issuer,
                         authorizationEndpoint: server.authorizationEndpoint, tokenEndpoint: server.tokenEndpoint,
                         registrationEndpoint: server.registrationEndpoint!, revocationEndpoint: server.revocationEndpoint)
    }

    static func register(_ discovery: Discovery, port: UInt16, environment env: Environment) async throws -> AccessRegistration {
        var registration = AccessOAuth.registrationRequest(endpoint: discovery.registrationEndpoint,
                                                           redirectURI: AccessOAuth.redirectURI(port: port),
                                                           resource: discovery.resource)
        prepare(&registration, env)
        let (data, response) = try await send(registration, env, host: discovery.issuer.host ?? "")
        guard (200..<300).contains(response.statusCode),
              let decoded = try? JSONDecoder().decode(AccessOAuth.RegistrationResponse.self, from: data) else {
            throw AccessError.registration(AccessOAuth.errorDescription(from: data) ?? "HTTP \(response.statusCode)")
        }
        return AccessRegistration(clientID: decoded.clientID, port: port, issuer: discovery.issuer,
                                  resource: discovery.resource)
    }

    // MARK: - Refresh and revoke

    /// A new access token (and usually a rotated refresh token) for `session`.
    /// Throws `.token` when the grant has ended, after which a browser sign-in
    /// is needed.
    static func refresh(_ session: AccessSession, environment env: Environment) async throws -> AccessSession {
        guard let refreshToken = session.refreshToken else { throw AccessError.token("there’s no refresh token") }
        let tokens = try await tokenCall(AccessOAuth.refreshRequest(
            endpoint: session.discovery.tokenEndpoint, refreshToken: refreshToken,
            clientID: session.registration.clientID, resource: session.discovery.resource), environment: env)
        var renewed = AccessSession(discovery: session.discovery, registration: session.registration,
                                    tokens: tokens, now: env.now())
        renewed.signedInAt = session.signedInAt
        if renewed.refreshToken == nil { renewed.refreshToken = refreshToken }
        return renewed
    }

    /// Revokes the session's tokens, best effort (sign-out goes ahead regardless).
    static func revoke(_ session: AccessSession, environment env: Environment) async {
        guard let endpoint = session.discovery.revocationEndpoint else { return }
        for (token, hint) in [(session.refreshToken, "refresh_token"), (session.accessToken, "access_token")] {
            guard let token else { continue }
            var request = AccessOAuth.revocationRequest(endpoint: endpoint, token: token, hint: hint,
                                                        clientID: session.registration.clientID)
            prepare(&request, env)
            _ = try? await send(request, env, host: endpoint.host ?? "")
        }
    }

    // MARK: - Plumbing

    private static func tokenCall(_ base: URLRequest, environment env: Environment) async throws -> AccessOAuth.TokenResponse {
        var request = base
        prepare(&request, env)
        let host = request.url?.host ?? ""
        let (data, response) = try await send(request, env, host: host)
        if response.statusCode == 200 {
            if let tokens = try? JSONDecoder().decode(AccessOAuth.TokenResponse.self, from: data) { return tokens }
            // A 200 that isn't a token response is a proxy or captive portal, not the grant ending.
            throw AccessError.unreachable(host, "unexpected response")
        }
        // Only a refusal ends the grant. A server error or rate limit is transient:
        // the caller keeps its tokens and tries again.
        if response.statusCode >= 500 || [408, 429].contains(response.statusCode) {
            throw AccessError.unreachable(host, "HTTP \(response.statusCode)")
        }
        throw AccessError.token(AccessOAuth.errorDescription(from: data) ?? "HTTP \(response.statusCode)")
    }

    private static func json<T: Decodable>(_ url: URL, _ env: Environment, what: String) async throws -> T {
        let (data, response) = try await send(request(url, env), env, host: url.host ?? "")
        guard response.statusCode == 200, let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw AccessError.discovery("couldn’t read \(what) (HTTP \(response.statusCode))")
        }
        return value
    }

    private static func request(_ url: URL, _ env: Environment) -> URLRequest {
        var request = URLRequest(url: url)
        prepare(&request, env)
        return request
    }

    /// Timeout, user agent, and no cookies: Access sets its own session cookie
    /// and judges a request by a stale one over a valid token.
    private static func prepare(_ request: inout URLRequest, _ env: Environment) {
        request.timeoutInterval = env.requestTimeout
        request.httpShouldHandleCookies = false
        request.setValue(env.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private static func send(_ request: URLRequest, _ env: Environment, host: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await env.session.data(for: request, delegate: RedirectRefuser.shared)
            guard let http = response as? HTTPURLResponse else { throw AccessError.unreachable(host, "non-HTTP response") }
            return (data, http)
        } catch let error as AccessError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw AccessError.cancelled
        } catch is CancellationError {
            throw AccessError.cancelled
        } catch {
            throw AccessError.unreachable(host, error.localizedDescription)
        }
    }
}
