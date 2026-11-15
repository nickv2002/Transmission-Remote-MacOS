import AppKit

@MainActor
enum ToolbarID {
    static let transferControls = NSToolbarItem.Identifier("transferControls")
    static let torrentControls = NSToolbarItem.Identifier("torrentControls")
    static let serverControls = NSToolbarItem.Identifier("serverControls")
    static let add = NSToolbarItem.Identifier("add")
    static let start = NSToolbarItem.Identifier("start")
    static let stop = NSToolbarItem.Identifier("stop")
    static let forceStart = NSToolbarItem.Identifier("forceStart")
    static let rename = NSToolbarItem.Identifier("rename")
    static let move = NSToolbarItem.Identifier("move")
    static let verify = NSToolbarItem.Identifier("verify")
    static let remove = NSToolbarItem.Identifier("remove")
    static let search = NSToolbarItem.Identifier("search")
    static let server = NSToolbarItem.Identifier("server")
    static let serverOptions = NSToolbarItem.Identifier("serverOptions")
    static let speedLimits = NSToolbarItem.Identifier("speedLimits")

    static let groups: [NSToolbarItem.Identifier: [NSToolbarItem.Identifier]] = [
        transferControls: [start, stop, forceStart],
        torrentControls: [rename, move, verify],
        serverControls: [server, speedLimits, serverOptions],
    ]

    static let defaultItems: [NSToolbarItem.Identifier] = [
        add, .space, transferControls, .space, torrentControls, .space, remove,
        .flexibleSpace, serverControls, .flexibleSpace, search,
    ]
}

/// Native groups keep actions together during customization and in overflow.
@MainActor
enum ToolbarGroups {
    static let autosaveIdentifier = "MainToolbar5Grouped"

    static func migrateConfiguration(defaults: UserDefaults = .standard) {
        let key = "NSToolbar Configuration " + autosaveIdentifier
        let classicKey = "NSToolbar Configuration MainToolbar4"
        guard defaults.object(forKey: key) == nil,
              var configuration = defaults.dictionary(forKey: classicKey),
              let identifiers = configuration["TB Item Identifiers"] as? [String] else { return }
        configuration["TB Item Identifiers"] = ToolbarGroups.migrated(
            identifiers.map { NSToolbarItem.Identifier($0) }).map(\.rawValue)
        defaults.set(configuration, forKey: key)
    }

    /// The standalone item and a grouped copy may coexist after customization.
    /// Read the current toolbar so removed items and palette copies cannot become
    /// the refresh target instead of the controls that are actually displayed.
    static func menuItems(in items: [NSToolbarItem], identifier: NSToolbarItem.Identifier) -> [NSMenuToolbarItem] {
        func collect(_ items: [NSToolbarItem]) -> [NSMenuToolbarItem] {
            items.flatMap { item in
                if let group = item as? NSToolbarItemGroup { return collect(group.subitems) }
                guard item.itemIdentifier == identifier, let menu = item as? NSMenuToolbarItem else { return [] }
                return [menu]
            }
        }
        return collect(items)
    }

    /// Replace complete adjacent legacy groups once; preserve removed/reordered items.
    static func migrated(_ identifiers: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
        let oldDefault: [NSToolbarItem.Identifier] = [
            ToolbarID.add, .space, ToolbarID.start, ToolbarID.stop, ToolbarID.forceStart,
            ToolbarID.rename, ToolbarID.move, ToolbarID.verify, ToolbarID.remove, .flexibleSpace,
            ToolbarID.server, ToolbarID.speedLimits, ToolbarID.serverOptions, .flexibleSpace, ToolbarID.search,
        ]
        if identifiers == oldDefault { return ToolbarID.defaultItems }

        var result = identifiers
        for (group, members) in ToolbarID.groups where !result.contains(group) {
            guard let first = members.first, let index = result.firstIndex(of: first),
                  result[index...].starts(with: members) else { continue }
            result.replaceSubrange(index..<(index + members.count), with: [group])
        }
        return result
    }
}

