import AppKit
import Testing

@Suite("Native toolbar groups", .serialized)
@MainActor
struct ToolbarGroupTests {
    @Test(arguments: [15, 26]) func alignedCaptionsMatchEachServerAction(on version: Int) throws {
        _ = NSApplication.shared
        let server = NSMenuToolbarItem(itemIdentifier: .init("server"))
        server.label = "Server"
        server.title = "localhost"
        server.menu = NSMenu(title: "Servers")
        let speed = NSMenuToolbarItem(itemIdentifier: .init("speedLimits"))
        speed.label = "Speed Limits"
        speed.menu = NSMenu(title: "Speed Limits")
        let settings = NSToolbarItem(itemIdentifier: .init("serverOptions"))
        settings.label = "Server Settings"
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: settings.label)
        let group = NativeToolbarGroup(id: .init("serverControls"), items: [server, speed, settings],
                                       palette: false, showsLabels: true, macOSMajorVersion: version)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil) // AppKit publishes segment accessibility frames for visible windows.
        defer { window.close() }
        for shown in [true, false, true] {
            group.setShowsLabels(shown)
            group.refreshContents()
            #expect(group.control.segmentCount == 3)
            #expect(group.control.image(forSegment: 2) === settings.image)
            #expect(group.control.menu(forSegment: 0) === server.menu)
            #expect(group.control.menu(forSegment: 1) === speed.menu)
            if shown {
                let host = try #require(group.view)
                #expect(group.control.controlSize == (version == 26 ? .large : .regular))
                #expect(group.control.isDescendant(of: host))
                window.contentView?.addSubview(host)
                host.frame = NSRect(origin: NSPoint(x: 10, y: 24), size: host.intrinsicContentSize)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let fields = host.subviews.compactMap { $0 as? NSTextField }
                #expect(fields.map(\.stringValue) == ["Server", "Speed Limits", "Server Settings"])
                let targets = try #require(group.control.cell?.accessibilityChildren() as? [NSAccessibilityElement])
                try #require(targets.count == 3 && fields.count == 3)
                for (field, target) in zip(fields, targets) {
                    let frame = field.convert(field.bounds, to: nil)
                    let button = window.convertFromScreen(target.accessibilityFrame())
                    #expect(abs(frame.midX - button.midX) <= 1)
                    #expect(frame.width >= field.intrinsicContentSize.width)
                    #expect(frame.maxY <= button.minY)
                }
                host.setFrameSize(NSSize(width: 30, height: host.frame.height))
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                #expect(fields.allSatisfy { $0.frame.width >= 0 && $0.frame.maxX <= 30.01 })
                host.removeFromSuperview()
            } else {
                #expect(group.view === group.control)
                #expect(group.control.width(forSegment: 0) == 0)
                server.title = "A long server name for comparing the caption positions after switching modes"
            }
        }
    }

    @Test func goldenGateAndPaletteUseNativeSegmentedControlInBothModes() {
        _ = NSApplication.shared
        for (version, palette) in [(15, true), (26, true), (27, false), (28, false)] {
            let item = NSToolbarItem(itemIdentifier: .init("start"))
            item.label = "Start"
            let shared = NativeToolbarGroup(id: .init("transferControls"), items: [item],
                                            palette: palette, showsLabels: true, macOSMajorVersion: version)
            for shown in [true, false, true] {
                shared.setShowsLabels(shown)
                #expect(shared.view === shared.control)
            }
        }
    }

    @Test func speedMenusIncludeGroupedAndStandaloneCopiesInEitherInsertionOrder() {
        _ = NSApplication.shared
        let speedID = NSToolbarItem.Identifier("speedLimits")
        for standaloneFirst in [false, true] {
            let grouped = NSMenuToolbarItem(itemIdentifier: speedID)
            let standalone = NSMenuToolbarItem(itemIdentifier: speedID)
            let unrelated = NSMenuToolbarItem(itemIdentifier: .init("server"))
            let palette = NSMenuToolbarItem(itemIdentifier: speedID)
            let group = NSToolbarItemGroup(itemIdentifier: .init("serverControls"))
            group.subitems = [unrelated, grouped]
            var items: [NSToolbarItem] = standaloneFirst ? [standalone, group] : [group, standalone]
            let live = ToolbarGroups.menuItems(in: items, identifier: speedID)
            #expect(live.count == 2)
            #expect(live.contains { $0 === grouped })
            #expect(live.contains { $0 === standalone })
            #expect(!live.contains { $0 === unrelated || $0 === palette })
            for item in live { item.menu = NSMenu(title: "Refreshed") }
            #expect(grouped.menu.title == "Refreshed")
            #expect(standalone.menu.title == "Refreshed")
            items.removeAll { $0 === standalone }
            let remaining = ToolbarGroups.menuItems(in: items, identifier: speedID)
            #expect(remaining.count == 1)
            #expect(remaining.first === grouped)
            items.removeAll()
            #expect(ToolbarGroups.menuItems(in: items, identifier: speedID).isEmpty)
        }
    }

    @Test func migrationGroupsOnlyCompleteAdjacentActionsAndIsIdempotent() {
        func ids(_ strings: [String]) -> [NSToolbarItem.Identifier] { strings.map { .init($0) } }
        let legacy = ids(["add", "start", "stop", "forceStart", "rename", "move", "verify", "remove", "server", "speedLimits", "serverOptions", "search"])
        let expected = ids(["add", "transferControls", "torrentControls", "remove", "serverControls", "search"])
        #expect(ToolbarGroups.migrated(legacy) == expected)
        #expect(ToolbarGroups.migrated(expected) == expected)
        let custom = ids(["start", "search", "stop", "forceStart", "serverOptions", "server"])
        #expect(ToolbarGroups.migrated(custom) == custom)
        let reorderedServer = ids(["server", "serverOptions", "speedLimits"])
        #expect(ToolbarGroups.migrated(reorderedServer) == reorderedServer)
    }
}
