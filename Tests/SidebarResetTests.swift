import AppKit
import XCTest

/// Switching servers clears the torrent model; the sidebar must follow, or the
/// previous server's Status / Tracker / Folder counts linger while the new
/// server is unreachable (`MainWindowController.selectServer` calls
/// `sidebar.update(with: [])`).
@MainActor
final class SidebarResetTests: XCTestCase {
    private func statusCounts(_ sidebar: SidebarController) -> [Int] {
        let outline = sidebar.outlineView
        var counts: [Int] = []
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarController.Node, !node.isGroup {
                counts.append(node.count)
            }
        }
        return counts
    }

    func testUpdatingWithNoTorrentsZeroesEveryCount() {
        let sidebar = SidebarController()
        sidebar.outlineView.expandItem(nil, expandChildren: true)
        sidebar.update(with: [TorrentFactory.make(["id": 1]), TorrentFactory.make(["id": 2])])
        sidebar.outlineView.expandItem(nil, expandChildren: true)
        XCTAssertTrue(statusCounts(sidebar).contains { $0 > 0 }, "precondition: counts populated")

        sidebar.update(with: [])
        sidebar.outlineView.expandItem(nil, expandChildren: true)
        XCTAssertFalse(statusCounts(sidebar).isEmpty)
        XCTAssertTrue(statusCounts(sidebar).allSatisfy { $0 == 0 })
    }

    func testTrackerAndFolderRowsDisappearWhenTorrentsAreCleared() {
        let sidebar = SidebarController()
        sidebar.update(with: [TorrentFactory.make(["id": 1])])
        sidebar.outlineView.expandItem(nil, expandChildren: true)
        let populated = statusCounts(sidebar).count
        sidebar.update(with: [])
        sidebar.outlineView.expandItem(nil, expandChildren: true)
        XCTAssertLessThan(statusCounts(sidebar).count, populated)
    }
}
