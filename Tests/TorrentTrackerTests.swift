import XCTest
import Foundation

/// Decoding, status text, and sorting for the Trackers tab
/// (`TrackerStatsInfo` / `TrackerSortKey` in `Models.swift`).
final class TorrentTrackerTests: XCTestCase {
    private func tracker(_ dict: [String: Any]) -> TrackerStatsInfo {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(TrackerStatsInfo.self, from: data)
    }

    // MARK: - Decoding

    func testDecodeFullTracker() {
        let t = tracker([
            "id": 2, "announce": "https://tracker.example.org/announce",
            "announceState": 1, "hasAnnounced": true, "lastAnnounceSucceeded": true,
            "lastAnnounceResult": "Success", "hasScraped": true, "lastScrapeSucceeded": true,
            "lastScrapeResult": "", "nextAnnounceTime": 1_800_000_000,
            "seederCount": 12, "leecherCount": 3,
        ])
        XCTAssertEqual(t.id, 2)
        XCTAssertEqual(t.announce, "https://tracker.example.org/announce")
        XCTAssertEqual(t.seederCount, 12)
        XCTAssertEqual(t.leecherCount, 3)
        XCTAssertEqual(t.nextAnnounceTime, 1_800_000_000)
    }

    func testDecodeEmptyObjectUsesDefaults() {
        let t = tracker([:])
        XCTAssertEqual(t.id, 0)
        XCTAssertEqual(t.announce, "")
        XCTAssertEqual(t.seederCount, -1)
        XCTAssertEqual(t.leecherCount, -1)
        XCTAssertFalse(t.hasAnnounced)
        XCTAssertEqual(t.statusText, "")
    }

    func testDecodeTrackersArguments() throws {
        let json = #"{"torrents":[{"id":7,"trackerStats":[{"id":0,"announce":"udp://a:1"},{"id":1,"announce":"udp://b:2"}]}]}"#
        let args = try JSONDecoder().decode(TorrentTrackersArguments.self, from: Data(json.utf8))
        XCTAssertEqual(args.torrents.first?.trackerStats.map(\.announce), ["udp://a:1", "udp://b:2"])
    }

    // MARK: - Status text

    func testStatusBeforeFirstAnnounceIsEmpty() {
        XCTAssertEqual(TrackerStatsInfo(announce: "x").statusText, "")
    }

    func testStatusUpdatingForQueuedAndActive() {
        XCTAssertEqual(TrackerStatsInfo(announceState: 2).statusText, "Updating")
        XCTAssertEqual(TrackerStatsInfo(announceState: 3, hasAnnounced: true,
                                        lastAnnounceSucceeded: true).statusText, "Updating")
    }

    func testStatusWorkingAfterSuccess() {
        let t = TrackerStatsInfo(hasAnnounced: true, lastAnnounceSucceeded: true, lastAnnounceResult: "Success")
        XCTAssertEqual(t.statusText, "Working")
    }

    func testStatusShowsAnnounceError() {
        let t = TrackerStatsInfo(hasAnnounced: true, lastAnnounceSucceeded: false,
                                 lastAnnounceResult: "Could not connect to tracker")
        XCTAssertEqual(t.statusText, "Could not connect to tracker")
    }

    func testStatusShowsScrapeErrorWhenAnnounceWorked() {
        let t = TrackerStatsInfo(hasAnnounced: true, lastAnnounceSucceeded: true,
                                 hasScraped: true, lastScrapeSucceeded: false,
                                 lastScrapeResult: "Unregistered torrent")
        XCTAssertEqual(t.statusText, "Unregistered torrent")
    }

    // MARK: - Next announce

