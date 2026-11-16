import AppKit

extension MainWindowController {
    /// Torrent ▸ Properties… (⌘I) for the targeted torrents (the right-clicked row
    /// wins when it is outside the selection). Each window keeps the client and the
    /// torrent hashes captured here.
    @objc func showPropertiesSelected(_ sender: Any?) {
        let hashes = selectionForAction().map(\.hashString)
        guard !hashes.isEmpty, let client = refresh.activeClient else { return }
        openPropertiesWindow(hashes: hashes, service: client, serverID: refresh.activeServerConfig.id) { [weak self] in
            if self?.refresh.activeClient === client { self?.refresh.refreshNow() }
        }
    }

    /// One window per set of torrents: the same set brings its window to the front;
    /// another set opens a new window, cascaded from the last one.
    @discardableResult
    func openPropertiesWindow(hashes: [String], service: any TorrentPropertiesService, serverID: UUID?,
                              display: Bool = true, onApplied: @escaping () -> Void) -> TorrentPropertiesWindowController {
        let key = TorrentPropertiesWindowController.key(for: hashes)
        if let existing = propertiesWindows[key] {
            if display { existing.showWindow(nil) }
            return existing
        }
        let controller = TorrentPropertiesWindowController(service: service, hashes: hashes, serverID: serverID)
        controller.onApplied = onApplied
        controller.onClose = { [weak self] in self?.propertiesWindows[key] = nil }
        let others = propertiesWindows.values.compactMap(\.window)
        let previous = others.first { $0.isKeyWindow } ?? others.last
        propertiesWindows[key] = controller
        controller.place(cascadingFrom: previous)
        if display { controller.showWindow(nil) }
        controller.load()
        return controller
    }

    /// Edits can't be applied to another server, so a server switch closes the
    /// windows opened on the previous one, without asking.
    func closePropertiesWindowsForInactiveServers() {
        let active = refresh.activeServerConfig.id
        for controller in propertiesWindows.values where controller.serverID != active {
            controller.close()
        }
    }
}
