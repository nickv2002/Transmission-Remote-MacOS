import AppKit

extension ServerEncryption: DisplayNamed {}
extension ServerTransports: DisplayNamed {}
extension PeerPortProtocol: DisplayNamed {}

/// Native, server-bound preferences with an explicit Apply boundary. Opening,
/// tab switching, typing, Reload and Cancel never send session-set.
@MainActor
final class ServerOptionsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTabViewDelegate {
    let server: ServerConfig
    let session: ServerOptionsSession
    var onApplied: (() -> Void)?
    var onClose: (() -> Void)?

    let tabView = NSTabView()
    let sectionPicker = ServerOptionsSectionPicker(labels: ServerOption.Section.allCases.map(\.rawValue),
                                         trackingMode: .selectOne, target: nil, action: nil)
    private(set) var controls: [ServerOption: [NSControl]] = [:]
    private var fieldRows: [ServerOption: NSView] = [:]
    private var labels: [ServerOption: NSTextField] = [:]
    private let serverLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading server settings…")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let portButton = NSButton(title: "Test Incoming Port", target: nil, action: nil)
    private let portProtocol = NSPopUpButton()
    private let groupsButton = NSButton(title: "Manage Bandwidth Groups…", target: nil, action: nil)
    private var groupsController: BandwidthGroupsWindowController?
    private let spinner = NSProgressIndicator()
    private var working = false

