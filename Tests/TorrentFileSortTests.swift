import XCTest

final class TorrentFileSortTests: XCTestCase {
    private func file(_ index: Int, _ name: String, length: Int64 = 100, done: Int64 = 0,
                      wanted: Bool = true, priority: Int = 0) -> TorrentFile {
        TorrentFile(index: index, name: name, length: length, bytesCompleted: done,
                    wanted: wanted, priorityRaw: priority)
    }

    private func indices(_ list: [TorrentFile]) -> [Int] { list.map(\.index) }

    func testNilKeyRestoresServerOrder() {
        let list = [file(2, "c"), file(0, "a"), file(1, "b")]
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: nil, ascending: false)), [0, 1, 2])
    }

    func testNameUsesNaturalOrder() {
        let list = [file(0, "ep10.mkv"), file(1, "ep2.mkv"), file(2, "ep1.mkv")]
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .name, ascending: true)), [2, 1, 0])
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .name, ascending: false)), [0, 1, 2])
    }

    func testSizeAscendingAndDescending() {
        let list = [file(0, "a", length: 30), file(1, "b", length: 10), file(2, "c", length: 20)]
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .size, ascending: true)), [1, 2, 0])
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .size, ascending: false)), [0, 2, 1])
    }

    func testProgressSortsByFraction() {
        let list = [file(0, "a", length: 100, done: 50), file(1, "b", length: 10, done: 10), file(2, "c", length: 100, done: 0)]
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .progress, ascending: true)), [2, 0, 1])
    }

    func testPriorityTreatsUnwantedAsSkipBelowLow() {
        let list = [file(0, "a", priority: 1), file(1, "b", wanted: false, priority: 1),
                    file(2, "c", priority: -1), file(3, "d", priority: 0)]
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .priority, ascending: true)), [1, 2, 3, 0])
    }

    func testTiesFallBackToIndexInBothDirections() {
        let list = [file(2, "c", length: 5), file(0, "a", length: 5), file(1, "b", length: 5)]
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .size, ascending: true)), [0, 1, 2])
        XCTAssertEqual(indices(TorrentFileSort.sorted(list, by: .size, ascending: false)), [0, 1, 2])
    }

    func testEmptyList() {
        XCTAssertTrue(TorrentFileSort.sorted([], by: .name, ascending: true).isEmpty)
    }
}
