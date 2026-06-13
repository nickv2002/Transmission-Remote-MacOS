import AppKit

/// A source-list sidebar (`NSOutlineView`) that groups torrents by status,
/// tracker, and download folder — the native take on the legacy `filtering.pas`
/// filter panel. Selecting a row reports the active `SidebarFilter`; the torrent
/// list filters on it.
@MainActor
final class SidebarController: NSObject {
    /// A node in the outline: a non-selectable group header or a selectable filter.
    final class Node {
        let title: String
        let symbol: String?
        let filter: SidebarFilter?
        var count: Int
        var children: [Node]

        init(title: String, symbol: String? = nil, filter: SidebarFilter? = nil,
             count: Int = 0, children: [Node] = []) {
            self.title = title
            self.symbol = symbol
            self.filter = filter
            self.count = count
            self.children = children
        }

        var isGroup: Bool { filter == nil }
    }

    let outlineView = NSOutlineView()
    let scrollView = NSScrollView()

    /// Reported whenever the selected filter changes (including back to `.all`).
    var onFilterChange: ((SidebarFilter) -> Void)?

    private var groups: [Node] = []
    /// The currently selected filter, preserved across rebuilds.
    private(set) var selectedFilter: SidebarFilter = .all

    override init() {
        super.init()
        buildOutline()
    }

    private func buildOutline() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.autosaveExpandedItems = false
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    // MARK: - Rebuild from the torrent list

    /// Recompute group rows and counts from the current torrents, preserving the
    /// expanded state and the active selection.
    func update(with torrents: [Torrent]) {
        // Status group: every case, with counts.
        let statusNode = Node(title: "Status")
        statusNode.children = StatusFilter.allCases.map { sf in
            Node(title: sf.displayName, symbol: sf.symbol, filter: .status(sf),
                 count: torrents.lazy.filter(sf.matches).count)
        }

        // Trackers group: distinct hosts, sorted, with counts.
        var trackerCounts: [String: Int] = [:]
        for t in torrents { if let host = t.trackerHost { trackerCounts[host, default: 0] += 1 } }
        let trackerNode = Node(title: "Trackers")
        trackerNode.children = trackerCounts.keys.sorted().map { host in
            Node(title: host, symbol: "antenna.radiowaves.left.and.right",
                 filter: .tracker(host), count: trackerCounts[host] ?? 0)
        }

        // Folders group: distinct download dirs, sorted, with counts.
        var folderCounts: [String: Int] = [:]
        for t in torrents { folderCounts[t.downloadDir, default: 0] += 1 }
        let folderNode = Node(title: "Folders")
        let folderLabels = disambiguatedFolderLabels(Array(folderCounts.keys))
        folderNode.children = folderCounts.keys.sorted().map { dir in
            Node(title: folderLabels[dir] ?? dir,
                 symbol: "folder", filter: .folder(dir), count: folderCounts[dir] ?? 0)
        }

        groups = [statusNode, trackerNode, folderNode]

        // If the selected tracker/folder vanished, fall back to All.
        if case .tracker(let h) = selectedFilter, trackerCounts[h] == nil { selectedFilter = .all }
        if case .folder(let d) = selectedFilter, folderCounts[d] == nil { selectedFilter = .all }

        outlineView.reloadData()
        for group in groups { outlineView.expandItem(group) }
        reselectActive()
    }

    /// Compute the shortest trailing-path suffix for each folder that makes it
    /// distinguishable from every other folder. Folders with a unique leaf keep
    /// just the leaf (e.g. "movies"); those that collide grow toward the root one
    /// component at a time until unique (e.g. "2024/11" vs "2025/11"). A folder
    /// that can't be extended further falls back to its full path.
    private func disambiguatedFolderLabels(_ dirs: [String]) -> [String: String] {
        // Split each distinct dir into its non-empty path components.
        let components: [String: [String]] = Dictionary(uniqueKeysWithValues: Set(dirs).map { dir in
            (dir, (dir as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty })
        })

        // Current suffix depth per dir (number of trailing components used).
        var depth: [String: Int] = components.mapValues { min(1, $0.count) }

        func label(for dir: String) -> String {
            let parts = components[dir] ?? []
            let d = max(depth[dir] ?? 1, 1)
            let suffix = parts.suffix(d)
            return suffix.isEmpty ? dir : suffix.joined(separator: "/")
        }

        // Repeatedly grow the depth of any label shared by more than one dir,
        // but only for dirs that still have a deeper parent to include.
        while true {
            var labelToDirs: [String: [String]] = [:]
            for dir in components.keys { labelToDirs[label(for: dir), default: []].append(dir) }
            var grew = false
            for (_, group) in labelToDirs where group.count > 1 {
                for dir in group {
                    let parts = components[dir] ?? []
                    if (depth[dir] ?? 1) < parts.count {
                        depth[dir, default: 1] += 1
                        grew = true
                    }
                }
            }
            if !grew { break }
        }

        return Dictionary(uniqueKeysWithValues: components.keys.map { ($0, label(for: $0)) })
    }

    /// Reselect the row matching `selectedFilter` after a reload.
    private func reselectActive() {
        for group in groups {
            for child in group.children where child.filter == selectedFilter {
                let row = outlineView.row(forItem: child)
                if row >= 0 {
                    outlineView.selectRowIndexes([row], byExtendingSelection: false)
                    return
                }
            }
        }
    }

    /// The node currently selected, if any.
    private func selectedNode() -> Node? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? Node : nil
    }
}

// MARK: - Data source

extension SidebarController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groups.count }
        return (item as? Node)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return groups[index] }
        return (item as! Node).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
}

// MARK: - Delegate

extension SidebarController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Node)?.isGroup ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        if node.isGroup {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf); c.textField = tf
                c.identifier = id
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = node.title.uppercased()
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("FilterCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FilterCellView)
            ?? FilterCellView(identifier: id)
        cell.configure(symbol: node.symbol, title: node.title, count: node.count)
        // For folders show the full path on hover; the visible label is only the
        // minimal disambiguating suffix.
        if case .folder(let dir) = node.filter {
            cell.toolTip = dir
        } else {
            cell.toolTip = node.title
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let filter = selectedNode()?.filter else { return }
        selectedFilter = filter
        onFilterChange?(filter)
    }
}

/// A sidebar row: icon + title on the left, a count badge on the right.
private final class FilterCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(icon); addSubview(title); addSubview(badge)
        self.textField = title
        self.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String?, title titleText: String, count: Int) {
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        title.stringValue = titleText
        badge.stringValue = count > 0 ? "\(count)" : ""
    }
}
