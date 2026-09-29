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

    private let iconOnly = ToolbarLayout(titleBar: .full, showsLabels: false)
    private let slim = ToolbarLayout(titleBar: .hidden, showsLabels: false)

    func testIconOnlyKeepsTitleAndUsesExpandedStyleSoDisplayModeControlsSurvive() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: iconOnly)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.toolbarStyle, .expanded)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertTrue(toolbar.allowsDisplayModeCustomization)
    }

    func testHiddenTitleWithoutLabelsUsesUnifiedStyle() {
        let (window, toolbar) = makeWindow()
        window.apply(toolbarLayout: slim)
        // `.unifiedCompact` would hide the palette's Show: popup and the
        // right-click display-mode items.
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

    func testUserChoosingIconAndTextReportsLabelsOnAndKeepsTitleBar() {
        let (window, toolbar) = makeWindow()
        let current = LayoutBox(slim)
        window.apply(toolbarLayout: current.value)
        let reported = ReportBox()
        let token = toolbar.observeLayoutChanges(current: { current.value },
                                                 onChange: { reported.layouts.append($0) })
        toolbar.displayMode = .iconAndLabel        // the palette's "Icon and Text"
        XCTAssertEqual(reported.layouts, [ToolbarLayout(titleBar: .hidden, showsLabels: true)])
        current.value = reported.layouts[0]
        toolbar.displayMode = .iconOnly            // and back
        XCTAssertEqual(reported.layouts.last, slim)
        token.invalidate()
    }

    func testApplyingALayoutDoesNotReportItself() {
        let (window, toolbar) = makeWindow()
        let current = LayoutBox(.default)
        window.apply(toolbarLayout: current.value)
        let reported = ReportBox()
        let token = toolbar.observeLayoutChanges(current: { current.value },
                                                 onChange: { reported.layouts.append($0) })
        current.value = iconOnly                    // applyToolbarLayout sets this first
        window.apply(toolbarLayout: iconOnly)
        current.value = .default
        window.apply(toolbarLayout: .default)
        XCTAssertEqual(reported.layouts, [])
        token.invalidate()
    }

    func testTextOnlyCountsAsLabelsOn() {
        let (_, toolbar) = makeWindow()
        let reported = ReportBox()
        let token = toolbar.observeLayoutChanges(current: { self.iconOnly },
                                                 onChange: { reported.layouts.append($0) })
        toolbar.displayMode = .labelOnly
        XCTAssertEqual(reported.layouts, [.default])
        token.invalidate()
    }

    func testVisibilityObserverFiresOnShowAndHide() {
        let (_, toolbar) = makeWindow()
        let count = ReportBox()
        let token = toolbar.observeVisibility { count.layouts.append(.default) }
        toolbar.isVisible = false
        XCTAssertFalse(count.layouts.isEmpty)   // may fire more than once; applying is idempotent
        count.layouts.removeAll()
        toolbar.isVisible = true
        XCTAssertFalse(count.layouts.isEmpty)
        token.invalidate()
    }
}
