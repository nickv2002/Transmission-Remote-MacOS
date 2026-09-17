import XCTest

/// Regression coverage for the two concurrency bugs found in the bug-bash
/// review and fixed in `TransmissionClient.swift`/`RefreshController.swift`:
/// the CSRF session-id retry could hard-fail under concurrent RPCs, and
/// `refreshNow()` could race the scheduled poll loop and clobber its result.
///
/// Neither bug had a deterministic unit-testable trigger (both depend on real
/// network timing against a real daemon), so these are stress tests: they
/// fire many concurrent operations against the fixture and assert the
/// invariants the fixes are supposed to guarantee. They are not proof the old
/// code always failed (the races were probabilistic), but they exercise
/// exactly the code paths the fixes touch, against a real daemon.
///
/// Same gating/isolation rules as `FixtureTransmissionTests.swift`: skipped
/// unless `RUN_FIXTURE_TRANSMISSION_TESTS=1`, hardcoded `localhost:19091`,
/// never routed through `AppConfig`'s legacy-JSONC loading path.
final class FixtureConcurrencyTests: XCTestCase {
    private static let fixtureServer = ServerConfig(
        name: "Fixture",
        host: "localhost",
        port: 19091,
        useHTTPS: false,
        rpcPath: "/transmission/rpc",
        username: "fixture",
        password: "fixture-pass"
    )

    private func requireFixture() throws {
        guard ProcessInfo.processInfo.environment["RUN_FIXTURE_TRANSMISSION_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 to run fixture "
                + "concurrency tests (requires `make fixture-up` first).")
        }
    }

    // MARK: - TransmissionClient CSRF retry under concurrency

    /// Fires many `TransmissionClient`s at the daemon simultaneously, each
    /// starting with no session id, so every one of them takes the 409→retry
    /// path in `perform(body:allowRetry:)` at (as near as possible) the same
    /// moment. Before the fix, a second 409 on the retry (e.g. from the
    /// daemon rotating the session id again while these requests are in
    /// flight together) surfaced as `TransmissionError.httpError(409)`
    /// instead of retrying further. All of these must succeed.
    func testConcurrentColdClientsAllSucceedThe409Retry() async throws {
        try requireFixture()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let client = try TransmissionClient(server: Self.fixtureServer)
                    _ = try await client.fetchSession()
                }
            }
            try await group.waitForAll()
        }
    }

    /// Same idea, but against a single shared `TransmissionClient` (the
    /// actor), firing a burst of concurrent RPCs right after construction —
    /// this is the shape `RefreshController.poll()` actually uses (torrent
    /// list fetch + free-space fetch issued together).
    func testConcurrentRPCsOnSharedClientAllSucceed() async throws {
        try requireFixture()
        let client = try TransmissionClient(server: Self.fixtureServer)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await client.fetchSession() }
                group.addTask { _ = try await client.freeSpace(path: "/downloads") }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - RefreshController refreshNow() vs. the scheduled poll loop

    /// Starts the poll loop, waits for the first successful connect, then
    /// fires a burst of concurrent `refreshNow()` calls while the scheduled
    /// loop keeps running underneath. Before the fix, `refreshNow()` spawned
    /// an unstored `Task` with no single-flight guard against the loop's own
    /// `poll(client:)` call, so whichever of two overlapping polls finished
    /// second could win with stale data, or null out a freshly-adopted valid
    /// client and force a spurious reconnect. Asserts the controller settles
    /// back into a stable connected state with a non-nil client afterward.
    func testRefreshNowDoesNotRaceTheScheduledPollLoop() async throws {
        try requireFixture()

        let config = AppConfig(servers: [Self.fixtureServer], refreshSeconds: 1)
        let controller = await RefreshController(config: config)
        await controller.start()

        // Wait for the first connect (short poll interval, local daemon —
        // should be near-instant; bail out after a generous timeout). Polled
        // directly on the main actor rather than via a delegate closure, to
        // avoid capturing mutable state across isolation domains.
        let deadline = Date().addingTimeInterval(10)
        var connected = false
        while !connected, Date() < deadline {
            connected = await MainActor.run {
                if case .connected = controller.state { return true }
                return false
            }
            if !connected { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(connected, "expected the controller to connect to the fixture")

        // Fire a burst of concurrent manual refreshes while the scheduled
        // loop (refreshSeconds: 1) is also actively polling underneath.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await MainActor.run { controller.refreshNow() }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            await group.waitForAll()
        }

        // Give any in-flight polls a moment to settle, then assert the
        // controller is still in a healthy, connected state with a live
        // client — not nulled out by a losing/overlapping poll.
        try await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run {
            XCTAssertNotNil(controller.activeClient,
                             "client should not have been clobbered by racing refreshNow()/poll() calls")
            if case .connected = controller.state {
                // healthy
            } else {
                XCTFail("expected .connected state after the concurrent-refresh burst, got \(controller.state)")
            }
        }

        await controller.stop()
    }
}
