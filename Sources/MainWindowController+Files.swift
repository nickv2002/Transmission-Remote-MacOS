import AppKit
import Quartz

/// The Files tab of the detail pane: a directory tree (`NSOutlineView`) of the
/// torrent's files. Folder rows aggregate their subtree (size, progress, a
/// tri-state "wanted" checkbox, a shared priority), and a folder action
/// applies to every file beneath it via `files-wanted` / `priority-*` on its
/// file indices.
///
/// The tree is derived each poll from the flat `[TorrentFile]` fetch by
/// `TorrentFileTree` (see that file for the model); `reloadFilesData()` below
/// is where expansion, selection, and focus survive the refresh.
extension MainWindowController {
    /// Column identifiers for the files outline.
    enum FileColumn: String, CaseIterable {
        case wanted, name, size, progress, priority

        var title: String {
            switch self {
            case .wanted: return ""
            case .name: return "Name"
            case .size: return "Size"
            case .progress: return "Progress"
            case .priority: return "Priority"
            }
        }

        var width: CGFloat {
            switch self {
            case .wanted: return 26
            case .name: return 320
            case .size: return 80
            case .progress: return 90
            case .priority: return 70
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    // MARK: - Building

    private static let filesColumnWidthsKey = "FilesColumnWidths"

    func buildFilesOutline() -> NSScrollView {
        for column in FileColumn.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            if column != .wanted {
                col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            filesOutline.addTableColumn(col)
            // Disclosure triangles + per-level indentation live in Name.
            if column == .name { filesOutline.outlineTableColumn = col }
        }
        restoreFilesColumnWidths()
        NotificationCenter.default.addObserver(self, selector: #selector(filesColumnResized(_:)),
                                               name: NSTableView.columnDidResizeNotification,
                                               object: filesOutline)

        filesOutline.indentationPerLevel = 14
        // Expansion is session-only, tracked by folder path (see the outline
        // delegate below) — AppKit's autosave is keyed off persistent objects
        // and would needlessly survive launches.
        filesOutline.autosaveExpandedItems = false
        filesOutline.usesAlternatingRowBackgroundColors = true
        filesOutline.allowsMultipleSelection = true
        filesOutline.rowHeight = 20
        filesOutline.dataSource = self
        filesOutline.delegate = self
        // Outside-app drag-out to Finder needs `.copy` granted via the
        // `NSDraggingSource` delegate method `FilesOutlineView` overrides below
        // (`draggingSession(_:sourceOperationMaskFor:)`) — see the identical note on
        // `TorrentTableView` in `MainWindowController.swift` for how this was confirmed.
        filesOutline.target = self
        filesOutline.doubleAction = #selector(didDoubleClickFileRow)
        filesOutline.menu = filesContextMenu()
        filesOutline.quickLookOwner = self
        filesOutline.onSpaceKey = { [weak self] in
            guard let self else { return false }
            if self.currentPreviewURL() != nil {
                self.togglePreviewPanel()
                return true
            }
            // A node is targeted but didn't resolve to a local file or folder —
            // say so instead of leaving Space looking like it did nothing.
            guard let remote = self.targetedNodeRemotePath() else { return false }
            self.showToast(self.unavailableToastMessage(forRemotePath: remote))
            return true
        }

        let scroll = NSScrollView()
        scroll.documentView = filesOutline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    private func restoreFilesColumnWidths() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.filesColumnWidthsKey) else { return }
        for col in filesOutline.tableColumns {
            if let width = dict[col.identifier.rawValue] as? CGFloat {
                col.width = width
            }
        }
    }

    @objc private func filesColumnResized(_ notification: Notification) {
        var dict: [String: CGFloat] = [:]
        for col in filesOutline.tableColumns {
            dict[col.identifier.rawValue] = col.width
        }
        UserDefaults.standard.set(dict, forKey: Self.filesColumnWidthsKey)
    }

    private func filesContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Download (Wanted)", action: #selector(setFilesWantedAction(_:)), keyEquivalent: "").tag = 1
        menu.addItem(withTitle: "Skip (Unwanted)", action: #selector(setFilesWantedAction(_:)), keyEquivalent: "").tag = 0
        menu.addItem(.separator())
        let priorityItem = menu.addItem(withTitle: "Priority", action: nil, keyEquivalent: "")
        let priorityMenu = NSMenu()
        for priority in [FilePriority.high, .normal, .low] {
            let item = priorityMenu.addItem(withTitle: priority.displayName, action: #selector(setFilePriorityAction(_:)), keyEquivalent: "")
            item.tag = priority.rawValue
            item.target = self
        }
        priorityItem.submenu = priorityMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename…", action: #selector(renameFile(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealFileInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open", action: #selector(openFile(_:)), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    // MARK: - Reveal / Open / Rename a node (remote→local path mapping)

    @objc func revealFileInFinder(_ sender: Any?) {
        guard let remote = targetedNodeRemotePath() else { return }
        revealOrOpen(remotePath: remote, open: false)
    }

    @objc func openFile(_ sender: Any?) {
        guard let remote = targetedNodeRemotePath() else { return }
        revealOrOpen(remotePath: remote, open: true)
    }

    /// Double-clicking a *file* row opens it locally if a path mapping resolves
    /// it, otherwise shows the same "Not available locally" toast as the
    /// context-menu Open (mirrors `didDoubleClickRow` on the main table).
    /// Folder rows are left to AppKit's own expand-on-double-click.
    @objc private func didDoubleClickFileRow() {
        let row = filesOutline.clickedRow
        guard row >= 0, let node = filesOutline.item(atRow: row) as? FileNode, !node.isFolder,
              let torrent = selectedTorrents.first else { return }
        revealOrOpen(remotePath: torrent.remotePath(fileName: node.path), open: true, warnIfUnmapped: true)
    }

    /// Rename the targeted file *or folder* — `torrent-rename-path` renames
    /// directories too. The next fetch arrives with new paths, so the tree
    /// rebuilds structurally (the in-place merge rightly refuses).
    @objc func renameFile(_ sender: Any?) {
        guard let torrent = selectedTorrents.first, let node = targetedSingleNode() else { return }
        let torrentId = torrent.id
        let oldPath = node.path
        let oldName = node.displayName
        promptText(title: node.isFolder ? "Rename Folder" : "Rename File",
                   message: "New name for \u{201C}\(oldName)\u{201D}:",
                   defaultValue: oldName) { [weak self] newName in
            guard let newName, newName != oldName, !newName.isEmpty else { return }
            self?.runFilesRPC { try await $0.rename(id: torrentId, path: oldPath, name: newName) }
        }
    }

    /// The remote path of the single targeted node (right-clicked row, else a
    /// lone selection): the current torrent's download dir + the node's path —
    /// a file, or the folder itself for folder rows (Reveal/Open/Quick Look all
    /// work on a mapped directory). `nil` when no single node is targeted.
    func targetedNodeRemotePath() -> String? {
        guard let torrent = selectedTorrents.first, let node = targetedSingleNode() else { return nil }
        return torrent.remotePath(fileName: node.path)
    }

    /// The node under the right-clicked row (even when outside the selection),
    /// else a lone selection. `nil` when no single node is targeted.
    func targetedSingleNode() -> FileNode? {
        let clicked = filesOutline.clickedRow
        let selected = filesOutline.selectedRowIndexes
        let row: Int
        if clicked >= 0, !selected.contains(clicked) {
            row = clicked
        } else if selected.count == 1, let only = selected.first {
            row = only
        } else {
            return nil
        }
        guard row >= 0, row < filesOutline.numberOfRows else { return nil }
        return filesOutline.item(atRow: row) as? FileNode
    }

    // MARK: - Fetching

    /// Refresh the Files tab for the current main-table selection. Fetches only
    /// when exactly one torrent is selected and the Files tab is visible; otherwise
    /// clears the tree. Cheap to call on every poll and selection change.
    func loadFilesIfNeeded() {
        let isFilesTabVisible = detailTabView.selectedTabViewItem?.identifier as? String == "files"
        let selection = selectedTorrents
        guard isFilesTabVisible, selection.count == 1, let torrent = selection.first else {
            if filesTorrentId != nil || !filesTopLevel.isEmpty {
                filesFetchTask?.cancel()
                filesTorrentId = nil
                files = []
                reloadFilesData()
            }
            return
        }

        // Changed torrent: drop the stale tree immediately so we don't show
        // another torrent's files while the new ones load. Expansion state is
        // session-only and per torrent; the new torrent's single root folder
        // opens itself once when its tree first builds.
        if filesTorrentId != torrent.id {
            filesTorrentId = torrent.id
            files = []
            expandedFolderPaths = []
            filesAutoExpandRoot = true
            reloadFilesData()
        }

        guard let client = refresh.activeClient else { return }
        let id = torrent.id
        filesFetchTask?.cancel()
        filesFetchTask = Task { @MainActor in
            do {
                let fetched = try await client.fetchFiles(id: id)
                guard !Task.isCancelled, self.filesTorrentId == id else { return }
                self.applyFetchedFiles(fetched)
            } catch {
                // Silent: the list poll surfaces connection errors already.
            }
        }
    }

    // MARK: - Actions

    /// Nodes the action targets: the right-clicked row if it is outside the
    /// selection, else the whole selection.
    private func targetedNodes() -> [FileNode] {
        let clicked = filesOutline.clickedRow
        let selected = filesOutline.selectedRowIndexes
        if clicked >= 0, !selected.contains(clicked) {
            return [filesOutline.item(atRow: clicked)].compactMap { $0 as? FileNode }
        }
        return selected.compactMap { filesOutline.item(atRow: $0) as? FileNode }
    }

    /// Every server file index beneath the targeted nodes (a folder row carries
    /// its whole subtree), first occurrence winning, in row order.
    private func targetedFileIndices() -> [Int] {
        var seen = Set<Int>()
        var indices: [Int] = []
        for node in targetedNodes() {
            for index in node.fileIndices where seen.insert(index).inserted {
                indices.append(index)
            }
        }
        return indices
    }

    @objc func setFilesWantedAction(_ sender: NSMenuItem) {
        guard let id = filesTorrentId else { return }
        let indices = targetedFileIndices()
        let wanted = sender.tag == 1
        runFilesRPC { try await $0.setFilesWanted(id: id, fileIndices: indices, wanted: wanted) }
    }

    @objc func setFilePriorityAction(_ sender: NSMenuItem) {
        guard let id = filesTorrentId, let priority = FilePriority(rawValue: sender.tag) else { return }
        let indices = targetedFileIndices()
        runFilesRPC { try await $0.setFilePriority(id: id, fileIndices: indices, priority: priority) }
    }

    /// Toggle "wanted" from the row checkbox. The click is interpreted against
    /// the node's state, not the checkbox's own cycling: everything wanted
    /// unchecks the lot; nothing (or only some) wanted checks the lot — and the
    /// box is then pinned to what was actually sent.
    @objc func toggleFileWanted(_ sender: NonFocusableCheckbox) {
        guard let id = filesTorrentId, let node = sender.fileNode else { return }
        let wanted = node.wantedState != .all
        sender.state = wanted ? .on : .off
        runFilesRPC { try await $0.setFilesWanted(id: id, fileIndices: node.fileIndices, wanted: wanted) }
    }

    /// Store a freshly fetched file list in the tree, preserving the user's
    /// selection and folder expansion. The sort or structure can move a node to
    /// another row, so the selection is restored by node path — files and
    /// folders alike — not by row.
    func applyFetchedFiles(_ fetched: [TorrentFile]) {
        let selectedPaths = Set(filesOutline.selectedRowIndexes.compactMap {
            (filesOutline.item(atRow: $0) as? FileNode)?.path
        })
        files = fetched
        reloadFilesData()
        guard !selectedPaths.isEmpty else { return }
        let rows = IndexSet((0..<filesOutline.numberOfRows).filter {
            guard let node = filesOutline.item(atRow: $0) as? FileNode else { return false }
            return selectedPaths.contains(node.path)
        })
        if rows != filesOutline.selectedRowIndexes {
            filesOutline.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// NSOutlineView reports header clicks through its own data-source method;
    /// the NSTableView one never fires for it.
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        filesSortDescriptorsDidChange(from: oldDescriptors)
    }

    /// Re-sort the tree after the user clicks a column header. Header clicks
    /// cycle ascending → descending → unsorted (server file order), since
    /// AppKit never clears a descriptor on its own. The Name column is the
    /// exception: it only flips between A→Z and Z→A.
    func filesSortDescriptorsDidChange(from old: [NSSortDescriptor]) {
        if let new = filesOutline.sortDescriptors.first, let prev = old.first,
           new.key == prev.key, new.key != TorrentFileSortKey.name.rawValue,
           new.ascending, !prev.ascending {
            filesOutline.sortDescriptors = []  // re-enters via the delegate and re-sorts
            return
        }
        applyFetchedFiles(files)
    }

    /// Build the tree from `files` in the outline's current sort order.
    private func buildFilesTree() -> [FileNode] {
        let descriptor = filesOutline.sortDescriptors.first
        let key = descriptor?.key.flatMap(TorrentFileSortKey.init(rawValue:))
        return TorrentFileTree.build(from: files, sortedBy: key, ascending: descriptor?.ascending ?? true,
                                     foldersFirst: filesFoldersFirst)
    }

    /// Reload the files tree, preserving the user's selection, focus, and
    /// folder expansion.
    ///
    /// `reloadData()` drops `selectedRowIndexes` on this toolchain (the main
    /// table works around the same thing via `restoreSelection`), and on an
    /// outline view it also forgets expansion — AppKit tracks it by item
    /// identity. So a poll/RPC refresh first tries `TorrentFileTree.merge` to
    /// update the existing nodes in place: an unchanged structure keeps the
    /// same items in AppKit's expansion + selection maps and only the visible
    /// cells re-render — which, like the flat table's old in-place path, also
    /// avoids `reloadData()` recreating every row view (a full reload landing
    /// between the two mouse-downs of a double-click can silently swallow the
    /// gesture). Only a structural change (rename, file added/removed, torrent
    /// switch, sort change) pays for the full reload; expansion and selection
    /// are rebuilt from the tracked folder paths.
    private func reloadFilesData() {
        let restoreFocus = window?.firstResponder === filesOutline
        let expansion = expandedFolderPaths
        let newTree = buildFilesTree()
        if TorrentFileTree.merge(newTree, into: filesTopLevel) {
            // Structure unchanged: keep the nodes (AppKit's expansion and
            // selection survive untouched) and refresh the visible cells only.
            let rows = IndexSet(0..<filesOutline.numberOfRows)
            let columns = IndexSet(0..<filesOutline.numberOfColumns)
            filesOutline.reloadData(forRowIndexes: rows, columnIndexes: columns)
        } else {
            filesTopLevel = newTree
            filesOutline.reloadData()
            // Paranoia: if AppKit fired will-collapse notifications while
            // dropping the old items, restore the tracked paths before
            // re-expanding (expandItem's inserts are idempotent anyway).
            expandedFolderPaths = expansion
            applyExpansion(expansion)
            autoExpandRootIfNeeded()
        }
        if restoreFocus { window?.makeFirstResponder(filesOutline) }
    }

    /// Re-expand the folders in `paths`, parents first — a folder only becomes
    /// visible, and thus expandable, once its parents are.
    private func applyExpansion(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        func expand(_ nodes: [FileNode]) {
            for node in nodes where node.isFolder {
                if paths.contains(node.path) { filesOutline.expandItem(node) }
                expand(node.children)
            }
        }
        expand(filesTopLevel)
    }

    /// Open every top-level folder once when a newly selected torrent's tree
    /// first builds (nested folders stay collapsed), so the tab shows content
    /// instead of collapsed rows. A folder the user later collapses stays so.
    private func autoExpandRootIfNeeded() {
        guard filesAutoExpandRoot, !filesTopLevel.isEmpty else { return }
        filesAutoExpandRoot = false
        for root in filesTopLevel where root.isFolder {
            expandedFolderPaths.insert(root.path)
            filesOutline.expandItem(root)
        }
    }

    /// Run a files RPC then re-fetch the file list to reflect the change.
    private func runFilesRPC(_ body: @escaping (TransmissionClient) async throws -> Void) {
        guard let client = refresh.activeClient, let id = filesTorrentId else { return }
        Task { @MainActor in
            do {
                try await body(client)
                let fetched = try await client.fetchFiles(id: id)
                guard self.filesTorrentId == id else { return }
                self.applyFetchedFiles(fetched)
            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: - Cell construction

    /// The `outlineView(_:viewFor:tableColumn:item:)` body: render one node for
    /// one column. Folders aggregate their subtree; both cell kinds dim to
    /// secondary color when nothing beneath them is wanted.
    func fileCell(for tableColumn: NSTableColumn?, node: FileNode) -> NSView? {
        guard let tableColumn, let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

        if column == .wanted {
            let id = NSUserInterfaceItemIdentifier("FileWantedCell")
            let check = (filesOutline.makeView(withIdentifier: id, owner: self) as? NonFocusableCheckbox) ?? {
                let b = NonFocusableCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggleFileWanted(_:)))
                b.identifier = id
                return b
            }()
            switch node.wantedState {
            case .all: check.state = .on
            case .none: check.state = .off
            case .mixed: check.state = .mixed
            }
            check.fileNode = node
            return check
        }

        if column == .progress {
            let cell = (filesOutline.makeView(withIdentifier: ProgressCellView.reuseIdentifier, owner: self) as? ProgressCellView)
                ?? {
                    let c = ProgressCellView()
                    c.identifier = ProgressCellView.reuseIdentifier
                    return c
                }()
            cell.configure(fraction: node.percentDone,
                           color: node.percentDone >= 1 ? .systemGreen : .controlAccentColor)
            return cell
        }

        if column == .name {
            let id = NSUserInterfaceItemIdentifier("FileNameCell")
            let cell = (filesOutline.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.imageScaling = .scaleProportionallyDown
                iv.symbolConfiguration = .init(pointSize: 12, weight: .regular)
                iv.contentTintColor = .secondaryLabelColor
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                c.addSubview(iv)
                c.addSubview(tf)
                c.imageView = iv
                c.textField = tf
                c.identifier = id
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.imageView?.image = NSImage(systemSymbolName: node.isFolder ? "folder.fill" : "doc",
                                             accessibilityDescription: node.isFolder ? "Folder" : "File")
            cell.textField?.stringValue = node.displayName
            cell.textField?.textColor = node.wantedState == .none ? .secondaryLabelColor : .labelColor
            return cell
        }

        // size / priority: right-aligned text cells.
        let id = NSUserInterfaceItemIdentifier("FileTextCell")
        let cell = (filesOutline.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
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
        case .size: value = Formatters.size(node.length)
        case .priority: value = node.priorityDisplay
        case .wanted, .name, .progress: value = ""  // handled above
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = .right
        cell.textField?.textColor = node.wantedState == .none ? .secondaryLabelColor : .labelColor
        return cell
    }
}

// MARK: - Outline data source

extension MainWindowController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.isFolder ? node.children.count : 0 }
        return filesTopLevel.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children[index] }
        return filesTopLevel[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    // MARK: Drag out to Finder

    /// The Files side of drag-out (the torrent list's side is
    /// `tableView(_:pasteboardWriterForRow:)` in `MainWindowController.swift`):
    /// the item's remote path resolves through the active server's path
    /// mappings to a local file — a folder row drags its whole mapped
    /// directory. See the long comment on the torrent-list method for why a
    /// plain `NSURL` and never a file promise.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, let torrent = selectedTorrents.first else { return nil }
        return resolvedDragWriter(forRemotePath: torrent.remotePath(fileName: node.path))
    }

    /// Same toast-on-unresolved as the torrent list's
    /// `tableView(_:draggingSession:willBeginAt:forRowIndexes:)`: if *none* of
    /// the dragged items resolve to a real local file, say why instead of
    /// silently dropping nothing in Finder.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        guard !draggedItems.contains(where: itemResolvesForDrag(_:)),
              let first = draggedItems.first, let message = unresolvedDragMessage(forDraggedItem: first) else { return }
        showToast(message)
    }

    private func itemResolvesForDrag(_ item: Any) -> Bool {
        guard let node = item as? FileNode, let torrent = selectedTorrents.first,
              let url = resolvedExistingLocalURL(forRemotePath: torrent.remotePath(fileName: node.path)) else { return false }
        return !PathPermissions.blocksCrossProcessDrag(atPath: url.path)
    }

    private func unresolvedDragMessage(forDraggedItem item: Any) -> String? {
        guard let node = item as? FileNode, let torrent = selectedTorrents.first else { return nil }
        let remote = torrent.remotePath(fileName: node.path)
        if let url = resolvedExistingLocalURL(forRemotePath: remote) {
            guard PathPermissions.blocksCrossProcessDrag(atPath: url.path) else { return nil }
            return "Can't drag out — restrictive permissions on \(url.path): try Reveal in Finder instead"
        }
        return unavailableToastMessage(forRemotePath: remote)
    }
}

// MARK: - Outline delegate

extension MainWindowController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        return fileCell(for: tableColumn, node: node)
    }

    /// Track folder expansion by path (session-only) — the identity that
    /// survives the tree rebuilds each poll (see `reloadFilesData`).
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = expandedItem(of: notification) else { return }
        expandedFolderPaths.insert(node.path)
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard let node = expandedItem(of: notification) else { return }
        expandedFolderPaths.remove(node.path)
    }

