import AppKit
import Testing

@MainActor
private final class ToolbarGroupTarget: NSObject, NSToolbarItemValidation {
    var calls: [String] = []
    var canStart = true
    @objc func start(_ sender: Any?) { calls.append("start") }
    @objc func stop(_ sender: Any?) { calls.append("stop") }
    @objc func force(_ sender: Any?) { calls.append("force") }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.action != #selector(start(_:)) || canStart
    }
}

@Suite("Native toolbar groups", .serialized)
@MainActor
struct ToolbarGroupTests {
    @Test func speedMenusIncludeGroupedAndStandaloneCopiesInEitherInsertionOrder() {
        _ = NSApplication.shared
        let speedID = NSToolbarItem.Identifier("speedLimits")
        for standaloneFirst in [false, true] {
            let grouped = NSMenuToolbarItem(itemIdentifier: speedID)
            let standalone = NSMenuToolbarItem(itemIdentifier: speedID)
            let unrelated = NSMenuToolbarItem(itemIdentifier: .init("server"))
            let palette = NSMenuToolbarItem(itemIdentifier: speedID)
            let group = ToolbarGroups.actions(identifier: .init("serverControls"), items: [unrelated, grouped])
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

    @Test func serverCaptionsStayOutsideGlassAndHostForwardsInput() throws {
        _ = NSApplication.shared
        let titles = ["Server", "Speed Limits", "Server Options"]
        let items = titles.map { title in
            let item = NSToolbarItem(itemIdentifier: .init(title))
            item.label = title
            return item
        }
        let group = SegmentedToolbarGroup(identifier: .init("serverControls"), items: items)
        for (index, width) in [160.0, 118, 118].enumerated() { group.segments.setWidth(width, forSegment: index) }
        group.alignsCaptionsToSegments = true
        let host = try #require(group.view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        content.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 30),
        ])
        content.layoutSubtreeIfNeeded()
        group.segments.layoutSubtreeIfNeeded()
        #expect(!group.isBordered)
        #expect(host.frame.width == 396)
        #expect(host.frame.height == 36)
        #expect(group.segments.frame.height == 36)
        #expect(host.accessibilityRole() == .group)
        #expect(host.accessibilityChildren()?.first as? NSView === group.segments)
        #expect(!host.acceptsFirstResponder)
        #expect(host.hitTest(NSPoint(x: host.frame.midX, y: host.frame.midY)) === group.segments)
        #expect(host.hitTest(NSPoint(x: host.frame.maxX + 1, y: host.frame.midY)) == nil)
        for (index, field) in group.segments.captionFields.enumerated() {
            #expect(field.superview === host)
            #expect(!field.isDescendant(of: group.segments))
            let caption = field.convert(field.bounds, to: group.segments)
            #expect(abs(caption.midX - group.segments.segmentRect(for: index).midX) < 0.5)
        }
    }

    @Test func longServerNamesStayWithinTheirSegment() {
        let item = NSToolbarItem(itemIdentifier: .init("server"))
        item.label = "Server"
        let group = SegmentedToolbarGroup(identifier: .init("servers"), items: [item])
        group.segments.setWidth(160, forSegment: 0)
        for name in ["localhost", "Server Options UI Fixture", "A very long server name 🏠 in the office", "First\nSecond"] {
            group.setServerName(name)
            let title = group.segments.label(forSegment: 0) ?? ""
            #expect(!title.contains("\n"))
            #expect((title as NSString).size(withAttributes: [.font: group.segments.font!]).width <= 116)
            #expect(item.toolTip == name)
            #expect(group.segments.toolTip(forSegment: 0) == name)
        }
        group.setServerName("localhost")
        #expect(group.segments.label(forSegment: 0) == "localhost")
    }

    @Test func searchPlaceholderKeepsRegularFontWhenModeChanges() throws {
        let field = NSSearchField()
        for text in ["Search", "Exact filter by name", "Fuzzy filter by name"] {
            ToolbarGroups.configureSearchField(field, placeholder: text)
            let placeholder = try #require(field.placeholderAttributedString)
            let font = try #require(placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(placeholder.string == text)
            #expect(font == NSFont.systemFont(ofSize: 14, weight: .regular))
            #expect(field.controlSize == .large)
        }
    }

