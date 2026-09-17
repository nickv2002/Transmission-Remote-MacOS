import XCTest

/// Integration tests against a disposable, local Docker Transmission daemon
/// fixture (see `scripts/fixture/`), covering RPCs that have never been
/// exercised against any server: `torrent-add`, per-file wanted/priority,
/// `torrent-rename-path`, and `torrent-remove` with `delete-local-data`.
///
/// Skipped unless `RUN_FIXTURE_TRANSMISSION_TESTS=1` is forwarded to the test
/// runner, e.g.:
///
///   RUN_FIXTURE_TRANSMISSION_TESTS=1 TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 \
///     xcodebuild ... test -only-testing:TransmissionRemoteTests/FixtureTransmissionTests
///
/// The fixture must already be running (`scripts/fixture/up.sh` /
/// `make fixture-up`) before these tests are invoked. This file is entirely
/// separate from `LiveConnectionTests.swift`, which hits the owner's real
/// production server — it never touches `PreferencesStore`/`AppConfig`'s
/// legacy-JSONC loading path, and hardcodes a `localhost:19091` server
/// config directly so it can never accidentally resolve to a real host.
final class FixtureTransmissionTests: XCTestCase {
    /// Matches `settings.json.template`'s rpc-username/rpc-password.
    private static let fixtureServer = ServerConfig(
        name: "Fixture",
        host: "localhost",
        port: 19091,
        useHTTPS: false,
        rpcPath: "/transmission/rpc",
        username: "fixture",
        password: "fixture-pass"
    )

    private var client: TransmissionClient!
    /// Torrent ids added during a test, removed in `tearDown()` even on failure.
    private var addedIds: [Int] = []

