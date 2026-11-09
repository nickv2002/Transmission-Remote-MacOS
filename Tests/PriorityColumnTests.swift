import XCTest

/// The transfer list's Priority column sorts by `bandwidthPriorityRaw` and shows
/// `bandwidthPriority.displayName`; these pin both, plus the stable id tie-break.
final class PriorityColumnTests: XCTestCase {
    private func torrents() -> [Torrent] {
        [TorrentFactory.make(["id": 1, "bandwidthPriority": 0]),
         TorrentFactory.make(["id": 2, "bandwidthPriority": 1]),
         TorrentFactory.make(["id": 3, "bandwidthPriority": -1]),
         TorrentFactory.make(["id": 4, "bandwidthPriority": 1])]
    }

    func testCellTextIsThePriorityName() {
        XCTAssertEqual(torrents().map { $0.bandwidthPriority.displayName }, ["Normal", "High", "Low", "High"])
    }

    func testSortAscendingPutsLowFirstWithStableTies() {
        let sorted = Torrent.ordered(torrents(), ascending: true) { $0.bandwidthPriorityRaw < $1.bandwidthPriorityRaw }
        XCTAssertEqual(sorted.map(\.id), [3, 1, 2, 4])
    }

    func testSortDescendingPutsHighFirstWithStableTies() {
        let sorted = Torrent.ordered(torrents(), ascending: false) { $0.bandwidthPriorityRaw < $1.bandwidthPriorityRaw }
        XCTAssertEqual(sorted.map(\.id), [2, 4, 1, 3])
    }
}
