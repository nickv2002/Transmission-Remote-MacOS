import AppKit

/// Native groups keep actions together during customization and in overflow.
@MainActor
enum ToolbarGroups {
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

    static func configureSearchField(_ field: NSSearchField, placeholder: String) {
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        field.controlSize = .large
        field.font = font
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    /// Palette copies are pictures, not live controls. Using labels here avoids
    /// AppKit substituting its own bold popup/search representation in snapshots.
    static func paletteItem(identifier: NSToolbarItem.Identifier, label: String,
                            text: String, image: NSImage?, width: CGFloat,
                            showsMenuIndicator: Bool = false) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.image = image
        if identifier.rawValue == "search" { item.visibilityPriority = .high }
        item.isBordered = false
        let preview = ToolbarPalettePreview(horizontalInset: 6)
        preview.update([.init(width: width, title: text, image: image,
                              showsMenuIndicator: showsMenuIndicator, enabled: true)])
        item.view = preview
        return item
    }

    static func addPaletteItem(identifier: NSToolbarItem.Identifier, image: NSImage?) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Add"
        item.isBordered = false
        let preview = ToolbarPalettePreview()
        let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        preview.update([
            .init(width: 38, title: "", image: image, showsMenuIndicator: false, enabled: true),
            .init(width: 38, title: "", image: arrow, showsMenuIndicator: false, enabled: true),
        ])
        item.view = preview
        return item
    }

    static func actions(identifier: NSToolbarItem.Identifier, items: [NSToolbarItem],
                        isPaletteItem: Bool = false) -> SegmentedToolbarGroup {
        SegmentedToolbarGroup(identifier: identifier, items: items, isPaletteItem: isPaletteItem)
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

/// A native split control keeps Add's primary action while sharing the same
/// below-button menu anchor as the server controls.
@MainActor
final class ToolbarAddItem: NSToolbarItem {
    let control = ToolbarSegmentedControl()
    let addMenu: NSMenu
    // NSToolbarItem forwards target/action to a custom view. The outer glass
    // host is not a control, so retain the primary action here explicitly.
    private weak var primaryTarget: AnyObject?
    private var primaryAction: Selector?
    override var target: AnyObject? {
        get { primaryTarget }
        set { primaryTarget = newValue }
    }
    override var action: Selector? {
        get { primaryAction }
        set { primaryAction = newValue }
    }

    override var isEnabled: Bool {
        didSet { control.isEnabled = isEnabled }
    }

    init(identifier: NSToolbarItem.Identifier, image: NSImage?, menu: NSMenu) {
        addMenu = menu
        super.init(itemIdentifier: identifier)
        label = "Add"
        isBordered = false
        control.cell = ToolbarSegmentCell()
        control.controlSize = .large
        control.segmentCount = 2
        control.segmentStyle = .rounded
        control.segmentDistribution = .fit
        control.trackingMode = .momentary
        control.setWidth(38, forSegment: 0)
        control.setWidth(26, forSegment: 1)
        control.setImage(image, forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Add menu")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)), forSegment: 1)
        control.menuSegments = [1]
        control.target = self
        control.action = #selector(activate(_:))
        control.onActivate = { [weak self] index in self?.performAction(at: index) }
        control.widthAnchor.constraint(equalToConstant: 64).isActive = true
        control.heightAnchor.constraint(equalToConstant: 36).isActive = true
        // Keep outer padding separate from the 64-point button surface.
        let host = NSView()
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = control
            surface = glass
        } else {
            surface = control
        }
        host.addSubview(surface)
        host.widthAnchor.constraint(equalToConstant: 72).isActive = true
        host.heightAnchor.constraint(equalToConstant: 36).isActive = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: 64),
            surface.heightAnchor.constraint(equalToConstant: 36),
            surface.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            surface.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        if surface !== control {
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                control.topAnchor.constraint(equalTo: surface.topAnchor),
            ])
        }
        view = host
        let overflow = NSMenuItem(title: "Add", action: nil, keyEquivalent: "")
        overflow.submenu = menu.copy() as? NSMenu
        menuFormRepresentation = overflow
    }

    @objc private func activate(_ sender: NSSegmentedControl) {
        performAction(at: sender.selectedSegment)
    }

    func performAction(at index: Int) {
        guard isEnabled else { return }
        if index == 0, let action {
            NSApp.sendAction(action, to: target, from: self)
        } else if index == 1 {
            control.showPressed(index) {
                addMenu.popUp(positioning: nil, at: control.menuAnchor(for: index), in: control)
            }
        }
    }
}

