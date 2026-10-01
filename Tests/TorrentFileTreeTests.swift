import XCTest

/// Tree build/aggregation/sort/merge for the Files tab (`TorrentFileTree.swift`)
/// — the sort cases the flat `TorrentFileSort` used to carry, now per level.
final class TorrentFileTreeTests: XCTestCase {
    private func file(_ index: Int, _ name: String, length: Int64 = 100, done: Int64 = 0,
                      wanted: Bool = true, priority: Int = 0) -> TorrentFile {
        TorrentFile(index: index, name: name, length: length, bytesCompleted: done,
                    wanted: wanted, priorityRaw: priority)
    }

    private func build(_ files: [TorrentFile], sortedBy key: TorrentFileSortKey? = nil,
                       ascending: Bool = true) -> [FileNode] {
        TorrentFileTree.build(from: files, sortedBy: key, ascending: ascending)
    }

    // MARK: - Building

    func testBuildGroupsFilesIntoSharedFolders() {
        let nodes = build([
            file(0, "Show/S01/a.mkv"),
            file(1, "Show/S01/b.mkv"),
            file(2, "Show/notes.txt"),
        ])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].displayName, "Show")
        XCTAssertTrue(nodes[0].isFolder)
        XCTAssertEqual(nodes[0].children.map(\.displayName), ["S01", "notes.txt"])
        XCTAssertEqual(nodes[0].children[0].children.map(\.displayName), ["a.mkv", "b.mkv"])
    }

    func testBuildMixedTopLevelEntriesStaySiblings() {
        let nodes = build([
            file(0, "dir/one.bin"),
            file(1, "loose.txt"),
            file(2, "other/two.bin"),
        ])
        XCTAssertEqual(nodes.map(\.displayName), ["dir", "loose.txt", "other"])
        XCTAssertEqual(nodes.map(\.isFolder), [true, false, true])
    }

    func testBuildSingleFileTorrentIsOneLeaf() {
        let nodes = build([file(0, "movie.mkv")])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertFalse(nodes[0].isFolder)
        XCTAssertEqual(nodes[0].displayName, "movie.mkv")
        XCTAssertEqual(nodes[0].path, "movie.mkv")
    }

    func testBuildSharesOneFolderAcrossInterleavedFiles() {
        let nodes = build([
            file(0, "d/x"),
            file(1, "d/sub/y"),
            file(2, "d/z"),
        ])
        XCTAssertEqual(nodes.count, 1)
        // Children arrive in server order even as the subfolder interleaves.
        XCTAssertEqual(nodes[0].children.map(\.displayName), ["x", "sub", "z"])
        XCTAssertEqual(nodes[0].children[1].children.map(\.displayName), ["y"])
    }

    func testFirstIndexAnchorsServerOrder() {
        let nodes = build([
            file(3, "d/sub/x"),
            file(1, "d/a"),
            file(0, "top"),
        ])
        XCTAssertEqual(nodes.map(\.displayName), ["d", "top"])
        // The folder's anchor drops to its earliest descendant.
        XCTAssertEqual(nodes.map(\.firstIndex), [1, 0])
        XCTAssertEqual(nodes[0].children.map(\.firstIndex), [3, 1])
    }

    // MARK: - Aggregates

    func testFolderAggregatesSizeAndProgress() {
        let nodes = build([
            file(0, "d/big", length: 300, done: 100),
            file(1, "d/small", length: 100, done: 100),
        ])
        let folder = nodes[0]
        XCTAssertEqual(folder.length, 400)
        XCTAssertEqual(folder.bytesCompleted, 200)
        XCTAssertEqual(folder.percentDone, 0.5, accuracy: 1e-9)
    }

    func testFileIndicesFlattenInServerOrder() {
        let nodes = build([
            file(0, "d/a"),
            file(1, "d/e"),
            file(2, "loose"),
        ])
        XCTAssertEqual(nodes[0].fileIndices, [0, 1])
        XCTAssertEqual(nodes[1].fileIndices, [2])
    }

    func testWantedStateAllNoneMixed() {
        let nodes = build([
            file(0, "d/on"),
            file(1, "d/sub/off", wanted: false),
        ])
        XCTAssertEqual(nodes[0].wantedState, .mixed)
        XCTAssertEqual(nodes[0].children[0].wantedState, .all)
        XCTAssertEqual(nodes[0].children[1].wantedState, .none)

        let allOn = build([file(0, "d/a"), file(1, "d/b")])
        XCTAssertEqual(allOn[0].wantedState, .all)
        let allOff = build([file(0, "d/a", wanted: false), file(1, "d/b", wanted: false)])
        XCTAssertEqual(allOff[0].wantedState, .none)
    }

    func testPriorityDisplayLeafAndFolder() {
        XCTAssertEqual(build([file(0, "a", priority: 1)])[0].priorityDisplay, "High")
        // An unwanted leaf shows "Skip" regardless of its raw priority.
        XCTAssertEqual(build([file(0, "a", wanted: false, priority: 1)])[0].priorityDisplay, "Skip")
        // A folder with one shared priority shows it.
        XCTAssertEqual(build([file(0, "d/a", priority: 1), file(1, "d/b", priority: 1)])[0].priorityDisplay, "High")
        // A folder with nothing wanted shows "Skip".
        XCTAssertEqual(build([file(0, "d/a", wanted: false), file(1, "d/b", wanted: false, priority: 1)])[0].priorityDisplay, "Skip")
        // A folder whose wanted files differ shows "—".
        XCTAssertEqual(build([file(0, "d/a", priority: 1), file(1, "d/b", priority: 0)])[0].priorityDisplay, "—")
    }

    // MARK: - Sorting

    func testNilKeyKeepsServerOrder() {
        let nodes = build([file(2, "c"), file(0, "a"), file(1, "b")], sortedBy: nil, ascending: false)
        XCTAssertEqual(nodes.map(\.displayName), ["c", "a", "b"])
    }

    func testNameSortUsesNaturalOrderWithinEachLevel() {
        let files = [file(0, "ep10.mkv"), file(1, "ep2.mkv"), file(2, "ep1.mkv")]
        XCTAssertEqual(build(files, sortedBy: .name, ascending: true).map(\.displayName),
                       ["ep1.mkv", "ep2.mkv", "ep10.mkv"])
        XCTAssertEqual(build(files, sortedBy: .name, ascending: false).map(\.displayName),
                       ["ep10.mkv", "ep2.mkv", "ep1.mkv"])
    }

    func testSizeSortUsesFolderAggregates() {
        let nodes = build([
            file(0, "big/x", length: 500),
            file(1, "small/x", length: 10),
            file(2, "mid", length: 100),
        ], sortedBy: .size, ascending: true)
        XCTAssertEqual(nodes.map(\.displayName), ["small", "mid", "big"])
    }

    func testProgressSortsByFraction() {
        let nodes = build([
            file(0, "a", length: 100, done: 50),
            file(1, "b", length: 10, done: 10),
            file(2, "c", length: 100, done: 0),
        ], sortedBy: .progress, ascending: true)
        XCTAssertEqual(nodes.map(\.displayName), ["c", "a", "b"])
    }

    func testPrioritySortTreatsUnwantedAsSkipBelowLow() {
        let nodes = build([
            file(0, "a", priority: 1),
            file(1, "b", wanted: false, priority: 1),
            file(2, "c", priority: -1),
            file(3, "d", priority: 0),
        ], sortedBy: .priority, ascending: true)
        XCTAssertEqual(nodes.map(\.displayName), ["b", "c", "d", "a"])
    }

    func testSortDescendsIntoFolders() {
        let nodes = build([
            file(0, "d/ep10"), file(1, "d/ep2"),
        ], sortedBy: .name, ascending: true)
        XCTAssertEqual(nodes[0].children.map(\.displayName), ["ep2", "ep10"])
    }

    func testTiesFallBackToServerOrderInBothDirections() {
        let files = [file(2, "c", length: 5), file(0, "a", length: 5), file(1, "b", length: 5)]
        XCTAssertEqual(build(files, sortedBy: .size, ascending: true).map(\.displayName), ["a", "b", "c"])
        XCTAssertEqual(build(files, sortedBy: .size, ascending: false).map(\.displayName), ["a", "b", "c"])
    }

    func testEmptyListBuildsNoNodes() {
        XCTAssertTrue(build([]).isEmpty)
        XCTAssertTrue(TorrentFileTree.merge([], into: []))
    }

    // MARK: - Poll merge

    func testMergeUpdatesLeavesInPlace() {
        let old = build([file(0, "d/a", length: 100, done: 0), file(1, "d/b")])
        let refreshed = build([file(0, "d/a", length: 100, done: 100), file(1, "d/b", wanted: false)])
        XCTAssertTrue(TorrentFileTree.merge(refreshed, into: old))
        XCTAssertEqual(old[0].bytesCompleted, 100)
        XCTAssertEqual(old[0].percentDone, 0.5, accuracy: 1e-9)
        XCTAssertEqual(old[0].wantedState, .mixed)
    }

    func testMergeRejectsCountChange() {
        let old = build([file(0, "a")])
        XCTAssertFalse(TorrentFileTree.merge(build([file(0, "a"), file(1, "b")]), into: old))
    }

    func testMergeRejectsRename() {
        let old = build([file(0, "d/a")])
        XCTAssertFalse(TorrentFileTree.merge(build([file(0, "d/renamed")]), into: old))
    }

    func testMergeRejectsOrderAndKindChange() {
        let old = build([file(0, "a/b"), file(1, "c")])
        // Same files, swapped order: "c" leaf now first, "a" folder second.
        XCTAssertFalse(TorrentFileTree.merge(build([file(1, "c"), file(0, "a/b")]), into: old))
    }
}
