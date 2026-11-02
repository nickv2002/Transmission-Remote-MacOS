import XCTest

/// The client behind an access proxy: the fixture's nginx sidecar on
/// localhost:19092 (`scripts/fixture/nginx.conf`) redirects `/redirect/...` to a
/// login page on another host, and forwards `/gated/...` to the daemon only when
/// the `X-Fixture-Token` header is present.
///
/// Skipped unless `RUN_FIXTURE_TRANSMISSION_TESTS=1` is forwarded to the test
/// runner; `scripts/fixture/run-tests.sh` (`make fixture-test`) runs it.
final class FixtureProxyTests: XCTestCase {
    private static let proxyPort = 19092

    private func server(path: String, headers: [CustomHeader] = []) -> ServerConfig {
        ServerConfig(name: "Fixture proxy", host: "localhost", port: Self.proxyPort, useHTTPS: false,
                     rpcPath: path, username: "fixture", password: "fixture-pass", headers: headers)
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FIXTURE_TRANSMISSION_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 to run fixture "
                + "proxy tests (requires `make fixture-up` first).")
        }
    }

    /// A redirect must not be followed: the client reports it, naming the host
    /// it pointed to, instead of fetching the login page and failing to decode it.
    func testRedirectRaisesRedirectedErrorNamingTheHost() async throws {
        let client = try TransmissionClient(server: server(path: "/redirect/transmission/rpc"), timeout: 10)
        do {
            _ = try await client.fetchSession()
            XCTFail("Expected the redirect to be refused")
        } catch let error as TransmissionError {
            guard case .redirected(let status, _) = error else {
                return XCTFail("Expected .redirected, got \(error)")
            }
            XCTAssertEqual(status, 302)
            XCTAssertEqual(error.redirectHost, "login.fixture.invalid")
        }
    }

    func testGatedPathAnswersWithTheCustomHeader() async throws {
        let client = try TransmissionClient(
            server: server(path: "/gated/transmission/rpc",
                           headers: [CustomHeader(name: "X-Fixture-Token", value: "fixture-token")]),
            timeout: 10)
        let session = try await client.fetchSession()
        XCTAssertFalse(session.version.isEmpty)
    }

    func testGatedPathRejectsAWrongHeaderValue() async throws {
        let client = try TransmissionClient(
            server: server(path: "/gated/transmission/rpc",
                           headers: [CustomHeader(name: "X-Fixture-Token", value: "wrong")]),
            timeout: 10)
        do {
            _ = try await client.fetchSession()
            XCTFail("Expected HTTP 403")
        } catch TransmissionError.httpError(let code) {
            XCTAssertEqual(code, 403)
        }
    }
}
