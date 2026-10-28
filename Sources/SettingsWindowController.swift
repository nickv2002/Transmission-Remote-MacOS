import AppKit

/// The one Settings window (⌘,): a System Settings–style sidebar with
/// **App ▸ General** and one row per **server**. Selecting a server shows a
/// header and five tabs — **Connection** (stored on this Mac) and **Transfers /
/// Speed / Network / Advanced** (the daemon's session settings, stored on the
/// server).
///
/// - General applies immediately and never touches any server's dirty state.
/// - Each server has one **Apply** and one **Revert**. Apply writes the server
///   side first (conflict check + verified readback); only when that succeeds
///   are the Mac-side fields (connection, presets) saved through `onChange`.
/// - Return commits the focused field and never applies; Esc does nothing
///   special. Changing rows, closing (⌘W) or quitting with unsaved edits asks
///   Apply / Discard / Cancel. Switching tabs keeps edits.
/// - Reorder, remove (undoable) and Make Default apply immediately.
/// - Server tabs are blocked until the server is reachable: an unsaved new
///   server, connecting, or offline (Retry / Test Connection). The Mac-side
///   speed presets stay editable throughout.
@MainActor
final class SettingsWindowController: NSWindowController {
    typealias Tab = ServerSettingsScope.Tab

    enum Selection: Equatable {
        case general
        case server(UUID)
    }

    /// A service bound to one server, plus the endpoint it reached.
    struct ResolvedService: Sendable {
        let service: any ServerOptionsService
        let endpoint: String
    }

    /// Persist + apply a saved config (General change, applied server, list edit).
    var onChange: ((AppConfig) -> Void)?
    /// After an Apply: refresh the live session and the speed menus.
    var onApplied: ((UUID) -> Void)?
    /// The main window's active server, for the header and routing.
    var activeServerID: () -> UUID? = { nil }
    /// Builds a session-settings service for a server. Defaults to resolving its
    /// host candidates with a fresh client; the app reuses the live client for
    /// the active server. Injected by tests.
    var serviceProvider: (@MainActor (ServerConfig) async throws -> ResolvedService)?

    /// The editing model: working copy + saved baseline.
    var editor: SettingsEditor
    private(set) var selection: Selection = .general

    /// Remote (session-settings) state per server, bound by id.
    final class RemoteState {
        var session: ServerOptionsSession?
        var load: ServerSettingsScope.Load = .notLoaded
        var endpoint: String?
        var generation = 0
        /// A poll saw speed limits change while the Speed tab had edits.
        var changedOnServer = false
    }
    private(set) var remote: [UUID: RemoteState] = [:]

    // Sidebar.
    private static let serverRowType = NSPasteboard.PasteboardType("com.nickvance.transmission-remote-mac.server-row")
    let sidebar = NSTableView()
    private let addButton = NSButton()
    var addButtonForTesting: NSButton { addButton }
    let removeButton = NSButton()
    let defaultButton = NSButton()
    private enum Row: Equatable { case header(String), general, server(UUID) }
    private var rows: [Row] {
        [.header("App"), .general, .header("Servers")] + editor.servers.map { .server($0.id) }
    }
    private static let firstServerRow = 3
    static let footerButtonHeight: CGFloat = 24

