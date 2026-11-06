import AppKit
import XCTest

@MainActor
final class ToolbarAppKitTests: XCTestCase {
    private func makeWindow() -> (NSWindow, NSToolbar) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let toolbar = NSToolbar(identifier: "ToolbarAppKitTests")
        window.toolbar = toolbar
        return (window, toolbar)
    }

    private let iconOnly = ToolbarLayout(titleBar: .full, showsLabels: false)
    private let slim = ToolbarLayout(titleBar: .hidden, showsLabels: false)

    func testIconOnlyKeepsTitleAndUsesExpandedStyle() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: iconOnly)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.toolbarStyle, .expanded)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
    }

    func testHiddenTitleWithoutLabelsUsesUnifiedStyle() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: slim)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
    }

    func testHiddenToolbarForcesTitleVisible() {
        let (window, toolbar) = makeWindow()
        toolbar.isVisible = false
        window.apply(toolbarLayout: slim)
        XCTAssertEqual(window.titleVisibility, .visible)
        toolbar.isVisible = true
        window.apply(toolbarLayout: slim)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    func testHiddenTitleWithLabelsIsASingleUnifiedRow() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: ToolbarLayout(titleBar: .hidden, showsLabels: true))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
    }

    func testDefaultShowsTitleAndLabels() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: slim)
        window.apply(toolbarLayout: .default)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.toolbarStyle, .expanded)
        XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
    }

    func testVisibilityObserverFiresOnShowAndHide() {
        let (_, toolbar) = makeWindow()
        var count = 0
        let token = toolbar.observeVisibility { count += 1 }
        toolbar.isVisible = false
        XCTAssertGreaterThan(count, 0)   // may fire more than once; applying is idempotent
        count = 0
        toolbar.isVisible = true
        XCTAssertGreaterThan(count, 0)
        token.invalidate()
    }
}
