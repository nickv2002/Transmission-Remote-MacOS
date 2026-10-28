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
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let scope = NSTextField(labelWithString: ServerSettingsScope.Storage.mac.rawValue + " · changes apply immediately")
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        scope.textColor = .secondaryLabelColor
        scope.setAccessibilityHelp(ServerSettingsScope.Storage.mac.help)

        let column = NSStackView(views: [scope] + generalRows + [separator] + incomingRows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(14, after: scope)
        column.setCustomSpacing(14, after: separator)
        separator.widthAnchor.constraint(equalToConstant: 400).isActive = true
        column.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: pane.topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 4),
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