    /// The expand/collapse notifications carry the item in userInfo under
    /// "NSObject" (wrapped in an `NSTreeNode` on some AppKit versions — unwrap
    /// either shape).
    private func expandedItem(of notification: Notification) -> FileNode? {
        let object = notification.userInfo?["NSObject"]
        return (object as? FileNode) ?? (object as? NSTreeNode)?.representedObject as? FileNode
    }
}

// MARK: - Tab switching

extension MainWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: "DetailTabIdentifier")
        }
        loadFilesIfNeeded()
        loadPeersIfNeeded()
    }
}

// MARK: - FilesOutlineView

/// The Files tab tree — intercepts ↩ to trigger the rename action on the single
/// targeted node (file or folder; `torrent-rename-path` handles both), matching
/// Finder's convention for renaming selected items, and Space to Quick Look the
/// targeted node when its remote path resolves locally — a folder previews as a
/// folder natively (`onSpaceKey` returns `false` otherwise, so Space falls
/// through instead of being silently swallowed).
final class FilesOutlineView: NSOutlineView {
    var onSpaceKey: (() -> Bool)?
    weak var quickLookOwner: MainWindowController?

    override func keyDown(with event: NSEvent) {
        let noMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if noMods, event.charactersIgnoringModifiers == "\r" {
            NSApp.sendAction(#selector(MainWindowController.renameFile(_:)), to: nil, from: self)
            return
        }
        if noMods, event.keyCode == 49 { // Space
            if onSpaceKey?() != true { super.keyDown(with: event) }
            return
        }
        super.keyDown(with: event)
    }

    // See TorrentTableView's identical overrides: this outline is already the
    // first responder when Space is pressed, so it's naturally reachable by
    // QLPreviewPanel's responder-chain search without splicing anything into
    // `window.nextResponder`.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // See TorrentTableView's identical overrides for why `assumeIsolated` is safe
    // here (AppKit only calls these on the main thread).
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookOwner?.quickLookBeginControl(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookOwner?.quickLookEndControl(panel) }
    }

    // See the identical override + note on `TorrentTableView` in
    // `MainWindowController.swift`: `setDraggingSourceOperationMask` alone was
    // confirmed live to still leave Finder rejecting the drop.
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// The per-row "wanted" checkbox. Plain `NSButton` grabs first responder on
/// click (standard `NSControl` tracking behavior), which then swallows a
/// later Space keystroke as "toggle checkbox" instead of letting it reach
/// `FilesOutlineView.keyDown` for Quick Look — refusing first responder keeps
/// keyboard focus on the outline after a checkbox click, same as clicking
/// anywhere else in the row. Carries the row's `FileNode` (strong — identity
/// is survival-critical for the click handler) so the action can act on the
/// node's whole subtree without mapping row numbers back through the outline.
final class NonFocusableCheckbox: NSButton {
    /// The node this checkbox was last configured for.
    var fileNode: FileNode?

    override var acceptsFirstResponder: Bool { false }
}
