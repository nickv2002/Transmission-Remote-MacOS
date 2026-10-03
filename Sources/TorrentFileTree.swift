import Foundation

/// One node in the Files tab's directory tree: a leaf (one of the torrent's
/// files) or a folder aggregating everything beneath it.
///
/// A reference type on purpose: `NSOutlineView` items need stable identity
/// across AppKit's queries (`child(_:ofItem:)`, `item(atRow:)`, selection and
/// the expansion map), and the poll-time merge (`TorrentFileTree.merge`)
/// replaces leaf payloads *in place* on the existing nodes so AppKit's
/// identity-keyed expansion + selection survive a refresh without a full
/// reload. Nothing below `children`/`file` is ever cached — aggregates are
/// computed on demand, so an in-place merge needs no invalidation.
final class FileNode {
    /// Wanted state of everything beneath the node, driving the tri-state
    /// checkbox: `.all` → on, `.none` → off, `.mixed` → dash.
    enum WantedState { case all, none, mixed }

    /// The last path component — what the Name column shows.
    let displayName: String
    /// The full path relative to the torrent's download dir: the RPC's file
    /// `name` for leaves, the joined components for folders. Doubles as the
    /// node's identity for expansion/selection restore across reloads, and the
    /// key fed to `Torrent.remotePath(fileName:)` for Reveal/Open/Quick
    /// Look/drag-out (a folder resolves to the mapped local directory).
    let path: String
    /// Folders only (empty for leaves); display order — server order at
    /// build, or the active column sort after `TorrentFileTree.sorted`
    /// (file-scope setter: only TorrentFileTree, in this file, rewrites it).
    fileprivate(set) var children: [FileNode]
    /// Leaves only; `nil` for folders. Replaced in place by `TorrentFileTree.merge`.
    fileprivate(set) var file: TorrentFile?
    /// The smallest server file index at or beneath the node — the stable
    /// tie-break for sorting and the server-order anchor (files arrive in
    /// server order, so it is set by the first child ever appended).
    private(set) var firstIndex: Int

    init(file: TorrentFile) {
        displayName = (file.name as NSString).lastPathComponent
        path = file.name
        children = []
        self.file = file
        firstIndex = file.index
    }

    init(name: String, path: String) {
        displayName = name
        self.path = path
        children = []
        file = nil
        firstIndex = .max
    }

    /// Append a child during `build` (children arrive in server order).
    func append(_ child: FileNode) {
        if child.firstIndex < firstIndex { firstIndex = child.firstIndex }
        children.append(child)
    }

    var isFolder: Bool { file == nil }

    // MARK: - Aggregates

    /// Σ file lengths beneath the node (a leaf's own size).
    var length: Int64 {
        if let file { return file.length }
        return children.reduce(0) { $0 + $1.length }
    }

    /// Σ completed bytes beneath the node.
    var bytesCompleted: Int64 {
        if let file { return file.bytesCompleted }
        return children.reduce(0) { $0 + $1.bytesCompleted }
    }

    var percentDone: Double {
        let total = length
        return total > 0 ? Double(bytesCompleted) / Double(total) : 1
    }

    /// Every server file index at or beneath the node, in display order —
    /// what `files-wanted` / `priority-*` take (a folder acts on all of them).
    var fileIndices: [Int] {
        if let file { return [file.index] }
        return children.flatMap(\.fileIndices)
    }

    var wantedState: WantedState {
        if let file { return file.wanted ? .all : .none }
        var sawWanted = false
        var sawUnwanted = false
        for child in children {
            switch child.wantedState {
            case .all: sawWanted = true
            case .none: sawUnwanted = true
            case .mixed: return .mixed
            }
            if sawWanted, sawUnwanted { return .mixed }
        }
        return sawUnwanted ? .none : .all
    }

    /// The Priority cell text: a leaf shows its own priority, or "Skip" while
    /// unwanted. A folder shows the one priority its wanted files share, "Skip"
    /// when nothing beneath it is wanted, and "—" when they differ.
    var priorityDisplay: String {
        if let file { return file.wanted ? file.priority.displayName : "Skip" }
        var sawUnwanted = false
        var raws = Set<Int>()
        forEachLeaf { leaf in
            if leaf.wanted { raws.insert(leaf.priorityRaw) } else { sawUnwanted = true }
        }
        if raws.count == 1, let raw = raws.first {
            return (FilePriority(rawValue: raw) ?? .normal).displayName
        }
        return raws.isEmpty && sawUnwanted ? "Skip" : "—"
    }

