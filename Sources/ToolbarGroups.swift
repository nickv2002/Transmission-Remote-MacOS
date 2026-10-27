import AppKit

/// Native groups keep actions together during customization and in overflow.
@MainActor
enum ToolbarGroups {
    static func actions(identifier: NSToolbarItem.Identifier, items: [NSToolbarItem]) -> SegmentedToolbarGroup {
        SegmentedToolbarGroup(identifier: identifier, items: items)
    }

    /// Replace complete adjacent legacy groups once; preserve removed/reordered items.
    static func migrated(_ identifiers: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
        var result = identifiers.map(\.rawValue)
        for (members, group) in [
            (["start", "stop", "forceStart"], "transferControls"),
            (["rename", "move", "verify"], "torrentControls"),
            (["server", "serverOptions", "speedLimits"], "serverControls"),
        ] where !result.contains(group) && result.count >= members.count {
            if let start = (0...(result.count - members.count)).first(where: {
                Array(result[$0..<($0 + members.count)]) == members
            }) {
                result.replaceSubrange(start..<(start + members.count), with: [group])
            }
        }
        var spaced: [String] = []
        let actionGroups: Set<String> = ["transferControls", "torrentControls"]
        for value in result {
            if let previous = spaced.last,
               (previous == "add" && actionGroups.contains(value)
                || actionGroups.contains(previous) && (actionGroups.contains(value) || value == "remove")) {
                spaced.append(NSToolbarItem.Identifier.space.rawValue)
            }
            spaced.append(value)
        }
        return spaced.map { NSToolbarItem.Identifier($0) }
    }
}

/// One native segmented control supplies the joined bezel and separators. Keeping
/// the original subitems preserves customization, overflow and action validation.
@MainActor
final class SegmentedToolbarGroup: NSToolbarItemGroup {
    let segments = ToolbarSegmentedControl()
    private let overflowIdentifier = NSUserInterfaceItemIdentifier("ToolbarGroupOverflow.\(UUID().uuidString)")
    var alignsCaptionsToSegments = false {
        didSet { refreshContents() }
    }

