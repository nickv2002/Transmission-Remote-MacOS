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
}
