import AppKit
import XCTest

/// The AppKit half of the toolbar layout: what `apply(toolbarLayout:)` does to a
/// window, and that the toolbar's own display-mode control round-trips back.
final class LayoutBox { var value: ToolbarLayout; init(_ v: ToolbarLayout) { value = v } }
final class ReportBox { var layouts: [ToolbarLayout] = [] }

@MainActor
final class ToolbarAppKitTests: XCTestCase {
    private func makeWindow() -> (NSWindow, NSToolbar) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let toolbar = NSToolbar(identifier: "ToolbarAppKitTests")
        toolbar.allowsDisplayModeCustomization = true
        window.toolbar = toolbar
        return (window, toolbar)
    }

    func testCompactUsesUnifiedStyleSoDisplayModeControlsSurvive() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: .compact)
        XCTAssertEqual(window.titleVisibility, .hidden)
        // `.unifiedCompact` would hide the palette's Show: popup and the
        // right-click display-mode items, stranding the user in Compact.
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertTrue(toolbar.allowsDisplayModeCustomization)
    }

    func testDefaultShowsTitleAndLabels() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: .compact)
        window.apply(toolbarLayout: .default)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.toolbarStyle, .expanded)
        XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
    }

    func testUserChoosingIconAndTextInCompactReportsDefault() {
        let (window, toolbar) = makeWindow()
        let current = LayoutBox(.compact)
        window.apply(toolbarLayout: current.value)
        let reported = ReportBox()
        let token = toolbar.observeLayoutChanges(current: { current.value },
                                                 onChange: { reported.layouts.append($0) })
        toolbar.displayMode = .iconAndLabel        // the palette's "Icon and Text"
        XCTAssertEqual(reported.layouts, [.default])
        current.value = .default
        toolbar.displayMode = .iconOnly            // and back
        XCTAssertEqual(reported.layouts, [.default, .compact])
        token.invalidate()
    }

    func testApplyingALayoutDoesNotReportItself() {
        let (window, toolbar) = makeWindow()
        let current = LayoutBox(.default)
        window.apply(toolbarLayout: current.value)
        let reported = ReportBox()
        let token = toolbar.observeLayoutChanges(current: { current.value },
                                                 onChange: { reported.layouts.append($0) })
        current.value = .compact                    // applyToolbarLayout sets this first
        window.apply(toolbarLayout: .compact)
        current.value = .default
        window.apply(toolbarLayout: .default)
        XCTAssertEqual(reported.layouts, [])
        token.invalidate()
    }

    func testTextOnlyCountsAsDefault() {
        let (_, toolbar) = makeWindow()
        let reported = ReportBox()
        let token = toolbar.observeLayoutChanges(current: { .compact },
                                                 onChange: { reported.layouts.append($0) })
        toolbar.displayMode = .labelOnly
        XCTAssertEqual(reported.layouts, [.default])
        token.invalidate()
    }
}