    init(identifier: NSToolbarItem.Identifier, items: [NSToolbarItem]) {
        super.init(itemIdentifier: identifier)
        NotificationCenter.default.addObserver(self, selector: #selector(flattenOverflow(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        subitems = items
        paletteLabel = items.map(\.label).joined(separator: " / ")
        segments.controlSize = .large
        segments.heightAnchor.constraint(equalToConstant: 36).isActive = true
        segments.segmentCount = items.count
        segments.trackingMode = .momentary
        segments.segmentStyle = .rounded
        segments.segmentDistribution = .fillEqually
        segments.target = self
        segments.action = #selector(activate(_:))
        segments.onActivate = { [weak self] index in self?.performAction(at: index) }
        for index in items.indices {
            segments.setWidth(80, forSegment: index)
        }
        view = segments
        refreshContents()
    }

    func refreshContents() {
        for (index, item) in subitems.enumerated() {
            segments.setImage(item.image, forSegment: index)
            segments.setToolTip(item.toolTip, forSegment: index)
            if let menuItem = item as? NSMenuToolbarItem {
                // A normal click should open the menu, not require a press-and-hold.
                // Give the subitem the same action for accessibility and overflow.
                menuItem.target = self
                menuItem.action = #selector(showMenu(_:))
                menuItem.autovalidates = false
                // Keep menu presentation here so both the icon and arrow use
                // the same below-button anchor instead of AppKit's popup position.
                segments.menuSegments.insert(index)
                segments.setShowsMenuIndicator(true, forSegment: index)
            }
        }
        if alignsCaptionsToSegments {
            // AppKit divides its group caption row equally, even when segment
            // widths differ. Reserve that same row and align our captions to
            // the actual segments; retain the subitem labels for accessibility.
            label = " "
            segments.setCaptions(subitems.map(\.label), visible: toolbar?.displayMode != .iconOnly)
            let menu = NSMenu()
            menu.items = makeOverflowItems()
            let entry = NSMenuItem(title: paletteLabel, action: nil, keyEquivalent: "")
            entry.identifier = overflowIdentifier
            entry.submenu = menu
            menuFormRepresentation = entry
        }
        validate()
    }

    override func validate() {
        for (index, item) in subitems.enumerated() {
            item.validate()
            segments.setEnabled(item.isEnabled, forSegment: index)
            if segments.captionFields.indices.contains(index) {
                segments.captionFields[index].textColor = item.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
            }
            menuFormRepresentation?.submenu?.item(at: index)?.isEnabled = item.isEnabled
        }
    }

    private func makeOverflowItems() -> [NSMenuItem] {
        subitems.map { item in
            let entry = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
            entry.target = item.target
            entry.isEnabled = item.isEnabled
            if let source = (item as? NSMenuToolbarItem)?.menu {
                entry.action = nil
                entry.submenu = source.copy() as? NSMenu
            }
            return entry
        }
    }

    @objc private func flattenOverflow(_ notification: Notification) {
        // AppKit wraps an item group in a submenu, including groups with custom
        // views. Expand only our marked representation when its containing menu
        // opens; leave other toolbar items and normal application menus alone.
        // The identifier survives AppKit copying the menu representation.
        guard alignsCaptionsToSegments, let menu = notification.object as? NSMenu,
              let index = menu.items.firstIndex(where: { $0.identifier == overflowIdentifier }) else { return }
        validate()
        menu.removeItem(at: index)
        for (offset, item) in makeOverflowItems().enumerated() {
            menu.insertItem(item, at: index + offset)
        }
    }

    @objc private func showMenu(_ item: NSToolbarItem) {
        guard let index = subitems.firstIndex(of: item),
              let menu = (item as? NSMenuToolbarItem)?.menu else { return }
        segments.showPressed(index) {
            menu.popUp(positioning: nil, at: segments.menuAnchor(for: index), in: segments)
        }
    }

    @objc private func activate(_ sender: NSSegmentedControl) {
        performAction(at: sender.selectedSegment)
    }

    func performAction(at index: Int) {
        guard subitems.indices.contains(index) else { return }
        let item = subitems[index]
        guard item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Retains AppKit's bezel, symbols, captions and keyboard/accessibility behavior,
/// while providing an edge-to-edge momentary highlight and one menu click path.
@MainActor
final class ToolbarSegmentedControl: NSSegmentedControl {
    var menuSegments: Set<Int> = []
    var onActivate: ((Int) -> Void)?
    private(set) var captionFields: [NSTextField] = []
    private(set) var pressedSegment: Int? {
        didSet {
            needsDisplay = true
            displayIfNeeded()
        }
    }

    func setCaptions(_ titles: [String], visible: Bool) {
        if captionFields.count != titles.count {
            captionFields.forEach { $0.removeFromSuperview() }
            captionFields = titles.map { title in
                let field = NSTextField(labelWithString: title)
                field.font = .systemFont(ofSize: 11, weight: .medium)
                field.alignment = .center
                field.lineBreakMode = .byTruncatingTail
                field.setAccessibilityElement(false)
                addSubview(field)
                return field
            }
            // Captions occupy the label row already reserved by NSToolbar.
            // Keeping them outside the control bounds preserves its height.
            clipsToBounds = false
        }
        for (field, title) in zip(captionFields, titles) {
            field.stringValue = title
            field.isHidden = !visible
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, field) in captionFields.enumerated() {
            let segment = segmentRect(for: index)
            field.frame = NSRect(x: segment.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 20,
                                 width: segment.width, height: 16)
        }
    }

    func segmentRect(for index: Int) -> NSRect {
        guard (0..<segmentCount).contains(index) else { return .zero }
        let widths = (0..<segmentCount).map { width(forSegment: $0) }
        let total = widths.reduce(0, +)
        guard total > 0 else { return .zero }
        let leading = widths.prefix(index).reduce(0, +)
        return NSRect(x: bounds.minX + bounds.width * leading / total, y: bounds.minY,
                      width: bounds.width * widths[index] / total, height: bounds.height)
    }

    func segment(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return (0..<segmentCount).first { segmentRect(for: $0).contains(point) }
    }

    func menuAnchor(for index: Int) -> NSPoint {
        NSPoint(x: segmentRect(for: index).minX,
                y: isFlipped ? bounds.maxY + 8 : bounds.minY - 8)
    }

    func showPressed(_ index: Int, while action: () -> Void) {
        pressedSegment = index
        defer { pressedSegment = nil }
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let index = pressedSegment else { return }
        NSGraphicsContext.saveGraphicsState()
        // Clip only the outer ends of the group. Interior segments highlight all
        // the way to their dividers, without an inset pill around the symbol.
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).addClip()
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        segmentRect(for: index).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled,
              let index = segment(at: convert(event.locationInWindow, from: nil)),
              isEnabled(forSegment: index) else { return }
        if menuSegments.contains(index) {
            onActivate?(index)
            return
        }
        // Track the original segment like a momentary native button: dragging
        // away cancels its highlight, and releasing outside cancels the action.
        pressedSegment = index
        defer { pressedSegment = nil }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = segment(at: convert(next.locationInWindow, from: nil)) == index
            pressedSegment = inside ? index : nil
            if next.type == .leftMouseUp {
                pressedSegment = nil
                if inside { onActivate?(index) }
                return
            }
        }
    }
}
