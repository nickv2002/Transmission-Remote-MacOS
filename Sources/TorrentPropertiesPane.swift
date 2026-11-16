import AppKit

/// The Properties tab of the detail pane: speed, seeding, peer and tracker settings
/// for the selected torrent(s). Follows the table selection (`retarget`). Mixed values
/// stay untouched unless edited; Apply sends only the changed keys (see
/// `TorrentPropertiesEditor`), verifies them and re-baselines from the readback.
/// Revert drops edits and refetches. Trackers are editable for one torrent only, so
/// with several selected that section is grayed out with a note.
@MainActor
final class TorrentPropertiesPane: NSObject, NSTextFieldDelegate {
    enum CloseChoice { case apply, discard, keepEditing }

    /// What the pane edits: the hashes and server captured when the selection was read.
    struct Target {
        let service: any TorrentPropertiesService
        let hashes: [String]
        let serverID: UUID?
        var key: String { hashes.sorted().joined(separator: ",") }
    }

    let view: NSView = PaneBackgroundView()
    private(set) var target: Target?
    private(set) var session: TorrentPropertiesSession?
    /// The server the hashes were captured on.
    var serverID: UUID? { target?.serverID }
    /// After a verified Apply (the caller refreshes the list).
    var onApplied: (() -> Void)?
    /// The user cancelled leaving unsaved edits: reselect these hashes in the table.
    var onKeepEditing: (([String]) -> Void)?
    /// Asked when the selection changes (or the app quits, `true`) with unsaved edits.
    /// Nil = an Apply / Discard / Cancel alert as a sheet on the window; tests replace it.
    var confirmClose: (@MainActor (_ quitting: Bool, _ done: @escaping @MainActor (CloseChoice) -> Void) -> Void)?

    let header = NSTextField(labelWithString: "No torrent selected")
    private(set) var checkboxes: [TorrentProperty: NSButton] = [:]
    private(set) var fields: [TorrentProperty: NSTextField] = [:]
    private(set) var popups: [TorrentProperty: NSPopUpButton] = [:]
    let trackers = ServerOptionsTextArea(accessibilityLabel: "Trackers, one URL per line, blank line between tiers",
                                         identifier: "torrent-properties-trackers", height: 72)
    let trackersReason = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private var rows: [TorrentProperty: NSView] = [:]
    private var scrollView: NSScrollView?
    private var footerView: NSView?
    private var separatorView: NSView?
    private var document: NSView?
    private var documentStack: NSStackView?
    /// Fetching the torrents; retargeting cancels it.
    private(set) var loading = false
    /// Writing to the server; the pane can't be retargeted until it finishes.
    private(set) var applying = false
    /// The last load failed; Revert retries it.
    private var loadFailed = false
    var working: Bool { loading || applying }
    private var loadTask: Task<Void, Never>?
    private var loaded = false
    private var wantsFocus = false
    /// A retarget that arrived mid-Apply; runs when the Apply finishes.
    private var pending: PendingTarget?
    private struct PendingTarget { let target: Target? }
    private static let unitHelp = "1 kB/s = 1,000 bytes per second."
    /// The status label currently shows a live validation message (cleared once fixed).
    private var showingValidation = false
    private static let mixedTitle = "Mixed"

    override init() {
        super.init()
        build()
        updateEnabled()
    }

    // MARK: - Building

    /// Scroll view above, separator and footer (Revert / Apply and the status) below.
    private func layoutPane() {
        guard let scrollView, let footerView, let separatorView else { return }
        let bounds = view.bounds
        let footerWidth = max(0, bounds.width - 32)
        footerView.setFrameSize(NSSize(width: footerWidth, height: footerView.frame.height))
        footerView.layoutSubtreeIfNeeded()
        let footerHeight = footerView.fittingSize.height
        footerView.frame = NSRect(x: 16, y: 8, width: footerWidth, height: footerHeight)
        let separatorY = 8 + footerHeight + 8
        separatorView.frame = NSRect(x: 0, y: separatorY, width: bounds.width, height: 1)
        let top = separatorY + 1
        scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        sizeDocument()
    }

