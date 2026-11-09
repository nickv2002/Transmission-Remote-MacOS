import AppKit
import XCTest

@MainActor private final class DisplayLayoutState {
    var value: ToolbarLayout = .default
}

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

    func testPickerChangesReportLabelsAndPreserveTheTitleSetting() {
        let (window, toolbar) = makeWindow()
        var saved = slim
        var reports: [ToolbarLayout] = []
        window.apply(toolbarLayout: saved)
        let token = toolbar.observeLayoutChanges(current: { saved }, onChange: {
            saved = $0
            reports.append($0)
            window.apply(toolbarLayout: $0)
        })
        defer { token.invalidate() }
        toolbar.displayMode = .iconAndLabel
        toolbar.displayMode = .iconOnly
        XCTAssertEqual(reports, [ToolbarLayout(titleBar: .hidden, showsLabels: true), slim])
        XCTAssertEqual(saved, slim)
    }

    func testApplyingLayoutsDoesNotReportTransientModeChanges() {
        let (window, toolbar) = makeWindow()
        let saved = DisplayLayoutState()
        var reports: [ToolbarLayout] = []
        let token = toolbar.observeLayoutChanges(current: { saved.value }, onChange: { reports.append($0) })
        defer { token.invalidate() }
        for layout in [slim, .default, iconOnly, ToolbarLayout(titleBar: .hidden, showsLabels: true)] {
            saved.value = layout
            window.apply(toolbarLayout: layout)
        }
        XCTAssertTrue(reports.isEmpty)
    }

    func testLegacyTextOnlyNormalizesFromEitherLabelPreference() {
        for labels in [true, false] {
            let (window, toolbar) = makeWindow()
            var saved = ToolbarLayout(titleBar: .full, showsLabels: labels)
            var reports: [ToolbarLayout] = []
            window.apply(toolbarLayout: saved)
            let token = toolbar.observeLayoutChanges(current: { saved }, onChange: {
                saved = $0
                reports.append($0)
                window.apply(toolbarLayout: $0)
            })
            toolbar.displayMode = .labelOnly
            XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
            XCTAssertTrue(saved.showsLabels)
            XCTAssertEqual(reports.count, labels ? 0 : 1)
            token.invalidate()
        }
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

@MainActor
private final class DisplayModeTestWindow: NSWindow {
    @objc func selectMode(_ sender: NSMenuItem) { toolbar?.displayMode = .init(rawValue: UInt(clamping: sender.tag)) ?? .default }
    @objc func anotherAction(_ sender: NSMenuItem) {}
}

@MainActor
final class ToolbarDisplayModeMenuTests: XCTestCase {
    private func makeWindow() -> DisplayModeTestWindow {
        _ = NSApplication.shared
        let window = DisplayModeTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "DisplayModeMenuTests")
        window.toolbar?.allowsDisplayModeCustomization = true
        return window
    }

    private func makeMenu(_ window: DisplayModeTestWindow, context: Bool = false) -> NSMenu {
        let menu = NSMenu()
        // Deliberately use unrelated labels: matching must be language-independent.
        for (mode, title) in [(NSToolbar.DisplayMode.iconAndLabel, "Symbols and captions"), (.iconOnly, "Symbols"), (.labelOnly, "Captions")] {
            let item = menu.addItem(withTitle: title, action: #selector(DisplayModeTestWindow.selectMode(_:)), keyEquivalent: "")
            item.target = window
            item.tag = Int(mode.rawValue)
        }
        if context {
            menu.addItem(.separator())
            let customize = menu.addItem(withTitle: "Edit toolbar", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
            customize.target = window
        }
        return menu
    }

    func testBothNativeMenuShapesHideOnlyTextAndKeepActionsUsable() {
        let window = makeWindow()
        let filter = ToolbarDisplayModeMenuFilter(window: window)
        for context in [false, true] {
            let menu = makeMenu(window, context: context)
            for _ in 0..<2 { filter.hideTextOnly(in: menu) }
            XCTAssertEqual(menu.items.filter(\.isHidden).map(\.tag), [Int(NSToolbar.DisplayMode.labelOnly.rawValue)])
            menu.performActionForItem(at: 1)
            XCTAssertEqual(window.toolbar?.displayMode, .iconOnly)
            menu.performActionForItem(at: 0)
            XCTAssertEqual(window.toolbar?.displayMode, .iconAndLabel)
            if context { XCTAssertFalse(menu.items.last!.isHidden) }
        }
    }

    func testTrackingNotificationFiltersTheMenu() {
        let window = makeWindow()
        let filter = ToolbarDisplayModeMenuFilter(window: window)
        let menu = makeMenu(window)
        withExtendedLifetime(filter) {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            XCTAssertTrue(menu.items[2].isHidden)
        }
    }

    func testOtherWindowsAndChangedMenuStructuresAreUntouched() {
        let window = makeWindow(), otherWindow = makeWindow()
        let filter = ToolbarDisplayModeMenuFilter(window: window)
        let foreign = makeMenu(otherWindow)
        filter.hideTextOnly(in: foreign)
        XCTAssertFalse(foreign.items.contains(where: \.isHidden))
        for variation in 0..<5 {
            let menu = makeMenu(window)
            switch variation {
            case 0: menu.items[1].action = #selector(DisplayModeTestWindow.anotherAction(_:))
            case 1: menu.addItem(menu.items[2].copy() as! NSMenuItem)
            case 2: menu.removeItem(at: 0)
            case 3: menu.addItem(withTitle: "Unrelated", action: nil, keyEquivalent: "")
            default: menu.items[2].submenu = NSMenu()
            }
            filter.hideTextOnly(in: menu)
            XCTAssertFalse(menu.items.contains(where: \.isHidden))
        }
    }

    func testDisablingPickerOrReleasingWindowLeavesMenusUntouched() {
        var window: DisplayModeTestWindow? = makeWindow()
        let filter = ToolbarDisplayModeMenuFilter(window: window!)
        let menu = makeMenu(window!)
        window?.toolbar?.allowsDisplayModeCustomization = false
        filter.hideTextOnly(in: menu)
        XCTAssertFalse(menu.items.contains(where: \.isHidden))
        window = nil
        filter.hideTextOnly(in: menu)
        XCTAssertFalse(menu.items.contains(where: \.isHidden))
    }
}
