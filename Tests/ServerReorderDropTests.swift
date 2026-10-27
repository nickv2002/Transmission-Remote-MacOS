import AppKit
import XCTest

/// Drag-to-reorder in the Settings sidebar: the pasteboard/drop layer over
/// `SettingsEditor.moveServer` (whose index math is tested in SettingsEditorTests).
/// Sidebar rows 0–2 are the App header, General and the Servers header, so the
/// servers start at row 3. A reorder applies (persists) immediately.
@MainActor
final class ServerReorderDropTests: XCTestCase {
    private var controller: SettingsWindowController!
    private var pasteboard: NSPasteboard!
    private var saved: [AppConfig] = []
    private let first = 3   // first server row in the sidebar

    override func setUp() async throws {
        try await super.setUp()
        func server(_ name: String) -> ServerConfig {
            ServerConfig(name: name, host: "h", port: 1, useHTTPS: false, rpcPath: "/r")
        }
        SettingsWindowController.remembersUIState = false
        controller = SettingsWindowController(
            config: AppConfig(servers: [server("A"), server("B"), server("C")],
                              refreshSeconds: 4, currentServer: "A"))
        saved = []
        controller.onChange = { [unowned self] in saved.append($0) }
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

    private func names() -> [String] { controller.sidebarServerNames }

    /// Put row `row`'s drag payload on the pasteboard, as a real drag would.
    private func beginDrag(row: Int) {
        let table = serverTable()!
        let item = controller.tableView(table, pasteboardWriterForRow: first + row)!
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func testServerTableIsFound() {
        XCTAssertTrue(serverTable() === controller.sidebar)
        XCTAssertEqual(names(), ["A", "B", "C"])
    }

    func testHeaderAndGeneralRowsAreNotDraggable() {
        let table = serverTable()!
        for row in 0..<first { XCTAssertNil(controller.tableView(table, pasteboardWriterForRow: row)) }
    }

    func testDraggingFirstServerBelowLastMovesIt() {
        beginDrag(row: 0)
        XCTAssertTrue(controller.acceptServerDrop(from: pasteboard, row: first + 3))
        XCTAssertEqual(names(), ["B", "C", "A"])
        XCTAssertEqual(saved.last?.serverNames, ["B", "C", "A"], "a reorder persists immediately")
    }

    func testDraggingLastServerToTopMovesIt() {
        beginDrag(row: 2)
        XCTAssertTrue(controller.acceptServerDrop(from: pasteboard, row: first))
        XCTAssertEqual(names(), ["C", "A", "B"])
    }

    func testDropIntoOwnGapKeepsOrder() {
        beginDrag(row: 1)
        XCTAssertTrue(controller.acceptServerDrop(from: pasteboard, row: first + 2))
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
        XCTAssertFalse(controller.acceptServerDrop(from: pasteboard, row: first))
        XCTAssertEqual(names(), ["A", "B", "C"])
    }

    func testDropAboveTheServersHeaderIsRefused() {
        beginDrag(row: 2)
        XCTAssertFalse(controller.acceptServerDrop(from: pasteboard, row: 1))
        XCTAssertEqual(names(), ["A", "B", "C"])
        XCTAssertTrue(saved.isEmpty)
    }

    func testOutOfRangeDropIsRefused() {
        beginDrag(row: 0)
        XCTAssertFalse(controller.acceptServerDrop(from: pasteboard, row: first + 9))
        XCTAssertEqual(names(), ["A", "B", "C"])
    }
}
