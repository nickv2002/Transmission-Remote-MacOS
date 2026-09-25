import AppKit
import UniformTypeIdentifiers

/// One pending add: `.torrent` files, or a magnet/URL link.
enum AddRequest: Equatable {
    case files([URL])
    case link(String)
    /// A link picked up from the clipboard. Always confirmed with the sheet,
    /// even with "Show options" off: a 40-hex string could just as well be a
    /// copied git SHA, and that shouldn't silently add a torrent.
    case clipboardLink(String)

    var link: String? {
        switch self {
        case .files: return nil
        case .link(let link), .clipboardLink(let link): return link
        }
    }

    var isClipboard: Bool {
        if case .clipboardLink = self { return true }
        return false
    }
}

/// Adding torrents: via a `.torrent` file (open panel), via a magnet/URL paste
/// box, via drag-and-drop / Dock drop, via a clicked `magnet:` link or opened
/// `.torrent` (Launch Services), and via the clipboard. All routes converge on an
/// options sheet (destination + start) — or, with "Show options" off in Settings,
/// straight to `torrent-add` — and then `torrent-add`.
///
/// Everything except the explicit "Add Magnet or URL…" box goes through a FIFO
/// (`pendingAdds`) that waits out the initial connect: a magnet click that
/// launches the app arrives before the first handshake, when neither the client
/// nor the daemon's default download folder is known yet. The queue also shows
/// one sheet at a time, so several links clicked in a row are handled in turn.
extension MainWindowController {
    // MARK: - Entry points