    // Panes.
    private(set) var generalPane: SettingsGeneralPane!
    let connectionPane = SettingsConnectionPane()
    private(set) var form: ServerSettingsFormController!
    let serverView = NSView()
    let nameLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let notActiveLabel = NSTextField(labelWithString: "Not the active server")
    let tabPicker = ServerOptionsSectionPicker(labels: Tab.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    let tabView = NSTabView()

    // Bottom bar.
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private(set) var working = false
    private var groupsController: BandwidthGroupsWindowController?
    private var isSelectingProgrammatically = false

    // Remembered UI state (UserDefaults; skipped under TestIsolation).
    private var tabByServer: [UUID: Tab] = [:]
    private static let selectionKey = "SettingsSelection"
    private static let tabsKey = "SettingsServerTabs"
    private static let expansionKey = "SettingsExpandedGroups"
    static let frameName = "SettingsWindow2"
    /// Off under TestIsolation; unit tests turn it off too, so a run never reads
    /// or leaves remembered selection/tab/expansion state.
    static var remembersUIState = true
    private static var remembers: Bool { remembersUIState && !TestIsolation.isActive }

    init(config: AppConfig) {
        editor = SettingsEditor(config)
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onControlTab = { [weak self] backwards in self?.cycleTab(backwards: backwards) }
        // Restore the saved frame explicitly (this app's manual run loop doesn't
        // reliably flush AppKit's autosave); center when there's nothing saved.
        window.setFrameAutosaveName(Self.frameName)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        loadRememberedState()
        generalPane = SettingsGeneralPane(read: { [unowned self] in editor },
                                          apply: { [unowned self] change in onChange?(change(&editor)) })
        generalPane.window = window
        form = ServerSettingsFormController(presets: connectionPane.presetsView, expansion: Self.storedExpansion())
        window.contentView = buildContent()
        window.initialFirstResponder = sidebar   // ↑/↓ move through the sidebar
        wireForm()
        connectionPane.onEdit = { [weak self] server, normalize in self?.connectionEdited(server, normalize: normalize) }
        connectionPane.onTestConnection = { [weak self] in
            guard let self else { return }
            runTestConnection(connectionPane.currentServer())
        }
        generalPane.reload()
        sidebar.reloadData()
        select(rememberedSelection(), tab: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("row"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowSizeStyle = .default
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.allowsEmptySelection = false
        sidebar.registerForDraggedTypes([Self.serverRowType])
        sidebar.setAccessibilityLabel("Settings sections and servers")
        sidebar.setAccessibilityIdentifier("settings-sidebar")
        let menu = NSMenu()
        menu.delegate = self
        sidebar.menu = menu

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebar.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        addButton.bezelStyle = .smallSquare
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add server")
        addButton.target = self
        addButton.action = #selector(addServer)
        addButton.setAccessibilityIdentifier("settings-add-server")
        removeButton.bezelStyle = .smallSquare
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove server")
        removeButton.target = self
        removeButton.action = #selector(removeServer)
        removeButton.setAccessibilityIdentifier("settings-remove-server")
        defaultButton.bezelStyle = .smallSquare
        defaultButton.title = "Default"
        defaultButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        defaultButton.target = self
        defaultButton.action = #selector(makeSelectedDefault(_:))
        defaultButton.toolTip = "Make this the default server"
        defaultButton.setAccessibilityLabel("Make this the default server")
        defaultButton.setAccessibilityIdentifier("settings-make-default")
        let divider = NSBox()
        divider.boxType = .separator

        let detail = NSView()
        buildServerView()
        for view in [generalPane.view, serverView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: detail.topAnchor),
                view.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            ])
        }

        for view in [sidebarScroll, addButton, removeButton, defaultButton, divider, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // Explicit constraints (not a stack view): see CLAUDE.md gotcha #3.
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sidebarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 200),
            sidebarScroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),
            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            // Default sits at the footer's trailing edge; one shared height keeps
            // all three footer buttons identical.
            defaultButton.trailingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: -10),
            defaultButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            defaultButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            addButton.heightAnchor.constraint(equalToConstant: Self.footerButtonHeight),
            removeButton.heightAnchor.constraint(equalTo: addButton.heightAnchor),
            defaultButton.heightAnchor.constraint(equalTo: addButton.heightAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detail.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        return root
    }

    private func buildServerView() {
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityIdentifier("server-options-server")
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        stateLabel.setAccessibilityIdentifier("server-settings-state")
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        notActiveLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notActiveLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [nameLabel, stateLabel, detailLabel, notActiveLabel])
        header.spacing = 10
        header.alignment = .firstBaseline
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tabPicker.segmentStyle = .rounded
        tabPicker.selectedSegment = 0
        tabPicker.target = self
        tabPicker.action = #selector(tabPicked(_:))
        tabPicker.setAccessibilityLabel("Server Settings tabs")
        tabPicker.setAccessibilityIdentifier("server-options-sections")

        // Start at a usable size so adding items before Auto Layout doesn't squeeze them.
        tabView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        tabView.delegate = self
        for tab in Tab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.rawValue
            item.view = tab.pane.flatMap { form.paneViews[$0] } ?? connectionPane.view
            tabView.addTabViewItem(item)
        }

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("server-options-status")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for (button, action, identifier) in [
            (revertButton, #selector(revertSettings(_:)), "server-options-revert"),
            (applyButton, #selector(applySettings(_:)), "server-options-apply"),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        // Deliberately no key equivalents: Return commits the focused field and
        // Esc never discards; Apply and Revert are explicit clicks only.
        revertButton.keyEquivalent = ""
        applyButton.keyEquivalent = ""
        revertButton.toolTip = "Discard unsaved changes to this server and load its current values from the server."

        let separator = NSBox()
        separator.boxType = .separator
        for view in [header, tabPicker, tabView, separator, statusLabel, spinner, revertButton, applyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            serverView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: serverView.topAnchor),
            header.leadingAnchor.constraint(equalTo: serverView.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: serverView.trailingAnchor),
            tabPicker.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tabPicker.leadingAnchor.constraint(equalTo: serverView.leadingAnchor),
            tabPicker.trailingAnchor.constraint(lessThanOrEqualTo: serverView.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: tabPicker.bottomAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: serverView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: serverView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: serverView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: serverView.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: serverView.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: serverView.trailingAnchor),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            applyButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            applyButton.trailingAnchor.constraint(equalTo: serverView.trailingAnchor),
            applyButton.bottomAnchor.constraint(equalTo: serverView.bottomAnchor),
            applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            revertButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            revertButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: serverView.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func wireForm() {
        form.onEdit = { [weak self] in self?.updateDirtyState() }
        form.onTestPort = { [weak self] choice in self?.runPortTest(choice) }
        form.onManageGroups = { [weak self] in self?.manageGroups() }
        form.onRetry = { [weak self] in
            guard let self, case .server(let id) = selection else { return }
            ensureLoaded(id, force: true)
        }
        form.onTestConnection = { [weak self] in
            guard let self, selectedServerID != nil else { return }
            runTestConnection(connectionPane.currentServer())
        }
        form.onExpansionChange = { expansion in
            guard Self.remembers else { return }
            UserDefaults.standard.set(expansion, forKey: Self.expansionKey)
        }
    }

    // MARK: - Remembered state

    private static func storedExpansion() -> [String: Bool] {
        guard remembers else { return [:] }
        return UserDefaults.standard.dictionary(forKey: expansionKey) as? [String: Bool] ?? [:]
    }

    private func loadRememberedState() {
        guard Self.remembers,
              let stored = UserDefaults.standard.dictionary(forKey: Self.tabsKey) as? [String: String] else { return }
        for (id, tab) in stored {
            if let uuid = UUID(uuidString: id), let tab = Tab(rawValue: tab) { tabByServer[uuid] = tab }
        }
    }

    private func rememberedSelection() -> Selection {
        guard Self.remembers, let raw = UserDefaults.standard.string(forKey: Self.selectionKey),
              let id = UUID(uuidString: raw), editor.index(of: id) != nil else { return .general }
        return .server(id)
    }

    private func rememberSelection() {
        guard Self.remembers else { return }
        switch selection {
        case .general: UserDefaults.standard.set("general", forKey: Self.selectionKey)
        case .server(let id): UserDefaults.standard.set(id.uuidString, forKey: Self.selectionKey)
        }
        let tabs = Dictionary(uniqueKeysWithValues: tabByServer.map { ($0.key.uuidString, $0.value.rawValue) })
        UserDefaults.standard.set(tabs, forKey: Self.tabsKey)
    }

    // MARK: - Routing

    /// The tab a server opens on: its last-used tab, else Transfers (Connection
    /// for a server that isn't saved yet).
    func lastTab(for id: UUID) -> Tab {
        tabByServer[id] ?? (editor.isSaved(id) ? .transfers : .connection)
    }

    /// Re-seed from the saved config. Only for a window that isn't open: an
    /// open window keeps its unsaved edits, and routing just changes selection.
    func reset(to config: AppConfig) {
        let target = selection
        editor.reset(to: config)
        remote = [:]
        generalPane.reload()
        sidebar.reloadData()
        select(target, tab: nil)   // falls back to General if that server is gone
    }

    /// Called whenever Settings is opened from a menu or button. Re-seeds from the
    /// saved config only when nothing would be lost: never with pending edits
    /// (a minimized or hidden window reports `isVisible == false` too), and never
    /// while the window is on screen.
    func reopen(with config: AppConfig) {
        guard !hasPendingEdits, window?.isVisible != true, !working else { return }
        reset(to: config)
    }

    /// Keep the editor in step with a toolbar layout changed in the View menu,
    /// without touching pending server edits.
    func showToolbarLayout(_ layout: ToolbarLayout) {
        editor.setToolbarLayout(layout)
    }

    /// ⌘, (last selection), Server Settings… (active server's last tab), Manage
    /// Servers… (Connection), Edit Presets… (Speed, presets focused). If another
    /// server has unsaved edits, asks first.
    func route(to target: Selection?, tab: Tab? = nil, focusPresets: Bool = false) {
        let destination = target ?? selection
        let go = { [weak self] in
            guard let self else { return }
            select(destination, tab: tab)
            if focusPresets { focusPresetsField() }
        }
        if destination != selection, case .server(let current) = selection, isDirty(current) {
            resolvePendingEdits(for: current, action: "Switching servers", then: go)
        } else {
            go()
        }
    }

    var selectedServerID: UUID? {
        if case .server(let id) = selection { return id }
        return nil
    }

    private func select(_ target: Selection, tab: Tab?) {
        var target = target
        if case .server(let id) = target, editor.index(of: id) == nil { target = .general }
        selection = target
        let row: Int
        switch target {
        case .general: row = 1
        case .server(let id): row = Self.firstServerRow + (editor.index(of: id) ?? 0)
        }
        isSelectingProgrammatically = true
        sidebar.selectRowIndexes([row], byExtendingSelection: false)
        sidebar.scrollRowToVisible(row)
        isSelectingProgrammatically = false
        showSelection(tab: tab)
    }

    private func showSelection(tab: Tab?) {
        switch selection {
        case .general:
            generalPane.view.isHidden = false
            serverView.isHidden = true
            window?.title = "Settings"
            generalPane.reload()
        case .server(let id):
            generalPane.view.isHidden = true
            serverView.isHidden = false
            let target = tab ?? lastTab(for: id)
            tabByServer[id] = target
            showTab(target)
            connectionPane.load(editor.servers.first { $0.id == id })
            ensureLoaded(id)
            refreshServerUI()
        }
        updateFooter()
        rememberSelection()
    }

    private func showTab(_ tab: Tab) {
        tabView.selectTabViewItem(withIdentifier: tab.rawValue)
        tabPicker.selectedSegment = Tab.allCases.firstIndex(of: tab) ?? 0
    }

    var selectedTab: Tab {
        Tab(rawValue: tabView.selectedTabViewItem?.identifier as? String ?? "") ?? .connection
    }

    @objc private func tabPicked(_ sender: ServerOptionsSectionPicker) {
        guard Tab.allCases.indices.contains(sender.selectedSegment) else { return }
        selectTab(Tab.allCases[sender.selectedSegment])
        // Pointer selection should not leave a focus halo around the segment.
        if !sender.isKeyboardSelection { window?.makeFirstResponder(nil) }
    }

    func selectTab(_ tab: Tab) {
        showTab(tab)
        if let id = selectedServerID { tabByServer[id] = tab; rememberSelection() }
        refreshServerUI()
    }

    /// Ctrl-Tab / Ctrl-Shift-Tab cycle the server tabs (⌘1–9 switch servers).
    private func cycleTab(backwards: Bool) {
        guard selectedServerID != nil, let index = Tab.allCases.firstIndex(of: selectedTab) else { return }
        let count = Tab.allCases.count
        selectTab(Tab.allCases[(index + (backwards ? count - 1 : 1)) % count])
    }

    private func focusPresetsField() {
        if let presets = form.groupViews["Menu presets"], !presets.isExpanded { presets.setExpanded(true) }
        window?.makeFirstResponder(connectionPane.downPresetsField)
    }

    // MARK: - Remote state

    private func state(_ id: UUID) -> RemoteState {
        if let state = remote[id] { return state }
        let state = RemoteState()
        remote[id] = state
        return state
    }

    /// Load the server's session settings once (or again, with `force`).
    func ensureLoaded(_ id: UUID, force: Bool = false) {
        guard editor.isSaved(id), let server = editor.savedServer(id) else { refreshServerUI(); return }
        let state = state(id)
        if !force {
            switch state.load {
            case .loading, .loaded, .failed: refreshServerUI(); return
            case .notLoaded: break
            }
        }
        state.generation += 1
        let generation = state.generation
        state.load = .loading
        refreshServerUI()
        let provider = serviceProvider ?? Self.resolveService
        Task { [weak self] in
            var load = ServerSettingsScope.Load.loaded
            var session: ServerOptionsSession?
            var endpoint: String?
            do {
                let resolved = try await provider(server)
                let fresh = ServerOptionsSession(service: resolved.service)
                try await fresh.load()
                session = fresh
                endpoint = resolved.endpoint
            } catch {
                load = .failed(Self.shortMessage(error))
            }
            guard let self, state.generation == generation, remote[id] === state else { return }
            state.load = load
            if let session { state.session = session; state.endpoint = endpoint; state.changedOnServer = false }
            if selectedServerID == id {
                form.session = state.session
                refreshServerUI()
            }
            updateRow(id)
        }
    }

    /// The default provider: race the server's host candidates with a fresh client.
    static func resolveService(_ server: ServerConfig) async throws -> ResolvedService {
        let winner = await ConnectionResolver.firstToRespond(server.connectionCandidates) { candidate -> ServerConfig? in
            guard let client = try? TransmissionClient(server: candidate, timeout: 5),
                  (try? await client.fetchSession()) != nil else { return nil }
            return candidate
        }
        guard let winner else {
            throw ServerOptionsError(message: server.hasMultipleHostCandidates
                ? "None of its \(server.connectionCandidates.count) hosts responded." : "The server didn’t respond.")
        }
        return ResolvedService(service: try TransmissionClient(server: winner, timeout: 30),
                               endpoint: SettingsConnectionPane.endpointLabel(winner))
    }

    private static func shortMessage(_ error: Error) -> String {
        guard error is TransmissionError else { return error.localizedDescription }
        let reason = SettingsConnectionPane.shortError(error)
        return reason.prefix(1).uppercased() + reason.dropFirst() + "."
    }

    /// The live poll saw a new `session-get` for `id`: follow speed limits
    /// changed from the menus, unless the Speed tab has edits (then ask for a Revert).
    func sessionObserved(_ info: SessionInfo?, serverID id: UUID?) {
        guard let info, let id, let state = remote[id], let session = state.session, !working else { return }
        switch session.absorb(info.speedOptionValues) {
        case .unchanged: return
        case .updated:
            if selectedServerID == id { form.render() }
        case .conflict:
            state.changedOnServer = true
        }
        if selectedServerID == id { refreshServerUI() }
    }

    // MARK: - Dirty state and the header

    /// Unsaved edits for one server: connection/presets or server-side drafts.
    func isDirty(_ id: UUID) -> Bool {
        ServerSettingsScope.isDirty(localDirty: editor.isServerDirty(id),
                                    remoteDirty: remote[id]?.session?.editor?.isDirty == true)
    }

    var hasPendingEdits: Bool { editor.servers.contains { isDirty($0.id) } || groupsController?.session.editor.isDirty == true }

    private func availability(_ id: UUID) -> ServerSettingsScope.Availability {
        ServerSettingsScope.availability(isSaved: editor.isSaved(id), load: remote[id]?.load ?? .notLoaded)
    }

    private func updateDirtyState() {
        guard let id = selectedServerID else { window?.isDocumentEdited = hasPendingEdits; return }
        let dirty = isDirty(id)
        let plan = applyPlan(id)
        applyButton.isEnabled = !working && dirty && connectionPane.portValidationError == nil
            && { if case .blocked = plan { false } else { true } }()
        // Revert also clears a pending "load the server's values" state (failed
        // write, or speed limits changed elsewhere while edited).
        let stale = remote[id]?.session?.needsReload == true || remote[id]?.changedOnServer == true
        revertButton.isEnabled = !working && (dirty || stale)
        window?.isDocumentEdited = hasPendingEdits
        updateRow(id)
        updateFooter()
    }

    private func applyPlan(_ id: UUID) -> ServerSettingsScope.ApplyPlan {
        let session = remote[id]?.session
        return ServerSettingsScope.plan(localDirty: editor.isServerDirty(id),
                                        remoteDirty: session?.editor?.isDirty == true,
                                        remoteNeedsReload: session?.needsReload == true)
    }

    private func refreshServerUI() {
        guard let id = selectedServerID, let server = editor.servers.first(where: { $0.id == id }) else { return }
        let availability = availability(id)
        let state = remote[id]
        nameLabel.stringValue = server.name
        window?.title = "Settings — \(server.name)"
        switch availability {
        case .unsavedNewServer:
            stateLabel.stringValue = "Not saved"
            stateLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = ""
        case .connecting:
            stateLabel.stringValue = "Connecting…"
            stateLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = ""
        case .offline:
            stateLabel.stringValue = "● Offline"
            stateLabel.textColor = .systemOrange
            detailLabel.stringValue = ""
        case .ready:
            stateLabel.stringValue = "● Connected"
            stateLabel.textColor = .systemGreen
            let version = state?.session?.editor?.baseline.version
            detailLabel.stringValue = [state?.endpoint.map { "via \($0)" }, version.map { "Transmission \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
        notActiveLabel.isHidden = activeServerID() == id || !editor.isSaved(id)
        if form.session !== state?.session { form.session = state?.session }
        form.setAvailability(availability, serverName: server.name)
        form.updateEnabledState(working: working)
        if !working { statusLabel.stringValue = statusMessage(id, availability: availability); statusLabel.textColor = .secondaryLabelColor }
        updateDirtyState()
    }

    private func statusMessage(_ id: UUID, availability: ServerSettingsScope.Availability) -> String {
        if selectedServerID == id, let problem = connectionPane.portValidationError { return problem }
        if remote[id]?.changedOnServer == true { return "Speed limits changed on the server. Click Revert to load them (this discards your unsaved changes)." }
        if remote[id]?.session?.needsReload == true { return "Click Revert to load the server’s current values before applying again." }
        if case .ready = availability, let editor = remote[id]?.session?.editor {
            let missing = ServerOption.allCases.filter { !editor.supports($0) }.count
            if missing > 0 { return "\(missing) settings are unavailable on this server. Changes apply only when you click Apply." }
        }
        if case .unsavedNewServer = availability { return "Fill in the connection, then click Apply to save this server." }
        return "Changes apply only when you click Apply. Revert discards them and loads the server’s current values."
    }

    // MARK: - Sidebar rows

    private func updateRow(_ id: UUID) {
        guard let index = editor.index(of: id) else { return }
        let row = Self.firstServerRow + index
        if let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: false) as? ServerRowCell {
            configure(cell, id: id)
        }
    }

    private func configure(_ cell: ServerRowCell, id: UUID) {
        guard let server = editor.servers.first(where: { $0.id == id }) else { return }
        let saved = editor.isSaved(id)
        let state = remote[id]?.load ?? .notLoaded
        let isActive = activeServerID() == id
        let status: (NSColor, String)
        switch (saved, state) {
        case (false, _): status = (.tertiaryLabelColor, "not saved")
        case (_, .loaded): status = (.systemGreen, "connected")
        case (_, .failed): status = (.systemOrange, "offline")
        case (_, .loading): status = (.secondaryLabelColor, "connecting")
        case (_, .notLoaded): status = (isActive ? .systemGreen : .tertiaryLabelColor, isActive ? "active" : "not checked")
        }
        let isDefault = editor.currentServer == server.name
        let dirty = isDirty(id)
        cell.configure(name: server.name, dot: status.0, badge: isDefault ? "Default" : nil, edited: dirty)
        cell.setAccessibilityLabel([server.name, "server", status.1, isDefault ? "default" : nil, dirty ? "edited" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// Names in the sidebar's server rows (tests).
    var sidebarServerNames: [String] {
        (0..<editor.serverCount).map { index in
            (tableView(sidebar, viewFor: nil, row: Self.firstServerRow + index) as? ServerRowCell)?.nameField.stringValue ?? "?"
        }
    }

    // MARK: - Add / remove / default

    @objc private func addServer() {
        let add = { [weak self] in
            guard let self else { return }
            let index = editor.addServer()
            sidebar.reloadData()
            select(.server(editor.servers[index].id), tab: .connection)
            window?.makeFirstResponder(connectionPane.nameField)
        }
        if let current = selectedServerID, isDirty(current) {
            resolvePendingEdits(for: current, action: "Adding a server", then: add)
        } else {
            add()
        }
    }

    /// Applies immediately; Edit ▸ Undo puts the server back.
    @objc private func removeServer() {
        guard let id = selectedServerID, let index = editor.index(of: id), editor.canRemoveServer(at: index) else { return }
        let saved = editor.isSaved(id)
        let wasDefault = editor.currentServer == editor.servers[index].name
        guard let removed = editor.removeServer(at: index) else { return }
        remote[id] = nil
        if saved { onChange?(editor.savedConfig) }
        sidebar.reloadData()
        select(.server(editor.servers[min(index, editor.serverCount - 1)].id), tab: nil)
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.editor.restoreServer(removed, at: index, saved: saved, wasDefault: wasDefault)
            if saved { target.onChange?(target.editor.savedConfig) }
            target.sidebar.reloadData()
            target.select(.server(removed.id), tab: nil)
        }
        window?.undoManager?.setActionName("Remove Server")
    }

    /// Sidebar footer: − needs a server and more than one; Default needs a saved, non-default server.
    func updateFooter() {
        let id = selectedServerID
        // One rule, the editor's: at least one server stays, and no *other* server has pending edits.
        removeButton.isEnabled = id.flatMap(editor.index(of:)).map(editor.canRemoveServer(at:)) ?? false
        defaultButton.isEnabled = id.map(canMakeDefault) ?? false
    }

    private func canMakeDefault(_ id: UUID) -> Bool {
        editor.isSaved(id) && editor.currentServer != editor.servers.first { $0.id == id }?.name
    }

    @objc private func makeDefaultFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { makeDefault(id) }
    }

    @objc func makeSelectedDefault(_ sender: Any?) {
        if let id = selectedServerID { makeDefault(id) }
    }

    /// Applies immediately, like the other list edits.
    func makeDefault(_ id: UUID) {
        guard canMakeDefault(id), let server = editor.servers.first(where: { $0.id == id }) else { return }
        let previous = editor.currentServer
        editor.setDefaultServer(server.name)
        onChange?(editor.savedConfig)
        for other in editor.servers where other.name == previous || other.id == id { updateRow(other.id) }
        updateFooter()
    }

    // MARK: - Editing

    private func connectionEdited(_ candidate: ServerConfig, normalize: Bool) {
        guard let id = selectedServerID, let index = editor.index(of: id) else { return }
        let stored = editor.updateServer(at: index, to: candidate, normalizeName: normalize)
        if normalize, connectionPane.nameField.stringValue != stored.name { connectionPane.nameField.stringValue = stored.name }
        nameLabel.stringValue = stored.name
        window?.title = "Settings — \(stored.name)"
        if !working {
            statusLabel.stringValue = statusMessage(id, availability: availability(id))
            statusLabel.textColor = connectionPane.portValidationError == nil ? .secondaryLabelColor : .systemRed
        }
        updateDirtyState()
    }

    // MARK: - Apply / Revert

    @objc func applySettings(_ sender: Any?) { applySelected(completion: nil) }

    /// Remote first; Mac-side fields only after it succeeds. On failure every
    /// edit stays put, and the failing field's group is opened and focused.
    func applySelected(completion: ((Bool) -> Void)?) {
        guard let id = selectedServerID, !working else { completion?(false); return }
        window?.makeFirstResponder(nil)   // commit the focused field (end-of-edit normalize)
        // An unusable port is never saved (the editor holds the last valid one).
        if let problem = connectionPane.validatePort() {
            selectTab(.connection)
            window?.makeFirstResponder(connectionPane.portField)
            statusLabel.stringValue = problem
            statusLabel.textColor = .systemRed
            completion?(false)
            return
        }
        let plan = applyPlan(id)
        if plan == .nothing { completion?(true); return }
        let session = remote[id]?.session
        let before = editor.savedServer(id)
        let serverName = editor.servers.first { $0.id == id }?.name ?? "the server"
        perform(message: "Applying and verifying changes…", completion: completion) { [self] in
            try await ServerSettingsScope.apply(plan, remote: {
                guard let session else { return }
                try await session.apply()
            }, local: {
                onChange?(editor.applyServer(id))
            })
            remote[id]?.changedOnServer = false
            let after = editor.savedServer(id)
            if before == nil || !Self.sameConnection(before, after) {
                // New or re-pointed server: reconnect with the saved details.
                remote[id] = nil
                ensureLoaded(id)
            } else {
                form.render()
            }
            onApplied?(id)
            for server in editor.servers { updateRow(server.id) }   // name / Default badge
            switch plan {
            case .localOnly: return "Saved \(serverName) on this Mac."
            default: return "Changes saved and verified on \(serverName)."
            }
        }
    }

    private static func sameConnection(_ a: ServerConfig?, _ b: ServerConfig?) -> Bool {
        guard let a, let b else { return false }
        return a.host == b.host && a.port == b.port && a.useHTTPS == b.useHTTPS && a.rpcPath == b.rpcPath
            && a.username == b.username && a.password == b.password
    }

    /// Revert: discard this server's unsaved edits (connection, presets and
    /// server tabs) and load its current values from the server again. This is
    /// also how to clear "changed on the server" or a failed, unverified write.
    @objc func revertSettings(_ sender: Any?) {
        guard let id = selectedServerID, !working else { return }
        revert(id, refetch: true)
    }

    /// `refetch: false` (Discard in the close/quit/switch prompts) only drops
    /// edits locally; a session that needed a refetch is dropped so it loads
    /// again next time the server is shown.
    private func revert(_ id: UUID, refetch: Bool = false) {
        window?.makeFirstResponder(nil)
        let wasSaved = editor.isSaved(id)
        let index = editor.index(of: id) ?? 0
        editor.revertServer(id)
        if let state = remote[id], let session = state.session {
            session.revert()
            if !refetch, session.needsReload || state.changedOnServer { remote[id] = nil }
        }
        if wasSaved {
            if selectedServerID == id {
                connectionPane.load(editor.servers.first { $0.id == id })
                form.render()
                refreshServerUI()
            }
            updateRow(id)
            if refetch { refetchServerValues(id) }
        } else {
            remote[id] = nil
            sidebar.reloadData()
            if selectedServerID == id {
                select(editor.serverCount > 0 ? .server(editor.servers[max(0, min(index, editor.serverCount) - 1)].id) : .general, tab: nil)
            }
        }
        window?.isDocumentEdited = hasPendingEdits
    }

    private func refetchServerValues(_ id: UUID) {
        guard let session = remote[id]?.session else { ensureLoaded(id, force: true); return }
        perform(message: "Loading the server’s current values…", completion: nil) { [self] in
            try await session.load()
            remote[id]?.changedOnServer = false
            if selectedServerID == id { form.render() }
            return "Reverted to the server’s current values."
        }
    }

    /// Test Connection probes the Connection form as typed (unsaved edits
    /// included), so it works for a new server or one whose tabs are blocked.
    private func runTestConnection(_ server: ServerConfig) {
        if let problem = connectionPane.validatePort() {   // e.g. from the offline notice
            statusLabel.stringValue = problem
            statusLabel.textColor = .systemRed
            return
        }
        connectionPane.setTesting(true)
        SettingsConnectionPane.testConnection(server, window: window) { [weak self] in
            self?.connectionPane.setTesting(false)
        }
    }

    private func runPortTest(_ choice: PeerPortProtocol) {
        guard let id = selectedServerID, let session = remote[id]?.session else { return }
        perform(message: "Testing the server’s applied incoming port (\(choice.displayName))…", completion: nil) {
            let current = try await session.service.fetchServerOptions()
            let result = try await session.testPort(protocol: choice)
            let port = current.values[.peerPort]?.text(for: .peerPort) ?? "unknown"
            return "Port \(port) — " + result.description(requested: choice)
        }
    }

    /// Opens the bandwidth groups editor as a sheet; it keeps its own Apply Group.
    private func manageGroups() {
        guard let id = selectedServerID, let session = remote[id]?.session, let window, groupsController == nil else { return }
        let name = editor.servers.first { $0.id == id }?.name ?? ""
        let controller = BandwidthGroupsWindowController(serverName: name, service: session.service)
        groupsController = controller
        guard let sheet = controller.window else { return }
        window.beginSheet(sheet) { [weak self] _ in self?.groupsController = nil }
        controller.loadGroups()
    }

    private func perform(message: String, completion: ((Bool) -> Void)?,
                         action: @escaping @MainActor () async throws -> String) {
        guard !working else { completion?(false); return }
        working = true
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        spinner.startAnimation(nil)
        refreshServerUI()
        Task { [self] in
            var focusKey: ServerOption?
            var ok = true
            do {
                statusLabel.stringValue = try await action()
            } catch {
                ok = false
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                focusKey = (error as? ServerOptionsError)?.fields.first
            }
            working = false
            spinner.stopAnimation(nil)
            let result = statusLabel.stringValue
            let color = statusLabel.textColor
            refreshServerUI()
            statusLabel.stringValue = result
            statusLabel.textColor = color
            if let window {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: result, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            if let key = focusKey { focus(key) }
            completion?(ok)
        }
    }

    /// Expand the field's group, switch to its tab, and focus it.
    func focus(_ key: ServerOption) {
        form.reveal(key)
        selectTab(Tab(key.definition.pane))
        if let control = form.controls[key]?.first {
            control.scrollToVisible(control.bounds)
            window?.makeFirstResponder((control as? ServerOptionsTextArea)?.textView ?? control)
        }
    }

    // MARK: - Pending-edit guards

    /// Apply / Discard / Cancel before leaving a server with unsaved edits.
    private func resolvePendingEdits(for id: UUID, action: String, then proceed: @escaping () -> Void) {
        guard isDirty(id), !working else { if !working { proceed() }; return }
        switch askAboutPendingEdits(id, detail: "\(action) leaves edits that haven’t been applied.") {
        case .apply:
            if selectedServerID != id { select(.server(id), tab: nil) }
            applySelected { ok in if ok { proceed() } }
        case .discard:
            revert(id)
            proceed()
        case .cancel:
            // Keep the sidebar on the edited server.
            if selectedServerID == id { select(.server(id), tab: selectedTab) }
        }
    }

    enum PendingChoice { case apply, discard, cancel }

    /// The Apply / Discard / Cancel question for one server's unsaved edits.
    private func askAboutPendingEdits(_ id: UUID, detail: String) -> PendingChoice {
        let name = editor.servers.first { $0.id == id }?.name ?? "this server"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply changes to “\(name)”?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .apply
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// For Quit: resolves pending edits, then reports whether quitting may go
    /// ahead. Apply is asynchronous, so the answer may come later.
    func confirmQuit(_ reply: @escaping (Bool) -> Void) {
        if let groupsController, !groupsController.canQuit() { reply(false); return }
        // Every server with pending edits: Connection/presets *or* server-tab drafts.
        confirmQuitEdits(for: editor.servers.map(\.id).filter(isDirty), reply: reply)
    }

    /// Asks about each server in `ids` that still has edits, one at a time. Apply
    /// continues to the next server only if it succeeded; Cancel on any server aborts the quit.
    private func confirmQuitEdits(for ids: [UUID], reply: @escaping (Bool) -> Void) {
        guard let id = ids.first else { reply(true); return }
        let remaining = Array(ids.dropFirst())
        guard isDirty(id) else { confirmQuitEdits(for: remaining, reply: reply); return }
        if selectedServerID != id { select(.server(id), tab: nil) }
        window?.makeKeyAndOrderFront(nil)
        switch askAboutPendingEdits(id, detail: "Your changes haven’t been applied. Apply them before quitting?") {
        case .apply:
            applySelected { [weak self] ok in
                guard ok else { reply(false); return }
                self?.confirmQuitEdits(for: remaining, reply: reply)
            }
        case .discard:
            revert(id)
            confirmQuitEdits(for: remaining, reply: reply)
        case .cancel:
            reply(false)
        }
    }
}

// MARK: - Sidebar data source / delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        return 26
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
            return cell
        case .general:
            let cell = ServerRowCell()
            cell.configure(name: "General", dot: nil, badge: nil, edited: false)
            cell.icon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            cell.icon.contentTintColor = .secondaryLabelColor
            cell.setAccessibilityLabel("General settings")
            return cell
        case .server(let id):
            let cell = (tableView.makeView(withIdentifier: ServerRowCell.reuseID, owner: self) as? ServerRowCell) ?? ServerRowCell()
            configure(cell, id: id)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return false }
        if isSelectingProgrammatically { return true }
        let target: Selection
        switch rows[row] {
        case .general: target = .general
        case .server(let id): target = .server(id)
        case .header: return false
        }
        if target != selection, let current = selectedServerID, isDirty(current) {
            // Ask outside the delegate callback, then select programmatically.
            DispatchQueue.main.async { [weak self] in self?.route(to: target) }
            return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, rows.indices.contains(sidebar.selectedRow) else { return }
        switch rows[sidebar.selectedRow] {
        case .general: selection = .general
        case .server(let id): selection = .server(id)
        case .header: return
        }
        showSelection(tab: nil)
    }

    // Drag-to-reorder the server rows; applies immediately.

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= Self.firstServerRow, rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row - Self.firstServerRow), forType: Self.serverRowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let operation = serverDropOperation(for: info.draggingPasteboard)
        guard !operation.isEmpty, row >= Self.firstServerRow else { return [] }
        tableView.setDropRow(row, dropOperation: .above)   // onto a row means "next to it"
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        acceptServerDrop(from: info.draggingPasteboard, row: row)
    }

    /// Only our own server-row drags reorder; anything else is refused.
    func serverDropOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
        pasteboard.types?.contains(Self.serverRowType) == true ? .move : []
    }

    /// Move the dragged server to the gap before sidebar `row`.
    func acceptServerDrop(from pasteboard: NSPasteboard, row: Int) -> Bool {
        // Reorder isn't gated: it persists only the saved list's order, never another
        // server's pending edits (those stay in the working copy).
        guard row >= Self.firstServerRow,
              let source = pasteboard.string(forType: Self.serverRowType).flatMap(Int.init),
              editor.moveServer(from: source, to: row - Self.firstServerRow) != nil else { return false }
        onChange?(editor.savedConfig)
        sidebar.reloadData()
        select(selection, tab: selectedServerID.map { _ in selectedTab })
        return true
    }
}

// MARK: - Sidebar context menu (Make Default)

extension SettingsWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = sidebar.clickedRow
        guard rows.indices.contains(row), case .server(let id) = rows[row] else { return }
        let item = menu.addItem(withTitle: "Make Default", action: #selector(makeDefaultFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = canMakeDefault(id)
    }
}

extension SettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        tabPicker.selectedSegment = tabView.indexOfTabViewItem(tabViewItem)
        // Don't start editing the first text field of the newly shown tab.
        window?.makeFirstResponder(tabPicker)
    }
}

