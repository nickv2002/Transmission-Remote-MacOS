import XCTest

final class ServerMenuSyncTests: XCTestCase {
    func testEmptyExistingRequiresStructuralBuild() {
        XCTAssertFalse(ServerMenuSync.canUpdateInPlace(existingNames: [], available: []))
        XCTAssertFalse(ServerMenuSync.canUpdateInPlace(existingNames: [], available: ["A"]))
    }

    func testIdenticalListsSameOrderUpdatesInPlace() {
        XCTAssertTrue(ServerMenuSync.canUpdateInPlace(existingNames: ["A", "B"], available: ["A", "B"]))
    }

    func testSingleServerNoOpUpdatesInPlace() {
        XCTAssertTrue(ServerMenuSync.canUpdateInPlace(existingNames: ["A"], available: ["A"]))
    }

    func testSameSetDifferentOrderRequiresStructuralBuild() {
        XCTAssertFalse(ServerMenuSync.canUpdateInPlace(existingNames: ["A", "B"], available: ["B", "A"]))
    }

    func testServerAddedRequiresStructuralBuild() {
        XCTAssertFalse(ServerMenuSync.canUpdateInPlace(existingNames: ["A"], available: ["A", "B"]))
    }

    func testServerRemovedRequiresStructuralBuild() {
        XCTAssertFalse(ServerMenuSync.canUpdateInPlace(existingNames: ["A", "B"], available: ["A"]))
    }

    func testServerRenamedRequiresStructuralBuild() {
        XCTAssertFalse(ServerMenuSync.canUpdateInPlace(existingNames: ["A"], available: ["A2"]))
    }

    func testShortcutKeys() {
        XCTAssertEqual((0..<10).map(ServerMenuSync.shortcutKey(forIndex:)),
                       ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    }

    func testNoShortcutBeyondTenServers() {
        XCTAssertEqual(ServerMenuSync.shortcutKey(forIndex: 10), "")
        XCTAssertEqual(ServerMenuSync.shortcutKey(forIndex: 42), "")
    }
}