    init(server: ServerConfig, service: any ServerOptionsService) {
        self.server = server
        session = ServerOptionsSession(service: service)
        let window = ServerOptionsWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Server Options — \(server.name)"
        window.contentMinSize = NSSize(width: 680, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        window.contentView = buildContent()
        window.initialFirstResponder = sectionPicker
        updateEnabledState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadOptions() {
        perform(message: "Loading server settings…") { [self] in
            try await session.load()
            renderValues()
            return availabilityMessage
        }
    }

    private var availabilityMessage: String {
        let missing = ServerOption.allCases.filter { session.editor?.supports($0) != true }.count
        return missing > 0
            ? "\(missing) settings are unavailable on this server. Changes apply only when you click Apply."
            : "Changes apply to this server only when you click Apply."
    }

    private func buildContent() -> NSView {
        let root = NSView()
        let sectionBox = NSBox()
        sectionBox.boxType = .custom
        sectionBox.borderWidth = 1
        sectionBox.borderColor = .separatorColor
        sectionBox.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
        sectionBox.cornerRadius = 5
        sectionBox.titlePosition = .noTitle
        sectionBox.contentViewMargins = .zero
        sectionBox.setAccessibilityIdentifier("server-options-box")
        // Native segments are translucent; mask the box's border behind them.
        let pickerBackdrop = NSBox()
        pickerBackdrop.boxType = .custom
        pickerBackdrop.titlePosition = .noTitle
        pickerBackdrop.borderWidth = 0
        pickerBackdrop.cornerRadius = 7
        pickerBackdrop.fillColor = .windowBackgroundColor
        serverLabel.stringValue = "\(server.name) · \(server.host):\(server.port)"
        serverLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        serverLabel.textColor = .secondaryLabelColor
        serverLabel.lineBreakMode = .byTruncatingMiddle
        serverLabel.setAccessibilityIdentifier("server-options-server")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("server-options-status")

        // Adding the first item may lay it out before Auto Layout attaches this view.
        // Start at the window's usable size so AppKit does not squeeze it to zero.
        tabView.frame = window?.contentView?.bounds ?? .zero
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        tabView.delegate = self
        sectionPicker.segmentStyle = .rounded
        sectionPicker.selectedSegment = 0
        sectionPicker.target = self
        sectionPicker.action = #selector(selectSection(_:))
        sectionPicker.setAccessibilityLabel("Server Options sections")
        sectionPicker.setAccessibilityIdentifier("server-options-sections")
        for section in ServerOption.Section.allCases {
            let tab = NSTabViewItem(identifier: section.rawValue)
            tab.label = section.rawValue
            tab.view = buildSection(section)
            tabView.addTabViewItem(tab)
        }
        for (button, action, identifier) in [
            (applyButton, #selector(applyOptions(_:)), "server-options-apply"),
            (reloadButton, #selector(reloadOptions(_:)), "server-options-reload"),
            (closeButton, #selector(closeOptions(_:)), "server-options-close"),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        applyButton.keyEquivalent = "\r"
        closeButton.keyEquivalent = "\u{1b}"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        for view in [serverLabel, sectionBox, pickerBackdrop, sectionPicker, statusLabel, applyButton, reloadButton, closeButton, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let boxContent = sectionBox.contentView!
        tabView.translatesAutoresizingMaskIntoConstraints = false
        boxContent.addSubview(tabView)
        NSLayoutConstraint.activate([
            serverLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            serverLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            serverLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            sectionPicker.topAnchor.constraint(equalTo: serverLabel.bottomAnchor, constant: 16),
            sectionPicker.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sectionPicker.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            sectionPicker.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            pickerBackdrop.leadingAnchor.constraint(equalTo: sectionPicker.leadingAnchor, constant: -2),
            pickerBackdrop.trailingAnchor.constraint(equalTo: sectionPicker.trailingAnchor, constant: 2),
            pickerBackdrop.topAnchor.constraint(equalTo: sectionPicker.topAnchor),
            pickerBackdrop.bottomAnchor.constraint(equalTo: sectionPicker.bottomAnchor),
            sectionBox.topAnchor.constraint(equalTo: sectionPicker.centerYAnchor),
            sectionBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sectionBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sectionBox.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 26),
            tabView.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 2),
            tabView.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor, constant: -2),
            tabView.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -2),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            statusLabel.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -12),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            closeButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            reloadButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        return root
    }

    @objc private func selectSection(_ sender: ServerOptionsSectionPicker) {
        guard tabView.tabViewItems.indices.contains(sender.selectedSegment) else { return }
        tabView.selectTabViewItem(at: sender.selectedSegment)
        // Pointer selection should not leave a keyboard focus halo around the segment.
        // Keyboard navigation retains the native focus indicator and Tab-key access.
        if !sender.isKeyboardSelection {
            window?.makeFirstResponder(nil)
        }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        sectionPicker.selectedSegment = tabView.indexOfTabViewItem(tabViewItem)
        // Avoid automatically editing the first text control in the selected section.
        window?.makeFirstResponder(sectionPicker)
    }

    private func buildSection(_ section: ServerOption.Section) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = ServerOptionsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
        ])

        let note: String
        switch section {
        case .download: note = "Folder paths are on the server. Changing the default folder does not move existing downloads."
        case .network: note = "These settings control the server’s peer connections. They do not change your connection to the server."
        case .bandwidth: note = "Schedules use the server’s local time zone and can run overnight. 1 kB/s = 1,000 bytes per second."
        case .queue: note = "Queue limits control how many torrents run at once. Stalled torrents can be excluded from these limits."
        case .advanced: note = "Advanced settings apply to the server. Script paths refer to existing executable files on the server; this app does not upload or run scripts."
        }
        let caption = NSTextField(wrappingLabelWithString: note)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        stack.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        func addCaption(_ text: String) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        var lastGroup = ""
        for field in ServerOption.definitions where field.section == section {
            if field.group != lastGroup {
                if !lastGroup.isEmpty {
                    let separator = NSBox()
                    separator.boxType = .separator
                    stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
                    stack.addArrangedSubview(separator)
                    separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
                let heading = NSTextField(labelWithString: field.group)
                heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
                stack.addArrangedSubview(heading)
                if field.group == "Default trackers" { addCaption("One tracker URL per line; blank lines separate tiers.") }
                if field.group == "Authentication" { addCaption("Failures from all clients count together. Exceeding the threshold locks out RPC authentication until the server restarts.") }
                lastGroup = field.group
            }
            let row = buildField(field)
            fieldRows[field.key] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if section == .download {
            addCaption("The Start choice when adding a torrent overrides the server default. Original .torrent disposal applies to the server’s watch folder, not files on this Mac.")
        }
        if section == .bandwidth {
            configureAction(groupsButton, #selector(manageGroups(_:)), "server-options-groups")
            stack.addArrangedSubview(groupsButton)
            addCaption("Groups share limits among assigned torrents. Use Bandwidth Group… in a torrent’s context menu to assign it.")
        }

        if section == .network {
            portProtocol.configure(for: PeerPortProtocol.self)
            portProtocol.setAccessibilityLabel("Port test IP protocol")
            portProtocol.setAccessibilityIdentifier("server-options-port-protocol")
            portButton.bezelStyle = .rounded
            portButton.target = self
            portButton.action = #selector(testPort(_:))
            portButton.setAccessibilityIdentifier("server-options-test-port")
            portButton.toolTip = "Tests the server’s currently applied port, not an unsaved port number."
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            let tests = NSStackView(views: [portProtocol, portButton])
            tests.spacing = 12
            stack.addArrangedSubview(tests)
        }
        return scroll
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
            switch field.kind {
            case .directory, .scriptPath: text.placeholderString = "/path/on/server"
            case .time: text.placeholderString = "HH:mm"
            default: break
            }
            input = text
        }
        input.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(input)
        let labelWidth: CGFloat = key == .scheduleDays ? 85 : 235
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
            input.widthAnchor.constraint(equalToConstant: 245).isActive = true
        case .days: break
        default:
            input.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }
        return row
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

    /// Called only after explicit Load/Apply, never by the main polling loop.
    func renderValues() {
        guard let editor = session.editor else { return }
        serverLabel.stringValue = "\(server.name) · \(server.host):\(server.port) · Transmission \(editor.baseline.version)"
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
                    if !editor.supports(key) {
                        text.placeholderString = "Unavailable"
                    } else {
                        switch key.definition.kind {
                        case .directory, .scriptPath: text.placeholderString = "/path/on/server"
                        case .time: text.placeholderString = "HH:mm"
                        default: text.placeholderString = nil
                        }
                    }
                }
            }
        }
        fieldRows[.utp]?.isHidden = editor.supports(.transports)
        if !editor.baseline.supportsPortProtocol { portProtocol.select(PeerPortProtocol.automatic) }
        updateEnabledState()
    }

