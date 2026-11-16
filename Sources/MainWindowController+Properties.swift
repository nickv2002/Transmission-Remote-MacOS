import AppKit

extension MainWindowController {
    /// Torrent ▸ Properties… (⌘I): shows the Properties tab for the targeted torrents and
    /// puts the keyboard in it. The right-clicked row wins when it is outside the selection.
    @objc func showPropertiesSelected(_ sender: Any?) {
        if let clicked = clickedTorrent(), !selectedTorrents.contains(where: { $0.id == clicked.id }),
           let row = (0..<tableView.numberOfRows).first(where: { torrentAt(row: $0)?.id == clicked.id }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        guard let item = detailTabView.tabViewItems.first(where: { ($0.identifier as? String) == "properties" }) else { return }
        detailTabView.selectTabViewItem(item)
        loadPropertiesIfNeeded()
        propertiesPane.requestFocus()
    }

    /// Points the Properties tab at the current selection (or nothing). Cheap to call on
    /// every poll and selection change: the same torrents are a no-op. While another tab
    /// is showing, an existing target is kept only for the same selection, so unsaved
    /// edits are still asked about when the selection moves on.
    func loadPropertiesIfNeeded() {
        let visible = detailTabView.selectedTabViewItem?.identifier as? String == "properties"
        let hashes = selectedTorrents.map(\.hashString)
        guard !hashes.isEmpty else { propertiesPane.retarget(nil); return }
        guard let client = refresh.activeClient else { return }
        let key = hashes.sorted().joined(separator: ",")
        guard visible || propertiesPane.target?.key == key else { propertiesPane.retarget(nil); return }
        propertiesPane.retarget(.init(service: client, hashes: hashes, serverID: refresh.activeServerConfig.id))
    }

    /// Edits can't be applied to another server, so a server switch drops them without asking.
    func resetPropertiesForInactiveServer() {
        guard let serverID = propertiesPane.serverID, serverID != refresh.activeServerConfig.id else { return }
        propertiesPane.reset()
        loadPropertiesIfNeeded()
    }

    /// Reselects the rows of `hashes` (the user chose to keep editing them).
    func reselect(hashes: [String]) {
        let wanted = Set(hashes)
        let rows = IndexSet((0..<tableView.numberOfRows).filter { wanted.contains(torrentAt(row: $0)?.hashString ?? "") })
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }
}
