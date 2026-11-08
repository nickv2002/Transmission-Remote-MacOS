import AppKit

/// Settings ▸ App ▸ General: a "General" group (poll interval, auto-update check,
/// Files/Info tab options) over an "Incoming Torrents" group (default add-file
/// handling, add-options sheet, clipboard pickup, default-app rows).
///
/// Every control applies immediately — no Apply button — through the editor's
/// write-through setters, so a General change never touches any server's
/// pending edits or dirty state.
@MainActor
final class SettingsGeneralPane: NSObject, NSTextFieldDelegate {
    /// Runs an editor setter and persists + applies the config it returns.
    private let apply: ((inout SettingsEditor) -> AppConfig) -> Void
    private let read: () -> SettingsEditor
    private(set) var view = NSView()

    let refreshField = NSTextField()
    private let refreshStepper = NSStepper()
    private let autoCheckBox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let removeFileMethodPopup = NSPopUpButton()
    private let showAddOptionsBox = NSButton(checkboxWithTitle: "Show options when adding torrents", target: nil, action: nil)
    private let foldersFirstBox = NSButton(checkboxWithTitle: "List folders before files in the Files tab", target: nil, action: nil)
    private let pieceMapBox = NSButton(checkboxWithTitle: "Show piece map in the Info tab", target: nil, action: nil)
    private let peerCountryBox = NSButton(checkboxWithTitle: "Show peer countries in the Peers tab", target: nil, action: nil)
    private let peerCountryStatus = NSTextField(wrappingLabelWithString: "")
    private let peerCountryButton = NSButton(title: "Update Now", target: nil, action: nil)
    private var geoObserver: NSObjectProtocol?
    private let clipboardBox = NSButton(checkboxWithTitle: "Add magnet links copied to the clipboard", target: nil, action: nil)
    /// "Magnet links: <app>" / ".torrent files: <app>" status + Make Default,
    /// keyed by kind. These act immediately (system-wide).
    private var handlerStatusLabels: [DefaultHandlers.Kind: NSTextField] = [:]
    private var handlerButtons: [DefaultHandlers.Kind: NSButton] = [:]
    weak var window: NSWindow?

    init(read: @escaping () -> SettingsEditor, apply: @escaping ((inout SettingsEditor) -> AppConfig) -> Void) {
        self.read = read
        self.apply = apply
        super.init()
        view = build()
    }

    private func build() -> NSView {
        let pane = NSView()
        refreshField.translatesAutoresizingMaskIntoConstraints = false
        refreshField.target = self
        refreshField.action = #selector(refreshChanged)
        refreshField.delegate = self
        refreshField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        refreshStepper.target = self
        refreshStepper.action = #selector(stepperChanged)
        refreshStepper.minValue = 1
        refreshStepper.maxValue = 600
        refreshStepper.increment = 1
        refreshStepper.valueWraps = false
        autoCheckBox.target = self
        autoCheckBox.action = #selector(autoCheckChanged)
        removeFileMethodPopup.target = self
        removeFileMethodPopup.action = #selector(removeFileMethodChanged)
        removeFileMethodPopup.configure(for: TorrentFileRemoval.self)
        showAddOptionsBox.target = self
        showAddOptionsBox.action = #selector(showAddOptionsChanged)
        showAddOptionsBox.toolTip = "When off, clicked magnet links, opened .torrent files, drops, and "
            + "clipboard links are added straight away to the server's default folder and started."
        foldersFirstBox.target = self
        foldersFirstBox.action = #selector(foldersFirstChanged)
        foldersFirstBox.toolTip = "When sorting the Files tab by a column, keep folders above files. "
            + "Off mixes them by the sort order."
        pieceMapBox.target = self
        pieceMapBox.action = #selector(pieceMapChanged)
        pieceMapBox.toolTip = "Show the progress bar and map of downloaded pieces at the top of the "
            + "Info tab. Off also stops fetching the piece bitfield."
        peerCountryBox.target = self
        peerCountryBox.action = #selector(peerCountryChanged)
        peerCountryBox.toolTip = "Downloads a free country database (about 5 MB) from DB-IP.com and "
            + "adds a Country column to the Peers tab. Turning this off deletes the download."
        peerCountryStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        peerCountryStatus.textColor = .secondaryLabelColor
        peerCountryStatus.preferredMaxLayoutWidth = 420
        peerCountryButton.controlSize = .small
        peerCountryButton.bezelStyle = .push
        peerCountryButton.target = self
        peerCountryButton.action = #selector(peerCountryUpdate)
        geoObserver = NotificationCenter.default.addObserver(forName: .geoIPDatabaseDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPeerCountryStatus() }
        }
        clipboardBox.target = self
        clipboardBox.action = #selector(clipboardChanged)
        clipboardBox.toolTip = "When the app becomes active, add a magnet link, .torrent URL, or "
            + "info-hash that was newly copied to the clipboard."