    private func updateEnabledState() {
        for (key, inputs) in controls {
            let supported = session.editor?.supports(key) == true
            let enabled = !working && session.editor?.isEditable(key) == true
            for input in inputs {
                input.isEnabled = enabled
                input.toolTip = supported ? nil : "Not supported by this server."
            }
            labels[key]?.textColor = enabled ? .labelColor : .secondaryLabelColor
        }
        applyButton.isEnabled = !working && !session.needsReload && session.editor?.isDirty == true
        reloadButton.isEnabled = !working
        closeButton.isEnabled = !working
        portButton.isEnabled = !working && session.editor?.supports(.peerPort) == true
        portProtocol.isEnabled = !working && session.editor?.baseline.supportsPortProtocol == true
        groupsButton.isEnabled = !working && session.editor?.baseline.supportsGroups == true
        window?.isDocumentEdited = session.editor?.isDirty == true
    }

    @objc private func valueChanged(_ sender: NSControl) {
        guard let id = sender.identifier, let key = ServerOption(rawValue: id.rawValue) else { return }
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
        statusLabel.stringValue = session.needsReload ? "Reload the server values before applying again." : availabilityMessage
        statusLabel.textColor = .secondaryLabelColor
        updateEnabledState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        valueChanged(field)
    }

    @objc func applyOptions(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        perform(message: "Applying and verifying changes…") { [self] in
            try await session.apply()
            renderValues()
            onApplied?()
            return "Changes saved and verified on \(server.name)."
        }
    }

    @objc private func reloadOptions(_ sender: Any?) {
        guard confirmDiscard(action: "Reload") else { return }
        loadOptions()
    }

    @objc private func closeOptions(_ sender: Any?) { window?.performClose(sender) }

    @objc private func testPort(_ sender: Any?) {
        runPortTest(portProtocol.selectedCase(default: PeerPortProtocol.automatic))
    }

    private func runPortTest(_ choice: PeerPortProtocol) {
        perform(message: "Testing the server’s applied incoming port (\(choice.displayName))…") { [self] in
            let current = try await session.service.fetchServerOptions()
            let result = try await session.testPort(protocol: choice)
            let port = current.values[.peerPort]?.text(for: .peerPort) ?? "unknown"
            return "Port \(port) — " + result.description(requested: choice)
        }
    }



    @objc private func manageGroups(_ sender: Any?) {
        if let groupsController { groupsController.showWindow(nil); return }
        let controller = BandwidthGroupsWindowController(serverName: server.name, service: session.service)
        controller.onClose = { [weak self] in self?.groupsController = nil }
        groupsController = controller
        controller.showWindow(nil)
        controller.loadGroups()
    }

    private func perform(message: String, action: @escaping @MainActor () async throws -> String) {
        guard !working else { return }
        working = true
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        spinner.startAnimation(nil)
        updateEnabledState()
        Task { [self] in
            var focusKey: ServerOption?
            do { statusLabel.stringValue = try await action() }
            catch {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                focusKey = (error as? ServerOptionsError)?.fields.first
            }
            working = false
            spinner.stopAnimation(nil)
            updateEnabledState()
            if let key = focusKey {
                tabView.selectTabViewItem(withIdentifier: key.definition.section.rawValue)
                if let control = controls[key]?.first {
                    control.scrollToVisible(control.bounds)
                    window?.makeFirstResponder((control as? ServerOptionsTextArea)?.textView ?? control)
                }
            }
        }
    }

    private func confirmDiscard(action: String) -> Bool {
        guard !working else { return false }
        guard session.editor?.isDirty == true || session.needsReload else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved edits?"
        alert.informativeText = "\(action) discards the edits in this window. Any settings already accepted by the server remain in effect."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard and \(action)")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { (groupsController?.canQuit() ?? true) && confirmDiscard(action: "Close") }
    func canQuit() -> Bool { (groupsController?.canQuit() ?? true) && confirmDiscard(action: "Quit") }
    func windowWillClose(_ notification: Notification) { groupsController?.close(); onClose?() }
}

/// Blank-space clicks end text editing without discarding the draft or applying it.
/// Controls, selectable text and scrollbars keep their normal mouse behavior.
@MainActor
final class ServerOptionsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView,
           let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) {
            var view: NSView? = hit
            var isInteractive = false
            while let current = view {
                if let label = current as? NSTextField, !label.isEditable && !label.isSelectable {
                    // Static labels are part of the form background.
                } else if current is NSControl || current is NSTextView {
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

private final class ServerOptionsDocumentView: NSView {
    override var isFlipped: Bool { true }
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
