import AppKit

/// Torrent ▸ Properties… (⌘I): a regular (non-modal) window over one or more
/// torrents, like Finder's Get Info. Sections: Speed, Seeding, Peers, Trackers.
/// Mixed values stay untouched unless edited; Apply sends only the changed keys
/// (see `TorrentPropertiesEditor`), verifies them and re-baselines from the
/// readback, keeping the window open. Revert drops edits and refetches.
@MainActor
final class TorrentPropertiesWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    enum CloseChoice { case apply, discard, keepEditing }

    /// Off in unit tests; also skipped under `TestIsolation`. Gates the frame autosave.
    static var remembersUIState = true
    static let frameAutosaveName = "TorrentPropertiesWindow"
    private static var remembers: Bool { remembersUIState && !TestIsolation.isActive }

    let session: TorrentPropertiesSession
    /// The server the hashes were captured on (the window closes if it stops being active).
    let serverID: UUID?
    /// After a verified Apply (the caller refreshes the list).
    var onApplied: (() -> Void)?
    var onClose: (() -> Void)?
    /// Asked when closing (or quitting, `true`) with unsaved edits. Nil = an
    /// Apply / Discard / Cancel alert as a sheet on this window; tests replace it.
    var confirmClose: (@MainActor (_ quitting: Bool, _ done: @escaping @MainActor (CloseChoice) -> Void) -> Void)?

    let header = NSTextField(labelWithString: "Loading…")
    private(set) var checkboxes: [TorrentProperty: NSButton] = [:]
    private(set) var fields: [TorrentProperty: NSTextField] = [:]
    private(set) var popups: [TorrentProperty: NSPopUpButton] = [:]
    let trackers = ServerOptionsTextArea(accessibilityLabel: "Trackers, one URL per line, blank line between tiers",
                                         identifier: "torrent-properties-trackers")
    let trackersReason = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private var rows: [TorrentProperty: NSView] = [:]
    /// Fetching the torrents; closing the window cancels it.
    private(set) var loading = false
    /// Writing to the server; the window can't be closed until it finishes.
    private(set) var applying = false
    /// The last load failed; Revert retries it.
    private var loadFailed = false
    var working: Bool { loading || applying }
    private var loadTask: Task<Void, Never>?
    private var closed = false
    private var loaded = false
    private var focusedOnce = false
    private static let unitHelp = "1 kB/s = 1,000 bytes per second."
    /// The status label currently shows a live validation message (cleared once fixed).
    private var showingValidation = false
    private static let mixedTitle = "Mixed"

    init(service: any TorrentPropertiesService, hashes: [String], serverID: UUID? = nil) {
        session = TorrentPropertiesSession(service: service, hashes: hashes)
        self.serverID = serverID
        let window = ServerOptionsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Properties"
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.setAccessibilityIdentifier("torrent-properties-window")
        super.init(window: window)
        window.delegate = self
        build(in: window)
        updateEnabled()
    }

    /// The key MainWindowController uses to find the window for a set of torrents.
    static func key(for hashes: [String]) -> String { hashes.sorted().joined(separator: ",") }
    var key: String { Self.key(for: session.hashes) }

    /// Position before first showing: cascade from `previous` when given, else the
    /// remembered (autosaved) position, else centered. Only one window can own the
    /// autosave name; later ones cascade.
    func place(cascadingFrom previous: NSWindow?) {
        guard let window else { return }
        if let previous {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else if !(Self.remembers && window.setFrameUsingName(Self.frameAutosaveName)) {
            window.center()
        }
        if Self.remembers { window.setFrameAutosaveName(Self.frameAutosaveName) }
        fitToContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Building

    private func build(in window: NSWindow) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 500),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        header.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        header.lineBreakMode = .byTruncatingMiddle
        header.setAccessibilityIdentifier("torrent-properties-header")
        add(header)

        let speed = SettingsGroupView(title: "Speed", storage: nil, collapsible: false, expanded: true)
        speed.addRow(limitRow(.downloadLimited, .downloadLimit), fullWidth: false)
        speed.addRow(limitRow(.uploadLimited, .uploadLimit), fullWidth: false)
        speed.addRow(checkbox(.honorsSessionLimits), fullWidth: false)
        add(speed)

        let seeding = SettingsGroupView(title: "Seeding", storage: nil, collapsible: false, expanded: true)
        seeding.addRow(modeRow(.seedRatioMode, .seedRatioLimit, label: "Ratio:", unit: nil), fullWidth: false)
        seeding.addRow(modeRow(.seedIdleMode, .seedIdleLimit, label: "Idle:", unit: "min"), fullWidth: false)
        add(seeding)

        let peers = SettingsGroupView(title: "Peers", storage: nil, collapsible: false, expanded: true)
        let peerLabel = NSTextField(labelWithString: TorrentProperty.peerLimit.title + ":")
        let peerField = textField(.peerLimit, label: peerLabel)
        let peerRow = NSStackView(views: [peerLabel, peerField])
        peerRow.spacing = 8
        peerRow.alignment = .firstBaseline
        rows[.peerLimit] = peerRow
        peers.addRow(peerRow, fullWidth: false)
        add(peers)

        let trackerGroup = SettingsGroupView(title: TorrentProperty.trackerList.title, storage: nil, collapsible: false, expanded: true)
        trackers.target = self
        trackers.action = #selector(trackersChanged(_:))
        trackers.setAccessibilityLabel(TorrentProperty.trackerList.title)
        trackers.setAccessibilityTitleUIElement(trackerGroup.titleLabel)
        trackerGroup.addRow(trackers)
        trackerGroup.addCaption("One tracker URL per line; blank lines separate tiers.")
        trackersReason.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        trackersReason.textColor = .secondaryLabelColor
        trackersReason.setAccessibilityIdentifier("torrent-properties-trackers-reason")
        trackerGroup.addRow(trackersReason)
        add(trackerGroup)

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("torrent-properties-status")
        status.preferredMaxLayoutWidth = 290
        for (button, selector, id) in [(revertButton, #selector(revert(_:)), "torrent-properties-revert"),
                                       (applyButton, #selector(apply(_:)), "torrent-properties-apply")] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = selector
            button.setAccessibilityIdentifier(id)
        }
        // No key equivalents: Apply writes to the server, so it is never the Return-key
        // button; closing is the standard ⌘W / red button.
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView()
        footer.setViews([status], in: .leading)
        footer.setViews([revertButton, applyButton], in: .trailing)
        footer.spacing = 8
        footer.alignment = .centerY
        add(footer)

        window.contentView = root
        fitToContent()
    }

    /// The window is exactly as tall as its content, keeping its top-left corner in place.
    func fitToContent() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        if frame != old { window.setFrame(frame, display: window.isVisible) }
    }

    private func checkbox(_ property: TorrentProperty) -> NSButton {
        let button = NSButton(checkboxWithTitle: property.title, target: self, action: #selector(checkboxChanged(_:)))
        identify(button, property)
        checkboxes[property] = button
        rows[property] = button
        return button
    }

    private func textField(_ property: TorrentProperty, label: NSTextField?) -> NSTextField {
        let field = NSTextField()
        field.delegate = self
        identify(field, property)
        if let label { field.setAccessibilityTitleUIElement(label) }
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        fields[property] = field
        return field
    }

    private func unitLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// [ ] Limit download speed  [ field ] kB/s
    private func limitRow(_ flag: TorrentProperty, _ value: TorrentProperty) -> NSView {
        let box = checkbox(flag)
        let field = textField(value, label: nil)
        let unit = unitLabel("kB/s")
        unit.toolTip = Self.unitHelp
        unit.setAccessibilityHelp(Self.unitHelp)
        field.setAccessibilityHelp(Self.unitHelp)
        let row = NSStackView(views: [box, field, unit])
        row.spacing = 8
        row.alignment = .firstBaseline
        box.widthAnchor.constraint(equalToConstant: 180).isActive = true
        rows[flag] = row
        rows[value] = row
        return row
    }

    /// Ratio: [ Server default (2) ▾ ] [ field ] unit
    private func modeRow(_ mode: TorrentProperty, _ value: TorrentProperty, label text: String, unit: String?) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let popup = NSPopUpButton()
        // The transient "Mixed" item is shown but can't be picked again.
        popup.autoenablesItems = false
        popup.target = self
        popup.action = #selector(modeChanged(_:))
        identify(popup, mode)
        popup.setAccessibilityTitleUIElement(label)
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        popups[mode] = popup
        let field = textField(value, label: nil)
        var views: [NSView] = [label, popup, field]
        if let unit { views.append(unitLabel(unit)) }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.alignment = .firstBaseline
        rows[mode] = row
        rows[value] = row
        return row
    }

    private func identify(_ control: NSControl, _ property: TorrentProperty) {
        control.identifier = NSUserInterfaceItemIdentifier(property.rawValue)
        control.setAccessibilityIdentifier("torrent-properties-\(property.rawValue)")
        control.setAccessibilityLabel(property.title)
    }

    private func property(of control: NSControl) -> TorrentProperty? {
        control.identifier.flatMap { TorrentProperty(rawValue: $0.rawValue) }
    }

    // MARK: - Loading and rendering

    /// Starts loading; the window shows "Loading…" (and can be closed) right away.
    func load() {
        guard beginLoad() else { return }
        loadTask = Task { await finishLoad() }
    }

    func loadNow() async {
        guard beginLoad() else { return }
        await finishLoad()
    }

    private func beginLoad() -> Bool {
        guard !working, !closed else { return false }
        loading = true
        loadFailed = false
        setStatus("Loading properties…")
        updateEnabled()
        return true
    }

    private func finishLoad() async {
        do {
            try await session.load()
            loading = false
            guard !closed, !Task.isCancelled else { return }
            loaded = true
            setStatus("")
            render()
            focusFirstControl()
        } catch {
            loading = false
            guard !closed, !Task.isCancelled else { return }
            loadFailed = true
            header.stringValue = "Couldn’t load properties"
            setStatus(error.localizedDescription, isError: true)
            updateEnabled()
        }
    }

    /// The first enabled text field (else the first popup) gets focus once, after the first render.
    private func focusFirstControl() {
        guard !focusedOnce, let window else { return }
        focusedOnce = true
        let order: [TorrentProperty] = [.downloadLimit, .uploadLimit, .seedRatioLimit, .seedIdleLimit, .peerLimit]
        let visible: (NSControl) -> Bool = { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
        let target: NSControl? = order.compactMap { self.fields[$0] }.first(where: visible)
            ?? [TorrentProperty.seedRatioMode, .seedIdleMode].compactMap { self.popups[$0] }.first(where: visible)
        guard let target else { return }
        window.initialFirstResponder = target
        window.makeFirstResponder(target)
    }

    /// The status line beside the buttons; VoiceOver hears every non-empty message.
    private func setStatus(_ text: String, isError: Bool = false) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
        if !text.isEmpty, let window {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        fitToContent()
    }

    func render() {
        guard let editor = session.editor else { updateEnabled(); return }
        let torrents = editor.torrents
        header.stringValue = torrents.count == 1 ? torrents[0].name : "\(torrents.count) torrents"
        header.toolTip = torrents.count == 1 ? torrents[0].name : nil
        window?.title = torrents.count == 1 ? "\(torrents[0].name) Properties" : "\(torrents.count) Torrents Properties"
        for (property, button) in checkboxes {
            if editor.isMixed(property) {
                button.allowsMixedState = true
                button.state = .mixed
            } else {
                button.allowsMixedState = false
                button.state = editor.text(property) == "true" ? .on : .off
            }
        }
        for property in fields.keys { refreshField(property) }
        for (property, popup) in popups {
            popup.removeAllItems()
            let defaultTitle = property == .seedRatioMode ? session.defaults.ratioTitle : session.defaults.idleTitle
            let ownTitle = property == .seedRatioMode ? "Stop at ratio" : "Stop when idle for"
            popup.addItems(withTitles: [defaultTitle, ownTitle, "Seed forever"])
            if editor.isMixed(property) {
                popup.addItem(withTitle: Self.mixedTitle)
                popup.lastItem?.isEnabled = false
                popup.selectItem(at: popup.numberOfItems - 1)
            } else if let raw = Int(editor.text(property)), let mode = SeedRatioMode(rawValue: raw) {
                popup.selectItem(at: SeedRatioMode.allCases.firstIndex(of: mode) ?? 0)
            }
        }
        trackers.stringValue = editor.supports(.trackerList) ? editor.text(.trackerList) : ""
        trackersReason.stringValue = editor.trackersUnavailableReason ?? ""
        trackersReason.isHidden = editor.trackersUnavailableReason == nil
        for (property, row) in rows where property.companion == nil {
            row.isHidden = !editor.supports(property)
        }
        updateEnabled()
        fitToContent()
    }

    /// A value field shows its value only while it applies. Behind "Server default" it
    /// shows the server's value as a placeholder; behind "Seed forever" (or an unticked
    /// limit's companion mode) it is empty, so nothing stale looks in effect.
    private func refreshField(_ property: TorrentProperty) {
        guard let editor = session.editor, let field = fields[property] else { return }
        let mode = property.companion.flatMap { popups[$0] != nil ? $0 : nil }
        if let mode, !editor.isEditable(property) {
            field.stringValue = ""
            let isDefault = editor.text(mode) == String(SeedRatioMode.global.rawValue)
            field.placeholderString = isDefault ? (property == .seedRatioLimit ? session.defaults.ratioValue : session.defaults.idleValue) : nil
        } else {
            field.stringValue = editor.text(property)
            field.placeholderString = editor.isMixed(property) ? Self.mixedTitle : nil
        }
    }

    func updateEnabled() {
        let editor = session.editor
        let editable = loaded && !working && !session.needsReload
        for (property, control) in allControls {
            control.isEnabled = editable && (editor?.isEditable(property) ?? false)
        }
        trackers.isEnabled = editable && (editor?.isEditable(.trackerList) ?? false)
        let error = editor?.isDirty == true ? editor?.validationError : nil
        applyButton.isEnabled = editable && (editor?.isDirty ?? false) && error == nil
        revertButton.isEnabled = !working && (loadFailed || session.needsReload || (loaded && editor?.isDirty == true))
        window?.isDocumentEdited = hasUnsavedEdits
        guard !working, !session.needsReload else { return }
        if let error {
            if status.stringValue != error { setStatus(error, isError: true) }
            showingValidation = true
        } else if showingValidation {
            setStatus("")
            showingValidation = false
        }
    }

    private var allControls: [(TorrentProperty, NSControl)] {
        checkboxes.map { ($0.key, $0.value as NSControl) } + fields.map { ($0.key, $0.value as NSControl) }
            + popups.map { ($0.key, $0.value as NSControl) }
    }

    // MARK: - Editing

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let property = property(of: sender) else { return }
        // Mixed only until the first click; from then on it is a plain on/off box.
        if sender.allowsMixedState {
            sender.allowsMixedState = false
            sender.state = .on
        }
        edit(property, sender.state == .on ? "true" : "false")
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard let property = property(of: sender) else { return }
        let index = sender.indexOfSelectedItem
        guard SeedRatioMode.allCases.indices.contains(index) else { return }
        if let mixed = sender.item(withTitle: Self.mixedTitle) { sender.removeItem(at: sender.index(of: mixed)) }
        edit(property, String(SeedRatioMode.allCases[index].rawValue))
        if let value = TorrentProperty.allCases.first(where: { $0.companion == property }) { refreshField(value) }
    }

    @objc private func trackersChanged(_ sender: Any?) { edit(.trackerList, trackers.stringValue) }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let property = property(of: field) else { return }
        edit(property, field.stringValue)
    }

    private func edit(_ property: TorrentProperty, _ text: String) {
        guard loaded, !working else { return }
        session.set(property, text: text)
        updateEnabled()
    }

    // MARK: - Apply / Revert / close

    @objc func apply(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        Task { await applyNow() }
    }

    /// Returns whether the changes were applied and verified. The window stays open,
    /// re-baselined on the values read back from the server.
    @discardableResult
    func applyNow() async -> Bool {
        guard loaded, !working, !closed else { return false }
        applying = true
        showingValidation = false
        setStatus("Applying and verifying…")
        updateEnabled()
        var applied = false
        do {
            try await session.apply()
            applied = true
            render()
            setStatus("Applied and verified.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
        applying = false
        updateEnabled()
        if applied { onApplied?() }
        return applied
    }

    /// Discard edits and refetch (also retries a failed load, and clears an unverified Apply).
    @objc func revert(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        Task { await revertNow() }
    }

    func revertNow() async {
        guard !working, !closed else { return }
        showingValidation = false
        await loadNow()
    }

    /// Edits worth asking about: unsaved, and Apply could still send them.
    var hasUnsavedEdits: Bool { loaded && session.editor?.isDirty == true && !session.needsReload }

    /// Red button / ⌘W. A load in progress is cancelled; unsaved edits ask Apply / Discard / Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if applying { return false }
        if loading { loadTask?.cancel(); return true }
        // Nothing to lose, or a failed/unverified Apply that only a refetch can resolve.
        guard hasUnsavedEdits else { return true }
        guard sender.attachedSheet == nil else { return false }
        sender.makeFirstResponder(nil)
        ask(quitting: false) { [weak self] choice in
            switch choice {
            case .apply:
                Task { if await self?.applyNow() == true { self?.close() } }
            case .discard: self?.close()
            case .keepEditing: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        loadTask?.cancel()
        onClose?()
    }

    /// From `applicationShouldTerminate`: true lets the app quit. Replies exactly once.
    func confirmQuit(_ reply: @escaping @MainActor (Bool) -> Void) {
        if closed { reply(true); return }
        if applying { reply(false); return }
        if loading { loadTask?.cancel(); close(); reply(true); return }
        guard hasUnsavedEdits else { reply(true); return }
        // A close prompt is already up: the user is answering it, so don't queue a second one.
        if window?.attachedSheet != nil { reply(false); return }
        // The prompt hangs off this window; make sure it's visible before asking.
        if !TestIsolation.isActive, let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeFirstResponder(nil)
        ask(quitting: true) { [weak self] choice in
            switch choice {
            case .apply: Task { reply(await self?.applyNow() ?? true) }
            case .discard: self?.close(); reply(true)
            case .keepEditing: reply(false)
            }
        }
    }

    /// Asks each window in turn (quit); stops at the first that refuses. `done` runs exactly once.
    static func confirmQuit(_ windows: [TorrentPropertiesWindowController], done: @escaping @MainActor (Bool) -> Void) {
        guard let first = windows.first else { done(true); return }
        first.confirmQuit { ok in
            guard ok else { done(false); return }
            confirmQuit(Array(windows.dropFirst()), done: done)
        }
    }

    override func close() {
        super.close()
        // `windowWillClose` normally ran already; this covers a window that never showed.
        windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    private func ask(quitting: Bool, _ done: @escaping @MainActor (CloseChoice) -> Void) {
        if let confirmClose { confirmClose(quitting, done); return }
        guard let window else { done(.keepEditing); return }
        let alert = NSAlert()
        alert.messageText = quitting ? "Apply your torrent property changes before quitting?"
                                     : "Apply your changes to these torrents?"
        alert.informativeText = "If you don’t apply them, your changes are discarded."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: done(.apply)
            case .alertSecondButtonReturn: done(.discard)
            default: done(.keepEditing)
            }
        }
    }
}