/// One native segmented control supplies the joined bezel and separators. Keeping
/// the original subitems preserves customization, overflow and action validation.
@MainActor
final class SegmentedToolbarGroup: NSToolbarItemGroup {
    let segments = ToolbarSegmentedControl()
    private let isPaletteItem: Bool
    private var captionContainer: ToolbarCaptionContainer?
    private var palettePreview: ToolbarPalettePreview?
    private let overflowIdentifier = NSUserInterfaceItemIdentifier("ToolbarGroupOverflow.\(UUID().uuidString)")
    var alignsCaptionsToSegments = false {
        didSet { refreshContents() }
    }

    init(identifier: NSToolbarItem.Identifier, items: [NSToolbarItem], isPaletteItem: Bool = false) {
        self.isPaletteItem = isPaletteItem
        super.init(itemIdentifier: identifier)
        NotificationCenter.default.addObserver(self, selector: #selector(flattenOverflow(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        subitems = items
        if items.contains(where: { $0 is NSMenuToolbarItem }) {
            segments.cell = ToolbarSegmentCell()
        }
        controlRepresentation = .expanded
        paletteLabel = items.map(\.label).joined(separator: " / ")
        // Both the palette and its default-set preview supply their own single
        // caption. Do not draw the live toolbar's per-segment captions there.
        if isPaletteItem {
            label = paletteLabel
            isBordered = false
        }
        segments.controlSize = .large
        segments.font = .systemFont(ofSize: 14, weight: .regular)
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
        if isPaletteItem {
            let preview = ToolbarPalettePreview()
            palettePreview = preview
            view = preview
        }
        refreshContents()
    }

    /// Keep a long server name on one line even when AppKit renders a toolbar
    /// segment using its multiline text implementation. The full name remains
    /// available in the tooltip and in the server menu.
    func setServerName(_ name: String) {
        guard !subitems.isEmpty else { return }
        let font = segments.font ?? .systemFont(ofSize: 14)
        let available = max(0, segments.width(forSegment: 0) - (segments.image(forSegment: 0)?.size.width ?? 0) - 44)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let singleLine = name.components(separatedBy: .newlines).joined(separator: " ")
        var title = singleLine
        if (title as NSString).size(withAttributes: attributes).width > available {
            while !title.isEmpty && ((title + "…") as NSString).size(withAttributes: attributes).width > available {
                title.removeLast()
            }
            title += "…"
        }
        subitems[0].toolTip = name
        segments.setToolTip(name, forSegment: 0)
        segments.setLabel(title, forSegment: 0)
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
        if alignsCaptionsToSegments && !isPaletteItem {
            // Keep captions outside the glass surface, in the label row reserved
            // by NSToolbar. Descendants of its glass content view are clipped.
            label = " "
            isBordered = false
            if captionContainer == nil {
                let container = ToolbarCaptionContainer(control: segments)
                captionContainer = container
                segments.captionContainer = container
                view = container
            }
            captionContainer?.updateWidth()
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
        palettePreview?.update(subitems.enumerated().map { index, item in
            .init(width: segments.width(forSegment: index), title: segments.label(forSegment: index) ?? "",
                  image: item.image, showsMenuIndicator: segments.menuSegments.contains(index), enabled: item.isEnabled)
        })
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

/// Customization uses static pictures. Keep their measurements explicit: the
/// segmented control's intrinsic size adds bezel margins that can overflow the
/// default-set strip. A flat fill also avoids clipped glass borders in snapshots.
@MainActor
private final class ToolbarPalettePreview: NSView {
    struct Entry {
        var width: CGFloat
        var title: String
        var image: NSImage?
        var showsMenuIndicator: Bool
        var enabled: Bool
    }

    private let horizontalInset: CGFloat
    private var widthConstraint: NSLayoutConstraint!
    private var entries: [Entry] = []

    init(horizontalInset: CGFloat = 0) {
        self.horizontalInset = horizontalInset
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ entries: [Entry]) {
        self.entries = entries
        widthConstraint.constant = entries.reduce(2 * horizontalInset) { $0 + $1.width }
        subviews.forEach { $0.removeFromSuperview() }
        var x = horizontalInset
        for entry in entries {
            let content = NSStackView()
            content.orientation = .horizontal
            content.spacing = 6
            if let image = entry.image {
                let icon = NSImageView(image: image)
                icon.imageScaling = .scaleNone
                icon.widthAnchor.constraint(equalToConstant: max(20, image.size.width)).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
                content.addArrangedSubview(icon)
            }
            if !entry.title.isEmpty {
                let title = NSTextField(labelWithString: entry.title)
                title.font = .systemFont(ofSize: 14, weight: .regular)
                title.textColor = entry.enabled ? .labelColor : .disabledControlTextColor
                title.lineBreakMode = .byTruncatingTail
                title.maximumNumberOfLines = 1
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                content.addArrangedSubview(title)
            }
            addSubview(content)
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: leadingAnchor, constant: x + entry.width / 2 - (entry.showsMenuIndicator ? 7 : 0)),
                content.centerYAnchor.constraint(equalTo: centerYAnchor),
                content.widthAnchor.constraint(lessThanOrEqualToConstant: max(20, entry.width - (entry.showsMenuIndicator ? 48 : 24))),
            ])
            if entry.showsMenuIndicator {
                let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage())
                arrow.alphaValue = entry.enabled ? 1 : 0.35
                addSubview(arrow)
                arrow.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    arrow.trailingAnchor.constraint(equalTo: leadingAnchor, constant: x + entry.width - 12),
                    arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
                    arrow.widthAnchor.constraint(equalToConstant: 10),
                    arrow.heightAnchor.constraint(equalToConstant: 10),
                ])
            }
            x += entry.width
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: horizontalInset, dy: 0), xRadius: 18, yRadius: 18).fill()
        NSColor.separatorColor.setStroke()
        var x = horizontalInset
        for entry in entries.dropLast() {
            x += entry.width
            let divider = NSBezierPath()
            divider.lineWidth = 0.5
            divider.move(to: NSPoint(x: x, y: 8))
            divider.line(to: NSPoint(x: x, y: bounds.height - 8))
            divider.stroke()
        }
    }
}