        let generalRows: [NSView] = [
            sectionHeader("General"),
            stack([label("Refresh every:"), refreshField, refreshStepper, label("seconds")]),
            autoCheckBox,
            foldersFirstBox,
            pieceMapBox,
        ]
        var incomingRows: [NSView] = [
            sectionHeader("Incoming Torrents"),
            stack([label("Default when adding torrents:"), removeFileMethodPopup]),
            showAddOptionsBox,
            caption("Each server’s Transfers tab has its own “Start new torrents automatically” default, stored on the server."),
            clipboardBox,
        ]
        for kind in DefaultHandlers.Kind.allCases {
            let status = NSTextField(labelWithString: "")
            status.textColor = .secondaryLabelColor
            let button = NSButton(title: "Make Default", target: self, action: #selector(makeDefaultHandler(_:)))
            button.controlSize = .small
            button.bezelStyle = .push
            handlerStatusLabels[kind] = status
            handlerButtons[kind] = button
            incomingRows.append(stack([label(kind.title), status, button]))
        }
        let advancedRows: [NSView] = [
            sectionHeader("Advanced"),
            peerCountryBox,
            stack([peerCountryStatus, peerCountryButton]),
            attributionCaption(),
        ]
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let scope = NSTextField(labelWithString: ServerSettingsScope.Storage.mac.rawValue + " · changes apply immediately")
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        scope.textColor = .secondaryLabelColor
        scope.setAccessibilityHelp(ServerSettingsScope.Storage.mac.help)

        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        separator2.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let column = NSStackView(views: [scope] + generalRows + [separator] + incomingRows + [separator2] + advancedRows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(14, after: scope)
        column.setCustomSpacing(14, after: separator)
        column.setCustomSpacing(14, after: separator2)
        separator.widthAnchor.constraint(equalToConstant: 400).isActive = true
        column.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: pane.topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 0),
            column.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
        ])
        return pane
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let l = label(text)
        l.font = .boldSystemFont(ofSize: 12)
        return l
    }

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 420
        return l
    }

    /// Country-data credit with clickable links (DB-IP's CC BY 4.0 attribution).
    private func attributionCaption() -> NSTextField {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let result = NSMutableAttributedString(string: "Country data: ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        func link(_ text: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .link: URL(string: url)!])
        }
        func plain(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        result.append(link("IP to Country Lite", "https://db-ip.com/db/download/ip-to-country-lite"))
        result.append(plain(" by "))
        result.append(link("DB-IP.com", "https://db-ip.com"))
        result.append(plain(", licensed "))
        result.append(link("CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/"))
        result.append(plain(". Nothing is downloaded unless this is on."))
        let l = NSTextField(labelWithAttributedString: result)
        l.allowsEditingTextAttributes = true
        l.isSelectable = true
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 420
        return l
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        s.alignment = .firstBaseline
        return s
    }

    /// Refresh every control from the editor.
    func reload() {
        let editor = read()
        refreshField.stringValue = String(format: "%g", editor.refreshSeconds)
        refreshStepper.doubleValue = editor.refreshSeconds
        autoCheckBox.state = editor.autoCheckForUpdates ? .on : .off
        removeFileMethodPopup.select(editor.removeTorrentFileMethod)
        showAddOptionsBox.state = editor.showAddOptions ? .on : .off
        foldersFirstBox.state = editor.filesFoldersFirst ? .on : .off
        pieceMapBox.state = editor.showPieceMap ? .on : .off
        clipboardBox.state = editor.addLinksFromClipboard ? .on : .off
        peerCountryBox.state = editor.showPeerCountry ? .on : .off
        reloadPeerCountryStatus()
        reloadHandlerStatus()
    }

    /// Refresh the "Magnet links / .torrent files: <app>" rows from Launch Services.
    func reloadHandlerStatus() {
        for kind in DefaultHandlers.Kind.allCases {
            let status = DefaultHandlers.status(of: kind)
            switch status {
            case .thisApp: handlerStatusLabels[kind]?.stringValue = "Transmission Remote ✓"
            case .other(let name): handlerStatusLabels[kind]?.stringValue = name
            case .none: handlerStatusLabels[kind]?.stringValue = "No app"
            }
            handlerButtons[kind]?.isHidden = status == .thisApp
        }
    }

    /// Status line + button under the peer-country checkbox, from `GeoIPStore.shared`.
    func reloadPeerCountryStatus() {
        let enabled = peerCountryBox.state == .on
        let state = GeoIPStore.shared.state
        var text = "Off. Nothing is downloaded."
        var button: String?
        if enabled {
            switch state {
            case .absent: text = "Not downloaded yet."; button = "Download"
            case .loading: text = "Loading…"
            case .downloading: text = "Downloading…"
            case .ready(let date, let ranges):
                text = "Downloaded \(date.formatted(date: .abbreviated, time: .omitted)) · \(ranges.formatted()) ranges"
                button = "Update Now"
            case .failed(let message): text = message; button = "Retry"
            }
        }
        peerCountryStatus.stringValue = text
        peerCountryButton.title = button ?? ""
        peerCountryButton.isHidden = button == nil
    }

    @objc private func peerCountryChanged() {
        let on = peerCountryBox.state == .on
        apply { $0.setShowPeerCountry(on) }
        if on {
            GeoIPStore.shared.loadIfPresent()
            if GeoIPStore.shared.state == .absent { GeoIPStore.shared.download() }
        } else {
            GeoIPStore.shared.remove()
        }
        reloadPeerCountryStatus()
    }

    @objc private func peerCountryUpdate() {
        GeoIPStore.shared.download()
        reloadPeerCountryStatus()
    }

    @objc private func makeDefaultHandler(_ sender: NSButton) {
        guard let kind = handlerButtons.first(where: { $0.value === sender })?.key else { return }
        Task { @MainActor in
            do {
                try await DefaultHandlers.makeDefault(kind)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't change the default app"
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
            }
            reloadHandlerStatus()
        }
    }

    @objc private func foldersFirstChanged() { let on = foldersFirstBox.state == .on; apply { $0.setFilesFoldersFirst(on) } }
    @objc private func pieceMapChanged() { let on = pieceMapBox.state == .on; apply { $0.setShowPieceMap(on) } }
    @objc private func showAddOptionsChanged() { let on = showAddOptionsBox.state == .on; apply { $0.setShowAddOptions(on) } }
    @objc private func clipboardChanged() { let on = clipboardBox.state == .on; apply { $0.setAddLinksFromClipboard(on) } }
    @objc private func autoCheckChanged() { let on = autoCheckBox.state == .on; apply { $0.setAutoCheckForUpdates(on) } }

    @objc private func removeFileMethodChanged() {
        let method = removeFileMethodPopup.selectedCase(default: TorrentFileRemoval.none)
        apply { $0.setRemoveTorrentFileMethod(method) }
    }

    /// Applies on end-of-edit only, not per keystroke — typing "10" would otherwise apply "1" first.
    @objc private func refreshChanged() {
        let seconds = max(1, Double(refreshField.stringValue) ?? read().refreshSeconds)
        apply { $0.setRefreshSeconds(seconds) }
        refreshStepper.doubleValue = read().refreshSeconds
        refreshField.stringValue = String(format: "%g", read().refreshSeconds)
    }

    @objc private func stepperChanged() {
        let seconds = max(1, refreshStepper.doubleValue)
        apply { $0.setRefreshSeconds(seconds) }
        refreshField.stringValue = String(format: "%g", read().refreshSeconds)
    }

    /// Reflect the in-progress typed value on the stepper, without applying it.
    func controlTextDidChange(_ obj: Notification) {
        if let value = Double(refreshField.stringValue) { refreshStepper.doubleValue = max(1, value) }
    }
}
