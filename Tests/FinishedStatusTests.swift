import XCTest

/// A torrent the daemon stopped at its seed limit (`isFinished`) shows "Finished"
/// and sorts after every other status; a user-stopped one stays "Stopped".
final class FinishedStatusTests: XCTestCase {
    private let stopped = TorrentStatus.stopped.rawValue
    private let seeding = TorrentStatus.seeding.rawValue

    func testStoppedAndFinishedShowsFinished() {
        let t = TorrentFactory.make(["status": stopped, "isFinished": true])
        XCTAssertEqual(t.statusDisplayName, "Finished")
    }

    func testUserStoppedStaysStopped() {
        let t = TorrentFactory.make(["status": stopped, "isFinished": false])
        XCTAssertEqual(t.statusDisplayName, "Stopped")
    }

    func testMissingIsFinishedDefaultsToNotFinished() {
        XCTAssertFalse(TorrentFactory.make(["status": stopped]).isFinished)
    }

    func testFinishedFlagIgnoredWhileRunning() {
        let t = TorrentFactory.make(["status": seeding, "isFinished": true])
        XCTAssertEqual(t.statusDisplayName, "Seeding")
        XCTAssertEqual(t.statusSortRank, seeding)
    }

    func testIsFinishedIsRequestedFromTheDaemon() {
        XCTAssertTrue(Torrent.fields(for: []).contains("isFinished"))
        XCTAssertTrue(Torrent.requestedFields.contains("isFinished"))
        XCTAssertTrue(Torrent.firstFetchFields.contains("isFinished"))
    }

    func testFinishedSortsLastAscendingAndFirstDescending() {
        let list = [TorrentFactory.make(["id": 1, "status": stopped, "isFinished": true]),
                    TorrentFactory.make(["id": 2, "status": stopped]),
                    TorrentFactory.make(["id": 3, "status": seeding])]
        let by: (Torrent, Torrent) -> Bool = { $0.statusSortRank < $1.statusSortRank }
        XCTAssertEqual(Torrent.ordered(list, levels: [(true, by)]).map(\.id), [2, 3, 1])
        XCTAssertEqual(Torrent.ordered(list, levels: [(false, by)]).map(\.id), [1, 3, 2])
    }

    func testMultiColumnNameThenStatusGroupsFinishedAtBottom() {
        let list = [TorrentFactory.make(["id": 1, "name": "b", "status": stopped, "isFinished": true]),
                    TorrentFactory.make(["id": 2, "name": "a", "status": stopped, "isFinished": true]),
                    TorrentFactory.make(["id": 3, "name": "c", "status": seeding]),
                    TorrentFactory.make(["id": 4, "name": "a", "status": seeding])]
        let name: (Torrent, Torrent) -> Bool = { $0.name < $1.name }
        let status: (Torrent, Torrent) -> Bool = { $0.statusSortRank < $1.statusSortRank }
        // Click Name, then Status → status primary, name secondary.
        XCTAssertEqual(Torrent.ordered(list, levels: [(true, status), (true, name)]).map(\.id), [4, 3, 2, 1])
    }
}