/// Captions sit outside the glass surface in NSToolbar's reserved label row.
/// The group disables its automatic border so only the control receives glass.
@MainActor
private final class ToolbarCaptionContainer: NSView {
    let control: ToolbarSegmentedControl
    private var widthConstraint: NSLayoutConstraint!

    init(control: ToolbarSegmentedControl) {
        self.control = control
        super.init(frame: .zero)
        clipsToBounds = false
        setAccessibilityLabel("Server controls")
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 396)
        widthConstraint.isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = control
            surface = glass
        } else {
            surface = control
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.heightAnchor.constraint(equalToConstant: 36),
        ])
        if surface !== control {
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                control.topAnchor.constraint(equalTo: surface.topAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateWidth() {
        widthConstraint.constant = (0..<control.segmentCount).reduce(0) { $0 + control.width(forSegment: $1) }
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? control : nil
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { [control] }
    override func isAccessibilityElement() -> Bool { true }
}

@MainActor
private final class ToolbarSegmentCell: NSSegmentedCell {
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        (controlView as? ToolbarSegmentedControl)?.recordNativeSegmentFrame(frame, for: segment)
        guard let control = controlView as? ToolbarSegmentedControl, control.captionContainer != nil else {
            super.drawSegment(segment, inFrame: frame, with: controlView)
            return
        }
        // Use the same segment widths as the captions and preview. AppKit's
        // content frame includes bezel margins and puts arrows at the divider.
        super.drawSegment(segment, inFrame: control.segmentContentRect(for: segment), with: controlView)
    }
}

/// Retains AppKit's bezel, symbols, captions and keyboard/accessibility behavior,
/// while providing an edge-to-edge momentary highlight and one menu click path.
@MainActor
final class ToolbarSegmentedControl: NSSegmentedControl {
    private var nativeSegmentFrames: [Int: NSRect] = [:]
    private var nativeSegmentBounds = NSRect.zero
    var menuSegments: Set<Int> = []
    var onActivate: ((Int) -> Void)?
    weak var captionContainer: NSView?
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
                (captionContainer ?? self).addSubview(field)
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
            let rect = NSRect(x: segment.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 20,
                              width: segment.width, height: 16)
            field.frame = field.superview?.convert(rect, from: self) ?? rect
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

    func recordNativeSegmentFrame(_ frame: NSRect, for index: Int) {
        if nativeSegmentBounds != bounds {
            nativeSegmentFrames.removeAll()
            nativeSegmentBounds = bounds
        }
        nativeSegmentFrames[index] = frame
    }

    func highlightRect(for index: Int) -> NSRect {
        guard nativeSegmentBounds == bounds, let frame = nativeSegmentFrames[index] else {
            return segmentRect(for: index)
        }
        return frame.intersection(bounds)
    }

    func segmentContentRect(for index: Int) -> NSRect {
        segmentRect(for: index).insetBy(dx: 12, dy: 0)
    }

    func segment(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return (0..<segmentCount).first { highlightRect(for: $0).contains(point) }
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
        highlightRect(for: index).fill()
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