    @Test func customizationPreviewsUseOneCaptionAndDoNotChangeLiveCaptions() {
        _ = NSApplication.shared
        for titles in [["Start", "Stop", "Force Start"], ["Rename", "Move", "Verify"],
                       ["Server", "Speed Limits", "Server Options"], ["Remove"]] {
            func items() -> [NSToolbarItem] {
                titles.map { title in
                    let item = NSToolbarItem(itemIdentifier: .init(title))
                    item.label = title
                    return item
                }
            }
            let live = ToolbarGroups.actions(identifier: .init("live"), items: items())
            let preview = ToolbarGroups.actions(identifier: .init("preview"), items: items(), isPaletteItem: true)
            // The server group requests custom captions after construction.
            // Palette refreshes must still leave AppKit as the sole label owner.
            for group in [live, preview] {
                group.alignsCaptionsToSegments = true
                group.refreshContents()
                group.validate()
            }
            #expect(preview.label == titles.joined(separator: " / "))
            #expect(preview.paletteLabel == preview.label)
            #expect(preview.controlRepresentation == .expanded)
            #expect(preview.segments.captionFields.isEmpty)
            #expect(preview.subitems.map(\.label) == titles)
            #expect(live.label == " ")
            #expect(live.segments.captionFields.map(\.stringValue) == titles)
            #expect(live.segments.captionFields.allSatisfy { !$0.isHidden })
        }
    }

    @Test func customizationPicturesFitTheirConfiguredWidthsWithoutBezelOverflow() throws {
        for widths in [[80.0, 80, 80], [160.0, 118, 118], [60.0]] {
            let items = widths.indices.map { index in
                let item = NSToolbarItem(itemIdentifier: .init("item\(index)"))
                item.label = "Item \(index)"
                return item
            }
            let group = SegmentedToolbarGroup(identifier: .init("preview"), items: items, isPaletteItem: true)
            for (index, width) in widths.enumerated() { group.segments.setWidth(width, forSegment: index) }
            group.refreshContents()
            let preview = try #require(group.view)
            #expect(preview.fittingSize == NSSize(width: widths.reduce(0, +), height: 36))
            #expect(!group.isBordered)
            // Updating a long server name must not enlarge the default strip.
            group.setServerName("A very long server name in the office")
            group.refreshContents()
            #expect(abs(preview.fittingSize.width - widths.reduce(0, +)) < 0.01)
        }
    }