    /// The scroll document is as tall as its content and at least as wide, so a pane
    /// narrower than the controls scrolls sideways instead of squeezing anything.
    private func sizeDocument() {
        guard let document, let stack = documentStack, let scroll = document.enclosingScrollView else { return }
        stack.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let clip = scroll.contentSize
        let size = NSSize(width: max(clip.width, fit.width + 80), height: max(clip.height, fit.height + 24))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Frame-based on purpose: a constraint-based scroll document reports its content's
        // fixed-width minimum up the chain, and the split view then squeezes the sidebar's
        // neighbour (the whole detail pane) to that width. Only the height is tracked by hand.
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        document.autoresizingMask = [.width]
        document.addSubview(stack)
        self.document = document
        self.documentStack = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
        ])
        // Follow the pane's width without ever demanding one: the rows have fixed-width
        // controls, and a required trailing pin would make the whole detail pane (and the
        // window) as wide as they are.
        let followWidth = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -80)
        followWidth.priority = .init(400)
        followWidth.isActive = true
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

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.documentView = document
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

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
        // No key equivalents: Apply writes to the server, so it is never the Return-key button.
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView()
        footer.setViews([status], in: .leading)
        footer.setViews([revertButton, applyButton], in: .trailing)
        footer.spacing = 8
        footer.alignment = .centerY
        let separator = NSBox()
        separator.boxType = .separator

        view.setAccessibilityLabel("Properties")
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.addSubview(scroll)
        view.addSubview(separator)
        view.addSubview(footer)
        // Frame-based like the scroll document: the pane's own layout must never report
        // a minimum width, or the split view squeezes the whole detail pane to it.
        scrollView = scroll
        footerView = footer
        separatorView = separator
        (view as? PaneBackgroundView)?.onLayout = { [weak self] in self?.layoutPane() }
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

    // MARK: - Targeting and loading

    /// Follows the table selection: `nil` for none. The same torrents on the same server
    /// are a no-op. Unsaved edits ask Apply / Discard / Cancel first (Cancel reselects the
    /// old rows through `onKeepEditing`); a retarget that arrives mid-Apply waits for it.
    func retarget(_ new: Target?) {
        if applying { pending = PendingTarget(target: new); return }
        guard new?.key != target?.key || new?.serverID != target?.serverID else { return }
        guard hasUnsavedEdits, let old = target else { switchTo(new); return }
        view.window?.makeFirstResponder(nil)
        ask(quitting: false) { [weak self] choice in
            switch choice {
            case .apply:
                Task {
                    guard let self else { return }
                    if await self.applyNow() { self.switchTo(new) } else { self.onKeepEditing?(old.hashes) }
                }
            case .discard: self?.switchTo(new)
            case .keepEditing: self?.onKeepEditing?(old.hashes)
            }
        }
    }

    /// Drops the target and any edits without asking (a server switch).
    func reset() {
        pending = nil
        switchTo(nil)
    }

    private func switchTo(_ new: Target?) {
        loadTask?.cancel()
        loadTask = nil
        target = new
        session = new.map { TorrentPropertiesSession(service: $0.service, hashes: $0.hashes) }
        loading = false
        loaded = false
        loadFailed = false
        showingValidation = false
        setStatus("")
        if new == nil {
            header.stringValue = "No torrent selected"
            header.toolTip = nil
            render()
        } else {
            header.stringValue = "Loading…"
            header.toolTip = nil
            render()
            load()
        }
    }

    /// Starts loading; the pane shows "Loading…" right away.
    func load() {
        guard beginLoad(), let session else { return }
        loadTask = Task { await finishLoad(session) }
    }

    func loadNow() async {
        guard beginLoad(), let session else { return }
        await finishLoad(session)
    }

    private func beginLoad() -> Bool {
        guard !working, session != nil else { return false }
        loading = true
        loadFailed = false
        setStatus("Loading properties…", announce: false)
        updateEnabled()
        return true
    }

    private func finishLoad(_ session: TorrentPropertiesSession) async {
        do {
            try await session.load()
            // Retargeted meanwhile: that load owns the state now.
            guard session === self.session, !Task.isCancelled else { return }
            loading = false
            loaded = true
            setStatus("")
            render()
            focusIfWanted()
        } catch {
            guard session === self.session, !Task.isCancelled else { return }
            loading = false
            loadFailed = true
            header.stringValue = "Couldn’t load properties"
            setStatus(error.localizedDescription, isError: true)
            updateEnabled()
        }
    }

    /// ⌘I: put the keyboard in the first editable control, now or once the load finishes.
    func requestFocus() {
        wantsFocus = true
        focusIfWanted()
    }

    private func focusIfWanted() {
        guard wantsFocus, loaded, !working, let window = view.window else { return }
        wantsFocus = false
        let order: [TorrentProperty] = [.downloadLimit, .uploadLimit, .seedRatioLimit, .seedIdleLimit, .peerLimit]
        let visible: (NSControl) -> Bool = { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
        let control: NSControl? = order.compactMap { self.fields[$0] }.first(where: visible)
            ?? [TorrentProperty.seedRatioMode, .seedIdleMode].compactMap { self.popups[$0] }.first(where: visible)
        if let control { window.makeFirstResponder(control) }
    }

    /// The status line beside the buttons; VoiceOver hears every non-empty message except loading.
    private func setStatus(_ text: String, isError: Bool = false, announce: Bool = true) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
        view.needsLayout = true
        if announce, !text.isEmpty, view.window != nil {
            NSAccessibility.post(element: view, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: - Rendering

    private var defaults: ServerSeedDefaults { session?.defaults ?? ServerSeedDefaults() }

    func render() {
        guard loaded, let editor = session?.editor else { clearControls(); updateEnabled(); return }
        let torrents = editor.torrents
        header.stringValue = torrents.count == 1 ? torrents[0].name : "\(torrents.count) torrents"
        header.toolTip = torrents.count == 1 ? torrents[0].name : nil
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
            let defaultTitle = property == .seedRatioMode ? defaults.ratioTitle : defaults.idleTitle
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
    }

    /// No data to show (no selection, or still loading): empty values, nothing offered to edit.
    private func clearControls() {
        for button in checkboxes.values { button.allowsMixedState = false; button.state = .off }
        for field in fields.values { field.stringValue = ""; field.placeholderString = nil }
        for popup in popups.values { popup.removeAllItems() }
        trackers.stringValue = ""
        trackersReason.stringValue = ""
        trackersReason.isHidden = true
    }

    /// A value field shows its value only while it applies. Behind "Server default" it
    /// shows the server's value as a placeholder; behind "Seed forever" (or an unticked
    /// limit's companion mode) it is empty, so nothing stale looks in effect.
    private func refreshField(_ property: TorrentProperty) {
        guard let editor = session?.editor, let field = fields[property] else { return }
        let mode = property.companion.flatMap { popups[$0] != nil ? $0 : nil }
        if let mode, !editor.isEditable(property) {
            field.stringValue = ""
            let isDefault = editor.text(mode) == String(SeedRatioMode.global.rawValue)
            field.placeholderString = isDefault ? (property == .seedRatioLimit ? defaults.ratioValue : defaults.idleValue) : nil
        } else {
            field.stringValue = editor.text(property)
            field.placeholderString = editor.isMixed(property) ? Self.mixedTitle : nil
        }
    }

    func updateEnabled() {
        let editor = session?.editor
        let editable = loaded && !working && session?.needsReload != true
        for (property, control) in allControls {
            control.isEnabled = editable && (editor?.isEditable(property) ?? false)
        }
        trackers.isEnabled = editable && (editor?.isEditable(.trackerList) ?? false)
        let error = editor?.isDirty == true ? editor?.validationError : nil
        applyButton.isEnabled = editable && (editor?.isDirty ?? false) && error == nil
        revertButton.isEnabled = !working && (loadFailed || session?.needsReload == true || (loaded && editor?.isDirty == true))
        guard !working, session?.needsReload != true else { return }
        if let error {
            if status.stringValue != error { setStatus(error, isError: true, announce: false) }
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
        session?.set(property, text: text)
        updateEnabled()
    }

    // MARK: - Apply / Revert

    @objc func apply(_ sender: Any?) {
        view.window?.makeFirstResponder(nil)
        Task { await applyNow() }
    }

    /// Returns whether the changes were applied and verified. The pane stays on the same
    /// torrents, re-baselined on the values read back from the server.
    @discardableResult
    func applyNow() async -> Bool {
        guard loaded, !working, let session else { return false }
        applying = true
        showingValidation = false
        setStatus("Applying and verifying…", announce: false)
        updateEnabled()
        var applied = false
        do {
            try await session.apply()
            applied = true
            if session === self.session { render() }
            setStatus("Applied and verified.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
        applying = false
        updateEnabled()
        if applied { onApplied?() }
        if let next = pending {
            pending = nil
            retarget(next.target)
        }
        return applied
    }

    /// Discard edits and refetch (also retries a failed load, and clears an unverified Apply).
    @objc func revert(_ sender: Any?) {
        view.window?.makeFirstResponder(nil)
        Task { await revertNow() }
    }

    func revertNow() async {
        guard !working else { return }
        showingValidation = false
        await loadNow()
    }

    /// Edits worth asking about: unsaved, and Apply could still send them.
    var hasUnsavedEdits: Bool { loaded && session?.editor?.isDirty == true && session?.needsReload != true }

    /// From `applicationShouldTerminate`: true lets the app quit. Replies exactly once.
    func confirmQuit(_ reply: @escaping @MainActor (Bool) -> Void) {
        if applying { reply(false); return }
        guard hasUnsavedEdits else { reply(true); return }
        // A prompt is already up: the user is answering it, so don't queue a second one.
        if view.window?.attachedSheet != nil { reply(false); return }
        // The prompt hangs off the main window; make sure it is visible before asking.
        if !TestIsolation.isActive, let window = view.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        view.window?.makeFirstResponder(nil)
        ask(quitting: true) { [weak self] choice in
            switch choice {
            case .apply: Task { reply(await self?.applyNow() ?? true) }
            case .discard: reply(true)
            case .keepEditing: reply(false)
            }
        }
    }

    private func ask(quitting: Bool, _ done: @escaping @MainActor (CloseChoice) -> Void) {
        if let confirmClose { confirmClose(quitting, done); return }
        guard let window = view.window else { done(.discard); return }
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

/// The pane's backdrop: the same content background the other detail tabs draw.
private final class PaneBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