    /// Toolbar/menu: pick one or more `.torrent` files.
    @objc func addFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add"
        panel.message = "Choose .torrent files to add."
        if let type = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [type]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.enqueueAdd(.files(panel.urls))
        }
    }

    /// Toolbar/menu: paste a magnet link or the URL of a `.torrent`. Always shows
    /// the sheet (it's where the link gets typed), bypassing the queue.
    @objc func addLink(_ sender: Any?) {
        presentAddOptions(files: [], link: "")
    }

    /// Drag-and-drop of `.torrent` files.
    func addFiles(_ urls: [URL]) {
        let torrents = urls.filter { $0.pathExtension.lowercased() == "torrent" }
        guard !torrents.isEmpty else { return }
        window?.makeKeyAndOrderFront(nil)
        enqueueAdd(.files(torrents))
    }

    /// Dropped text — a magnet link or a `.torrent` URL.
    func addDroppedText(_ text: String) {
        guard let link = TorrentLink.acceptable(text) else { return }
        window?.makeKeyAndOrderFront(nil)
        enqueueAdd(.link(link))
    }

    /// Launch Services hand-off: a clicked `magnet:` link (browser) or a
    /// double-clicked / Dock-dropped / "Open With" `.torrent` file.
    func handleOpened(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "torrent" }
        let links = urls.filter { !$0.isFileURL }.compactMap { TorrentLink.acceptable($0.absoluteString) }
        guard !files.isEmpty || !links.isEmpty else { return }
        bringToFront()
        if !files.isEmpty { enqueueAdd(.files(files)) }
        for link in links { enqueueAdd(.link(link)) }
    }

    /// On activation: add a torrent link newly copied to the clipboard (Settings
    /// opt-in). Only reads the pasteboard when its change count moved, and never
    /// clears it (unlike the legacy app).
    func checkClipboardForLink() {
        let pasteboard = NSPasteboard.general
        guard addLinksFromClipboard, pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
              let link = TorrentLink.normalize(text) else { return }
        enqueueAdd(.clipboardLink(link))
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Queue

    /// Seconds within which the same link arriving again is treated as a repeat.
    private static let repeatLinkWindow: TimeInterval = 10

    /// Queue an add; it's shown/performed once connected and no queued sheet is up.
    func enqueueAdd(_ request: AddRequest) {
        if let link = request.link {
            // Keyed on the info-hash, so a copied and a clicked copy of the same
            // magnet match even if their `dn` percent-encoding differs.
            let key = TorrentLink.identity(of: link)
            let now = Date()
            recentAddLinks.removeAll { now.timeIntervalSince($0.at) > Self.repeatLinkWindow }
            guard !recentAddLinks.contains(where: { $0.link == key }),
                  !pendingAdds.contains(where: { $0.link.map(TorrentLink.identity) == key }) else { return }
            recentAddLinks.append((key, now))
        }
        pendingAdds.append(request)
        if !canDrainAdds {
            showToast("Will add once connected to \(refresh.currentServerName)…")
        }
        drainPendingAdds()
    }

    /// Adds wait out the connect (so the client and default folder are known);
    /// once connected — or once the connection has definitively failed, so the
    /// user sees the failure rather than a silently stuck queue — they proceed.
    private var canDrainAdds: Bool {
        switch refresh.state {
        case .idle, .connecting: return false
        case .connected, .failed: return true
        }
    }

    /// Show/perform queued adds in order: one sheet at a time, or all at once
    /// when the options sheet is turned off.
    func drainPendingAdds() {
        while canDrainAdds, !isPresentingQueuedAdd, !pendingAdds.isEmpty {
            let request = pendingAdds.removeFirst()
            if showAddOptions || request.isClipboard {
                isPresentingQueuedAdd = true
                let onFinish: () -> Void = { [weak self] in
                    self?.isPresentingQueuedAdd = false
                    self?.drainPendingAdds()
                }
                switch request {
                case .files(let urls): presentAddOptions(files: urls, link: nil, onFinish: onFinish)
                case .link(let link), .clipboardLink(let link):
                    presentAddOptions(files: [], link: link, onFinish: onFinish)
                }
            } else {
                addWithoutOptions(request)
            }
        }
    }

    /// "Show options" off: add to the daemon's default folder, started, with the
    /// Settings default for the `.torrent` file — like the legacy app with
    /// `ShowAddTorrentWindow` unchecked.
    private func addWithoutOptions(_ request: AddRequest) {
        let dest = refresh.defaultDownloadDir ?? ""
        switch request {
        case .files(let urls):
            addFromFiles(urls, downloadDir: dest, paused: false, method: removeTorrentFileMethod, confirm: true)
        case .link(let link), .clipboardLink(let link):
            performAdd(metainfo: nil, filename: link, downloadDir: dest, paused: false, confirm: true)
        }
    }

    // MARK: - Options sheet

    /// One sheet shared by both routes: editable link field (link route only), a
    /// destination folder prefilled from the daemon's default, and a "Start when
    /// added" checkbox. `link == nil` means the file route.
    /// `onFinish` runs once the sheet is dismissed (either button) — or right
    /// away if there's no window to show it on — so the queue can advance.
    private func presentAddOptions(files: [URL], link: String?, onFinish: (() -> Void)? = nil) {
        guard let window else { onFinish?(); return }

        let alert = NSAlert()
        if link != nil {
            alert.messageText = "Add Torrent Link"
        } else {
            alert.messageText = files.count == 1 ? "Add Torrent" : "Add \(files.count) Torrents"
        }

        // Accessory: vertical stack of labelled rows.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        var linkField: NSTextField?
        if let link {
            stack.addArrangedSubview(makeLabel("Magnet link or URL of a .torrent file:"))
            let field = NSTextField(string: link)
            field.placeholderString = "magnet:?xt=… or https://…/file.torrent"
            field.widthAnchor.constraint(equalToConstant: 460).isActive = true
            stack.addArrangedSubview(field)
            linkField = field
        } else {
            let names = files.map(\.lastPathComponent).joined(separator: "\n")
            let label = makeLabel(names)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 460).isActive = true
            stack.addArrangedSubview(label)
        }

        stack.addArrangedSubview(makeLabel("Destination folder on the server:"))
        // Same folder history the Move dialog reads/writes (`RecentFolders`),
        // plus every folder a current torrent already lives in — so the list is
        // useful the first time, not just after using Add once.
        let candidates = RecentFolders.candidates(extra: torrents.map(\.normalizedDownloadDir))
        let destField = NSComboBox()
        destField.stringValue = refresh.defaultDownloadDir ?? candidates.first ?? ""
        destField.placeholderString = "Server download directory"
        destField.lineBreakMode = .byTruncatingHead
        destField.addItems(withObjectValues: candidates)
        destField.completes = true
        destField.numberOfVisibleItems = 10
        destField.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(destField)

        if let free = refresh.freeSpace, free >= 0 {
            let freeLabel = makeLabel("Free space on server: \(Formatters.size(free))")
            freeLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(freeLabel)
        }

        let startCheck = NSButton(checkboxWithTitle: "Start when added", target: nil, action: nil)
        startCheck.state = .on
        stack.addArrangedSubview(startCheck)

        // Per-add override of the Settings default — only meaningful on the file
        // route (there's no local file to remove for a magnet/URL). Seeded from
        // the current Settings default.
        var removeMethodPopup: NSPopUpButton?
        if link == nil {
            stack.addArrangedSubview(makeLabel("Torrent file after adding:"))
            let popup = NSPopUpButton()
            popup.addItems(withTitles: TorrentFileRemoval.allCases.map(\.displayName))
            popup.selectItem(at: TorrentFileRemoval.allCases.firstIndex(of: removeTorrentFileMethod) ?? 0)
            stack.addArrangedSubview(popup)
            removeMethodPopup = popup
        }

        // Wrap in a sized container so the alert lays the accessory out correctly.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 460).isActive = true
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: 460, height: stack.fittingSize.height)
        alert.accessoryView = container

        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = linkField ?? destField

        alert.beginSheetModal(for: window) { [weak self] response in
            defer { onFinish?() }
            destField.validateEditing()
            guard response == .alertFirstButtonReturn else { return }
            let dest = destField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let paused = startCheck.state != .on
            if linkField != nil {
                let text = (linkField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                self?.performAdd(metainfo: nil, filename: text, downloadDir: dest, paused: paused)
            } else {
                // Snapshot the removal choice at confirm time so changing the
                // popup mid-add can't retarget an in-flight deletion.
                let allCases = TorrentFileRemoval.allCases
                let index = removeMethodPopup?.indexOfSelectedItem ?? 0
                let method = allCases.indices.contains(index) ? allCases[index] : .none
                self?.addFromFiles(files, downloadDir: dest, paused: paused, method: method)
            }
        }
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.isSelectable = false
        return label
    }

    // MARK: - Performing the add

    private func addFromFiles(_ files: [URL], downloadDir: String, paused: Bool,
                              method: TorrentFileRemoval, confirm: Bool = false) {
        Task { @MainActor in
            for url in files {
                do {
                    let base64 = try await Task.detached {
                        try Data(contentsOf: url).base64EncodedString()
                    }.value
                    performAdd(metainfo: base64, filename: nil, downloadDir: downloadDir, paused: paused,
                               sourceFileURL: url, method: method, confirm: confirm)
                } catch {
                    showError(TransmissionError.connectionFailed("Could not read \(url.lastPathComponent)."))
                }
            }
        }
    }

    /// `confirm` shows a brief "Added …" toast — for adds made without the
    /// options sheet, which otherwise give no sign anything happened.
    private func performAdd(metainfo: String?, filename: String?, downloadDir: String, paused: Bool,
                            sourceFileURL: URL? = nil, method: TorrentFileRemoval = .none,
                            confirm: Bool = false) {
        guard let client = refresh.activeClient else {
            showError(TransmissionError.connectionFailed(
                "Not connected to \(refresh.currentServerName), so the torrent wasn't added."))
            return
        }
        Task { @MainActor in
            do {
                let outcome = try await client.addTorrent(
                    metainfoBase64: metainfo, filename: filename,
                    downloadDir: downloadDir, paused: paused)
                RecentFolders.record(downloadDir)
                refresh.refreshNow()
                if outcome.duplicate {
                    self.showDuplicate(name: outcome.name)
                } else if confirm {
                    self.showToast("Added “\(outcome.name)”")
                }
                // The daemon accepted it (a duplicate counts as success) — honor
                // the removal choice captured when the dialog was confirmed.
                if method != .none, let sourceFileURL {
                    do {
                        _ = try await Task.detached {
                            try removeTorrentFile(at: sourceFileURL, method: method)
                        }.value
                    } catch {
                        // The torrent was already added — this is a distinct
                        // failure from an add failure, so don't imply retrying
                        // the add would help.
                        self.showError(error, title: "Torrent added, but couldn't remove file")
                    }
                }
            } catch {
                self.showError(error)
            }
        }
    }

    private func showDuplicate(name: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Already Added"
        alert.informativeText = "“\(name)” is already in Transmission."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

/// A top-level content view that accepts dropped `.torrent` files and magnet/URL
/// text and hands them to the window controller.
final class DropView: NSView {
    /// Called with dropped file URLs (`.torrent`).
    var onDropFiles: (([URL]) -> Void)?
    /// Called with dropped text (a magnet link or URL).
    var onDropText: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func torrentURLs(in sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType(filenameExtension: "torrent")?.identifier ?? "org.bittorrent.torrent"],
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls
    }

    private func droppedText(in sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .string).flatMap(TorrentLink.acceptable)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (!torrentURLs(in: sender).isEmpty || droppedText(in: sender) != nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = torrentURLs(in: sender)
        if !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }
        if let text = droppedText(in: sender) {
            onDropText?(text)
            return true
        }
        return false
    }
}
