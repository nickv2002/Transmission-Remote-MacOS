import XCTest
import Foundation

/// Which path the free-space figure is queried for (issue #20: it was always the
/// daemon's default download dir, i.e. often `/`, even for torrents on another mount).
final class FreeSpaceTargetTests: XCTestCase {
    private func torrent(_ dir: String) -> Torrent {
        TorrentFactory.make(["downloadDir": dir])
    }

    func testSingleSelectionUsesItsOwnFolderNotTheDefault() {
        let path = FreeSpaceTarget.path(selection: [torrent("/video/x")], sidebarFolder: nil, defaultDir: "/")
        XCTAssertEqual(path, "/video/x")
    }

    func testSingleSelectionBeatsSidebarFolder() {
        let path = FreeSpaceTarget.path(selection: [torrent("/video/x")], sidebarFolder: "/other", defaultDir: "/")
        XCTAssertEqual(path, "/video/x")
    }

    func testSidebarFolderUsedWhenNothingSelected() {
        let path = FreeSpaceTarget.path(selection: [], sidebarFolder: "/undupe", defaultDir: "/")
        XCTAssertEqual(path, "/undupe")
    }

    func testMultiSelectionFallsBackToSidebarThenDefault() {
        let two = [torrent("/a"), torrent("/b")]
        XCTAssertEqual(FreeSpaceTarget.path(selection: two, sidebarFolder: "/undupe", defaultDir: "/"), "/undupe")
        XCTAssertEqual(FreeSpaceTarget.path(selection: two, sidebarFolder: nil, defaultDir: "/"), "/")
    }

    func testFallsBackToDefaultWithNoContext() {
        XCTAssertEqual(FreeSpaceTarget.path(selection: [], sidebarFolder: nil, defaultDir: "/dl"), "/dl")
        XCTAssertNil(FreeSpaceTarget.path(selection: [], sidebarFolder: nil, defaultDir: nil))
    }
}
