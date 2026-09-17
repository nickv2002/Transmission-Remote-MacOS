import XCTest

/// Fixture-backed counterparts to the failure/failover shapes in
/// `LiveConnectionTests.swift` (unknown host, wrong password, multi-host
/// failover racing), so those code paths get real, deterministic coverage
/// instead of being skipped whenever `RUN_LIVE_TRANSMISSION_TESTS` is off.
///
/// This is deliberately a separate file from `LiveConnectionTests.swift`,
/// which stays pointed at the owner's real hosts and real credentials — that
/// file's whole point is verifying the app's actual production topology
/// (a specific IP, a specific `.local` hostname, a specific Tailscale HTTPS
/// endpoint), which a Docker fixture cannot stand in for without lying about
/// what's being tested. Rewriting it to hit `localhost:19091` would silently
/// defeat that (and invert the prod-leak risk this whole fixture setup was
/// built to avoid). So: same underlying mechanisms, exercised safely here;
/// the real-host checks stay real, gated, and separate.
///
/// Same isolation rules as `FixtureTransmissionTests.swift`/
/// `FixtureConcurrencyTests.swift`: skipped unless
/// `RUN_FIXTURE_TRANSMISSION_TESTS=1`, hardcoded `localhost:19091`, never
/// routed through `AppConfig`'s legacy-JSONC loading path.
final class FixtureFailoverTests: XCTestCase {
    private static let fixtureHost = "localhost"
    private static let fixturePort = 19091
    private static let fixtureUser = "fixture"
    private static let fixturePass = "fixture-pass"

    private func requireFixture() throws {
        guard ProcessInfo.processInfo.environment["RUN_FIXTURE_TRANSMISSION_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 to run fixture "
                + "failover tests (requires `make fixture-up` first).")
        }
    }

    private func make(_ host: String, port: Int = fixturePort, https: Bool = false,
                      user: String? = fixtureUser, pass: String? = fixturePass) -> ServerConfig {
        ServerConfig(name: host, host: host, port: port, useHTTPS: https,
                     rpcPath: "/transmission/rpc", username: user, password: pass)
    }

    // MARK: - Basic reachability

    /// Loopback isn't subject to the ATS cleartext-to-named-host restriction
    /// that forces `LiveConnectionTests` to special-case plain HTTP, so this
    /// runs unconditionally — no ATS skip path needed.
    func testConnectSucceedsAgainstFixture() async throws {
        try requireFixture()
        let client = try TransmissionClient(server: make(Self.fixtureHost))
        let info = try await client.fetchSession()
        XCTAssertFalse(info.version.isEmpty)
    }

    // MARK: - Failures

    func testUnknownHostFails() async throws {
        try requireFixture()
        let client = try TransmissionClient(server: make("does-not-exist.invalid", https: true))
        do {
            _ = try await client.fetchSession()
            XCTFail("Expected a connection failure for an unknown host.")
        } catch let error as TransmissionError {
            if case .connectionFailed = error { /* expected */ } else {
                XCTFail("Expected .connectionFailed, got \(error)")
            }
        }
    }

    func testWrongPasswordFailsAuth() async throws {
        try requireFixture()
        let client = try TransmissionClient(server: make(Self.fixtureHost, pass: "definitely-wrong-password"))
        do {
            _ = try await client.fetchSession()
            XCTFail("Expected authentication to fail with a wrong password.")
        } catch let error as TransmissionError {
            if case .authenticationFailed = error { /* expected */ } else {
                XCTFail("Expected .authenticationFailed, got \(error)")
            }
        }
    }

    // MARK: - Failover (multi-host)

    /// Candidates: two unreachable hosts (one bogus DNS name, one a closed
    /// local port so it fails fast rather than timing out) plus the fixture
    /// itself, deliberately listed last — proves `ConnectionResolver` races
    /// all candidates and picks the one that actually answers, not just the
    /// first in the list.
    func testFailoverPicksTheReachableFixtureHost() async throws {
        try requireFixture()
        let server = make("does-not-exist.invalid, localhost:1, localhost:\(Self.fixturePort)")
        let chosen = await ConnectionResolver.firstReachable(server.connectionCandidates) { candidate in
            guard let client = try? TransmissionClient(server: candidate, timeout: 5) else { return false }
            return (try? await client.fetchSession()) != nil
        }
        XCTAssertEqual(chosen?.port, Self.fixturePort,
                       "expected failover to resolve to the one reachable candidate (the fixture)")
    }
}
