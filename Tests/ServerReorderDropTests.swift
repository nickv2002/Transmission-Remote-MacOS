import AppKit
import XCTest

/// Drag-to-reorder in Settings ▸ Servers: the pasteboard/drop layer over
/// `SettingsEditor.moveServer` (whose index math is tested in SettingsEditorTests).
@MainActor
final class ServerReorderDropTests: XCTestCase {
    private var controller: SettingsWindowController!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        func server(_ name: String) -> ServerConfig {
            ServerConfig(name: name, host: "h", port: 1, useHTTPS: false, rpcPath: "/r")
        }
        controller = SettingsWindowController(
            config: AppConfig(servers: [server("A"), server("B"), server("C")],
                              refreshSeconds: 4, currentServer: "A"))
        controller.showServersTab()   // the tab's views only join the window once shown
        pasteboard = NSPasteboard(name: NSPasteboard.Name("reorder-tests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        controller = nil
        try await super.tearDown()
    }

    private func serverTable() -> NSTableView? {
        func find(_ v: NSView?) -> NSTableView? {
            guard let v else { return nil }
            if let t = v as? NSTableView, t.dataSource === controller { return t }
            return v.subviews.lazy.compactMap(find).first
        }
        return find(controller.window?.contentView)
    }

    private func names() -> [String] {
        guard let table = serverTable() else { return [] }
        return (0..<table.numberOfRows).map { row in
            (controller.tableView(table, viewFor: table.tableColumns[0], row: row) as? NSTableCellView)?
                .textField?.stringValue ?? "?"
        }
    }

    /// Put row `row`'s drag payload on the pasteboard, as a real drag would.
    private func beginDrag(row: Int) {
        let table = serverTable()!
        let item = controller.tableView(table, pasteboardWriterForRow: row)!
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func testServerTableIsFound() {
        XCTAssertEqual(names(), ["A", "B", "C"])
    }

    func testDraggingFirstServerBelowLastMovesIt() {
        beginDrag(row: 0)
        XCTAssertTrue(controller.acceptServerDrop(from: pasteboard, row: 3))
        XCTAssertEqual(names(), ["B", "C", "A"])
    }

    func testDraggingLastServerToTopMovesIt() {
        beginDrag(row: 2)
        XCTAssertTrue(controller.acceptServerDrop(from: pasteboard, row: 0))
        XCTAssertEqual(names(), ["C", "A", "B"])
    }

    func testDropIntoOwnGapKeepsOrder() {
        beginDrag(row: 1)
        XCTAssertTrue(controller.acceptServerDrop(from: pasteboard, row: 2))
        XCTAssertEqual(names(), ["A", "B", "C"])
    }

    func testOwnDragIsAcceptedAsMove() {
        beginDrag(row: 0)
        XCTAssertEqual(controller.serverDropOperation(for: pasteboard), .move)
    }

    func testForeignPasteboardIsRefusedAndIgnored() {
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(controller.serverDropOperation(for: pasteboard), [])
        XCTAssertFalse(controller.acceptServerDrop(from: pasteboard, row: 0))
        XCTAssertEqual(names(), ["A", "B", "C"])
    }

    func testOutOfRangeDropIsRefused() {
        beginDrag(row: 0)
        XCTAssertFalse(controller.acceptServerDrop(from: pasteboard, row: 9))
        XCTAssertEqual(names(), ["A", "B", "C"])
    }
}
