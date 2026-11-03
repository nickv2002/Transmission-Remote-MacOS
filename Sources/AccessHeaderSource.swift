import Foundation

/// Why a request needs a fresh Cloudflare Access sign-in.
enum AccessSignInReason: Equatable, Sendable {
    /// The sign-in has ended: the token couldn't be renewed (the grant expired
    /// or was revoked), so the browser is needed again.
    case expired
    /// Access answered with its Bearer challenge: there's no usable token.
    case signedOut
    /// Access redirected to its login page: Managed OAuth is off for the
    /// application, so an app can't sign in to it.
    case managedOAuthOff
}

extension Error {
    /// The Access sign-in this error calls for, if any.
    var accessSignInReason: AccessSignInReason? {
        switch self as? TransmissionError {
        case .accessSignInRequired(let reason): return reason
        case .redirected(_, let location) where CloudflareAccess.isLoginRedirect(location): return .managedOAuthOff
        default: return nil
        }
    }
}

/// Renews Access tokens, one refresh at a time per server: Access rotates the
/// refresh token on every use, so two concurrent refreshes would spoil each
/// other. A renewed session is saved quietly; one whose grant has ended is
/// saved signed out, and announced.
actor AccessTokenRefresher {
    static let shared = AccessTokenRefresher()

    private var inFlight: [UUID: Task<AccessSession, Error>] = [:]

    func refresh(_ server: UUID, sessions: AccessSessions,
                 environment: AccessSignIn.Environment) async throws -> AccessSession {
        if let running = inFlight[server] { return try await running.value }
        guard let current = sessions.session(for: server), current.isSignedIn else {
            throw AccessError.token("not signed in")
        }
        let task = Task { try await AccessSignIn.refresh(current, environment: environment) }
        inFlight[server] = task
        defer { inFlight[server] = nil }
        do {
            let renewed = try await task.value
            try sessions.setSession(renewed, for: server, announce: false)
            return renewed
        } catch {
            if case AccessError.token = error {
                try? sessions.setSession(current.signedOut, for: server)
            }
            throw error
        }
    }
}

/// Adds the server's Cloudflare Access token as `cf-access-token` (a
/// `RequestHeaderSource`), renewing it when it's about to expire or when Access
/// refuses it. Sent only to the HTTPS host the token was issued for, so a LAN or
/// other fallback host never sees it. `Authorization` stays free for
/// Transmission's own login.
///
/// - Not signed in, or another host: adds nothing (Access answers 401).
/// - Renewal fails because the sign-in ended: fails the request as `.expired`.
struct AccessTokenHeaderSource: RequestHeaderSource {
    let serverID: UUID
    let host: String
    let sessions: AccessSessions
    var environment: @Sendable () -> AccessSignIn.Environment = AccessTokenHeaderSource.defaultEnvironment
    var refresher: AccessTokenRefresher = .shared

    @Sendable static func defaultEnvironment() -> AccessSignIn.Environment {
        AccessSignIn.Environment(openBrowser: { _ in false })
    }

    /// The source for `server`'s client, or nil when Access isn't in play for it.
    static func source(for server: ServerConfig, sessions: AccessSessions) -> AccessTokenHeaderSource? {
        guard server.useCloudflareAccess, server.useHTTPS else { return nil }
        return AccessTokenHeaderSource(serverID: server.id, host: server.host, sessions: sessions)
    }

    private var applicableSession: AccessSession? {
        guard let session = sessions.session(for: serverID), session.isSignedIn,
              session.discovery.resourceHost == host.lowercased() else { return nil }
        return session
    }

    func headers() async throws -> [CustomHeader] {
        let env = environment()
        guard let session = applicableSession else { return [] }
        if let token = session.usableAccessToken(at: env.now()) { return [header(token)] }
        return [header(try await renewedToken(env))]
    }

    func requestRejected() async -> Bool {
        guard applicableSession != nil else { return false }
        return (try? await renewedToken(environment())) != nil
    }

    private func renewedToken(_ env: AccessSignIn.Environment) async throws -> String {
        do {
            let renewed = try await refresher.refresh(serverID, sessions: sessions, environment: env)
            guard let token = renewed.accessToken else { throw TransmissionError.accessSignInRequired(.expired) }
            return token
        } catch AccessError.token {
            throw TransmissionError.accessSignInRequired(.expired)
        } catch let error as AccessError {
            throw TransmissionError.connectionFailed(error.localizedDescription)
        }
    }

    private func header(_ token: String) -> CustomHeader {
        CustomHeader(name: CloudflareAccess.tokenHeader, value: token)
    }
}
