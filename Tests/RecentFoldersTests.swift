import XCTest

final class RecentFoldersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "RecentFoldersTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLoadIsEmptyByDefault() {
        XCTAssertEqual(RecentFolders.load(from: defaults), [])
    }

    func testRecordInsertsAtFront() {
        RecentFolders.record("/downloads/a", in: defaults)
        RecentFolders.record("/downloads/b", in: defaults)
        XCTAssertEqual(RecentFolders.load(from: defaults), ["/downloads/b", "/downloads/a"])
    }

    func testRecordMovesExistingEntryToFrontInsteadOfDuplicating() {
        RecentFolders.record("/downloads/a", in: defaults)
        RecentFolders.record("/downloads/b", in: defaults)
        RecentFolders.record("/downloads/a", in: defaults)
        XCTAssertEqual(RecentFolders.load(from: defaults), ["/downloads/a", "/downloads/b"])
    }

    func testRecordCapsAtMaxEntries() {
        for i in 0..<(RecentFolders.maxEntries + 2) {
            RecentFolders.record("/downloads/\(i)", in: defaults)
        }
        let list = RecentFolders.load(from: defaults)
        XCTAssertEqual(list.count, RecentFolders.maxEntries)
        XCTAssertEqual(list.first, "/downloads/\(RecentFolders.maxEntries + 1)")
    }

    func testRecordIgnoresBlankFolder() {
        RecentFolders.record("   ", in: defaults)
        XCTAssertEqual(RecentFolders.load(from: defaults), [])
    }

    func testRecordTrimsWhitespace() {
        RecentFolders.record("  /downloads/a  ", in: defaults)
        XCTAssertEqual(RecentFolders.load(from: defaults), ["/downloads/a"])
    }
}