// MARK: - Window delegate

extension SettingsWindowController: NSWindowDelegate {
    /// The default handler can change outside the app, so re-read it on focus.
    func windowDidBecomeKey(_ notification: Notification) {
        generalPane.reloadHandlerStatus()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let groupsController, !groupsController.canQuit() { return false }
        guard let id = editor.servers.map(\.id).first(where: isDirty) else { return true }
        if selectedServerID != id { select(.server(id), tab: nil) }
        switch askAboutPendingEdits(id, detail: "Your changes haven’t been applied. Apply them before closing?") {
        case .apply:
            // Apply is asynchronous (a server round trip): close once it succeeds.
            applySelected { [weak self] ok in if ok { self?.window?.close() } }
            return false
        case .discard:
            for server in editor.servers where isDirty(server.id) { revert(server.id) }
            return true
        case .cancel:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: Self.frameName)
        rememberSelection()
    }
}

// MARK: - Window and cells

/// Settings window: blank-space clicks end editing (from `ServerOptionsWindow`),
/// and Ctrl-Tab cycles the server tabs.
@MainActor
final class SettingsWindow: ServerOptionsWindow {
    var onControlTab: ((Bool) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control), let onControlTab {
            onControlTab(event.modifierFlags.contains(.shift))
            return
        }
        super.sendEvent(event)
    }
}

/// A sidebar row: status dot (or icon), name, "Default" badge, unsaved-edit dot.
@MainActor
final class ServerRowCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("serverRow")
    let icon = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let editedDot = NSTextField(labelWithString: "●")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        nameField.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 10)
        badge.textColor = .secondaryLabelColor
        editedDot.font = .systemFont(ofSize: 8)
        editedDot.textColor = .controlAccentColor
        editedDot.toolTip = "Unsaved changes"
        textField = nameField
        imageView = icon
        for view in [icon, nameField, badge, editedDot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            editedDot.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 4),
            editedDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: editedDot.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, dot: NSColor?, badge text: String?, edited: Bool) {
        nameField.stringValue = name
        if let dot {
            icon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
            icon.contentTintColor = dot
        }
        badge.stringValue = text ?? ""
        badge.isHidden = text == nil
        editedDot.isHidden = !edited
    }
}
