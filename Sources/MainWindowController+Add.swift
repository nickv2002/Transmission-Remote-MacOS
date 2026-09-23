import AppKit
import UniformTypeIdentifiers

/// Adding torrents: via a `.torrent` file (open panel), via a magnet/URL paste
/// box, and via drag-and-drop / Dock drop. All routes converge on an options
/// sheet (destination + start) and then `torrent-add`.
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
            self?.presentAddOptions(files: panel.urls, link: nil)
        }
    }

    /// Toolbar/menu: paste a magnet link or the URL of a `.torrent`.
    @objc func addLink(_ sender: Any?) {
        presentAddOptions(files: [], link: "")
    }

    /// Drag-and-drop / Dock drop of `.torrent` files.
    func addFiles(_ urls: [URL]) {
        let torrents = urls.filter { $0.pathExtension.lowercased() == "torrent" }
        guard !torrents.isEmpty else { return }
        window?.makeKeyAndOrderFront(nil)
        presentAddOptions(files: torrents, link: nil)
    }

    /// Dropped text — a magnet link or a `.torrent` URL.
    func addDroppedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("magnet:")
                || trimmed.hasPrefix("http://")
                || trimmed.hasPrefix("https://") else { return }
        window?.makeKeyAndOrderFront(nil)
        presentAddOptions(files: [], link: trimmed)
    }

    // MARK: - Options sheet

    /// One sheet shared by both routes: editable link field (link route only), a
    /// destination folder prefilled from the daemon's default, and a "Start when
    /// added" checkbox. `link == nil` means the file route.
    private func presentAddOptions(files: [URL], link: String?) {
        guard let window else { return }

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
                              method: TorrentFileRemoval) {
        Task { @MainActor in
            for url in files {
                do {
                    let base64 = try await Task.detached {
                        try Data(contentsOf: url).base64EncodedString()
                    }.value
                    performAdd(metainfo: base64, filename: nil, downloadDir: downloadDir, paused: paused,
                               sourceFileURL: url, method: method)
                } catch {
                    showError(TransmissionError.connectionFailed("Could not read \(url.lastPathComponent)."))
                }
            }
        }
    }

    private func performAdd(metainfo: String?, filename: String?, downloadDir: String, paused: Bool,
                            sourceFileURL: URL? = nil, method: TorrentFileRemoval = .none) {
        guard let client = refresh.activeClient else { return }
        Task { @MainActor in
            do {
                let outcome = try await client.addTorrent(
                    metainfoBase64: metainfo, filename: filename,
                    downloadDir: downloadDir, paused: paused)
                RecentFolders.record(downloadDir)
                refresh.refreshNow()
                if outcome.duplicate { self.showDuplicate(name: outcome.name) }
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
        let text = sender.draggingPasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, text.hasPrefix("magnet:") || text.hasPrefix("http://") || text.hasPrefix("https://") else {
            return nil
        }
        return text
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
