import AppKit

/// Settings ▸ <server> ▸ Connection (name, hosts, port, HTTPS, RPC path,
/// credentials, custom headers, path mappings) plus the speed-menu presets shown on the Speed
/// tab. All of it is stored on this Mac, in the server's `ServerConfig`.
///
/// Edits sync into the editor on every keystroke (so Apply enables at once)
/// without normalizing the name; end-of-edit normalizes it. Neither ever
/// reloads the sidebar table, which would drop its selection mid-edit.
@MainActor
final class SettingsConnectionPane: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    /// (fields as typed, normalize name?) — the shell stores it in the editor.
    var onEdit: ((ServerConfig, Bool) -> Void)?
    /// Test Connection, under the credentials: probes the fields as typed.
    var onTestConnection: (() -> Void)?
    let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private(set) var view = NSView()
    private(set) var presetsView = NSView()

    let nameField = NSTextField()
    let hostField = NSTextField()
    let portField = NSTextField()
    let httpsCheckbox = NSButton(checkboxWithTitle: "Use HTTPS", target: nil, action: nil)
    let rpcPathField = NSTextField()
    let usernameField = NSTextField()
    let passwordField = NSSecureTextField()
    let downPresetsField = NSTextField()
    let upPresetsField = NSTextField()
    let pathMappingsView = PlaceholderTextView()   // multi-line: one `remote=local` per line
    let headersTable = CustomHeadersTable()
    /// Under Host: names any host the form reaches over plain HTTP across a
    /// network, i.e. anything but this Mac (`ServerConfig.plainHTTPNetworkHosts`).
    /// Hidden otherwise.
    let plainHTTPWarning = NSTextField(labelWithString: "")
    private var plainHTTPRow: NSGridRow?
    /// The shown server's "send custom headers" setting, edited by `headersCheckbox`.
    private(set) var useCustomHeaders = false
    let headersCheckbox = NSButton(checkboxWithTitle: "Send custom headers", target: nil, action: nil)
    /// The form grid, and which of its rows belong to each switchable section.
    private var grid: NSGridView?
    /// Rows that appear only while the "Access Proxy" group is open.
    private var proxyGroupRows: [NSGridRow] = []
    /// Rows that appear only while the group is open and the section's checkbox is on.
    private var accessDetailRows: [NSGridRow] = []
    private var headerDetailRows: [NSGridRow] = []
    /// The "Access Proxy" disclosure: collapsed unless the server uses one of its
    /// features or the user opened it. Opening is remembered per server.
    let proxyDisclosure = NSButton()
    private(set) var proxyExpanded = false
    private var shownServerID: UUID?
    private static let proxyExpandedKey = "ConnectionProxyExpandedServers"
    /// The shown server's Cloudflare Access setting, edited by `accessCheckbox`.
    private(set) var useCloudflareAccess = false
    let accessCheckbox = NSButton(checkboxWithTitle: "Sign in with Cloudflare Access", target: nil, action: nil)
    let accessStatus = NSTextField(wrappingLabelWithString: "")
    private let accessSpinner = NSProgressIndicator()
    let accessSignInButton = NSButton(title: "Sign In…", target: nil, action: nil)
    let accessSignOutButton = NSButton(title: "Sign Out", target: nil, action: nil)
    let accessCopyLinkButton = NSButton(title: "Copy Link", target: nil, action: nil)
    let accessCancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Sign-in actions; the window controller supplies the server.
    var onAccessSignIn: (() -> Void)?
    var onAccessSignOut: (() -> Void)?
    var onAccessCancel: (() -> Void)?
    /// The sign-in URL while waiting for the browser (Copy Link).
    private var accessSignInURL: URL?
    private var detailFields: [NSControl] = []
    private var isLoading = false
    /// The last port that parsed, used in place of unusable input so the editor is
    /// never handed a substituted default. The controller must still gate Apply on
    /// `validatePort()`.
    private var lastValidPort = 9091

    override init() {
        super.init()
        view = buildForm()
        presetsView = buildPresets()
        headersTable.onChange = { [weak self] _ in
            guard let self, !self.isLoading else { return }
            self.onEdit?(self.currentServer(rawName: true), false)
        }
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func caption(_ text: String) -> NSTextField {
        let c = label(text)
        c.font = .systemFont(ofSize: 10)
        c.textColor = .secondaryLabelColor
        c.lineBreakMode = .byWordWrapping
        c.maximumNumberOfLines = 0
        return c
    }

    private func buildForm() -> NSView {
        for field in [nameField, hostField, portField, rpcPathField, usernameField, passwordField] {
            field.target = self
            field.action = #selector(fieldEnded)       // end-editing (Tab/Return/focus loss)
            field.delegate = self                       // controlTextDidChange → live per-keystroke
        }
        httpsCheckbox.target = self
        httpsCheckbox.action = #selector(fieldEnded)
        nameField.setAccessibilityIdentifier("server-name")
        hostField.setAccessibilityIdentifier("server-host")
        hostField.placeholderString = "e.g. 192.168.1.10, nas.local, https://example.ts.net"
        nameField.placeholderString = "e.g. Home NAS"
        hostField.toolTip = "One host, or a comma- or line-separated list of fallbacks tried in "
            + "order — e.g. 10.0.1.2, n5.local, https://transmission.example.ts.net. "
            + "Each may include a scheme/port; the app connects to the first that responds."
        // Two-line wrapping field so a multi-host fallback list is visible at once.
        hostField.usesSingleLineMode = false
        hostField.lineBreakMode = .byWordWrapping
        hostField.cell?.wraps = true
        hostField.cell?.isScrollable = false
        hostField.maximumNumberOfLines = 3
        hostField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        portField.placeholderString = "9091"
        rpcPathField.placeholderString = "/transmission/rpc"
        usernameField.placeholderString = "Optional"
        passwordField.placeholderString = "Optional"
        detailFields = [nameField, hostField, portField, httpsCheckbox, rpcPathField, usernameField, passwordField]

        let scope = label(ServerSettingsScope.Storage.mac.rawValue)
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        scope.textColor = .secondaryLabelColor
        scope.setAccessibilityHelp(ServerSettingsScope.Storage.mac.help)

        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection(_:))
        testButton.toolTip = "Try every host as typed here, including unsaved changes, and report which respond."
        testButton.setAccessibilityIdentifier("server-settings-test-connection")
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        let testRow = NSStackView(views: [testButton, testSpinner])
        testRow.spacing = 8
        testRow.alignment = .centerY

        let grid = NSGridView(views: [
            [NSView(), scope],
            [label("Name:"), nameField],
            [label("Host:"), hostField],
            [label("Port:"), portField],
            [NSView(), httpsCheckbox],
            [label("RPC Path:"), rpcPathField],
            [label("Username:"), usernameField],
            [label("Password:"), passwordField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        // Labels flush left, sized to the longest, so fields sit close to them.
        grid.column(at: 0).xPlacement = .leading
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 300
        self.grid = grid
        plainHTTPWarning.font = .systemFont(ofSize: 10)
        plainHTTPWarning.textColor = .systemOrange
        plainHTTPWarning.lineBreakMode = .byWordWrapping
        plainHTTPWarning.maximumNumberOfLines = 0
        plainHTTPWarning.setAccessibilityIdentifier("server-plain-http-warning")
        // Right under Host (rows: scope, name, host).
        plainHTTPRow = grid.insertRow(at: 3, with: [NSView(), plainHTTPWarning])
        updatePlainHTTPWarning()
        addProxyGroup(to: grid)
        // Test Connection probes everything above it (host, credentials, proxy
        // headers), so it follows the group; a divider then sets the unrelated
        // path mappings apart.
        grid.addRow(with: [NSView(), testRow])
        let rule = NSBox()
        rule.boxType = .separator
        let divider = grid.addRow(with: [rule, NSView()])
        divider.mergeCells(in: NSRange(location: 0, length: 2))
        divider.topPadding = 14
        divider.bottomPadding = 10
        let mappings = grid.addRow(with: [label("Path Mappings:"), buildPathMappingsEditor()])
        mappings.yPlacement = .top
        mappings.rowAlignment = .none
        grid.addRow(with: [NSView(), caption("Remote→local, one per line.\ne.g.  /video=/Volumes/Video\nLocal side also accepts smb://host/share/path, resolved to wherever that share is currently mounted.")])
        updateSectionVisibility()
        // Scrolls like the server tabs, so the form never forces the window taller
        // than its minimum size.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(grid)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])
        return scroll
    }

    /// Appends the collapsed "Access Proxy" group: Cloudflare Access sign-in and
    /// custom headers, both off by default. Rows are kept by reference, so moving
    /// them never breaks the visibility rules.
    private func addProxyGroup(to grid: NSGridView) {
        proxyDisclosure.bezelStyle = .disclosure
        proxyDisclosure.setButtonType(.pushOnPushOff)
        proxyDisclosure.title = ""
        proxyDisclosure.target = self
        proxyDisclosure.action = #selector(proxyDisclosureToggled)
        proxyDisclosure.setAccessibilityLabel("Access Proxy")
        proxyDisclosure.setAccessibilityIdentifier("server-proxy-disclosure")
        let title = label("Access Proxy")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let click = NSClickGestureRecognizer(target: self, action: #selector(proxyDisclosureToggled))
        title.addGestureRecognizer(click)
        let header = NSStackView(views: [proxyDisclosure, title])
        header.spacing = 4
        header.alignment = .centerY
        let hint = caption("For a server behind an access proxy such as Cloudflare Access. Most servers don’t need this.")
        grid.addRow(with: [NSView(), header])
        proxyGroupRows.append(grid.addRow(with: [NSView(), hint]))

        func add(_ views: [NSView]) -> NSGridRow { grid.addRow(with: views) }
        proxyGroupRows.append(add([label("Cloudflare Access:"), accessCheckbox]))
        accessDetailRows = [
            add([NSView(), buildAccessStatusRow()]),
            add([NSView(), buildAccessButtonsRow()]),
            add([NSView(), caption("Signs in through your browser with any login method the Access application offers. Needs Managed OAuth on for the application. The session is kept in the Keychain, renews itself, and is sent only to the HTTPS host it was issued for.")]),
        ]
        proxyGroupRows.append(add([label("Custom Headers:"), headersCheckbox]))
        let table = add([NSView(), headersTable.view])
        table.yPlacement = .top
        table.rowAlignment = .none
        headerDetailRows = [
            table,
            add([NSView(), caption("Sent with every request, e.g. the service-token headers an access proxy requires. Values are stored in the Keychain. They go only to HTTPS hosts; a plain-HTTP host never receives them.")]),
        ]
        headersCheckbox.target = self
        headersCheckbox.action = #selector(headersCheckboxChanged)
        headersCheckbox.setAccessibilityIdentifier("server-headers-enabled")
    }

    @objc private func proxyDisclosureToggled() {
        setProxyExpanded(!proxyExpanded, remember: true)
    }

    func setProxyExpanded(_ expanded: Bool, remember: Bool) {
        proxyExpanded = expanded
        proxyDisclosure.state = expanded ? .on : .off
        updateSectionVisibility()
        guard remember, let id = shownServerID, Self.remembersExpansion else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.proxyExpandedKey) ?? [])
        if expanded { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        UserDefaults.standard.set(Array(ids), forKey: Self.proxyExpandedKey)
    }

    private static var remembersExpansion: Bool { SettingsWindowController.remembersUIState && !TestIsolation.isActive }

    /// Opens the group when something inside it needs to be seen.
    func revealProxyGroup() {
        if !proxyExpanded { setProxyExpanded(true, remember: false) }
    }

    private func buildAccessStatusRow() -> NSView {
        accessStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessStatus.textColor = .secondaryLabelColor
        accessStatus.setAccessibilityIdentifier("server-access-status")
        accessStatus.preferredMaxLayoutWidth = 280
        accessSpinner.style = .spinning
        accessSpinner.controlSize = .small
        accessSpinner.isDisplayedWhenStopped = false
        let row = NSStackView(views: [accessSpinner, accessStatus])
        row.spacing = 6
        row.alignment = .firstBaseline
        return row
    }

    private func buildAccessButtonsRow() -> NSView {
        accessCheckbox.target = self
        accessCheckbox.action = #selector(accessCheckboxChanged)
        accessCheckbox.setAccessibilityIdentifier("server-access-enabled")
        for (button, action, id) in [
            (accessSignInButton, #selector(accessSignIn), "server-access-sign-in"),
            (accessSignOutButton, #selector(accessSignOut), "server-access-sign-out"),
            (accessCopyLinkButton, #selector(accessCopyLink), "server-access-copy-link"),
            (accessCancelButton, #selector(accessCancel), "server-access-cancel"),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
        }
        accessCopyLinkButton.toolTip = "Copy the sign-in link, to open it in another browser."
        let buttons = NSStackView(views: [accessSignInButton, accessSignOutButton, accessCopyLinkButton, accessCancelButton])
        buttons.spacing = 8
        return buttons
    }

    @objc private func accessCheckboxChanged() {
        useCloudflareAccess = accessCheckbox.state == .on
        updateSectionVisibility()
        fieldEnded()
    }

    @objc private func headersCheckboxChanged() {
        useCustomHeaders = headersCheckbox.state == .on
        updateSectionVisibility()
        fieldEnded()
    }

    /// Shows a section's rows only while its checkbox is on.
    private func updateSectionVisibility() {
        guard grid != nil else { return }
        for row in proxyGroupRows { row.isHidden = !proxyExpanded }
        for row in accessDetailRows { row.isHidden = !(proxyExpanded && useCloudflareAccess) }
        for row in headerDetailRows { row.isHidden = !(proxyExpanded && useCustomHeaders) }
    }

    /// Turns the headers section on without a click (for tests).
    func useCustomHeadersForTesting(_ on: Bool) {
        headersCheckbox.state = on ? .on : .off
        headersCheckboxChanged()
    }

    /// Whether a section's details are showing (for tests).
    var showsAccessDetails: Bool { accessDetailRows.allSatisfy { !$0.isHidden } }
    var showsHeaderDetails: Bool { headerDetailRows.allSatisfy { !$0.isHidden } }

    @objc private func accessSignIn() { onAccessSignIn?() }
    @objc private func accessSignOut() { onAccessSignOut?() }
    @objc private func accessCancel() { onAccessCancel?() }

    @objc private func accessCopyLink() {
        guard let url = accessSignInURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Shows the server's Access state. `saved` is whether sign-in is turned on in
    /// the server's saved settings: until it is applied, signing in has nothing
    /// to attach the session to, so the buttons wait for Apply.
    func renderAccess(session: AccessSession?, phase: AccessSignInController.Phase, saved: Bool, now: Date = Date()) {
        let on = useCloudflareAccess && accessCheckbox.isEnabled
        let waiting: Bool
        if case .waiting(let url) = phase { waiting = true; accessSignInURL = url } else { waiting = false; accessSignInURL = nil }
        let signedIn = session?.isSignedIn == true
        if on && !saved {
            accessStatus.stringValue = "Click Apply to turn on Cloudflare Access sign-in for this server."
        } else if on {
            accessStatus.stringValue = AccessSignInController.statusText(session: session, phase: phase, now: now)
        } else {
            accessStatus.stringValue = signedIn ? "Off. The saved session is kept until you sign out." : "Off."
        }
        if case .failed = phase, on, saved {
            accessStatus.textColor = .systemRed
        } else {
            accessStatus.textColor = .secondaryLabelColor
        }
        if waiting { accessSpinner.startAnimation(nil) } else { accessSpinner.stopAnimation(nil) }
        accessSignInButton.isEnabled = on && saved && !waiting
        accessSignInButton.title = signedIn ? "Sign In Again…" : "Sign In…"
        accessSignOutButton.isEnabled = signedIn || waiting
        accessCopyLinkButton.isHidden = !waiting
        accessCopyLinkButton.isEnabled = accessSignInURL != nil
        accessCancelButton.isHidden = !waiting
    }

    private func buildPresets() -> NSView {
        for field in [downPresetsField, upPresetsField] {
            field.target = self
            field.action = #selector(fieldEnded)
            field.delegate = self
            field.placeholderString = SpeedPresets.format(SpeedPresets.defaults)
        }
        downPresetsField.setAccessibilityIdentifier("server-down-presets")
        upPresetsField.setAccessibilityIdentifier("server-up-presets")
        downPresetsField.setAccessibilityLabel("Download presets")
        upPresetsField.setAccessibilityLabel("Upload presets")
        let grid = NSGridView(views: [
            [label("Download presets:"), downPresetsField],
            [label("Upload presets:"), upPresetsField],
            [NSView(), caption("Speed-menu choices in KB/s, comma-separated. Editable while the server is offline.")],
        ])
        // Line the fields up with the server-side fields above (label column 220 − 20 indent).
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = 200
        grid.columnSpacing = 10
        grid.column(at: 1).width = 300
        grid.rowAlignment = .firstBaseline
        grid.widthAnchor.constraint(equalToConstant: 510).isActive = true
        return grid
    }

    /// A multi-line text editor (scrollable `NSTextView`) for the `remote=local`
    /// path-mapping lines — the native take on the legacy app's `edPaths` memo.
    private func buildPathMappingsEditor() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        pathMappingsView.delegate = self
        pathMappingsView.isRichText = false
        pathMappingsView.isAutomaticQuoteSubstitutionEnabled = false
        pathMappingsView.isAutomaticDashSubstitutionEnabled = false
        pathMappingsView.isAutomaticSpellingCorrectionEnabled = false
        pathMappingsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathMappingsView.placeholderString = "/video=/Volumes/Video\n/backup=/Volumes/backup\n/downloads=smb://nas/share/downloads"
        pathMappingsView.textContainerInset = NSSize(width: 2, height: 4)
        pathMappingsView.isVerticallyResizable = true
        pathMappingsView.isHorizontallyResizable = false
        pathMappingsView.autoresizingMask = [.width]
        pathMappingsView.textContainer?.widthTracksTextView = true
        scroll.documentView = pathMappingsView
        return scroll
    }

    /// The port problem to show, or nil when the port field is valid or no server is
    /// loaded (the form is disabled). Read-only.
    var portValidationError: String? {
        guard portField.isEnabled else { return nil }
        return ServerPort.validationMessage(for: portField.stringValue)
    }

    /// Marks the port field red (with the problem as its tooltip) when it is invalid,
    /// clears the mark when it is valid, and returns the problem. The controller
    /// calls this before Apply and must not save while it returns non-nil.
    @discardableResult
    func validatePort() -> String? {
        let problem = portValidationError
        portField.textColor = problem == nil ? NSColor.controlTextColor : NSColor.systemRed
        portField.toolTip = problem
        portField.setAccessibilityHelp(problem)
        return problem
    }

    /// The header problem to show, or nil when every header is valid or no server is loaded.
    var headersValidationError: String? {
        // Headers that won't be sent don't block Apply.
        guard headersTable.isEnabled, useCustomHeaders else { return nil }
        return headersTable.validationError
    }

    /// The first problem in the form (port, then custom headers), or nil. Read-only.
    var validationError: String? { portValidationError ?? headersValidationError }

    /// Marks the port field and returns the form's first problem, or nil. The
    /// controller calls this before Apply or Test Connection and stops on a problem.
    @discardableResult
    func validate() -> String? {
        validatePort() ?? headersValidationError
    }

    /// The control to focus for the current problem.
    var firstInvalidControl: NSView {
        if portValidationError != nil { return portField }
        revealProxyGroup()   // the invalid header may be inside the collapsed group
        return headersTable.tableView
    }

    @objc private func testConnection(_ sender: Any?) {
        // Never probe with a wrong port or a header that wouldn't be sent: report
        // the problem instead.
        if let problem = validate() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = portValidationError != nil ? "Invalid port" : "Invalid custom header"
            alert.informativeText = problem
            let focus = firstInvalidControl
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            _ = focus.window?.makeFirstResponder(focus)
            return
        }
        onTestConnection?()
    }

    func setTesting(_ testing: Bool) {
        testButton.isEnabled = !testing
        if testing { testSpinner.startAnimation(nil) } else { testSpinner.stopAnimation(nil) }
    }

    /// Show `server` (nil clears and disables the form).
    func load(_ server: ServerConfig?) {
        isLoading = true
        defer { isLoading = false }
        for field in detailFields { field.isEnabled = server != nil }
        testButton.isEnabled = server != nil
        pathMappingsView.isEditable = server != nil
        headersTable.isEnabled = server != nil
        headersTable.load(server?.headers ?? [])
        useCloudflareAccess = server?.useCloudflareAccess ?? false
        accessCheckbox.state = useCloudflareAccess ? .on : .off
        accessCheckbox.isEnabled = server != nil
        useCustomHeaders = server?.useCustomHeaders ?? false
        headersCheckbox.state = useCustomHeaders ? .on : .off
        headersCheckbox.isEnabled = server != nil
        shownServerID = server?.id
        let remembered = server.map { shown in
            Self.remembersExpansion
                && (UserDefaults.standard.stringArray(forKey: Self.proxyExpandedKey) ?? []).contains(shown.id.uuidString)
        } ?? false
        // Never hide something that is switched on.
        setProxyExpanded(remembered || useCloudflareAccess || useCustomHeaders, remember: false)
        nameField.stringValue = server?.name ?? ""
        hostField.stringValue = server?.host ?? ""
        portField.stringValue = server.map { String($0.port) } ?? ""
        if let server { lastValidPort = server.port }
        validatePort()
        httpsCheckbox.state = server?.useHTTPS == true ? .on : .off
        rpcPathField.stringValue = server?.rpcPath ?? ""
        usernameField.stringValue = server?.username ?? ""
        passwordField.stringValue = server?.password ?? ""
        pathMappingsView.string = server.map { PathMapping.format($0.pathMappings) } ?? ""
        downPresetsField.stringValue = server.map { SpeedPresets.format($0.downSpeedPresets) } ?? ""
        upPresetsField.stringValue = server.map { SpeedPresets.format($0.upSpeedPresets) } ?? ""
        updatePlainHTTPWarning()
    }

    /// Shows or hides the plain-HTTP warning for the hosts as currently typed.
    private func updatePlainHTTPWarning() {
        let hosts = hostField.stringValue.isEmpty ? [] : currentServer().plainHTTPNetworkHosts
        plainHTTPWarning.stringValue = Self.plainHTTPWarningText(hosts)
        plainHTTPRow?.isHidden = hosts.isEmpty
    }

    static func plainHTTPWarningText(_ hosts: [String]) -> String {
        guard !hosts.isEmpty else { return "" }
        let one = hosts.count == 1
        let list = ListFormatter.localizedString(byJoining: hosts)
        return "⚠︎ Plain HTTP to \(list) crosses a network unencrypted, so anyone on that network could "
            + "read your Transmission username, password and traffic. Turn on Use HTTPS, or give "
            + "\(one ? "that host" : "those hosts") an https:// address."
    }

    /// The port for the editor: the typed port when valid, otherwise the last valid
    /// one (see `validatePort()` for the problem itself).
    private func portForEditor() -> Int {
        if let port = ServerPort.parse(portField.stringValue) {
            lastValidPort = port
            return port
        }
        return lastValidPort
    }

    /// The form's current text as a `ServerConfig` (its id is the editor row's
    /// concern). Also what Test Connection probes, so unsaved edits can be tested.
    /// An unusable port is not substituted: the last valid port stands in, and
    /// `validatePort()` reports the problem.
    func currentServer(rawName: Bool = false) -> ServerConfig {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let path = rpcPathField.stringValue.trimmingCharacters(in: .whitespaces)
        return ServerConfig(
            name: rawName ? nameField.stringValue : (name.isEmpty ? host : name),
            host: host,
            port: portForEditor(),
            useHTTPS: httpsCheckbox.state == .on,
            rpcPath: path.isEmpty ? "/transmission/rpc" : path,
            username: usernameField.stringValue.isEmpty ? nil : usernameField.stringValue,
            password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue,
            pathMappings: PathMapping.parse(pathMappingsView.string),
            downSpeedPresets: SpeedPresets.parse(downPresetsField.stringValue),
            upSpeedPresets: SpeedPresets.parse(upPresetsField.stringValue),
            headers: headersTable.headers,
            useCustomHeaders: useCustomHeaders,
            useCloudflareAccess: useCloudflareAccess)
    }

    @objc private func fieldEnded() {
        guard !isLoading else { return }
        validatePort()
        updatePlainHTTPWarning()
        onEdit?(currentServer(), true)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isLoading else { return }
        validatePort()
        updatePlainHTTPWarning()
        onEdit?(currentServer(rawName: true), false)
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading, (notification.object as AnyObject) === pathMappingsView else { return }
        onEdit?(currentServer(rawName: true), false)
    }

    // MARK: - Test Connection

    /// One candidate's probe outcome.
    struct HostProbeResult {
        let server: ServerConfig
        let version: String?      // non-nil on success
        let error: Error?         // non-nil on failure
        var ok: Bool { version != nil }
    }

    /// Probe every host candidate of `server` concurrently and report each one,
    /// so the whole failover picture is visible (the app uses the first ✓).
    static func testConnection(_ server: ServerConfig, window: NSWindow?, done: @escaping @MainActor () -> Void) {
        let candidates = server.connectionCandidates.filter { !$0.host.isEmpty }
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Enter a host to test"
            alert.informativeText = "Type a host name or IP address first, then try again."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            done()
            return
        }
        Task { @MainActor in
            let results = await probeAll(candidates)
            done()
            presentTestResults(results, window: window)
        }
    }

    /// Probe all candidates concurrently; results are returned in candidate order.
    private static func probeAll(_ candidates: [ServerConfig]) async -> [HostProbeResult] {
        await withTaskGroup(of: (Int, HostProbeResult).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    do {
                        let client = try TransmissionClient(server: candidate, timeout: 5)
                        let info = try await client.fetchSession()
                        return (index, HostProbeResult(server: candidate, version: info.version, error: nil))
                    } catch {
                        return (index, HostProbeResult(server: candidate, version: nil, error: error))
                    }
                }
            }
            var byIndex: [Int: HostProbeResult] = [:]
            for await (index, result) in group { byIndex[index] = result }
            return candidates.indices.compactMap { byIndex[$0] }
        }
    }

    static func endpointLabel(_ s: ServerConfig) -> String {
        "\(s.useHTTPS ? "https" : "http")://\(s.host):\(s.port)"
    }

    private static func presentTestResults(_ results: [HostProbeResult], window: NSWindow?) {
        let okCount = results.filter(\.ok).count
        let alert = NSAlert()
        if results.count == 1 {
            let r = results[0]
            if let version = r.version {
                alert.alertStyle = .informational
                alert.messageText = "Connection succeeded"
                alert.informativeText = "Connected to \(endpointLabel(r.server)).\nTransmission \(version)."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Connection failed"
                alert.informativeText = r.error.map { ConnectionDiagnostics.message(for: $0, server: r.server) }
                    ?? "Could not reach the server."
            }
        } else {
            alert.alertStyle = okCount > 0 ? .informational : .warning
            alert.messageText = okCount > 0 ? "\(okCount) of \(results.count) hosts responded" : "No hosts responded"
            alert.informativeText = results.map { r in
                if let version = r.version {
                    return "✓  \(endpointLabel(r.server)) — Transmission \(version)"
                } else {
                    return "✗  \(endpointLabel(r.server)) — \(shortError(r.error, server: r.server))"
                }
            }.joined(separator: "\n")
        }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// A terse failure reason for the per-host list.
    static func shortError(_ error: Error?, server: ServerConfig? = nil) -> String {
        guard let error else { return "no response" }
        if let reason = error.accessSignInReason { return ConnectionDiagnostics.shortAccess(reason) }
        switch error as? TransmissionError {
        case .authenticationFailed: return "auth failed (check username/password)"
        case .httpError(404): return "no RPC at that path (404)"
        case .httpError(let code): return "HTTP \(code)"
        case .connectionFailed: return "could not connect"
        case .invalidURL: return "invalid URL"
        case .rpcError(let m): return m
        case .decodingFailed: return "not a Transmission RPC endpoint"
        case .redirected(let status, let location):
            return ConnectionDiagnostics.shortRedirect(status: status, location: location, server: server)
        case .accessSignInRequired(let reason): return ConnectionDiagnostics.shortAccess(reason)
        case .none: return error.localizedDescription
        }
    }
}

/// An `NSTextView` that draws greyed-out placeholder text while it is empty —
/// `NSTextView` has no built-in placeholder the way `NSTextField` does.
final class PlaceholderTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
