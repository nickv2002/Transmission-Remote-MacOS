import AppKit

/// The Peers tab of the detail pane: a flat, sortable table of the selected
/// torrent's connected peers — address, client, flags, progress, and transfer
/// rates (the legacy app's peers list minus its GeoIP/hostname extras).
///
/// Fetched on demand per selected torrent, like the Files tab: only while the
/// tab is visible and exactly one torrent is selected, refreshed on each poll
/// with the selection (by peer identity) and focus preserved across reloads.
extension MainWindowController {
    /// Column identifiers for the peers table. Raw values double as
    /// `PeerSortKey`s (which are the `NSSortDescriptor` keys).
    enum PeerColumn: String, CaseIterable {
        case address, client, flags, progress, down, up

        var title: String {
            switch self {
            case .address: return "Address"
            case .client: return "Client"
            case .flags: return "Flags"
            case .progress: return "Progress"
            case .down: return "↓ Speed"
            case .up: return "↑ Speed"
            }
        }

        var width: CGFloat {
            switch self {
            case .address: return 140
            case .client: return 150
            case .flags: return 70
            case .progress: return 90
            case .down, .up: return 80
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    // MARK: - Building

    private static let peersColumnWidthsKey = "PeersColumnWidths"

    func buildPeersTable() -> NSScrollView {
        for column in PeerColumn.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            peersTable.addTableColumn(col)
        }
        restorePeersColumnWidths()
        NotificationCenter.default.addObserver(self, selector: #selector(peersColumnResized(_:)),
                                               name: NSTableView.columnDidResizeNotification,
                                               object: peersTable)

        peersTable.usesAlternatingRowBackgroundColors = true
        peersTable.allowsMultipleSelection = true
        peersTable.rowHeight = 20
        peersTable.dataSource = self
        peersTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = peersTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    private func restorePeersColumnWidths() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.peersColumnWidthsKey) else { return }
        for col in peersTable.tableColumns {
            if let width = dict[col.identifier.rawValue] as? CGFloat {
                col.width = width
            }
        }
    }

    @objc private func peersColumnResized(_ notification: Notification) {
        var dict: [String: CGFloat] = [:]
        for col in peersTable.tableColumns {
            dict[col.identifier.rawValue] = col.width
        }
        UserDefaults.standard.set(dict, forKey: Self.peersColumnWidthsKey)
    }

    // MARK: - Fetching

    /// Refresh the Peers tab for the current main-table selection. Fetches
    /// only when exactly one torrent is selected and the Peers tab is visible;
    /// otherwise clears the table. Cheap to call on every poll and selection
    /// change — mirrors `loadFilesIfNeeded`.
    func loadPeersIfNeeded() {
        let isPeersTabVisible = detailTabView.selectedTabViewItem?.identifier as? String == "peers"
        let selection = selectedTorrents
        guard isPeersTabVisible, selection.count == 1, let torrent = selection.first else {
            if peersTorrentId != nil || !peers.isEmpty {
                peersFetchTask?.cancel()
                peersTorrentId = nil
                peers = []
                reloadPeersData()
            }
            return
        }

        // Changed torrent: drop the stale rows immediately so we don't show
        // another torrent's peers while the new ones load.
        if peersTorrentId != torrent.id {
            peersTorrentId = torrent.id
            peers = []
            reloadPeersData()
        }

        guard let client = refresh.activeClient else { return }
        let id = torrent.id
        peersFetchTask?.cancel()
        peersFetchTask = Task { @MainActor in
            do {
                let fetched = try await client.fetchPeers(id: id)
                guard !Task.isCancelled, self.peersTorrentId == id else { return }
                self.applyFetchedPeers(fetched)
            } catch {
                // Silent: the list poll surfaces connection errors already.
            }
        }
    }

    /// Store a freshly fetched peer list, preserving the user's selection (by
    /// peer identity — a sort or a peer swap can move a peer to another row)
    /// and, via `reloadPeersData`, focus.
    private func applyFetchedPeers(_ fetched: [TorrentPeer]) {
        let selectedIds = Set(peersTable.selectedRowIndexes.compactMap { row in
            displayedPeers.indices.contains(row) ? displayedPeers[row].id : nil
        })
        peers = fetched
        reloadPeersData()
        guard !selectedIds.isEmpty else { return }
        let rows = IndexSet((0..<peersTable.numberOfRows).filter {
            displayedPeers.indices.contains($0) && selectedIds.contains(displayedPeers[$0].id)
        })
        if rows != peersTable.selectedRowIndexes {
            peersTable.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// Re-derive `displayedPeers` from `peers` (the daemon's order, or the
    /// header sort) and reload, restoring focus — `reloadData()` can steal
    /// it, same as the Files tab's `reloadFilesData`.
    private func reloadPeersData() {
        let restoreFocus = window?.firstResponder === peersTable
        let descriptor = peersTable.sortDescriptors.first
        let key = descriptor?.key.flatMap(PeerSortKey.init(rawValue:))
        displayedPeers = PeerSortKey.sorted(peers, by: key, ascending: descriptor?.ascending ?? true)
        peersTable.reloadData()
        if restoreFocus { window?.makeFirstResponder(peersTable) }
    }

    /// Re-sort after the user clicks a column header. Header clicks cycle
    /// ascending → descending → unsorted (back to the daemon's order),
    /// mirroring the Files tab, since AppKit never clears a descriptor on its
    /// own.
    func peersSortDescriptorsDidChange(from old: [NSSortDescriptor]) {
        if let new = peersTable.sortDescriptors.first, let prev = old.first,
           new.key == prev.key, new.ascending, !prev.ascending {
            peersTable.sortDescriptors = []  // re-enters via the delegate and re-sorts
            return
        }
        reloadPeersData()
    }

    // MARK: - Cell construction

    /// The `tableView(_:viewFor:row:)` body for the peers table: render one
    /// peer for one column.
    func peerCell(for tableColumn: NSTableColumn?, peer: TorrentPeer) -> NSView? {
        guard let tableColumn, let column = PeerColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

        if column == .progress {
            let cell = (peersTable.makeView(withIdentifier: ProgressCellView.reuseIdentifier, owner: self) as? ProgressCellView)
                ?? {
                    let c = ProgressCellView()
                    c.identifier = ProgressCellView.reuseIdentifier
                    return c
                }()
            cell.configure(fraction: peer.progress,
                           color: peer.progress >= 1 ? .systemGreen : .controlAccentColor)
            return cell
        }

        // address / client / flags / rates: text cells.
        let id = NSUserInterfaceItemIdentifier("PeerTextCell")
        let cell = (peersTable.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            c.addSubview(tf)
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let value: String
        switch column {
        case .address: value = "\(peer.address):\(peer.port)"
        case .client: value = peer.clientName
        case .flags: value = peer.flagStr
        case .down: value = Formatters.speed(peer.rateToClient)
        case .up: value = Formatters.speed(peer.rateToPeer)
        case .progress: value = ""  // handled above
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = column == .down || column == .up ? .right : .left
        return cell
    }
}