    /// Where the node sits in a priority sort: a leaf keeps the flat list's old
    /// semantics (unwanted = "Skip", below Low); a folder takes the minimum
    /// across its descendants, so folders holding skipped or low-priority files
    /// sort alongside them.
    var prioritySortValue: Int {
        if let file { return file.wanted ? file.priorityRaw : -2 }
        var value = Int.max
        for child in children {
            let childValue = child.prioritySortValue
            if childValue < value { value = childValue }
        }
        return value == Int.max ? -2 : value
    }

    /// Visit every leaf at or beneath the node, in display order.
    func forEachLeaf(_ body: (TorrentFile) -> Void) {
        if let file { body(file); return }
        for child in children { child.forEachLeaf(body) }
    }
}

// MARK: - Building, sorting, and the poll merge

enum TorrentFileTree {
    /// Build the top-level nodes of the Files tab's tree from the server's file
    /// list, grouping by the `/`-separated `name` components. A shared single
    /// root folder (the usual multi-file torrent) becomes one top-level row;
    /// loose files beside folders become sibling rows; a single-file torrent
    /// becomes one leaf. `nil` key keeps the server's file order, otherwise
    /// siblings are sorted recursively by `key`.
    static func build(from files: [TorrentFile], sortedBy key: TorrentFileSortKey?, ascending: Bool,
                      foldersFirst: Bool = true) -> [FileNode] {
        var folders: [String: FileNode] = [:]
        var topLevel: [FileNode] = []
        for file in files {
            let parts = file.name.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var parent: FileNode?
            var folderPath = ""
            for part in parts.dropLast() {
                folderPath += folderPath.isEmpty ? part : "/" + part
                if let existing = folders[folderPath] {
                    parent = existing
                } else {
                    let node = FileNode(name: part, path: folderPath)
                    folders[folderPath] = node
                    if let parent { parent.append(node) } else { topLevel.append(node) }
                    parent = node
                }
            }
            let leaf = FileNode(file: file)
            if let parent { parent.append(leaf) } else { topLevel.append(leaf) }
        }
        guard let key else { return topLevel }
        return sorted(topLevel, by: key, ascending: ascending, foldersFirst: foldersFirst)
    }

    /// Sort `nodes` and every folder's children (recursively) by `key`; ties
    /// keep server order via `firstIndex`. With `foldersFirst`, folders always
    /// list before files (in both directions); otherwise they interleave by the
    /// key. Folders compare by their aggregates either way.
    static func sorted(_ nodes: [FileNode], by key: TorrentFileSortKey, ascending: Bool,
                       foldersFirst: Bool = true) -> [FileNode] {
        let ordered = nodes.sorted { a, b in
            if foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
            let result = compare(a, b, by: key)
            if result == .orderedSame { return a.firstIndex < b.firstIndex }
            return (result == .orderedAscending) == ascending
        }
        for node in ordered where node.isFolder {
            node.children = sorted(node.children, by: key, ascending: ascending, foldersFirst: foldersFirst)
        }
        return ordered
    }

    private static func compare(_ a: FileNode, _ b: FileNode, by key: TorrentFileSortKey) -> ComparisonResult {
        func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
        switch key {
        case .name: return a.displayName.localizedStandardCompare(b.displayName)
        case .size: return order(a.length, b.length)
        case .progress: return order(a.percentDone, b.percentDone)
        case .priority: return order(a.prioritySortValue, b.prioritySortValue)
        }
    }

    /// Refresh the existing tree's leaf payloads from `newNodes` when the
    /// structure is identical (same nodes in the same order), returning `true`
    /// so the caller keeps the existing nodes and only re-renders the visible
    /// cells — AppKit's item-identity-keyed expansion and selection survive. Any
    /// structural difference (rename, file added/removed, sort change) returns
    /// `false`: the caller rebuilds via `reloadData()` and restores expansion +
    /// selection from the tracked paths.
    static func merge(_ newNodes: [FileNode], into oldNodes: [FileNode]) -> Bool {
        guard newNodes.count == oldNodes.count else { return false }
        for (new, old) in zip(newNodes, oldNodes) {
            guard new.path == old.path, new.isFolder == old.isFolder else { return false }
            if let file = new.file {
                old.file = file
            } else if !merge(new.children, into: old.children) {
                return false
            }
        }
        return true
    }
}
