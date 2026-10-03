import AppKit

/// The Trackers tab of the detail pane: a read-only, sortable table of the
/// selected torrent's trackers — announce URL, status, time to the next
/// announce, and the seeder/leecher counts each tracker reports (the legacy
/// app's trackers list, minus its add/edit/remove actions).
///
/// Fetched on demand per selected torrent, like the Peers tab: only while the
/// tab is visible and exactly one torrent is selected, refreshed on each poll
/// with the selection (by tracker id) and focus preserved across reloads.
extension MainWindowController {
    /// Column identifiers for the trackers table. Raw values double as
    /// `TrackerSortKey`s (which are the `NSSortDescriptor` keys).
    enum TrackerColumn: String, CaseIterable {
        case name, status, updateIn, seeds, leechers

        var title: String {
            switch self {
            case .name: return "Tracker"
            case .status: return "Status"
            case .updateIn: return "Update In"
            case .seeds: return "Seeds"
            case .leechers: return "Leechers"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 260
            case .status: return 200
            case .updateIn: return 80
            case .seeds, .leechers: return 70
            }
        }

        var isNumeric: Bool { self == .updateIn || self == .seeds || self == .leechers }

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    // MARK: - Building

    private static let trackersColumnWidthsKey = "TrackersColumnWidths"

    func buildTrackersTable() -> NSScrollView {
        for column in TrackerColumn.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            trackersTable.addTableColumn(col)
        }
        restoreTrackersColumnWidths()
        NotificationCenter.default.addObserver(self, selector: #selector(trackersColumnResized(_:)),
                                               name: NSTableView.columnDidResizeNotification,
                                               object: trackersTable)

        trackersTable.usesAlternatingRowBackgroundColors = true
        trackersTable.allowsMultipleSelection = true
        trackersTable.rowHeight = 20
        trackersTable.dataSource = self
        trackersTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = trackersTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    private func restoreTrackersColumnWidths() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.trackersColumnWidthsKey) else { return }
        for col in trackersTable.tableColumns {
            if let width = dict[col.identifier.rawValue] as? CGFloat {
                col.width = width
            }
        }
    }

    @objc private func trackersColumnResized(_ notification: Notification) {
        var dict: [String: CGFloat] = [:]
        for col in trackersTable.tableColumns {
            dict[col.identifier.rawValue] = col.width
        }
        UserDefaults.standard.set(dict, forKey: Self.trackersColumnWidthsKey)
    }

    // MARK: - Fetching

    /// Refresh the Trackers tab for the current main-table selection. Fetches
    /// only when exactly one torrent is selected and the Trackers tab is
    /// visible; otherwise clears the table. Cheap to call on every poll and
    /// selection change — mirrors `loadPeersIfNeeded`.
    func loadTrackersIfNeeded() {
        let isTrackersTabVisible = detailTabView.selectedTabViewItem?.identifier as? String == "trackers"
        let selection = selectedTorrents
        guard isTrackersTabVisible, selection.count == 1, let torrent = selection.first else {
            if trackersTorrentId != nil || !trackers.isEmpty {
                trackersFetchTask?.cancel()
                trackersTorrentId = nil
                trackers = []
                reloadTrackersData()
            }
            updateTrackersTabLabel()
            return
        }

        // Changed torrent: drop the stale rows immediately.
        if trackersTorrentId != torrent.id {
            trackersTorrentId = torrent.id
            trackers = []
            reloadTrackersData()
            updateTrackersTabLabel()
        }

        guard let client = refresh.activeClient else { return }
        let id = torrent.id
        trackersFetchTask?.cancel()
        trackersFetchTask = Task { @MainActor in
            do {
                let fetched = try await client.fetchTrackers(id: id)
                guard !Task.isCancelled, self.trackersTorrentId == id else { return }
                self.applyFetchedTrackers(fetched)
            } catch {
                // Silent: the list poll surfaces connection errors already.
            }
        }
    }

    /// Store a freshly fetched tracker list, preserving the user's selection
    /// (by tracker id) and, via `reloadTrackersData`, focus.
    private func applyFetchedTrackers(_ fetched: [TrackerStatsInfo]) {
        let selectedIds = Set(trackersTable.selectedRowIndexes.compactMap { row in
            displayedTrackers.indices.contains(row) ? displayedTrackers[row].id : nil
        })
        trackers = fetched
        reloadTrackersData()
        updateTrackersTabLabel()
        guard !selectedIds.isEmpty else { return }
        let rows = IndexSet((0..<trackersTable.numberOfRows).filter {
            displayedTrackers.indices.contains($0) && selectedIds.contains(displayedTrackers[$0].id)
        })
        if rows != trackersTable.selectedRowIndexes {
            trackersTable.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// "Trackers (N)" while a torrent's trackers are loaded, plain "Trackers" otherwise.
    private func updateTrackersTabLabel() {
        guard let item = detailTabView.tabViewItems.first(where: { ($0.identifier as? String) == "trackers" }) else { return }
        item.label = trackersTorrentId != nil && !trackers.isEmpty ? "Trackers (\(trackers.count))" : "Trackers"
    }

    /// Re-derive `displayedTrackers` from `trackers` (the daemon's order, or the
    /// header sort) and reload, restoring focus — `reloadData()` can steal it.
    private func reloadTrackersData() {
        let restoreFocus = window?.firstResponder === trackersTable
        let descriptor = trackersTable.sortDescriptors.first
        let key = descriptor?.key.flatMap(TrackerSortKey.init(rawValue:))
        displayedTrackers = TrackerSortKey.sorted(trackers, by: key, ascending: descriptor?.ascending ?? true)
        trackersTable.reloadData()
        if restoreFocus { window?.makeFirstResponder(trackersTable) }
    }

    /// Re-sort after a header click. Clicks cycle ascending → descending →
    /// unsorted (the daemon's order), mirroring the Peers and Files tabs.
    func trackersSortDescriptorsDidChange(from old: [NSSortDescriptor]) {
        if let new = trackersTable.sortDescriptors.first, let prev = old.first,
           new.key == prev.key, new.ascending, !prev.ascending {
            trackersTable.sortDescriptors = []  // re-enters via the delegate and re-sorts
            return
        }
        reloadTrackersData()
    }

    // MARK: - Cell construction

    /// The `tableView(_:viewFor:row:)` body for the trackers table.
    func trackerCell(for tableColumn: NSTableColumn?, tracker: TrackerStatsInfo) -> NSView? {
        guard let tableColumn, let column = TrackerColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

        let id = NSUserInterfaceItemIdentifier("TrackerTextCell")
        let cell = (trackersTable.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
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
        case .name: value = tracker.announce
        case .status: value = tracker.statusText
        case .updateIn:
            if tracker.isUpdating {
                value = "Updating…"
            } else if let seconds = tracker.secondsUntilNextAnnounce() {
                value = Formatters.eta(seconds)
            } else {
                value = "–"
            }
        case .seeds: value = tracker.seederCount >= 0 ? "\(tracker.seederCount)" : ""
        case .leechers: value = tracker.leecherCount >= 0 ? "\(tracker.leecherCount)" : ""
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = column.isNumeric ? .right : .left
        cell.textField?.toolTip = column == .status || column == .name ? value : nil
        return cell
    }
}
