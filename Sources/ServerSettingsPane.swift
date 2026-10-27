import AppKit

extension ServerEncryption: DisplayNamed {}
extension ServerTransports: DisplayNamed {}
extension PeerPortProtocol: DisplayNamed {}

/// The server-side tabs of Settings ▸ <server> (Transfers, Speed, Network,
/// Advanced), embedded in the Settings window. Built once and re-rendered from
/// whichever server's `ServerOptionsSession` is bound. Typing, switching tabs and
/// expanding groups never send `session-set`; only the window's Apply does.
///
/// Essential groups sit at the top of each tab; common and advanced groups have a
/// disclosure triangle whose state is remembered by group name. A group heading
/// carries a "Stored on the server / on this Mac" tag. While the server can't be
/// used (unsaved, connecting, offline) its server-side groups are replaced by a
/// notice; the Mac-side presets group stays editable.
@MainActor
final class ServerSettingsFormController: NSObject, NSTextFieldDelegate {
    /// The bound server's remote editor; nil while it hasn't loaded.
    var session: ServerOptionsSession? { didSet { render() } }
    /// Called after any draft edit (to refresh dirty state, Apply, the row dot).
    var onEdit: (() -> Void)?
    var onTestPort: ((PeerPortProtocol) -> Void)?
    var onManageGroups: (() -> Void)?
    var onRetry: (() -> Void)?
    var onTestConnection: (() -> Void)?
    /// Remembers expanded/collapsed groups by name.
    var expansion: [String: Bool] = [:]
    var onExpansionChange: (([String: Bool]) -> Void)?

    private(set) var paneViews: [ServerOption.Pane: NSView] = [:]
    private(set) var controls: [ServerOption: [NSControl]] = [:]
    private(set) var groupViews: [String: SettingsGroupView] = [:]
    private var fieldRows: [ServerOption: NSView] = [:]
    private var labels: [ServerOption: NSTextField] = [:]
    private var blockers: [ServerOption.Pane: SettingsBlockerView] = [:]
    let portButton = NSButton(title: "Test Incoming Port", target: nil, action: nil)
    let portProtocol = NSPopUpButton()
    let groupsButton = NSButton(title: "Manage Groups…", target: nil, action: nil)
    private var working = false
    private(set) var availability: ServerSettingsScope.Availability = .connecting

    /// `presets` is the Mac-side Menu presets content, shown on the Speed tab.
    /// `expansion` is the remembered open/closed state of collapsible groups.
    init(presets: NSView, expansion: [String: Bool] = [:]) {
        self.expansion = expansion
        super.init()
        for pane in ServerOption.Pane.allCases {
            paneViews[pane] = buildPane(pane, presets: pane == .speed ? presets : nil)
        }
        updateEnabledState(working: false)
    }

    // MARK: - Building

    private func buildPane(_ pane: ServerOption.Pane, presets: NSView?) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let blocker = SettingsBlockerView()
        blocker.retryButton.target = self
        blocker.retryButton.action = #selector(retry(_:))
        blocker.testButton.target = self
        blocker.testButton.action = #selector(testConnection(_:))
        blockers[pane] = blocker
        add(blocker)

