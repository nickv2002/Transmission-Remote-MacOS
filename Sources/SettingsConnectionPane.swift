import AppKit

/// Settings ▸ <server> ▸ Connection (name, hosts, port, HTTPS, RPC path,
/// credentials, path mappings) plus the speed-menu presets shown on the Speed
/// tab. All of it is stored on this Mac, in the server's `ServerConfig`.
///
/// Edits sync into the editor on every keystroke (so Apply enables at once)
/// without normalizing the name; end-of-edit normalizes it. Neither ever
/// reloads the sidebar table, which would drop its selection mid-edit.
@MainActor
final class SettingsConnectionPane: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    /// (fields as typed, normalize name?) — the shell stores it in the editor.
    var onEdit: ((ServerConfig, Bool) -> Void)?
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
    private var detailFields: [NSControl] = []
    private var isLoading = false

    override init() {
        super.init()
        view = buildForm()
        presetsView = buildPresets()
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
        hostField.placeholderString = "host, or comma/line-separated list of fallbacks"
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
        usernameField.placeholderString = "(none)"
        detailFields = [nameField, hostField, portField, httpsCheckbox, rpcPathField, usernameField, passwordField]

        let scope = label(ServerSettingsScope.Storage.mac.rawValue)
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        scope.textColor = .secondaryLabelColor
        scope.setAccessibilityHelp(ServerSettingsScope.Storage.mac.help)

        let grid = NSGridView(views: [
            [NSView(), scope],
            [label("Name:"), nameField],
            [label("Host:"), hostField],
            [label("Port:"), portField],
            [NSView(), httpsCheckbox],
            [label("RPC Path:"), rpcPathField],
            [label("Username:"), usernameField],
            [label("Password:"), passwordField],
            [label("Path Mappings:"), buildPathMappingsEditor()],
            [NSView(), caption("Remote→local, one per line.\ne.g.  /video=/Volumes/Video\nLocal side also accepts smb://host/share/path, resolved to wherever that share is currently mounted.")],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 300
        // The mappings editor is multi-line; top-align its row.
        grid.row(at: 8).yPlacement = .top
        grid.row(at: 8).rowAlignment = .none
        let pane = NSView()
        pane.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
        ])
        return pane
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

    /// Show `server` (nil clears and disables the form).
    func load(_ server: ServerConfig?) {
        isLoading = true
        defer { isLoading = false }
        for field in detailFields { field.isEnabled = server != nil }
        pathMappingsView.isEditable = server != nil
        nameField.stringValue = server?.name ?? ""
        hostField.stringValue = server?.host ?? ""
        portField.stringValue = server.map { String($0.port) } ?? ""
        httpsCheckbox.state = server?.useHTTPS == true ? .on : .off
        rpcPathField.stringValue = server?.rpcPath ?? ""
        usernameField.stringValue = server?.username ?? ""
        passwordField.stringValue = server?.password ?? ""
        pathMappingsView.string = server.map { PathMapping.format($0.pathMappings) } ?? ""
        downPresetsField.stringValue = server.map { SpeedPresets.format($0.downSpeedPresets) } ?? ""
        upPresetsField.stringValue = server.map { SpeedPresets.format($0.upSpeedPresets) } ?? ""
    }

    /// The form's current text as a `ServerConfig` (its id is the editor row's
    /// concern). Also what Test Connection probes, so unsaved edits can be tested.
    func currentServer(rawName: Bool = false) -> ServerConfig {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let path = rpcPathField.stringValue.trimmingCharacters(in: .whitespaces)
        return ServerConfig(
            name: rawName ? nameField.stringValue : (name.isEmpty ? host : name),
            host: host,
            port: Int(portField.stringValue) ?? 9091,
            useHTTPS: httpsCheckbox.state == .on,
            rpcPath: path.isEmpty ? "/transmission/rpc" : path,
            username: usernameField.stringValue.isEmpty ? nil : usernameField.stringValue,
            password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue,
            pathMappings: PathMapping.parse(pathMappingsView.string),
            downSpeedPresets: SpeedPresets.parse(downPresetsField.stringValue),
            upSpeedPresets: SpeedPresets.parse(upPresetsField.stringValue))
    }

    @objc private func fieldEnded() {
        guard !isLoading else { return }
        onEdit?(currentServer(), true)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isLoading else { return }
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
                    return "✗  \(endpointLabel(r.server)) — \(shortError(r.error))"
                }
            }.joined(separator: "\n")
        }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// A terse failure reason for the per-host list.
    static func shortError(_ error: Error?) -> String {
        guard let error else { return "no response" }
        switch error as? TransmissionError {
        case .authenticationFailed: return "auth failed (check username/password)"
        case .httpError(404): return "no RPC at that path (404)"
        case .httpError(let code): return "HTTP \(code)"
        case .connectionFailed: return "could not connect"
        case .invalidURL: return "invalid URL"
        case .rpcError(let m): return m
        case .decodingFailed: return "not a Transmission RPC endpoint"
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
