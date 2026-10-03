import AppKit
import XCTest

final class TrackerCellTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testUpdateInText() {
        XCTAssertEqual(TrackerStatsInfo(announceState: 3).updateInText(now: now), "Updating…")
        XCTAssertEqual(TrackerStatsInfo(announceState: 2, nextAnnounceTime: 1_500).updateInText(now: now), "Updating…")
        XCTAssertEqual(TrackerStatsInfo().updateInText(now: now), "–")
        XCTAssertEqual(TrackerStatsInfo(nextAnnounceTime: 1_090).updateInText(now: now), "1m 30s")
        XCTAssertEqual(TrackerStatsInfo(nextAnnounceTime: 900).updateInText(now: now), "0s")
    }

    func testSeedsAndLeechersBlankWhenUnknown() {
        XCTAssertEqual(TrackerStatsInfo().seedsText, "")
        XCTAssertEqual(TrackerStatsInfo().leechersText, "")
        XCTAssertEqual(TrackerStatsInfo(seederCount: 0, leecherCount: 12).seedsText, "0")
        XCTAssertEqual(TrackerStatsInfo(seederCount: 0, leecherCount: 12).leechersText, "12")
    }
}

final class HeaderSortCycleTests: XCTestCase {
    func testSecondClickOnDescendingColumnClears() {
        XCTAssertTrue(HeaderSortCycle.shouldClear(oldKey: "name", oldAscending: false,
                                                  newKey: "name", newAscending: true))
    }

    func testFirstAndSecondStatesDoNotClear() {
        // unsorted → ascending
        XCTAssertFalse(HeaderSortCycle.shouldClear(oldKey: nil, oldAscending: nil,
                                                   newKey: "name", newAscending: true))
        // ascending → descending
        XCTAssertFalse(HeaderSortCycle.shouldClear(oldKey: "name", oldAscending: true,
                                                   newKey: "name", newAscending: false))
    }

    func testTogglingKeyNeverClears() {
        XCTAssertFalse(HeaderSortCycle.shouldClear(oldKey: "name", oldAscending: false,
                                                   newKey: "name", newAscending: true,
                                                   togglingKey: "name"))
        XCTAssertTrue(HeaderSortCycle.shouldClear(oldKey: "size", oldAscending: false,
                                                  newKey: "size", newAscending: true,
                                                  togglingKey: "name"))
    }

    func testSwitchingColumnsDoesNotClear() {
        XCTAssertFalse(HeaderSortCycle.shouldClear(oldKey: "name", oldAscending: false,
                                                   newKey: "status", newAscending: true))
    }

    func testClearedDescriptorDoesNotClearAgain() {
        XCTAssertFalse(HeaderSortCycle.shouldClear(oldKey: "name", oldAscending: false,
                                                   newKey: nil, newAscending: nil))
    }
}

final class RowsToReselectTests: XCTestCase {
    private func t(_ ids: [Int]) -> [TrackerStatsInfo] { ids.map { TrackerStatsInfo(id: $0) } }

    func testFollowsItemsToTheirNewRows() {
        XCTAssertEqual(rowsToReselect(ids: [2, 0], in: t([2, 1, 0])), [0, 2])
        XCTAssertEqual(rowsToReselect(ids: [2, 0], in: t([0, 1, 2])), [0, 2])
        XCTAssertEqual(rowsToReselect(ids: [1], in: t([2, 1, 0])), [1])
    }

    func testVanishedItemsAreDropped() {
        XCTAssertEqual(rowsToReselect(ids: [5], in: t([0, 1])), [])
        XCTAssertEqual(rowsToReselect(ids: [], in: t([0, 1])), [])
    }

    func testWorksForPeersToo() {
        let peers = [TorrentPeer(address: "a", port: 1), TorrentPeer(address: "b", port: 2)]
        XCTAssertEqual(rowsToReselect(ids: ["b:2"], in: peers), [1])
    }
}

/// A real `NSTableView` driven the way the Trackers tab drives it: selection
/// and focus survive a reload that reorders rows, because they're restored by
/// identity via `rowsToReselect`.
@MainActor
final class TrackerTableReloadTests: XCTestCase, NSTableViewDataSource {
    var rows: [TrackerStatsInfo] = []

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, objectValueFor c: NSTableColumn?, row: Int) -> Any? { rows[row].announce }

    func testSelectionAndFocusSurviveReorderingReload() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.makeKeyAndOrderFront(nil)
        let table = NSTableView(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = self
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.documentView = table
        w.contentView!.addSubview(scroll)

        rows = (0..<4).map { TrackerStatsInfo(id: $0, announce: "t\($0)") }
        table.reloadData()
        w.makeFirstResponder(table)
        table.selectRowIndexes([1], byExtendingSelection: false)
        let selectedIds = Set(table.selectedRowIndexes.map { rows[$0].id })

        rows.reverse()  // tracker id 1 is now row 2
        table.reloadData()
        table.selectRowIndexes(rowsToReselect(ids: selectedIds, in: rows), byExtendingSelection: false)
        w.makeFirstResponder(table)

        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertEqual(rows[table.selectedRow].id, 1)
        XCTAssertIdentical(w.firstResponder, table)

        rows = rows.filter { $0.id != 1 }  // selected tracker disappears
        table.reloadData()
        table.selectRowIndexes(rowsToReselect(ids: selectedIds, in: rows), byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, -1)
        w.orderOut(nil)
    }
}

final class FetchSequencerTests: XCTestCase {
    func testLateOlderFetchIsDropped() {
        var seq = FetchSequencer()
        let poll = seq.begin()
        let refetch = seq.begin()
        XCTAssertTrue(seq.shouldApply(refetch))
        XCTAssertFalse(seq.shouldApply(poll))
    }

    func testInOrderFetchesApply() {
        var seq = FetchSequencer()
        let a = seq.begin()
        XCTAssertTrue(seq.shouldApply(a))
        let b = seq.begin()
        XCTAssertTrue(seq.shouldApply(b))
    }
}

extension TrackerCellTextTests {
    func testUpdateInCountsDownAsTimeAdvances() {
        let t = TrackerStatsInfo(nextAnnounceTime: 1_090)
        XCTAssertEqual(t.updateInText(now: now), "1m 30s")
        XCTAssertEqual(t.updateInText(now: now.addingTimeInterval(31)), "59s")
    }
}
