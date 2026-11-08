import XCTest

/// Mac-standard multi-column sort: `NSTableView` keeps the last-clicked header first
/// and earlier clicks behind it as tie-breakers. `Torrent.ordered(_:levels:)` applies
/// that array, and `TorrentSortState` persists it.
final class MultiColumnSortTests: XCTestCase {
    private func torrents() -> [Torrent] {
        [TorrentFactory.make(["id": 1, "status": 6, "totalSize": 300]),
         TorrentFactory.make(["id": 2, "status": 0, "totalSize": 100]),
         TorrentFactory.make(["id": 3, "status": 6, "totalSize": 100]),
         TorrentFactory.make(["id": 4, "status": 0, "totalSize": 200])]
    }

    private let status: (Torrent, Torrent) -> Bool = { $0.statusRaw < $1.statusRaw }
    private let size: (Torrent, Torrent) -> Bool = { $0.totalSize < $1.totalSize }

    func testSecondaryLevelBreaksPrimaryTies() {
        let sorted = Torrent.ordered(torrents(), levels: [(true, status), (true, size)])
        XCTAssertEqual(sorted.map(\.id), [2, 4, 3, 1])
    }

    func testLevelsHaveIndependentDirections() {
        let sorted = Torrent.ordered(torrents(), levels: [(true, status), (false, size)])
        XCTAssertEqual(sorted.map(\.id), [4, 2, 1, 3])
    }

    func testPrimaryOutranksSecondary() {
        // Same two columns, swapped priority: size leads, status only breaks the size tie.
        let sorted = Torrent.ordered(torrents(), levels: [(true, size), (true, status)])
        XCTAssertEqual(sorted.map(\.id), [2, 3, 4, 1])
    }

    func testFullTieFallsBackToId() {
        let ties = [TorrentFactory.make(["id": 9, "status": 6]), TorrentFactory.make(["id": 5, "status": 6])]
        XCTAssertEqual(Torrent.ordered(ties, levels: [(true, status), (false, size)]).map(\.id), [5, 9])
    }

    func testSingleLevelMatchesLegacyOrdered() {
        let legacy = Torrent.ordered(torrents(), ascending: false, by: size)
        let multi = Torrent.ordered(torrents(), levels: [(false, size)])
        XCTAssertEqual(multi.map(\.id), legacy.map(\.id))
    }

    func testSortStateRoundTripsAllDescriptorsInOrder() {
        let descriptors = [NSSortDescriptor(key: "name", ascending: false), NSSortDescriptor(key: "size", ascending: true)]
        let encoded = TorrentSortState.encode(descriptors)
        XCTAssertEqual(encoded, ["-name", "size"])
        let decoded = TorrentSortState.decode(encoded)
        XCTAssertEqual(decoded.map(\.key), ["name", "size"])
        XCTAssertEqual(decoded.map(\.ascending), [false, true])
    }

    func testDecodeSkipsEmptyEntries() {
        XCTAssertTrue(TorrentSortState.decode(["", "-"]).isEmpty)
    }

    /// The Mac click model: clicking a header moves its descriptor to the front.
    func testTableViewKeepsEarlierClickAsSecondary() {
        let table = NSTableView()
        for key in ["status", "size"] {
            let col = NSTableColumn(identifier: .init(key))
            col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(col)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true)]
        table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: true)] + table.sortDescriptors
        XCTAssertEqual(table.sortDescriptors.compactMap(\.key), ["status", "size"])
    }
}