    private func requireFixture() throws {
        guard ProcessInfo.processInfo.environment["RUN_FIXTURE_TRANSMISSION_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 to run fixture "
                + "Transmission tests (requires `make fixture-up` first).")
        }
    }

    override func setUp() async throws {
        try requireFixture()
        client = try TransmissionClient(server: Self.fixtureServer)
    }

    override func tearDown() async throws {
        guard let client, !addedIds.isEmpty else { return }
        // Best-effort: stop then remove (without deleting data, since most
        // tests never download anything) any torrent this test added.
        try? await client.stop(ids: addedIds)
        try? await client.remove(ids: addedIds, deleteLocalData: false)
        addedIds.removeAll()
    }

    // MARK: - Fixtures

    /// The four Ubuntu .torrent files' base64 metainfo. Only their bytes are
    /// read — the ISOs themselves are never fetched.
    private static let torrentFileNames = [
        "ubuntu-26.04.1-live-server-arm64.iso.torrent",
        "ubuntu-26.04.1-live-server-amd64.iso.torrent",
        "ubuntu-26.04.1-desktop-arm64.iso.torrent",
        "ubuntu-26.04.1-desktop-amd64.iso.torrent",
    ]

    private func metainfoBase64(_ fileName: String) throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(fileName) not found in ~/Downloads; skipping.")
        }
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
    }

    /// Adds one torrent (paused by default) and tracks it for teardown.
    @discardableResult
    private func addTorrent(_ fileName: String, paused: Bool = true) async throws -> Int {
        let metainfo = try metainfoBase64(fileName)
        let outcome = try await client.addTorrent(
            metainfoBase64: metainfo, filename: nil, downloadDir: nil, paused: paused)
        XCTAssertFalse(outcome.duplicate, "\(fileName) should not already be a duplicate on a fresh fixture")

        // The typed `addTorrent` wrapper doesn't expose the new id, so look it
        // up by matching the freshly-added torrent's name among all torrents.
        // NOTE: `Torrent`'s decoder requires a large core set of fields
        // non-optionally (only a few secondary fields are tolerant), so we
        // must request the app's full default field set here, not a minimal
        // ["id", "name"] subset.
        let torrents = try await client.fetchTorrents()
        guard let match = torrents.first(where: { $0.name == outcome.name }) else {
            XCTFail("Could not find newly added torrent named \(outcome.name)")
            return -1
        }
        addedIds.append(match.id)
        return match.id
    }

    // MARK: - torrent-add

    func testAddEachUbuntuTorrentPaused() async throws {
        for name in Self.torrentFileNames {
            let id = try await addTorrent(name, paused: true)
            XCTAssertGreaterThan(id, 0)
        }
    }

    // MARK: - torrent-get files/fileStats

    func testFetchFilesForAddedTorrent() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        let files = try await client.fetchFiles(id: id)
        XCTAssertFalse(files.isEmpty, "expected at least one file in the torrent")
        for file in files {
            XCTAssertFalse(file.name.isEmpty)
            XCTAssertGreaterThanOrEqual(file.length, 0)
            XCTAssertGreaterThanOrEqual(file.bytesCompleted, 0)
        }
    }

    // MARK: - setFilesWanted / setFilePriority round-trip

    func testSetFilesWantedRoundTrip() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        var files = try await client.fetchFiles(id: id)
        guard let first = files.first else {
            return XCTFail("torrent has no files")
        }
        let newWanted = !first.wanted

        try await client.setFilesWanted(id: id, fileIndices: [first.index], wanted: newWanted)
        files = try await client.fetchFiles(id: id)
        guard let updated = files.first(where: { $0.index == first.index }) else {
            return XCTFail("file index \(first.index) disappeared after setFilesWanted")
        }
        XCTAssertEqual(updated.wanted, newWanted)
    }

    func testSetFilePriorityRoundTrip() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        var files = try await client.fetchFiles(id: id)
        guard let first = files.first else {
            return XCTFail("torrent has no files")
        }
        let newPriority: FilePriority = first.priority == .high ? .low : .high

        try await client.setFilePriority(id: id, fileIndices: [first.index], priority: newPriority)
        files = try await client.fetchFiles(id: id)
        guard let updated = files.first(where: { $0.index == first.index }) else {
            return XCTFail("file index \(first.index) disappeared after setFilePriority")
        }
        XCTAssertEqual(updated.priority, newPriority)
    }

    // MARK: - torrent-rename-path

    func testRenameTopLevelPath() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        let before = try await client.fetchTorrents()
        guard let torrent = before.first(where: { $0.id == id }) else {
            return XCTFail("added torrent not found")
        }
        let oldName = torrent.name
        let newName = oldName + "-renamed"

        try await client.rename(id: id, path: oldName, name: newName)

        let after = try await client.fetchTorrents()
        guard let renamed = after.first(where: { $0.id == id }) else {
            return XCTFail("torrent not found after rename")
        }
        XCTAssertEqual(renamed.name, newName)
    }

    // MARK: - setLocation / queueMove / setBandwidthPriority (call-succeeds coverage)

    func testSetLocationSucceeds() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        // Same directory the daemon already uses — a no-op move, just
        // exercising that the RPC call succeeds without throwing.
        try await client.setLocation(ids: [id], location: "/downloads", move: false)
    }

    func testQueueMoveSucceeds() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        try await client.queueMove(ids: [id], to: .top)
        try await client.queueMove(ids: [id], to: .bottom)
    }

    func testSetBandwidthPrioritySucceeds() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        try await client.setBandwidthPriority(ids: [id], priority: .high)
        let torrents = try await client.fetchTorrents()
        guard let torrent = torrents.first(where: { $0.id == id }) else {
            return XCTFail("torrent not found")
        }
        XCTAssertEqual(torrent.bandwidthPriority, .high)
    }

    // MARK: - delete-local-data removal (highest-value new coverage)

    /// The scratch downloads directory (`scripts/fixture/.data/downloads`),
    /// resolved from this source file's own path so it works regardless of
    /// the process's current working directory.
    private static var scratchDownloadsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("scripts/fixture/.data/downloads")
    }

    /// Base64 metainfo for the deterministic seed torrent `up.sh` generates
    /// from a locally-created file (`fixture-delete-me.bin`/`.torrent`) —
    /// not a real peer download, since the fixture disables DHT/PEX/LPD and
    /// publishes no peer port. The daemon verifies it as already-complete
    /// on add, so this test doesn't depend on real network transfer at all.
    private func seedTorrentMetainfoBase64() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/fixture/.data/config/fixture-delete-me.torrent")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture-delete-me.torrent not found; run scripts/fixture/up.sh first.")
        }
        return try Data(contentsOf: url).base64EncodedString()
    }

    func testRemoveWithDeleteLocalData() async throws {
        let seedFile = Self.scratchDownloadsDir.appendingPathComponent("fixture-delete-me.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedFile.path),
                      "expected the seed file up.sh creates to exist before the test runs")

        // Added paused: the daemon verifies an existing on-disk file as
        // already complete, with zero reliance on peers/network.
        let metainfo = try seedTorrentMetainfoBase64()
        let outcome = try await client.addTorrent(
            metainfoBase64: metainfo, filename: nil, downloadDir: nil, paused: true)
        XCTAssertFalse(outcome.duplicate)

        let torrents = try await client.fetchTorrents()
        guard let added = torrents.first(where: { $0.name == outcome.name }) else {
            return XCTFail("could not find newly added torrent")
        }
        let id = added.id
        addedIds.append(id)

        // Give the daemon a moment to finish its on-add verification pass.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: seedFile.path),
                      "seed file should still be present before removal")

        try await client.remove(ids: [id], deleteLocalData: true)
        addedIds.removeAll(where: { $0 == id })

        // Verify the torrent is gone from the daemon's list...
        let after = try await client.fetchTorrents()
        XCTAssertFalse(after.contains(where: { $0.id == id }), "torrent should be removed")

        // ...and, crucially, that delete-local-data actually deleted the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: seedFile.path),
                       "delete-local-data should have removed the on-disk file")
    }

    // MARK: - start / stop / startNow

    func testStartStopStartNow() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0], paused: true)

        try await client.start(ids: [id])
        try await client.stop(ids: [id])
        try await client.startNow(ids: [id])
        try await client.stop(ids: [id])

        // No assertion beyond "didn't throw" — a small local torrent with no
        // peers won't reliably reach a specific status, but every RPC call
        // above must round-trip successfully against the real daemon.
    }

    // MARK: - verify / reannounce (call-succeeds coverage)

    func testVerifySucceeds() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        try await client.verify(ids: [id])
    }

    func testReannounceSucceeds() async throws {
        let id = try await addTorrent(Self.torrentFileNames[0])
        // The fixture publishes no peer port and disables DHT/PEX/LPD, so this
        // exercises only that the daemon accepts and acks the RPC call itself,
        // not that a real tracker announce succeeds.
        try await client.reannounce(ids: [id])
    }

    // MARK: - freeSpace / fetchSession

    func testFreeSpaceReturnsAValue() async throws {
        let bytes = try await client.freeSpace(path: "/downloads")
        XCTAssertNotNil(bytes, "the fixture daemon should report free space for its own download dir")
        if let bytes { XCTAssertGreaterThanOrEqual(bytes, 0) }
    }

    func testFetchSessionReturnsDownloadDir() async throws {
        let info = try await client.fetchSession()
        XCTAssertNotNil(info.downloadDir)
        XCTAssertFalse(info.downloadDir?.isEmpty ?? true)
    }

    // MARK: - torrent-add duplicate detection

    func testDuplicateAddIsDetected() async throws {
        let name = Self.torrentFileNames[0]
        try await addTorrent(name, paused: true)

        let metainfo = try metainfoBase64(name)
        let outcome = try await client.addTorrent(
            metainfoBase64: metainfo, filename: nil, downloadDir: nil, paused: true)
        XCTAssertTrue(outcome.duplicate, "re-adding the same torrent should be reported as a duplicate")
    }
}