@MainActor
final class NativeToolbarGroup: NSToolbarItemGroup {
    private let standardControl = NSSegmentedControl()
    var control: NSSegmentedControl { captionView?.control ?? standardControl }
    private let overflowID = NSUserInterfaceItemIdentifier("ServerGroupOverflow." + UUID().uuidString)
    private let captionControlSize: NSControl.ControlSize?
    private var captionView: AlignedToolbarCaptions?
    private var originalBorder = false

    init(id: NSToolbarItem.Identifier, items: [NSToolbarItem], palette: Bool,
         showsLabels: Bool, macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        if palette || macOSMajorVersion > 26 {
            captionControlSize = nil
        } else {
            captionControlSize = macOSMajorVersion == 26 ? .large : .regular
        }
        super.init(itemIdentifier: id)
        subitems = items
        paletteLabel = items.map(\.label).joined(separator: " / ")
        if palette { label = paletteLabel }
        if macOSMajorVersion == 27 && !palette {
            standardControl.cell = GoldenGateToolbarSegmentCell()
        }
        configure(standardControl)
        view = standardControl
        setShowsLabels(showsLabels)
        if id == ToolbarID.serverControls && !palette {
            let entry = NSMenuItem(title: paletteLabel, action: nil, keyEquivalent: "")
            entry.identifier = overflowID
            entry.submenu = NSMenu()
            menuFormRepresentation = entry
            NotificationCenter.default.addObserver(self, selector: #selector(expandServerOverflow(_:)),
                                                   name: NSMenu.didBeginTrackingNotification, object: nil)
        }
        refreshContents()
    }

    private func configure(_ control: NSSegmentedControl) {
        control.trackingMode = .momentary
        control.segmentCount = subitems.count
        control.target = self
        control.action = #selector(activate(_:))
    }

    /// Keep one hit target per segment in both modes. On Sequoia and Tahoe, supply
    /// the caption row so its columns use the same widths as those segments.
    func setShowsLabels(_ shown: Bool) {
        guard let captionControlSize, shown != (captionView != nil) else { return }
        if shown {
            label = " " // Reserve AppKit's caption row once for the whole group.
            originalBorder = isBordered
            isBordered = false
            let host = AlignedToolbarCaptions(titles: subitems.map(\.label), controlSize: captionControlSize)
            configure(host.control)
            captionView = host
            view = host
        } else {
            captionView = nil
            label = ""
            isBordered = originalBorder
            view = standardControl
        }
    }

    func refreshContents() {
        for (index, item) in subitems.enumerated() {
            control.setImage(item.image, forSegment: index)
            control.setLabel(item.title, forSegment: index)
            control.setToolTip(item.toolTip, forSegment: index)
            let menu = (item as? NSMenuToolbarItem)?.menu
            control.setMenu(menu, forSegment: index)
            control.setShowsMenuIndicator(menu != nil, forSegment: index)
        }
        if let captionView { captionView.fitSegments() }
        else { control.sizeToFit() }
        validate()
    }

    override func validate() {
        for (index, item) in subitems.enumerated() {
            item.validate()
            control.setEnabled(item.isEnabled, forSegment: index)
            captionView?.fields[index].textColor = item.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        }
    }

    @objc private func activate(_ sender: NSSegmentedControl) {
        performAction(at: sender.selectedSegment)
    }

