import Foundation
import Synchronization
import Testing

/// Access sessions: Keychain-shaped storage, the shared cache, pruning, and the
/// server flag that turns the feature on.
@Suite("Cloudflare Access: session storage")
struct AccessSessionStoreTests {
    private static let deployment = AccessStub.Deployment()
    private func session(_ token: String = "oauth:access-0") -> AccessSession {
        Self.deployment.session(accessToken: token, expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                                signedInAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Counts reads, and can fail them.
    final class CountingStore: AccessSessionStore {
        let inner = InMemoryAccessSessionStore()
        let reads = Mutex(0)
        let failing = Mutex(false)
        struct Boom: Error {}
        func session(for server: UUID) throws -> AccessSession? {
            reads.withLock { $0 += 1 }
            if failing.withLock({ $0 }) { throw Boom() }
            return try inner.session(for: server)
        }
        func setSession(_ session: AccessSession?, for server: UUID) throws { try inner.setSession(session, for: server) }
        func storedServerIDs() throws -> Set<UUID> { try inner.storedServerIDs() }
    }

    @Test func sessionsAreReadOnceAndAbsenceIsCachedToo() throws {
        let store = CountingStore()
        let id = UUID(), none = UUID()
        try store.inner.setSession(session(), for: id)
        let sessions = AccessSessions(store: store)
        #expect(sessions.session(for: id)?.accessToken == "oauth:access-0")
        #expect(sessions.session(for: id) != nil)
        #expect(sessions.session(for: none) == nil)
        #expect(sessions.session(for: none) == nil)
        #expect(store.reads.withLock { $0 } == 2)
    }

    @Test func aStoreErrorReadsAsSignedOutAndIsRetried() throws {
        let store = CountingStore()
        let id = UUID()
        try store.inner.setSession(session(), for: id)
        store.failing.withLock { $0 = true }
        let sessions = AccessSessions(store: store)
        #expect(sessions.session(for: id) == nil)
        store.failing.withLock { $0 = false }
        #expect(sessions.session(for: id) != nil)
    }

    @Test func settingASessionStoresCachesAndAnnounces() async throws {
        let store = InMemoryAccessSessionStore()
        let sessions = AccessSessions(store: store)
        let id = UUID()
        let posted = Mutex<[UUID]>([])
        let observer = NotificationCenter.default.addObserver(forName: AccessSessions.changedNotification,
                                                              object: sessions, queue: nil) { note in
            if let server = note.userInfo?[AccessSessions.serverIDKey] as? UUID { posted.withLock { $0.append(server) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try sessions.setSession(session(), for: id)
        #expect(try store.session(for: id) == session())
        try sessions.setSession(nil, for: id)
        #expect(try store.session(for: id) == nil)
        #expect(sessions.session(for: id) == nil)
        #expect(posted.withLock { $0 } == [id, id])
    }

    @Test func pruneRemovesSessionsOfRemovedServers() throws {
        let kept = UUID(), removed = UUID()
        let store = InMemoryAccessSessionStore([kept: session(), removed: session("oauth:old")])
        let sessions = AccessSessions(store: store)
        _ = sessions.session(for: removed)
        try sessions.prune(keeping: [kept])
        #expect(try store.storedServerIDs() == [kept])
        #expect(sessions.session(for: removed) == nil)
    }

    @Test func theServerFlagDecodesWithADefaultAndRoundTrips() throws {
        let old = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"host":"h"}"#.utf8))
        #expect(!old.useCloudflareAccess)
        var on = old
        on.useCloudflareAccess = true
        let json = try PreferencesStore.encode(AppConfig(servers: [on], refreshSeconds: 4))
        #expect(try PreferencesStore.decode(json).servers.first?.useCloudflareAccess == true)
        #expect(!String(decoding: json, as: UTF8.self).contains("cf-access"))
    }

    @Test func aSessionRoundTripsAndSigningOutKeepsTheRegistration() throws {
        let original = session()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AccessSession.self, from: data) == original)
        let out = original.signedOut
        #expect(!out.isSignedIn && out.accessToken == nil && out.refreshToken == nil)
        #expect(out.registration == original.registration && out.discovery == original.discovery)
    }

    @Test func aTokenIsUsableUntilShortlyBeforeItExpires() {
        let expires = Date(timeIntervalSince1970: 1_800_000_900)
        let s = Self.deployment.session(expiresAt: expires)
        #expect(s.usableAccessToken(at: expires.addingTimeInterval(-31)) == "oauth:access-0")
        #expect(s.usableAccessToken(at: expires.addingTimeInterval(-29)) == nil)
        #expect(Self.deployment.session(expiresAt: nil).usableAccessToken(at: expires) == "oauth:access-0")
    }

    /// Opt-in: the real login Keychain under a throwaway service name.
    @Test func keychainStoreRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1" else { return }
        let store = KeychainAccessSessionStore(service: "com.nickvance.transmission-remote-mac.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.setSession(nil, for: id) }
        #expect(try store.session(for: id) == nil)
        try store.setSession(session(), for: id)
        #expect(try store.session(for: id) == session())
        #expect(try store.storedServerIDs() == [id])
        try store.setSession(nil, for: id)
        #expect(try store.storedServerIDs().isEmpty)
    }
}
