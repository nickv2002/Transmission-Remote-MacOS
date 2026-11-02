import XCTest

/// Custom header config: decode/encode shapes (values never in the JSON),
/// name validation, and filling/persisting values through a `HeaderSecretStore`.
final class CustomHeadersTests: XCTestCase {
    private let secret = "s3cr3t-token-value"

    private func server(_ headers: [CustomHeader], id: UUID = UUID()) -> ServerConfig {
        ServerConfig(id: id, name: "Proxied", host: "example.test", port: 443, useHTTPS: true,
                     rpcPath: "/transmission/rpc", headers: headers)
    }

    private func decodeServer(_ json: String) throws -> ServerConfig {
        try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
    }

    // MARK: - Decode / encode

    func testOldShapeWithoutHeadersKeyDecodesToEmpty() throws {
        let s = try decodeServer(#"{"name":"N5","host":"10.0.1.2","port":9091}"#)
        XCTAssertEqual(s.headers, [])
    }

    func testNewShapeDecodesNamesInOrderWithEmptyValues() throws {
        let s = try decodeServer(#"""
        {"name":"N5","host":"h","headers":[{"name":"X-Client-Id"},{"name":"X-Client-Secret"}]}
        """#)
        XCTAssertEqual(s.headers.map(\.name), ["X-Client-Id", "X-Client-Secret"])
        XCTAssertEqual(s.headers.map(\.value), ["", ""])
    }

    func testValueInFileIsIgnored() throws {
        let s = try decodeServer(#"{"host":"h","headers":[{"name":"X-A","value":"leaked"}]}"#)
        XCTAssertEqual(s.headers, [CustomHeader(name: "X-A", value: "")])
    }

    func testEncodingWritesNamesButNeverValues() throws {
        let config = AppConfig(servers: [server([CustomHeader(name: "X-Client-Secret", value: secret)])], refreshSeconds: 4)
        let json = String(decoding: try PreferencesStore.encode(config), as: UTF8.self)
        XCTAssertTrue(json.contains("X-Client-Secret"))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("\"value\""))
    }

    func testOldPreferencesFileStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("preferences.json")
        try Data(#"{"servers":[{"id":"\#(UUID().uuidString)","name":"N5","host":"10.0.1.2","port":9091}]}"#.utf8)
            .write(to: url)
        let config = try PreferencesStore.load(storeURL: url, legacyURL: nil)
        XCTAssertEqual(config.servers.first?.headers, [])
    }

    // MARK: - Validation

    private func issue(_ name: String, value: String = "v") -> HeaderValidation.Issue? {
        HeaderValidation.issue(at: 0, in: [CustomHeader(name: name, value: value)])
    }

    func testValidNamesPass() {
        for name in ["X-Client-Id", "CF-Access-Client-Secret", "x_custom.1", "  X-Trimmed  "] {
            XCTAssertNil(issue(name), name)
        }
        XCTAssertNil(HeaderValidation.validationMessage(for: []))
    }

    func testSystemReservedNamesRejectedCaseInsensitively() {
        for name in ["Host", "connection", "CONTENT-LENGTH", "Proxy-Authorization", "Proxy-Authenticate", "WWW-Authenticate"] {
            XCTAssertEqual(issue(name), .reservedBySystem, name)
        }
    }

    func testAuthorizationPointsAtCredentialFields() {
        XCTAssertEqual(issue("authorization"), .useCredentials)
        XCTAssertTrue(HeaderValidation.message(for: .useCredentials, name: "Authorization").contains("Username and Password"))
    }

    func testAppOwnedNamesRejected() {
        XCTAssertEqual(issue("Content-Type"), .reservedByApp)
        XCTAssertEqual(issue("x-transmission-session-id"), .reservedByApp)
    }

    func testMalformedNamesRejected() {
        XCTAssertEqual(issue(""), .emptyName)
        XCTAssertEqual(issue("   "), .emptyName)
        for name in ["X Client", "X-Client:", "X-Clïent", "X\nY"] {
            XCTAssertEqual(issue(name), .invalidName, name)
        }
    }

    func testDuplicateFlaggedOnLaterCopyOnly() {
        let headers = [CustomHeader(name: "X-A", value: "1"), CustomHeader(name: "x-a", value: "2")]
        XCTAssertNil(HeaderValidation.issue(at: 0, in: headers))
        XCTAssertEqual(HeaderValidation.issue(at: 1, in: headers), .duplicate)
    }

    func testValueWithLineBreakRejected() {
        XCTAssertEqual(issue("X-A", value: "a\r\nInjected: 1"), .valueHasLineBreak)
    }

    func testValidationMessageNamesTheHeader() {
        let message = HeaderValidation.validationMessage(for: [
            CustomHeader(name: "X-Ok", value: "1"), CustomHeader(name: "Host", value: "evil"),
        ])
        XCTAssertEqual(message, "“Host” is set by macOS and can’t be overridden.")
        XCTAssertTrue(HeaderValidation.isReserved(" HOST "))
        XCTAssertFalse(HeaderValidation.isReserved("X-Ok"))
    }

    // MARK: - Secret store

    func testHydrateFillsValuesByNameAndBlanksMissingOnes() throws {
        let id = UUID()
        let store = InMemoryHeaderStore([id: ["X-A": "alpha"]])
        let config = AppConfig(servers: [server([CustomHeader(name: "X-A", value: ""),
                                                 CustomHeader(name: "X-B", value: "")], id: id)], refreshSeconds: 4)
        let hydrated = try store.hydrate(config)
        XCTAssertEqual(hydrated.servers[0].headers, [CustomHeader(name: "X-A", value: "alpha"),
                                                     CustomHeader(name: "X-B", value: "")])
    }

    func testPersistWritesValuesKeyedByServerID() throws {
        let id = UUID()
        let store = InMemoryHeaderStore()
        try store.persist(AppConfig(servers: [server([CustomHeader(name: "X-A", value: secret)], id: id)], refreshSeconds: 4))
        XCTAssertEqual(try store.values(for: id), ["X-A": secret])
    }

    func testRemovingAHeaderRemovesItsValue() throws {
        let id = UUID()
        let store = InMemoryHeaderStore([id: ["X-A": "1", "X-B": "2"]])
        try store.persist(AppConfig(servers: [server([CustomHeader(name: "X-B", value: "2")], id: id)], refreshSeconds: 4))
        XCTAssertEqual(try store.values(for: id), ["X-B": "2"])

        try store.persist(AppConfig(servers: [server([], id: id)], refreshSeconds: 4))
        XCTAssertEqual(try store.storedServerIDs(), [])
    }

    func testRemovingAServerRemovesItsEntry() throws {
        let kept = UUID(), removed = UUID()
        let store = InMemoryHeaderStore([kept: ["X-A": "1"], removed: ["X-A": "2"]])
        try store.persist(AppConfig(servers: [server([CustomHeader(name: "X-A", value: "1")], id: kept)], refreshSeconds: 4))
        XCTAssertEqual(try store.storedServerIDs(), [kept])
    }

    func testRoundTripThroughFileAndStore() throws {
        let original = AppConfig(
            servers: [server([CustomHeader(name: "X-Client-Id", value: "id.access"),
                              CustomHeader(name: "X-Client-Secret", value: secret)])], refreshSeconds: 4)
        let store = InMemoryHeaderStore()
        try store.persist(original)
        let reloaded = try store.hydrate(PreferencesStore.decode(PreferencesStore.encode(original)))
        XCTAssertEqual(reloaded.servers, original.servers)
    }

    /// Opt-in: exercises the real login Keychain under a throwaway service name.
    func testKeychainStoreRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RUN_KEYCHAIN_TESTS=1 to exercise the real Keychain.")
        }
        let store = KeychainHeaderStore(service: "com.nickvance.transmission-remote-mac.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.removeValues(for: id) }
        XCTAssertEqual(try store.values(for: id), [:])
        try store.setValues(["X-A": "1"], for: id)
        try store.setValues(["X-A": "2", "X-B": "3"], for: id)
        XCTAssertEqual(try store.values(for: id), ["X-A": "2", "X-B": "3"])
        XCTAssertEqual(try store.storedServerIDs(), [id])
        try store.removeValues(for: id)
        XCTAssertEqual(try store.storedServerIDs(), [])
    }
}