    func performAction(at index: Int) {
        guard subitems.indices.contains(index) else { return }
        let item = subitems[index]
        item.validate()
        guard item.isEnabled else { return }
        if let menu = (item as? NSMenuToolbarItem)?.menu {
            // AppKit already handles press-and-hold. Open the same menu on a
            // quick click or keyboard activation, just below the native control.
            var x = control.bounds.midX
            if let window = control.window, let children = control.cell?.accessibilityChildren(),
               children.indices.contains(index), let element = children[index] as? NSAccessibilityElement {
                let frame = window.convertFromScreen(element.accessibilityFrame())
                x = control.convert(frame, from: nil).minX
            } else if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.window === control.window {
                x = control.convert(event.locationInWindow, from: nil).x
            }
            let y = control.isFlipped ? control.bounds.maxY : control.bounds.minY
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: control)
        } else if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    // Keep the three server commands directly accessible in a narrow window.
    @objc private func expandServerOverflow(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              let position = menu.items.firstIndex(where: { $0.identifier == overflowID }) else { return }
        validate()
        // AppKit can reuse the overflow menu after the active server or limits change.
        for entry in menu.items where entry.identifier == overflowID { menu.removeItem(entry) }
        for (offset, item) in subitems.enumerated() {
            let entry = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
            entry.identifier = overflowID
            entry.target = item.target
            entry.isEnabled = item.isEnabled
            entry.submenu = (item as? NSMenuToolbarItem)?.menu.copy() as? NSMenu
            menu.insertItem(entry, at: position + offset)
        }
    }
}

private final class GoldenGateToolbarSegmentCell: NSSegmentedCell {
    override func accessibilityFrame() -> NSRect {
        guard let view = controlView, let window = view.window,
              window.toolbar?.displayMode == .iconAndLabel, !view.bounds.isEmpty else {
            return super.accessibilityFrame()
        }
        // AppKit also uses the segment rectangles to center the toolbar captions.
        // On macOS 27 its accessibility calculation includes an extra bezel inset.
        // Use the same bounds as drawing so a hit test and a press agree.
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// The toolbar reserves a row below the control for its label. Only the
/// noninteractive text extends into that row; the segmented control keeps its
/// native bezel, keyboard handling, menus and pressed state.
@MainActor
private final class AlignedToolbarCaptions: NSView {
    let control = NSSegmentedControl()
    let fields: [NSTextField]
    private var surface: NSView?

    init(titles: [String], controlSize: NSControl.ControlSize) {
        fields = titles.map { title in
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            field.alignment = .center
            field.setAccessibilityElement(false)
            return field
        }
        super.init(frame: .zero)
        clipsToBounds = false
        control.controlSize = controlSize
        control.segmentStyle = .rounded
        #if compiler(>=6.2) // Xcode 16 / the Sequoia SDK has no glass view.
        if #available(macOS 26.0, *), controlSize == .large {
            control.borderShape = .capsule
            let glass = NSGlassEffectView()
            surface = glass
            addSubview(glass)
        }
        #endif
        addSubview(control)
        fields.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { control.intrinsicContentSize }

    func fitSegments() {
        let font = control.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for (index, field) in fields.enumerated() {
            let title = control.label(forSegment: index) ?? ""
            let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
            let imageWidth = control.image(forSegment: index)?.size.width ?? 0
            let titleGap: CGFloat = title.isEmpty || imageWidth == 0 ? 0 : 6
            let arrowWidth: CGFloat = control.showsMenuIndicator(forSegment: index) ? 18 : 0
            let contentWidth = imageWidth + titleGap + min(titleWidth, 128) + arrowWidth + 24
            let width = ceil(max(contentWidth, field.intrinsicContentSize.width + 14))
            if control.width(forSegment: index) != width { control.setWidth(width, forSegment: index) }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.frame = bounds
            glass.cornerRadius = bounds.height / 2
        }
        #endif
        control.frame = bounds
        let widths = fields.indices.map { control.width(forSegment: $0) }
        let requested = widths.reduce(0, +)
        // AppKit can briefly compress a group when moving it into overflow.
        // Keep every caption inside the available width, even at zero width.
        let scale = requested > bounds.width && requested > 0 ? bounds.width / requested : 1
        let extra = max(0, bounds.width - requested) / CGFloat(max(fields.count, 1))
        let rtl = control.userInterfaceLayoutDirection == .rightToLeft
        var leading: CGFloat = 0
        for (index, field) in fields.enumerated() {
            let width = widths[index] * scale + extra
            let height = field.intrinsicContentSize.height
            let x = rtl ? bounds.maxX - leading - width : bounds.minX + leading
            field.frame = NSRect(x: x, y: bounds.minY - height - 3, width: width, height: height)
            leading += width
        }
    }
}
