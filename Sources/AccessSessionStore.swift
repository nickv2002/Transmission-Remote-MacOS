import Foundation
import Synchronization

/// This app's Managed OAuth client registration with an Access team: reused
/// across sign-ins together with the loopback port its redirect URI names.
struct AccessRegistration: Codable, Sendable, Equatable {
    var clientID: String
    var port: UInt16
    var issuer: URL
    var resource: String
}

/// A server's Cloudflare Access sign-in (Managed OAuth): where to sign in, this
/// app's registration, and the current tokens. Kept in the Keychain, never in
/// `preferences.json`, so signing in or out doesn't edit the server's settings.
/// Signing out clears the tokens but keeps the registration.
struct AccessSession: Codable, Sendable, Equatable {
    var discovery: AccessSignIn.Discovery
    var registration: AccessRegistration
    var accessToken: String?
    var refreshToken: String?
    /// When `accessToken` stops being valid.
    var expiresAt: Date?
    /// When the user last signed in through the browser.
    var signedInAt: Date?

    init(discovery: AccessSignIn.Discovery, registration: AccessRegistration,
         accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Date? = nil, signedInAt: Date? = nil) {
        self.discovery = discovery
        self.registration = registration
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.signedInAt = signedInAt
    }

    /// A session from a token response received at `now`.
    init(discovery: AccessSignIn.Discovery, registration: AccessRegistration,
         tokens: AccessOAuth.TokenResponse, now: Date) {
        self.init(discovery: discovery, registration: registration, accessToken: tokens.accessToken,
                  refreshToken: tokens.refreshToken, expiresAt: tokens.expiresIn.map { now.addingTimeInterval($0) },
                  signedInAt: now)
    }

    var isSignedIn: Bool { accessToken != nil || refreshToken != nil }

    /// The access token, if it is still good for `margin` seconds past `now`.
    func usableAccessToken(at now: Date, margin: TimeInterval = 30) -> String? {
        guard let accessToken else { return nil }
        guard let expiresAt else { return accessToken }
        return now.addingTimeInterval(margin) < expiresAt ? accessToken : nil
    }

    /// The same registration with no tokens (signed out).
    var signedOut: AccessSession { AccessSession(discovery: discovery, registration: registration) }
}

protocol AccessSessionStore: Sendable {
    func session(for server: UUID) throws -> AccessSession?
    /// Stores `session`, or deletes the server's entry when it is nil.
    func setSession(_ session: AccessSession?, for server: UUID) throws
    func storedServerIDs() throws -> Set<UUID>
}

/// Access sessions in the login Keychain: one item per server, data = JSON.
struct KeychainAccessSessionStore: AccessSessionStore {
    static let defaultService = "com.nickvance.transmission-remote-mac.cloudflare-access"

    let items: KeychainItems

    init(service: String = KeychainAccessSessionStore.defaultService) {
        items = KeychainItems(service: service, label: "Transmission Remote Cloudflare Access session")
    }

    func session(for server: UUID) throws -> AccessSession? {
        guard let data = try items.data(for: server) else { return nil }
        // An item from an earlier sign-in format reads as signed out.
        return try? JSONDecoder().decode(AccessSession.self, from: data)
    }

    func setSession(_ session: AccessSession?, for server: UUID) throws {
        try items.setData(session.map { try JSONEncoder().encode($0) }, for: server)
    }

    func storedServerIDs() throws -> Set<UUID> { try items.serverIDs() }
}

/// In-memory sessions for tests and `TestIsolation` runs.
final class InMemoryAccessSessionStore: AccessSessionStore {
    private let storage = Mutex<[UUID: AccessSession]>([:])

    init(_ initial: [UUID: AccessSession] = [:]) {
        storage.withLock { $0 = initial }
    }

    func session(for server: UUID) throws -> AccessSession? { storage.withLock { $0[server] } }

    func setSession(_ session: AccessSession?, for server: UUID) throws {
        storage.withLock { $0[server] = session }
    }

    func storedServerIDs() throws -> Set<UUID> { storage.withLock { Set($0.keys) } }
}

/// The app-wide view of Access sessions: reads each server's session from the
/// store once and caches it, so building a request never touches the Keychain.
/// Thread-safe; header sources read it from the client's actor.
final class AccessSessions: Sendable {
    static let changedNotification = Notification.Name("AccessSessionsChanged")
    /// The `UUID` of the server whose session changed.
    static let serverIDKey = "serverID"

    /// The Keychain normally; memory under test isolation and inside the unit-test
    /// bundle, so no test can reach the user's real sessions through `shared`.
    static let shared = AccessSessions(
        store: TestIsolation.isActive || NSClassFromString("XCTestCase") != nil
            ? InMemoryAccessSessionStore() : KeychainAccessSessionStore())

    private let store: any AccessSessionStore
    /// nil inside the cache means "read, and there is none".
    private let cache = Mutex<[UUID: AccessSession?]>([:])

    init(store: any AccessSessionStore) {
        self.store = store
    }

    /// The server's session, read from the store on first use. A store error
    /// reads as "no session" (the user is asked to sign in) and isn't cached.
    func session(for server: UUID) -> AccessSession? {
        if let cached = cache.withLock({ $0[server] }) { return cached }
        do {
            let loaded = try store.session(for: server)
            cache.withLock { $0[server] = .some(loaded) }
            return loaded
        } catch {
            return nil
        }
    }

    /// Stores (or, with nil, removes) the server's session and announces it.
    /// Stores (or, with nil, removes) the server's session. Announces it unless
    /// `announce` is false: a routine token refresh is saved quietly, since a
    /// change notification makes the connection restart.
    func setSession(_ session: AccessSession?, for server: UUID, announce: Bool = true) throws {
        try store.setSession(session, for: server)
        cache.withLock { $0[server] = .some(session) }
        if announce {
            NotificationCenter.default.post(name: Self.changedNotification, object: self,
                                            userInfo: [Self.serverIDKey: server])
        }
    }

    /// Deletes the sessions of servers that are no longer configured.
    func prune(keeping live: Set<UUID>) throws {
        for orphan in try store.storedServerIDs().subtracting(live) {
            try store.setSession(nil, for: orphan)
            cache.withLock { $0[orphan] = .some(nil) }
        }
    }
}
