import XCTest

/// Five ranges (AU, CN, US, DE v6, ZZ v6), gzip'd.
private let sampleGzipBase64 = "H4sIAAAAAAAAAzPUMwBBHUMwbWRqquMYygXiGEIFjcGCzn5cFnogaKADoUGCocFcRgYGhlYpSRZWVjpwZhoQ4CR0XFy5jBINDEAaQBRexRAdUVFcAAwXdF2mAAAA"

final class GeoIPDatabaseTests: XCTestCase {
    private let csv = """
    1.0.0.0,1.0.0.255,AU
    1.0.1.0,1.0.3.255,CN
    8.8.8.0,8.8.8.255,US
    2001:db8::,2001:db8:ffff:ffff:ffff:ffff:ffff:ffff,DE
    2a00::,2a00:ffff:ffff:ffff:ffff:ffff:ffff:ffff,ZZ
    garbage line
    """

    func testIPv4Lookup() {
        let db = GeoIPDatabase(csv: csv)
        XCTAssertEqual(db.country(for: "1.0.0.0"), "AU")
        XCTAssertEqual(db.country(for: "1.0.0.255"), "AU")
        XCTAssertEqual(db.country(for: "1.0.2.7"), "CN")
        XCTAssertEqual(db.country(for: "8.8.8.8"), "US")
        XCTAssertNil(db.country(for: "8.8.9.0"))
        XCTAssertNil(db.country(for: "0.0.0.1"))
        XCTAssertNil(db.country(for: "9.9.9.9"))
    }

    func testIPv6AndMappedLookup() {
        let db = GeoIPDatabase(csv: csv)
        XCTAssertEqual(db.country(for: "2001:db8::1"), "DE")
        XCTAssertNil(db.country(for: "2001:db9::1"))
        XCTAssertEqual(db.country(for: "::ffff:8.8.8.8"), "US")
    }

    func testUnknownPlaceholderAndBadInput() {
        let db = GeoIPDatabase(csv: csv)
        XCTAssertNil(db.country(for: "2a00::1"))   // ZZ
        XCTAssertNil(db.country(for: "not an ip"))
        XCTAssertNil(db.country(for: ""))
        XCTAssertEqual(db.count, 5)
    }

    func testUnsortedInputStillLooksUp() {
        let db = GeoIPDatabase(csv: "8.8.8.0,8.8.8.255,US\n1.0.0.0,1.0.0.255,AU")
        XCTAssertEqual(db.country(for: "1.0.0.9"), "AU")
        XCTAssertEqual(db.country(for: "8.8.8.8"), "US")
    }

    func testGzipRoundTrip() throws {
        let data = try XCTUnwrap(Data(base64Encoded: sampleGzipBase64))
        let db = try XCTUnwrap(GeoIPDatabase(gzipped: data))
        XCTAssertEqual(db.country(for: "1.0.1.1"), "CN")
        XCTAssertEqual(db.country(for: "2001:db8::5"), "DE")
        XCTAssertNil(GeoIPDatabase(gzipped: Data("hello".utf8)))
        XCTAssertNil(GeoIPDatabase(gzipped: Data(data.prefix(20))))
    }

    func testFlagEmoji() {
        XCTAssertEqual(GeoIPDatabase.flag(for: "US"), "🇺🇸")
        XCTAssertEqual(GeoIPDatabase.flag(for: "de"), "🇩🇪")
        XCTAssertEqual(GeoIPDatabase.flag(for: ""), "")
        XCTAssertEqual(GeoIPDatabase.flag(for: "USA"), "")
        XCTAssertEqual(GeoIPDatabase.flag(for: "1A"), "")
    }

    func testPeerSortByCountryPutsUnknownLast() {
        let peers = [TorrentPeer(address: "1.1.1.1", port: 1), TorrentPeer(address: "2.2.2.2", port: 1)]
        var a = peers[0]; a.countryCode = ""
        var b = peers[1]; b.countryCode = "US"
        XCTAssertEqual(PeerSortKey.sorted([a, b], by: .country, ascending: true).map(\.address), ["2.2.2.2", "1.1.1.1"])
        XCTAssertEqual(PeerSortKey.sorted([a, b], by: .country, ascending: false).map(\.address), ["1.1.1.1", "2.2.2.2"])
    }

    func testShowPeerCountryDefaultsOffAndRoundTrips() throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(cfg.showPeerCountry)
        let original = AppConfig(servers: [.localhost], refreshSeconds: 4, showPeerCountry: true)
        XCTAssertEqual(try PreferencesStore.decode(PreferencesStore.encode(original)), original)
    }
}

@MainActor
final class GeoIPStoreTests: XCTestCase {
    private nonisolated let dir = FileManager.default.temporaryDirectory.appendingPathComponent("geoip-\(UUID().uuidString)")

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func wait(_ store: GeoIPStore, for check: @escaping (GeoIPStore.State) -> Bool) async {
        for _ in 0..<200 where !check(store.state) { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testCandidateURLsAreCurrentThenPreviousMonth() {
        let date = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
        XCTAssertEqual(GeoIPStore.candidateURLs(now: date).map(\.lastPathComponent),
                       ["dbip-country-lite-2026-01.csv.gz", "dbip-country-lite-2025-12.csv.gz"])
    }

    func testDownloadFallsBackToPreviousMonthAndPersists() async throws {
        let sample = try XCTUnwrap(Data(base64Encoded: sampleGzipBase64))
        let dir = self.dir
        let store = GeoIPStore(directory: { dir }, now: { ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")! },
                               fetch: { url in
            if url.lastPathComponent.contains("2026-11") { throw URLError(.fileDoesNotExist) }
            return sample
        })
        XCTAssertEqual(store.state, .absent)
        store.download()
        await wait(store) { if case .ready = $0 { true } else { false } }
        guard case .ready(_, let ranges) = store.state else { return XCTFail("state \(store.state)") }
        XCTAssertEqual(ranges, 5)
        XCTAssertEqual(store.country(for: "8.8.8.8"), "US")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        // A fresh store reads the saved file back.
        let again = GeoIPStore(directory: { dir })
        again.loadIfPresent()
        await wait(again) { if case .ready = $0 { true } else { false } }
        XCTAssertEqual(again.country(for: "1.0.2.2"), "CN")

        store.remove()
        XCTAssertEqual(store.state, .absent)
        XCTAssertNil(store.country(for: "8.8.8.8"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testInvalidDownloadFailsAndKeepsNoFile() async {
        let dir = self.dir
        let store = GeoIPStore(directory: { dir }, fetch: { _ in Data("<html>nope</html>".utf8) })
        store.download()
        await wait(store) { if case .failed = $0 { true } else { false } }
        guard case .failed = store.state else { return XCTFail("state \(store.state)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(store.database)
    }
}