        for group in ServerOption.groups(in: pane) {
            let view = SettingsGroupView(title: group.name, storage: .server, collapsible: group.isCollapsible,
                                         expanded: expansion[group.name] ?? group.isExpandedByDefault)
            view.onToggle = { [weak self] expanded in self?.setExpanded(group.name, expanded) }
            if let caption = Self.caption(for: group.name) { view.addCaption(caption) }
            for key in group.keys {
                let row = buildField(key.definition)
                fieldRows[key] = row
                view.addRow(row)
            }
            if group.name == "Incoming port" {
                portProtocol.configure(for: PeerPortProtocol.self)
                portProtocol.setAccessibilityLabel("Port test IP protocol")
                portProtocol.setAccessibilityIdentifier("server-options-port-protocol")
                configureAction(portButton, #selector(testPort(_:)), "server-options-test-port")
                portButton.toolTip = "Tests the server’s currently applied port, not an unsaved port number."
                let tests = NSStackView(views: [portProtocol, portButton])
                tests.spacing = 12
                view.addRow(tests, fullWidth: false)
            }
            groupViews[group.name] = view
            add(view)
            // The Mac-side presets sit right after the limits they feed.
            if group.name == "Turtle mode", let presets {
                let local = SettingsGroupView(title: "Menu presets", storage: .mac, collapsible: true,
                                              expanded: expansion["Menu presets"] ?? true)
                local.onToggle = { [weak self] expanded in self?.setExpanded("Menu presets", expanded) }
                local.addRow(presets, fullWidth: false)
                groupViews["Menu presets"] = local
                add(local)
            }
        }
        if pane == .speed {
            let groups = SettingsGroupView(title: "Bandwidth groups", storage: .server, collapsible: true,
                                           expanded: expansion["Bandwidth groups"] ?? false)
            groups.onToggle = { [weak self] expanded in self?.setExpanded("Bandwidth groups", expanded) }
            groups.addCaption("Groups share limits among the torrents assigned to them. Assign a torrent with Bandwidth Group… in its context menu.")
            configureAction(groupsButton, #selector(manageGroups(_:)), "server-options-groups")
            groups.addRow(groupsButton, fullWidth: false)
            groupViews["Bandwidth groups"] = groups
            add(groups)
        }
        if let note = Self.footnote(for: pane) {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            add(label)
        }
        return scroll
    }

    private static func caption(for group: String) -> String? {
        switch group {
        case "Downloads":
            "Folder paths are on the server; changing the default folder doesn’t move existing downloads. "
                + "The Start choice when adding a torrent overrides this default — see also “Show options when adding torrents” in General."
        case "Queue": "Limits how many torrents run at once."
        case "Turtle mode": "The alternative limits used while turtle mode is on, from the speed menus or the schedule below."
        case "Schedule": "Uses the server’s local time zone and can run overnight."
        case "Watch folder": "Applies to the server’s watch folder. The .torrent removal choice in General applies to files on this Mac."
        case "Authentication": "Failures from all clients count together. Exceeding the threshold locks out RPC authentication until the server restarts."
        case "Default trackers": "One tracker URL per line; blank lines separate tiers."
        case "Server scripts": "Paths to existing executable files on the server. This app neither uploads nor runs scripts."
        default: nil
        }
    }

    private static func footnote(for pane: ServerOption.Pane) -> String? {
        switch pane {
        case .speed: "1 kB/s = 1,000 bytes per second."
        case .network: "These settings control the server’s peer connections, not this app’s connection to the server."
        default: nil
        }
    }

    private func buildField(_ field: ServerOption.Definition) -> NSView {
        let key = field.key
        if case .boolean = field.kind {
            let checkbox = NSButton(checkboxWithTitle: field.title, target: self, action: #selector(valueChanged(_:)))
            identify(checkbox, key: key)
            controls[key] = [checkbox]
            return checkbox
        }
        if case .trackers = field.kind {
            let area = ServerOptionsTextArea()
            identify(area, key: key)
            area.target = self
            area.action = #selector(valueChanged(_:))
            controls[key] = [area]
            return area
        }
        let row = NSView()
        let label = NSTextField(labelWithString: field.title + ":")
        label.translatesAutoresizingMaskIntoConstraints = false
        labels[key] = label
        row.addSubview(label)
        let input: NSView
        switch field.kind {
        case .encryption, .transports:
            let popup = NSPopUpButton()
            if key == .transports { popup.configure(for: ServerTransports.self) }
            else { popup.configure(for: ServerEncryption.self) }
            popup.target = self
            popup.action = #selector(valueChanged(_:))
            identify(popup, key: key)
            controls[key] = [popup]
            input = popup
        case .days:
            let days = NSStackView()
            days.orientation = .horizontal
            days.spacing = 7
            // RPC bit 0 = Sunday. Display Monday first without changing the mask.
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            var buttons: [NSControl] = []
            for day in [1, 2, 3, 4, 5, 6, 0] {
                let button = NSButton(checkboxWithTitle: names[day], target: self, action: #selector(valueChanged(_:)))
                button.controlSize = .small
                button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                button.tag = day
                identify(button, key: key)
                button.setAccessibilityLabel(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day])
                button.setAccessibilityIdentifier("\(key.rawValue)-\(day)")
                days.addArrangedSubview(button)
                buttons.append(button)
            }
            controls[key] = buttons
            input = days
        default:
            let text = NSTextField()
            text.delegate = self
            text.target = self
            text.action = #selector(valueChanged(_:))
            identify(text, key: key)
            controls[key] = [text]
            text.placeholderString = Self.placeholder(for: key)
            input = text
        }
        input.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(input)
        let labelWidth: CGFloat = key == .scheduleDays ? 60 : 220
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            label.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            input.topAnchor.constraint(equalTo: row.topAnchor),
            input.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            input.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        switch field.kind {
        case .directory, .scriptPath, .trackers:
            input.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        case .encryption, .transports:
            input.widthAnchor.constraint(equalToConstant: 220).isActive = true
        case .days: break
        default:
            input.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        return row
    }

    private static func placeholder(for key: ServerOption) -> String? {
        switch key.definition.kind {
        case .directory, .scriptPath: "/path/on/server"
        case .time: "HH:mm"
        default: nil
        }
    }

    private func configureAction(_ button: NSButton, _ action: Selector, _ identifier: String) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    private func identify(_ control: NSControl, key: ServerOption) {
        control.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        control.setAccessibilityIdentifier(key.rawValue)
        control.setAccessibilityLabel(key.definition.title)
    }

    // MARK: - Disclosure

    private func setExpanded(_ group: String, _ expanded: Bool) {
        expansion[group] = expanded
        onExpansionChange?(expansion)
    }

    /// Open the group holding `key` (e.g. before focusing it for a validation error).
    func reveal(_ key: ServerOption) {
        guard let view = groupViews[key.definition.group], !view.isExpanded else { return }
        view.setExpanded(true)
        setExpanded(key.definition.group, true)
    }

    // MARK: - State

    /// Show the server-side groups, or the notice that replaces them.
    func setAvailability(_ availability: ServerSettingsScope.Availability, serverName: String) {
        self.availability = availability
        let ready = availability == .ready
        for (pane, blocker) in blockers {
            blocker.isHidden = ready
            blocker.show(availability, serverName: serverName)
            for group in ServerOption.groups(in: pane) { groupViews[group.name]?.isHidden = !ready }
            if pane == .speed { groupViews["Bandwidth groups"]?.isHidden = !ready }
        }
    }

    /// Called only after an explicit load / Apply / Reload (or a poll-absorbed
    /// speed change), never from the main polling loop directly.
    func render() {
        guard let editor = session?.editor else { updateEnabledState(working: working); return }
        for (key, inputs) in controls {
            for control in inputs {
                if let popup = control as? NSPopUpButton {
                    let known: Bool
                    if key == .transports {
                        popup.configure(for: ServerTransports.self)
                        if let mode = ServerTransports(rawValue: editor.text(key)), editor.supports(key) { popup.select(mode); known = true }
                        else { known = false }
                    } else {
                        popup.configure(for: ServerEncryption.self)
                        if let mode = ServerEncryption(rawValue: editor.text(key)) { popup.select(mode); known = true }
                        else { known = false }
                    }
                    if !known {
                        popup.addItem(withTitle: editor.supports(key) ? "Unknown: \(editor.text(key))" : "Unavailable")
                        popup.selectItem(at: popup.numberOfItems - 1)
                    }
                } else if let button = control as? NSButton {
                    let on = key == .scheduleDays
                        ? ((Int(editor.text(key)) ?? 0) & (1 << button.tag)) != 0 : editor.flag(key)
                    button.state = on ? .on : .off
                } else if let area = control as? ServerOptionsTextArea {
                    area.stringValue = editor.text(key)
                } else if let text = control as? NSTextField {
                    text.stringValue = editor.supports(key) ? editor.text(key) : ""
                    text.placeholderString = editor.supports(key) ? Self.placeholder(for: key) : "Unavailable"
                }
            }
        }
        fieldRows[.utp]?.isHidden = editor.supports(.transports)
        if !editor.baseline.supportsPortProtocol { portProtocol.select(PeerPortProtocol.automatic) }
        updateEnabledState(working: working)
    }

    func updateEnabledState(working: Bool) {
        self.working = working
        let editor = session?.editor
        for (key, inputs) in controls {
            let supported = editor?.supports(key) == true
            let enabled = !working && editor?.isEditable(key) == true
            for input in inputs {
                input.isEnabled = enabled
                input.toolTip = supported || editor == nil ? nil : "Not supported by this server."
            }
            labels[key]?.textColor = enabled ? .labelColor : .secondaryLabelColor
        }
        portButton.isEnabled = !working && editor?.supports(.peerPort) == true
        portProtocol.isEnabled = !working && editor?.baseline.supportsPortProtocol == true
        groupsButton.isEnabled = !working && editor?.baseline.supportsGroups == true
    }

    // MARK: - Editing

    @objc private func valueChanged(_ sender: NSControl) {
        guard let session, let id = sender.identifier, let key = ServerOption(rawValue: id.rawValue) else { return }
        if let popup = sender as? NSPopUpButton {
            if key == .transports {
                guard ServerTransports.allCases.indices.contains(popup.indexOfSelectedItem) else { return }
                session.set(key, text: popup.selectedCase(default: ServerTransports.preferUTP).rawValue)
            } else {
                guard ServerEncryption.allCases.indices.contains(popup.indexOfSelectedItem) else { return }
                session.set(key, text: popup.selectedCase(default: ServerEncryption.tolerated).rawValue)
            }
        } else if let button = sender as? NSButton {
            if key == .scheduleDays {
                let mask = (controls[key] ?? []).reduce(0) { mask, control in
                    guard let day = control as? NSButton, day.state == .on else { return mask }
                    return mask | (1 << day.tag)
                }
                session.set(key, text: String(mask))
            } else { session.set(key, text: button.state == .on ? "true" : "false") }
        } else { session.set(key, text: sender.stringValue) }
        updateEnabledState(working: working)
        onEdit?()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        valueChanged(field)
    }

    @objc private func testPort(_ sender: Any?) {
        onTestPort?(portProtocol.selectedCase(default: PeerPortProtocol.automatic))
    }

    @objc private func manageGroups(_ sender: Any?) { onManageGroups?() }
    @objc private func retry(_ sender: Any?) { onRetry?() }
    @objc private func testConnection(_ sender: Any?) { onTestConnection?() }
}

// MARK: - Building blocks

/// A heading (optionally with a disclosure triangle) plus a scope tag, over a
/// column of rows. Collapsing hides the rows rather than zeroing their height.
@MainActor
final class SettingsGroupView: NSView {
    let disclosure = NSButton()
    let titleLabel: NSTextField
    let scopeLabel: NSTextField
    private let content = NSStackView()
    private let collapsible: Bool
    var onToggle: ((Bool) -> Void)?
    private(set) var isExpanded: Bool

    init(title: String, storage: ServerSettingsScope.Storage, collapsible: Bool, expanded: Bool) {
        titleLabel = NSTextField(labelWithString: title)
        scopeLabel = NSTextField(labelWithString: storage.rawValue)
        self.collapsible = collapsible
        isExpanded = collapsible ? expanded : true
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        scopeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.toolTip = storage.help
        scopeLabel.setAccessibilityHelp(storage.help)
        titleLabel.setAccessibilityHelp(storage.help)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.state = isExpanded ? .on : .off
        disclosure.target = self
        disclosure.action = #selector(toggle(_:))
        disclosure.setAccessibilityLabel(title)
        disclosure.setAccessibilityIdentifier("settings-group-\(title)")
        disclosure.isHidden = !collapsible
        let header = NSStackView(views: [disclosure, titleLabel, scopeLabel])
        header.spacing = 6
        header.alignment = .firstBaseline
        if collapsible {
            // Clicking the title toggles too, like a System Settings disclosure row.
            let click = NSClickGestureRecognizer(target: self, action: #selector(titleClicked(_:)))
            titleLabel.addGestureRecognizer(click)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.isHidden = !isExpanded
        let column = NSStackView(views: [header, content])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: collapsible ? 20 : 0),
            content.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addRow(_ view: NSView, fullWidth: Bool = true) {
        content.addArrangedSubview(view)
        if fullWidth { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }

    func addCaption(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        addRow(label)
    }

    func setExpanded(_ expanded: Bool) {
        guard collapsible else { return }
        isExpanded = expanded
        disclosure.state = expanded ? .on : .off
        content.isHidden = !expanded
    }

    @objc private func toggle(_ sender: NSButton) {
        setExpanded(sender.state == .on)
        onToggle?(isExpanded)
    }

    @objc private func titleClicked(_ sender: Any?) {
        setExpanded(!isExpanded)
        onToggle?(isExpanded)
    }
}

/// Replaces a server tab's server-side groups while they can't be used.
@MainActor
final class SettingsBlockerView: NSView {
    let message = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let testButton = NSButton(title: "Test Connection", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("server-settings-blocked")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.textColor = .secondaryLabelColor
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityIdentifier("server-settings-retry")
        testButton.bezelStyle = .rounded
        let top = NSStackView(views: [spinner, message])
        top.spacing = 8
        top.alignment = .centerY
        let buttons = NSStackView(views: [retryButton, testButton])
        buttons.spacing = 8
        let column = NSStackView(views: [top, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ availability: ServerSettingsScope.Availability, serverName: String) {
        let offline: Bool
        switch availability {
        case .ready:
            message.stringValue = ""
            offline = false
        case .unsavedNewServer:
            message.stringValue = "Apply the connection first. Server settings appear once this server is saved and reachable."
            offline = false
        case .connecting:
            message.stringValue = "Connecting to \(serverName)…"
            offline = false
        case .offline(let detail):
            message.stringValue = "Can’t reach \(serverName). \(detail)"
            offline = true
        }
        if availability == .connecting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        retryButton.isHidden = !offline
        testButton.isHidden = !offline
    }
}

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Blank-space clicks end text editing without discarding the draft or applying it.
/// Controls, selectable text and scrollbars keep their normal mouse behavior.
@MainActor
class ServerOptionsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView,
           let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) {
            var view: NSView? = hit
            var isInteractive = false
            while let current = view {
                if let label = current as? NSTextField, !label.isEditable && !label.isSelectable {
                    // Static labels are part of the form background.
                } else if current is NSControl || current is NSTextView || current is NSTableView {
                    isInteractive = true
                    break
                }
                view = current.superview
            }
            if !isInteractive { makeFirstResponder(nil) }
        }
        super.sendEvent(event)
    }
}

/// Preserve the standard focus indicator for keyboard selection, without leaving
/// a focus halo behind after a pointer/accessibility press.
@MainActor
final class ServerOptionsSectionPicker: NSSegmentedControl {
    private(set) var isKeyboardSelection = false
    override func keyDown(with event: NSEvent) {
        isKeyboardSelection = true
        defer { isKeyboardSelection = false }
        super.keyDown(with: event)
    }
}

/// A native multiline text control with normal selection, scrolling and keyboard editing.
@MainActor
final class ServerOptionsTextArea: NSControl, NSTextViewDelegate {
    let textView = NSTextView()
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { [textView] }
    override var stringValue: String {
        get { textView.string }
        set { textView.string = newValue }
    }
    override var isEnabled: Bool {
        didSet { textView.isEditable = isEnabled; textView.textColor = isEnabled ? .textColor : .disabledControlTextColor }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 100)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Default trackers, one URL per line")
        textView.setAccessibilityIdentifier("default-trackers-text")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 110),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func textDidChange(_ notification: Notification) { if let action { sendAction(action, to: target) } }
}