    func testNextAnnounceCountdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(TrackerStatsInfo(nextAnnounceTime: 1_090).secondsUntilNextAnnounce(now: now), 90)
        XCTAssertEqual(TrackerStatsInfo(nextAnnounceTime: 900).secondsUntilNextAnnounce(now: now), 0)
        XCTAssertNil(TrackerStatsInfo(nextAnnounceTime: 0).secondsUntilNextAnnounce(now: now))
        XCTAssertNil(TrackerStatsInfo(announceState: 3, nextAnnounceTime: 1_090).secondsUntilNextAnnounce(now: now))
    }

    // MARK: - Sorting

    private let sample = [
        TrackerStatsInfo(id: 0, announce: "udp://b.example:1", hasAnnounced: true,
                         lastAnnounceSucceeded: true, nextAnnounceTime: 1_300, seederCount: 5, leecherCount: 1),
        TrackerStatsInfo(id: 1, announce: "udp://a.example:1", hasAnnounced: true,
                         lastAnnounceSucceeded: false, lastAnnounceResult: "Timeout",
                         nextAnnounceTime: 1_100, seederCount: -1, leecherCount: -1),
        TrackerStatsInfo(id: 2, announce: "udp://c.example:1", hasAnnounced: true,
                         lastAnnounceSucceeded: true, nextAnnounceTime: 1_200, seederCount: 5, leecherCount: 9),
    ]
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNilKeyKeepsDaemonOrder() {
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: nil, ascending: true).map(\.id), [0, 1, 2])
    }

    func testSortByName() {
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .name, ascending: true).map(\.id), [1, 0, 2])
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .name, ascending: false).map(\.id), [2, 0, 1])
    }

    func testSortByStatus() {
        // "Timeout" < "Working" (case-insensitive).
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .status, ascending: true).map(\.id).first, 1)
    }

    func testSortByUpdateIn() {
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .updateIn, ascending: true, now: now).map(\.id), [1, 2, 0])
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .updateIn, ascending: false, now: now).map(\.id), [0, 2, 1])
    }

    func testSortBySeedsTieBreaksByIdAscendingBothDirections() {
        // ids 0 and 2 tie on 5 seeds; the tie-break stays id-ascending either way.
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .seeds, ascending: true).map(\.id), [1, 0, 2])
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .seeds, ascending: false).map(\.id), [0, 2, 1])
    }

    func testSortByLeechers() {
        XCTAssertEqual(TrackerSortKey.sorted(sample, by: .leechers, ascending: false).map(\.id), [2, 0, 1])
    }

    // MARK: - Edge cases

    func testCodableRoundTrip() throws {
        let original = TrackerStatsInfo(id: 4, announce: "udp://t:1", announceState: 3,
                                        hasAnnounced: true, lastAnnounceSucceeded: true,
                                        lastAnnounceResult: "Success", hasScraped: true,
                                        lastScrapeSucceeded: false, lastScrapeResult: "bad",
                                        nextAnnounceTime: 42, seederCount: 7, leecherCount: 2)
        let decoded = try JSONDecoder().decode(TrackerStatsInfo.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testTorrentSeedsTotalUsesFirstTrackerFromFullStats() {
        let t = TorrentFactory.make(["trackerStats": [
            ["id": 0, "announce": "udp://a:1", "seederCount": 8, "leecherCount": 2],
            ["id": 1, "announce": "udp://b:1", "seederCount": 99, "leecherCount": 99],
        ]])
        XCTAssertEqual(t.seedsTotal, 8)
        XCTAssertEqual(t.leechersTotal, 2)
    }

    func testTrackersArgumentsWithNoTorrentsOrStats() throws {
        let empty = try JSONDecoder().decode(TorrentTrackersArguments.self, from: Data(#"{"torrents":[]}"#.utf8))
        XCTAssertTrue(empty.torrents.isEmpty)
        let none = try JSONDecoder().decode(TorrentTrackersArguments.self,
                                            from: Data(#"{"torrents":[{"id":1,"trackerStats":[]}]}"#.utf8))
        XCTAssertEqual(none.torrents.first?.trackerStats.count, 0)
    }

    func testUpdatingTrackersDoNotCountAsScheduledWhenSortingByUpdateIn() {
        let list = [
            TrackerStatsInfo(id: 0, announceState: 3, nextAnnounceTime: 5_000),
            TrackerStatsInfo(id: 1, nextAnnounceTime: 1_100),
        ]
        // Updating sorts as 0 (like "none"), ahead of a real countdown.
        XCTAssertEqual(TrackerSortKey.sorted(list, by: .updateIn, ascending: true, now: now).map(\.id), [0, 1])
    }

    func testSortingEmptyAndSingleListIsStable() {
        XCTAssertTrue(TrackerSortKey.sorted([], by: .name, ascending: true).isEmpty)
        let one = [TrackerStatsInfo(id: 3, announce: "x")]
        XCTAssertEqual(TrackerSortKey.sorted(one, by: .seeds, ascending: false), one)
    }

    func testNameSortIsNumericAware() {
        let list = [TrackerStatsInfo(id: 0, announce: "udp://t10.example"),
                    TrackerStatsInfo(id: 1, announce: "udp://t2.example")]
        XCTAssertEqual(TrackerSortKey.sorted(list, by: .name, ascending: true).map(\.id), [1, 0])
    }

    func testSortKeyRawValuesMatchColumnIdentifiers() {
        for key in ["name", "status", "updateIn", "seeds", "leechers"] {
            XCTAssertNotNil(TrackerSortKey(rawValue: key), key)
        }
    }
}
