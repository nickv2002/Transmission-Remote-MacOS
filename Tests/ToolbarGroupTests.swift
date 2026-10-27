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