    @Test func textPalettePicturesReserveSpaceAndKeepRegularType() throws {
        for (identifier, title, width) in [("search", "Search", 120.0), ("server", "localhost", 160.0)] {
            let item = ToolbarGroups.paletteItem(identifier: .init(identifier), label: title, text: title,
                                                 image: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil),
                                                 width: width, showsMenuIndicator: identifier == "server")
            let preview = try #require(item.view)
            #expect(preview.fittingSize == NSSize(width: width + 12, height: 36))
            #expect(!item.isBordered)
            let content = try #require(preview.subviews.compactMap { $0 as? NSStackView }.first)
            let label = try #require(content.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
            #expect(label.font == NSFont.systemFont(ofSize: 14, weight: .regular))
            #expect(label.stringValue == title)
        }
    }

    @Test func addPreviewUsesTheSameBorderlessSurfaceAndHeight() throws {
        let item = ToolbarGroups.addPaletteItem(identifier: .init("add"), image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"))
        let preview = try #require(item.view)
        #expect(item.label == "Add")
        #expect(!item.isBordered)
        #expect(preview.fittingSize == NSSize(width: 76, height: 36))
        #expect(preview.subviews.compactMap { $0 as? NSStackView }.count == 2)
    }

    @Test func serverContentsLeaveRoomBeforeEachDivider() {
        let control = ToolbarSegmentedControl(frame: NSRect(x: 0, y: 0, width: 396, height: 36))
        control.segmentCount = 3
        for (index, width) in [160.0, 118, 118].enumerated() { control.setWidth(width, forSegment: index) }
        let expected = [NSRect(x: 12, y: 0, width: 136, height: 36),
                        NSRect(x: 172, y: 0, width: 94, height: 36),
                        NSRect(x: 290, y: 0, width: 94, height: 36)]
        for index in 0..<3 {
            #expect(control.segmentContentRect(for: index) == expected[index])
            #expect(control.segmentRect(for: index).contains(control.segmentContentRect(for: index)))
        }
    }

    @Test func groupPreservesActionTargetsAndIndividualValidation() throws {
        _ = NSApplication.shared
        let target = ToolbarGroupTarget()
        let actions = [#selector(ToolbarGroupTarget.start(_:)), #selector(ToolbarGroupTarget.stop(_:)), #selector(ToolbarGroupTarget.force(_:))]
        let items = zip(["Start", "Stop", "Force Start"], actions).map { title, action in
            let item = NSToolbarItem(itemIdentifier: .init(title))
            item.label = title
            item.image = NSImage(systemSymbolName: "play", accessibilityDescription: title)
            item.target = target
            item.action = action
            return item
        }
        let group = ToolbarGroups.actions(identifier: .init("testActions"), items: items)
        #expect(group.segments.trackingMode == .momentary)
        #expect(group.subitems.map(\.action) == actions.map(Optional.some))
        // Momentary controls expose selectedSegment only during an actual click.
        // Exercise the dispatcher directly; native pointer routing is UI-tested.
        for index in items.indices { group.performAction(at: index) }
        #expect(target.calls == ["start", "stop", "force"])
        target.canStart = false
        group.validate()
        #expect(!group.subitems[0].isEnabled)
        #expect(!group.segments.isEnabled(forSegment: 0))
        group.performAction(at: 0)
        group.performAction(at: -1)
        group.performAction(at: items.count)
        #expect(target.calls == ["start", "stop", "force"])
        #expect(group.subitems[1].isEnabled)
        #expect(group.subitems[2].isEnabled)
    }

    @Test func menuSegmentsPreserveMenusAndHaveAccessibleClickActions() throws {
        _ = NSApplication.shared
        let item = NSMenuToolbarItem(itemIdentifier: .init("server"))
        item.label = "Server"
        let menu = NSMenu(title: "Server")
        item.menu = menu
        let speed = NSMenuToolbarItem(itemIdentifier: .init("speedLimits"))
        speed.label = "Speed Limits"
        speed.menu = NSMenu(title: "Speed Limits")
        let target = ToolbarGroupTarget()
        let options = NSToolbarItem(itemIdentifier: .init("serverOptions"))
        options.label = "Server Options"
        options.target = target
        options.action = #selector(ToolbarGroupTarget.start(_:))
        let group = SegmentedToolbarGroup(identifier: .init("servers"), items: [item, speed, options])
        #expect(item.menu === menu)
        #expect(item.target === group)
        #expect(item.action != nil)
        #expect(!item.autovalidates)
        #expect(group.segments.showsMenuIndicator(forSegment: 0))
        #expect(group.segments.menu(forSegment: 0) == nil)
        #expect(group.segments.menuSegments == [0, 1])
        group.validate()
        #expect(group.segments.isEnabled(forSegment: 0))
        group.alignsCaptionsToSegments = true
        #expect(item.label == "Server")
        #expect(group.segments.captionFields.first?.stringValue == "Server")
        // AppKit copies the representation into the native overflow menu.
        let overflow = NSMenu()
        let before = NSMenuItem(title: "Before", action: nil, keyEquivalent: "")
        let after = NSMenuItem(title: "After", action: nil, keyEquivalent: "")
        overflow.items = [before, try #require(group.menuFormRepresentation?.copy() as? NSMenuItem), after]
        // Refresh dynamic menus after the representation was copied.
        menu.addItem(withTitle: "Current server", action: nil, keyEquivalent: "")
        target.canStart = false
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: overflow)
        #expect(overflow.items.map(\.title) == ["Before", "Server", "Speed Limits", "Server Options", "After"])
        #expect(overflow.items.first === before)
        #expect(overflow.items.last === after)
        #expect(overflow.items[1].submenu?.items.map(\.title) == ["Current server"])
        #expect(overflow.items[1].submenu !== menu)
        #expect(overflow.items[2].submenu != nil)
        #expect(overflow.items[3].submenu == nil)
        #expect(!overflow.items[3].isEnabled)
        #expect(overflow.items[1].isEnabled)
        // Tracking an already expanded menu must not duplicate its items.
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: overflow)
        #expect(overflow.items.count == 5)
        // A newly constructed overflow receives fresh validation and actions.
        target.canStart = true
        overflow.items = [try #require(group.menuFormRepresentation?.copy() as? NSMenuItem)]
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: overflow)
        let entry = overflow.items[2]
        #expect(entry.isEnabled)
        NSApp.sendAction(try #require(entry.action), to: entry.target, from: entry)
        #expect(target.calls == ["start"])
        // Similar titles in unrelated menus are never treated as our wrapper.
        let other = NSMenu()
        let unrelated = NSMenuItem(title: group.paletteLabel, action: nil, keyEquivalent: "")
        other.items = [unrelated]
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: other)
        #expect(other.items == [unrelated])
    }

    @Test func fullSegmentHitAreasAndMenusUseTheSameUnequalWidths() {
        let control = ToolbarSegmentedControl(frame: NSRect(x: 0, y: 0, width: 396, height: 36))
        control.segmentCount = 3
        control.segmentDistribution = .fit
        for (index, width) in [160.0, 118, 118].enumerated() {
            control.setWidth(width, forSegment: index)
        }
        #expect(control.segment(at: NSPoint(x: 159, y: 18)) == 0)
        #expect(control.segment(at: NSPoint(x: 160, y: 18)) == 1)
        #expect(control.segment(at: NSPoint(x: 277, y: 35)) == 1)
        #expect(control.segment(at: NSPoint(x: 278, y: 1)) == 2)
        #expect(control.segment(at: NSPoint(x: -1, y: 18)) == nil)
        #expect(control.segment(at: NSPoint(x: 200, y: 37)) == nil)
        #expect(control.segmentRect(for: 1) == NSRect(x: 160, y: 0, width: 118, height: 36))
        let anchor = control.menuAnchor(for: 1)
        #expect(anchor.x == 160)
        #expect(anchor.y == (control.isFlipped ? control.bounds.maxY + 8 : control.bounds.minY - 8))
        control.showPressed(1) { #expect(control.pressedSegment == 1) }
        #expect(control.pressedSegment == nil)
        control.setCaptions(["Server", "Speed Limits", "Server Options"], visible: true)
        control.layoutSubtreeIfNeeded()
        for (index, field) in control.captionFields.enumerated() {
            #expect(field.frame.midX == control.segmentRect(for: index).midX)
            #expect(field.alignment == .center)
            #expect(!field.isHidden)
        }
        #expect(control.frame.height == 36)
        control.setCaptions(["Server", "Speed Limits", "Server Options"], visible: false)
        for field in control.captionFields { #expect(field.isHidden) }
    }

    @Test func menuHighlightsFollowNativeDividersWithoutMovingContents() {
        let control = ToolbarSegmentedControl(frame: NSRect(x: 0, y: 0, width: 396, height: 36))
        control.segmentCount = 3
        for (index, width) in [160.0, 118, 118].enumerated() { control.setWidth(width, forSegment: index) }
        let contents = (0..<3).map { control.segmentContentRect(for: $0) }
        // Native content frames include bezel margins; adjoining edges are the
        // dividers even when they differ from the configured content widths.
        for (index, frame) in [NSRect(x: -7, y: 0, width: 164, height: 36),
                               NSRect(x: 157, y: 0, width: 123, height: 36),
                               NSRect(x: 280, y: 0, width: 123, height: 36)].enumerated() {
            control.recordNativeSegmentFrame(frame, for: index)
        }
        #expect(control.highlightRect(for: 0).minX == 0)
        #expect(control.highlightRect(for: 0).maxX == control.highlightRect(for: 1).minX)
        #expect(control.highlightRect(for: 1).maxX == control.highlightRect(for: 2).minX)
        #expect(control.highlightRect(for: 2).maxX == 396)
        #expect(control.segment(at: NSPoint(x: 156, y: 18)) == 0)
        #expect(control.segment(at: NSPoint(x: 157, y: 18)) == 1)
        #expect(control.segment(at: NSPoint(x: 279, y: 18)) == 1)
        #expect(control.segment(at: NSPoint(x: 280, y: 18)) == 2)
        #expect((0..<3).map { control.segmentContentRect(for: $0) } == contents)
        control.setFrameSize(NSSize(width: 420, height: 36))
        #expect(control.highlightRect(for: 1) == control.segmentRect(for: 1))
        control.recordNativeSegmentFrame(NSRect(x: 160, y: 0, width: 130, height: 36), for: 1)
        #expect(control.highlightRect(for: 0) == control.segmentRect(for: 0))
        #expect(control.highlightRect(for: 1).width == 130)
    }

    @Test func addSplitButtonRetainsPrimaryActionMenuAndHeight() throws {
        _ = NSApplication.shared
        let target = ToolbarGroupTarget()
        let menu = NSMenu()
        let file = menu.addItem(withTitle: "Add Torrent File…", action: #selector(ToolbarGroupTarget.start(_:)), keyEquivalent: "")
        file.target = target
        let link = menu.addItem(withTitle: "Add Magnet or URL…", action: #selector(ToolbarGroupTarget.stop(_:)), keyEquivalent: "")
        link.target = target
        let item = ToolbarAddItem(identifier: .init("add"), image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), menu: menu)
        item.target = target
        item.action = #selector(ToolbarGroupTarget.start(_:))
        let host = try #require(item.view)
        #expect(host.fittingSize == NSSize(width: 72, height: 36))
        #expect(item.control.fittingSize == NSSize(width: 64, height: 36))
        item.performAction(at: 0)
        #expect(target.calls == ["start"])
        item.isEnabled = false
        #expect(!item.control.isEnabled)
        item.performAction(at: 0)
        item.performAction(at: -1)
        item.performAction(at: 2)
        #expect(target.calls == ["start"])
        #expect(item.addMenu === menu)
        let overflow = try #require(item.menuFormRepresentation?.submenu)
        #expect(overflow !== menu)
        #expect(overflow.items.map(\.title) == menu.items.map(\.title))
        let entry = try #require(overflow.items.last)
        NSApp.sendAction(try #require(entry.action), to: entry.target, from: entry)
        #expect(target.calls == ["start", "stop"])
        #expect(item.control.menuSegments == [1])
        let anchor = item.control.menuAnchor(for: 1)
        #expect(anchor.y == (item.control.isFlipped ? item.control.bounds.maxY + 8 : item.control.bounds.minY - 8))
    }

    @Test func individualPalettePicturesRetainSymbolsForGroupCopies() throws {
        for name in ["play", "stop", "forward", "square.and.pencil", "folder", "checkmark.shield", "slider.horizontal.3", "gauge.with.needle"] {
            let image = try #require(NSImage(systemSymbolName: name, accessibilityDescription: name))
            let item = ToolbarGroups.paletteItem(identifier: .init(name), label: name, text: "", image: image, width: 36)
            #expect(item.image === image)
            #expect(!item.isBordered)
            let view = try #require(item.view)
            #expect(view.fittingSize == NSSize(width: 48, height: 36))
            let group = ToolbarGroups.actions(identifier: .init("preview"), items: [item], isPaletteItem: true)
            #expect(group.segments.image(forSegment: 0) === image)
        }
    }

    @Test func migrationGroupsOnlyCompleteAdjacentActionsAndIsIdempotent() {
        func ids(_ strings: [String]) -> [NSToolbarItem.Identifier] { strings.map { .init($0) } }
        let legacy = ids(["add", "start", "stop", "forceStart", "rename", "move", "verify", "remove", "server", "serverOptions", "speedLimits", "search"])
        let expected = [NSToolbarItem.Identifier("add"), .space, .init("transferControls"), .space, .init("torrentControls"), .space, .init("remove"), .init("serverControls"), .init("search")]
        #expect(ToolbarGroups.migrated(legacy) == expected)
        #expect(ToolbarGroups.migrated(expected) == expected)
        let custom = ids(["start", "search", "stop", "forceStart", "serverOptions", "server"])
        #expect(ToolbarGroups.migrated(custom) == custom)
    }
}
