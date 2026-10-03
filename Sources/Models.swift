import Foundation

/// Transmission torrent status codes (RPC spec). Mirrors the legacy app's `tsXxx`
/// constants in `rpc.pas`.
enum TorrentStatus: Int, Sendable {
    case stopped = 0
    case checkWait = 1
    case checking = 2
    case downloadWait = 3
    case downloading = 4
    case seedWait = 5
    case seeding = 6

    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .checkWait: return "Queued (check)"
        case .checking: return "Checking"
        case .downloadWait: return "Queued (down)"
        case .downloading: return "Downloading"
        case .seedWait: return "Queued (seed)"
        case .seeding: return "Seeding"
        }
    }

    /// True while the daemon is actively running this torrent (not stopped).
    var isActive: Bool { self != .stopped }
}

/// Transmission `bandwidthPriority` values (RPC spec): -1 low, 0 normal, 1 high.
enum BandwidthPriority: Int, Sendable, CaseIterable {
    case low = -1
    case normal = 0
    case high = 1

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// Transmission `seedRatioMode` values (RPC spec): 0 use the global limit, 1 use
/// this torrent's own `seedRatioLimit`, 2 seed regardless of ratio.
enum SeedRatioMode: Int, Sendable {
    case global = 0
    case single = 1
    case unlimited = 2
}

/// Per-file priority (`torrent-set` `priority-low/normal/high`). Same raw values
/// as `BandwidthPriority` but a distinct type because the RPC methods differ.
enum FilePriority: Int, Sendable, CaseIterable {
    case low = -1
    case normal = 0
    case high = 1

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// One file inside a torrent, merged from the `files` and `fileStats` arrays of a
/// single-torrent `torrent-get`. `index` is the file's position in those arrays —
/// the id used by `files-wanted` / `priority-*`.
struct TorrentFile: Sendable, Equatable, Identifiable {
    let index: Int
    let name: String
    let length: Int64
    let bytesCompleted: Int64
    let wanted: Bool
    let priorityRaw: Int

    var id: Int { index }
    var percentDone: Double { length > 0 ? Double(bytesCompleted) / Double(length) : 1 }
    var priority: FilePriority { FilePriority(rawValue: priorityRaw) ?? .normal }
}

/// A single torrent as returned by `torrent-get`. Only the MVP fields are decoded.
struct Torrent: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let statusRaw: Int
    let percentDone: Double
    let totalSize: Int64
    let sizeWhenDone: Int64
    let leftUntilDone: Int64
    let rateDownload: Int64
    let rateUpload: Int64
    let eta: Int
    let uploadRatio: Double
    let downloadDir: String
    let errorString: String
    let peersConnected: Int
    let peersSendingToUs: Int
    let peersGettingFromUs: Int
    let addedDate: Double
    let hashString: String
    let queuePosition: Int
    let bandwidthPriorityRaw: Int
    let trackers: [TrackerInfo]
    let trackerStats: [TrackerStatsInfo]
    let comment: String
    let errorCode: Int
    let doneDate: Double
    let activityDate: Double
    let downloadedEver: Int64
    let uploadedEver: Int64
    let seedRatioLimit: Double
    let seedRatioModeRaw: Int
    let recheckProgress: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case statusRaw = "status"
        case percentDone
        case totalSize
        case sizeWhenDone
        case leftUntilDone
        case rateDownload
        case rateUpload
        case eta
        case uploadRatio
        case downloadDir
        case errorString
        case peersConnected
        case peersSendingToUs
        case peersGettingFromUs
        case addedDate
        case hashString
        case queuePosition
        case bandwidthPriorityRaw = "bandwidthPriority"
        case trackers
        case trackerStats
        case comment
        case errorCode = "error"
        case doneDate
        case activityDate
        case downloadedEver
        case uploadedEver
        case seedRatioLimit
        case seedRatioModeRaw = "seedRatioMode"
        case recheckProgress
    }

    /// Tolerant decode: identity/display fields are required, but the heavier or
    /// secondary fields (`trackers`, `comment`, peers, ever-totals, dates, seed
    /// ratio) `decodeIfPresent` with defaults. This lets a slim first poll
    /// (`firstFetchFields`) omit them for a faster cold paint while a later full
    /// poll fills them in — and makes decoding robust to protocol variance.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        statusRaw = try c.decode(Int.self, forKey: .statusRaw)
        percentDone = try c.decode(Double.self, forKey: .percentDone)
        totalSize = try c.decode(Int64.self, forKey: .totalSize)
        sizeWhenDone = try c.decode(Int64.self, forKey: .sizeWhenDone)
        leftUntilDone = try c.decode(Int64.self, forKey: .leftUntilDone)
        rateDownload = try c.decode(Int64.self, forKey: .rateDownload)
        rateUpload = try c.decode(Int64.self, forKey: .rateUpload)
        eta = try c.decode(Int.self, forKey: .eta)
        uploadRatio = try c.decode(Double.self, forKey: .uploadRatio)
        downloadDir = try c.decode(String.self, forKey: .downloadDir)
        // Present in the slim set, but defaulted to stay tolerant.
        errorString = try c.decodeIfPresent(String.self, forKey: .errorString) ?? ""
        addedDate = try c.decodeIfPresent(Double.self, forKey: .addedDate) ?? 0
        hashString = try c.decodeIfPresent(String.self, forKey: .hashString) ?? ""
        queuePosition = try c.decodeIfPresent(Int.self, forKey: .queuePosition) ?? 0
        bandwidthPriorityRaw = try c.decodeIfPresent(Int.self, forKey: .bandwidthPriorityRaw) ?? 0
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode) ?? 0
        // Omitted by the slim first poll; arrive on the next full poll.
        trackers = try c.decodeIfPresent([TrackerInfo].self, forKey: .trackers) ?? []
        trackerStats = try c.decodeIfPresent([TrackerStatsInfo].self, forKey: .trackerStats) ?? []
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        peersConnected = try c.decodeIfPresent(Int.self, forKey: .peersConnected) ?? 0
        peersSendingToUs = try c.decodeIfPresent(Int.self, forKey: .peersSendingToUs) ?? 0
        peersGettingFromUs = try c.decodeIfPresent(Int.self, forKey: .peersGettingFromUs) ?? 0
        doneDate = try c.decodeIfPresent(Double.self, forKey: .doneDate) ?? 0
        activityDate = try c.decodeIfPresent(Double.self, forKey: .activityDate) ?? 0
        downloadedEver = try c.decodeIfPresent(Int64.self, forKey: .downloadedEver) ?? 0
        uploadedEver = try c.decodeIfPresent(Int64.self, forKey: .uploadedEver) ?? 0
        seedRatioLimit = try c.decodeIfPresent(Double.self, forKey: .seedRatioLimit) ?? 0
        seedRatioModeRaw = try c.decodeIfPresent(Int.self, forKey: .seedRatioModeRaw) ?? 0
        recheckProgress = try c.decodeIfPresent(Double.self, forKey: .recheckProgress) ?? 0
    }

    var status: TorrentStatus { TorrentStatus(rawValue: statusRaw) ?? .stopped }

    /// The fraction to show in the progress bar: verify progress while checking,
    /// download progress otherwise (`percentDone` reflects download completion and
    /// is stale/misleading during a recheck).
    var displayProgress: Double { status == .checking ? recheckProgress : percentDone }

    /// True while the torrent is actually transferring (has up/down throughput).
    var isTransferring: Bool { rateDownload > 0 || rateUpload > 0 }

    /// True when the daemon reported a tracker/local error for this torrent.
    var hasError: Bool { !errorString.isEmpty }

    /// ETA string for display. `eta == -1` ("∞") is only meaningful for a torrent
    /// that is genuinely still downloading; for a completed/seeding/stopped torrent
    /// there is nothing left to finish, so show "—" instead.
    var etaDisplay: String {
        guard percentDone < 1, status == .downloading || status == .downloadWait else {
            return "—"
        }
        return Formatters.eta(eta)
    }

    /// Connected seeds (peers currently sending to us) and, when a tracker has
    /// reported one, the swarm-wide seeder total (`-1` when unknown — mirrors the
    /// legacy Pascal app's sentinel for "no tracker stats yet").
    var seedsConnected: Int { peersSendingToUs }
    var seedsTotal: Int { trackerStats.first?.seederCount ?? -1 }

    /// Connected peers we're uploading to, and the swarm-wide leecher total.
    var peersConnectedForUpload: Int { peersGettingFromUs }
    var leechersTotal: Int { trackerStats.first?.leecherCount ?? -1 }

    /// `downloadDir` normalized so location-equivalent strings collapse into one:
    /// runs of "/" collapsed and any trailing "/" trimmed (root "/" preserved).
    /// Two dirs that differ only by a trailing slash (or doubled separators) share
    /// a single sidebar folder node and filter together.
    var normalizedDownloadDir: String { Self.normalizeDownloadDir(downloadDir) }

    /// See `normalizedDownloadDir`. Exposed statically so the sidebar filter can
    /// normalize both sides of a comparison.
    static func normalizeDownloadDir(_ dir: String) -> String {
        var result = ""
        var lastWasSlash = false
        for ch in dir {
            if ch == "/" {
                if lastWasSlash { continue }
                lastWasSlash = true
            } else {
                lastWasSlash = false
            }
            result.append(ch)
        }
        if result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// The remote path of the torrent itself, or (with `fileName`) a file inside
    /// it: the normalized download dir + the torrent's name, or + the file's
    /// relative name. This is the path fed to `ServerConfig.mapRemoteToLocal(_:)`
    /// for Reveal in Finder / Open / drag-out-to-Finder — kept in one place so
    /// those three call sites can't drift apart.
    func remotePath(fileName: String? = nil) -> String {
        normalizedDownloadDir + "/" + (fileName ?? name)
    }

    /// Host of the torrent's primary tracker (e.g. `tracker.example.org`), or nil.
    /// Used to group torrents in the sidebar. Strips a leading `www.`.
    var trackerHost: String? {
        for tracker in trackers {
            if let host = URL(string: tracker.announce)?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return nil
    }

    var bandwidthPriority: BandwidthPriority {
        BandwidthPriority(rawValue: bandwidthPriorityRaw) ?? .normal
    }

    var seedRatioMode: SeedRatioMode {
        SeedRatioMode(rawValue: seedRatioModeRaw) ?? .global
    }

    /// Display string for the torrent's seed-ratio limit: the global default,
    /// this torrent's own limit, or ∞ for "seed regardless".
    var seedRatioDisplay: String {
        switch seedRatioMode {
        case .global: return "Default"
        case .single: return Formatters.ratio(seedRatioLimit)
        case .unlimited: return "∞"
        }
    }

    /// Effective ratio limit for sorting: global → its own limit value, single →
    /// its limit, unlimited → +∞ so it sorts last.
    var effectiveRatioLimit: Double {
        switch seedRatioMode {
        case .global, .single: return seedRatioLimit
        case .unlimited: return .infinity
        }
    }

    /// A `magnet:` URI built client-side from fields already fetched by
    /// `torrent-get` (`hashString`, `name`, `trackers`) — no separate RPC field
    /// needed. Includes `tr=` params for every known tracker so magnet-based
    /// re-adds don't rely solely on DHT/PEX (which won't work for private torrents).
    var magnetLink: String { Self.buildMagnetLink(hashString: hashString, name: name, trackerURLs: trackers.map(\.announce)) }

    /// Percent-encodes every character except RFC 3986 "unreserved" ones — like
    /// `encodeURIComponent` — so a query-parameter *value* that is itself a URL
    /// (a tracker announce URL) doesn't leak `:`, `/`, `?`, `&` that would be
    /// misparsed as part of the outer magnet URI's query string.
    private static let magnetComponentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    /// Pure builder behind `magnetLink`, factored out for unit testing.
    static func buildMagnetLink(hashString: String, name: String, trackerURLs: [String]) -> String {
        let dn = name.addingPercentEncoding(withAllowedCharacters: magnetComponentAllowed) ?? name
        var uri = "magnet:?xt=urn:btih:\(hashString)&dn=\(dn)"
        for tracker in trackerURLs {
            let tr = tracker.addingPercentEncoding(withAllowedCharacters: magnetComponentAllowed) ?? tracker
            uri += "&tr=\(tr)"
        }
        return uri
    }

    /// The list of fields the MVP requests from `torrent-get`.
    static let requestedFields = [
        "id", "name", "status", "percentDone", "totalSize", "sizeWhenDone",
        "leftUntilDone", "rateDownload", "rateUpload", "eta", "uploadRatio",
        "downloadDir", "errorString", "peersConnected", "peersSendingToUs",
        "peersGettingFromUs", "addedDate", "hashString", "queuePosition",
        "bandwidthPriority", "trackers", "trackerStats", "comment", "error", "doneDate",
        "activityDate", "downloadedEver", "uploadedEver", "seedRatioLimit",
        "seedRatioMode", "recheckProgress",
    ]

    /// A slimmer field set for the very first poll after a fresh connect, so the
    /// cold list paints sooner — especially over high-latency LTE. Drops the two
    /// heaviest contributors (the per-torrent `trackers` array and `comment`) plus
    /// peer/ever/date extras not shown in the default columns. The sidebar tracker
    /// grouping and Info-pane comment fill in on the next (full) poll. Decoding
    /// tolerates the omitted fields via `init(from:)`.
    static let firstFetchFields = [
        "id", "name", "status", "percentDone", "totalSize", "sizeWhenDone",
        "leftUntilDone", "rateDownload", "rateUpload", "eta", "uploadRatio",
        "downloadDir", "error", "errorString", "addedDate", "hashString",
        "queuePosition", "bandwidthPriority", "recheckProgress",
    ]
}

/// One tracker entry from a torrent's `trackers` array (we only need the URL).
struct TrackerInfo: Codable, Sendable, Equatable {
    let announce: String
}

/// One entry from a torrent's `trackerStats` array — a tracker's announce URL,
/// its last announce/scrape outcome, and the swarm-wide seeder/leecher counts
/// it last reported (`-1` means "unknown"). Everything decodes tolerantly:
/// daemons omit zero-valued fields.
struct TrackerStatsInfo: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let announce: String
    /// Transmission's `announceState`: 0 inactive, 1 waiting, 2 queued, 3 active.
    let announceState: Int
    let hasAnnounced: Bool
    let lastAnnounceSucceeded: Bool
    let lastAnnounceResult: String
    let hasScraped: Bool
    let lastScrapeSucceeded: Bool
    let lastScrapeResult: String
    /// Epoch seconds; `0` when no announce is scheduled.
    let nextAnnounceTime: Double
    let seederCount: Int
    let leecherCount: Int

    init(id: Int = 0, announce: String = "", announceState: Int = 0,
         hasAnnounced: Bool = false, lastAnnounceSucceeded: Bool = false,
         lastAnnounceResult: String = "", hasScraped: Bool = false,
         lastScrapeSucceeded: Bool = false, lastScrapeResult: String = "",
         nextAnnounceTime: Double = 0, seederCount: Int = -1, leecherCount: Int = -1) {
        self.id = id
        self.announce = announce
        self.announceState = announceState
        self.hasAnnounced = hasAnnounced
        self.lastAnnounceSucceeded = lastAnnounceSucceeded
        self.lastAnnounceResult = lastAnnounceResult
        self.hasScraped = hasScraped
        self.lastScrapeSucceeded = lastScrapeSucceeded
        self.lastScrapeResult = lastScrapeResult
        self.nextAnnounceTime = nextAnnounceTime
        self.seederCount = seederCount
        self.leecherCount = leecherCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        announce = try c.decodeIfPresent(String.self, forKey: .announce) ?? ""
        announceState = try c.decodeIfPresent(Int.self, forKey: .announceState) ?? 0
        hasAnnounced = try c.decodeIfPresent(Bool.self, forKey: .hasAnnounced) ?? false
        lastAnnounceSucceeded = try c.decodeIfPresent(Bool.self, forKey: .lastAnnounceSucceeded) ?? false
        lastAnnounceResult = try c.decodeIfPresent(String.self, forKey: .lastAnnounceResult) ?? ""
        hasScraped = try c.decodeIfPresent(Bool.self, forKey: .hasScraped) ?? false
        lastScrapeSucceeded = try c.decodeIfPresent(Bool.self, forKey: .lastScrapeSucceeded) ?? false
        lastScrapeResult = try c.decodeIfPresent(String.self, forKey: .lastScrapeResult) ?? ""
        nextAnnounceTime = try c.decodeIfPresent(Double.self, forKey: .nextAnnounceTime) ?? 0
        seederCount = try c.decodeIfPresent(Int.self, forKey: .seederCount) ?? -1
        leecherCount = try c.decodeIfPresent(Int.self, forKey: .leecherCount) ?? -1
    }

    /// True while an announce is queued or in flight.
    var isUpdating: Bool { announceState == 2 || announceState == 3 }

    /// The Status column (legacy `FillTrackersList`): "Updating" mid-announce,
    /// "Working" after a successful one, otherwise the tracker's own error
    /// text; empty before the first announce. A tracker whose announce worked
    /// but whose scrape failed shows the scrape error — the "tracker doesn't
    /// recognize this torrent" case.
    var statusText: String {
        if isUpdating { return "Updating" }
        guard hasAnnounced else { return "" }
        guard lastAnnounceSucceeded else { return lastAnnounceResult }
        if hasScraped, !lastScrapeSucceeded, !lastScrapeResult.isEmpty { return lastScrapeResult }
        return "Working"
    }

    /// Seconds until the next announce: `nil` when none is scheduled (or one is
    /// in flight — see `isUpdating`), otherwise clamped to `>= 0`.
    func secondsUntilNextAnnounce(now: Date = Date()) -> Int? {
        guard !isUpdating, nextAnnounceTime > 0 else { return nil }
        return max(0, Int(nextAnnounceTime - now.timeIntervalSince1970))
    }
}

extension TrackerStatsInfo {
    /// The Update In cell: "Updating…" mid-announce, a countdown, or "–" when
    /// nothing is scheduled.
    func updateInText(now: Date = Date()) -> String {
        if isUpdating { return "Updating…" }
        guard let seconds = secondsUntilNextAnnounce(now: now) else { return "–" }
        // `eta(0)` reads "Done"; an announce that is due now is "0s", not done.
        return seconds == 0 ? "0s" : Formatters.eta(seconds)
    }

    /// Seeds / Leechers cells: blank while the tracker hasn't reported (`< 0`).
    var seedsText: String { seederCount >= 0 ? "\(seederCount)" : "" }
    var leechersText: String { leecherCount >= 0 ? "\(leecherCount)" : "" }
}

// MARK: - Detail-table helpers

/// Header-click cycle shared by the detail tables: ascending → descending →
/// unsorted. AppKit never clears a sort descriptor itself, so a second click
/// on a descending column (which AppKit flips back to ascending) is the cue
/// to clear it.
enum HeaderSortCycle {
    /// `togglingKey` names a column that only flips ascending ↔ descending
    /// (never clears), e.g. the Files tab's Name column.
    static func shouldClear(oldKey: String?, oldAscending: Bool?,
                            newKey: String?, newAscending: Bool?,
                            togglingKey: String? = nil) -> Bool {
        guard let newKey, let oldKey, let newAscending, let oldAscending else { return false }
        return newKey == oldKey && newKey != togglingKey && newAscending && !oldAscending
    }
}

/// Orders overlapping async fetches: each fetch takes a ticket when it starts,
/// and a result is applied only if no later-started fetch has already applied.
/// A slow fetch begun before a change can then never overwrite the post-change
/// refetch that finished first.
struct FetchSequencer {
    private var issued = 0
    private var applied = 0

    mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// True (and records it) when `ticket` is newer than anything applied so far.
    mutating func shouldApply(_ ticket: Int) -> Bool {
        guard ticket > applied else { return false }
        applied = ticket
        return true
    }
}

/// Rows to re-select after a reload, by identity (a sort or a poll can move
/// items to other rows).
func rowsToReselect<Item: Identifiable>(ids: Set<Item.ID>, in items: [Item]) -> IndexSet {
    IndexSet(items.indices.filter { ids.contains(items[$0].id) })
}

/// One torrent's `trackerStats` array from a single-torrent `torrent-get`.
struct TorrentTrackersEntry: Decodable, Sendable {
    let id: Int
    let trackerStats: [TrackerStatsInfo]
}

/// Decoded `arguments` for a single-torrent trackers `torrent-get`.
struct TorrentTrackersArguments: Decodable, Sendable {
    let torrents: [TorrentTrackersEntry]
}

// MARK: - Trackers sorting

/// Sortable columns of the Trackers tab; raw values match `TrackerColumn`
/// identifiers (the `NSSortDescriptor` keys).
enum TrackerSortKey: String, Sendable {
    case name, status, updateIn, seeds, leechers

    /// Trackers in the given order. `nil` keeps the daemon's order (the third
    /// header-click state). Ties break by tracker id, always ascending.
    /// "No next announce" sorts as 0, so unscheduled trackers cluster together.
    static func sorted(_ trackers: [TrackerStatsInfo], by key: TrackerSortKey?, ascending: Bool,
                       now: Date = Date()) -> [TrackerStatsInfo] {
        guard let key else { return trackers }
        func compare<T: Comparable>(_ l: T, _ r: T) -> ComparisonResult {
            l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
        }
        return trackers.sorted { a, b in
            let order: ComparisonResult
            switch key {
            case .name: order = a.announce.localizedStandardCompare(b.announce)
            case .status: order = a.statusText.localizedCaseInsensitiveCompare(b.statusText)
            case .updateIn: order = compare(a.secondsUntilNextAnnounce(now: now) ?? 0,
                                            b.secondsUntilNextAnnounce(now: now) ?? 0)
            case .seeds: order = compare(a.seederCount, b.seederCount)
            case .leechers: order = compare(a.leecherCount, b.leecherCount)
            }
            if order != .orderedSame {
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return a.id < b.id
        }
    }
}

/// Subset of `session-get` we care about for the MVP.
struct SessionInfo: Codable, Sendable {
    let version: String
    let downloadDir: String?

    enum CodingKeys: String, CodingKey {
        case version
        case downloadDir = "download-dir"
    }
}

// MARK: - RPC envelope

/// Generic Transmission RPC response: `{ "result": "...", "arguments": { ... } }`.
struct RPCResponse<Arguments: Decodable>: Decodable {
    let result: String
    let arguments: Arguments?
}

/// Decoded `arguments` for `torrent-get`.
struct TorrentListArguments: Decodable, Sendable {
    let torrents: [Torrent]
}

// MARK: - Files RPC decoding

/// Raw `files` array entry from a single-torrent `torrent-get`.
private struct RawFile: Decodable {
    let name: String
    let length: Int64
    let bytesCompleted: Int64
}

/// Raw `fileStats` array entry (parallel to `files`).
private struct RawFileStat: Decodable {
    let wanted: Bool
    let priority: Int
}

/// One torrent's `files` + `fileStats`, merged into `[TorrentFile]`.
struct TorrentFilesEntry: Decodable, Sendable {
    let id: Int
    let files: [TorrentFile]

    private enum CodingKeys: String, CodingKey {
        case id, files, fileStats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        let raw = try c.decode([RawFile].self, forKey: .files)
        let stats = try c.decodeIfPresent([RawFileStat].self, forKey: .fileStats) ?? []
        files = raw.enumerated().map { index, file in
            let stat = stats.indices.contains(index) ? stats[index] : nil
            return TorrentFile(
                index: index,
                name: file.name,
                length: file.length,
                bytesCompleted: file.bytesCompleted,
                wanted: stat?.wanted ?? true,
                priorityRaw: stat?.priority ?? 0
            )
        }
    }
}

/// Decoded `arguments` for a single-torrent files `torrent-get`.
struct TorrentFilesArguments: Decodable, Sendable {
    let torrents: [TorrentFilesEntry]
}

// MARK: - Peers RPC decoding

/// One entry from a torrent's `peers` array (single-torrent `torrent-get`).
/// Everything but `address` decodes tolerantly: daemons omit zero-valued
/// fields (`rateToClient`/`rateToPeer`, sometimes `port`) — the legacy app
/// guarded those with `IndexOfName`.
struct TorrentPeer: Decodable, Sendable, Equatable, Identifiable {
    let address: String
    let port: Int
    let clientName: String
    let flagStr: String
    let progress: Double
    let rateToClient: Int64
    let rateToPeer: Int64
    let isEncrypted: Bool
    let isIncoming: Bool
    let isUTP: Bool
    let isDownloadingFrom: Bool
    let isUploadingTo: Bool

    /// Address + port — unique per connected peer; the identity that survives
    /// the table reloads each poll.
    var id: String { "\(address):\(port)" }

    private enum CodingKeys: String, CodingKey {
        case address, port, clientName, flagStr, progress
        case rateToClient, rateToPeer
        case isEncrypted, isIncoming, isUTP
        case isDownloadingFrom, isUploadingTo
    }

    init(address: String = "", port: Int = 0, clientName: String = "",
         flagStr: String = "", progress: Double = 0,
         rateToClient: Int64 = 0, rateToPeer: Int64 = 0,
         isEncrypted: Bool = false, isIncoming: Bool = false, isUTP: Bool = false,
         isDownloadingFrom: Bool = false, isUploadingTo: Bool = false) {
        self.address = address
        self.port = port
        self.clientName = clientName
        self.flagStr = flagStr
        self.progress = progress
        self.rateToClient = rateToClient
        self.rateToPeer = rateToPeer
        self.isEncrypted = isEncrypted
        self.isIncoming = isIncoming
        self.isUTP = isUTP
        self.isDownloadingFrom = isDownloadingFrom
        self.isUploadingTo = isUploadingTo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? ""
        flagStr = try c.decodeIfPresent(String.self, forKey: .flagStr) ?? ""
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        rateToClient = try c.decodeIfPresent(Int64.self, forKey: .rateToClient) ?? 0
        rateToPeer = try c.decodeIfPresent(Int64.self, forKey: .rateToPeer) ?? 0
        isEncrypted = try c.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        isIncoming = try c.decodeIfPresent(Bool.self, forKey: .isIncoming) ?? false
        isUTP = try c.decodeIfPresent(Bool.self, forKey: .isUTP) ?? false
        isDownloadingFrom = try c.decodeIfPresent(Bool.self, forKey: .isDownloadingFrom) ?? false
        isUploadingTo = try c.decodeIfPresent(Bool.self, forKey: .isUploadingTo) ?? false
    }
}

/// One torrent's `peers` array from a single-torrent `torrent-get`.
struct TorrentPeersEntry: Decodable, Sendable {
    let id: Int
    let peers: [TorrentPeer]
}

/// Decoded `arguments` for a single-torrent peers `torrent-get`.
struct TorrentPeersArguments: Decodable, Sendable {
    let torrents: [TorrentPeersEntry]
}

// MARK: - Peers sorting

/// Sortable columns of the Peers tab. Raw values match `PeerColumn`
/// identifiers (which are the `NSSortDescriptor` keys); sorting itself is the
/// Foundation-only `sorted` below so it is unit-testable.
enum PeerSortKey: String, Sendable {
    case address, client, flags, progress, down, up

    /// `ComparisonResult` for two `Comparable` values (Swift's `Comparable`
    /// has no `compare`, unlike Foundation's `NSNumber`).
    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// Peers in the given order. `nil` key keeps the daemon's own order (the
    /// third header-click state, mirroring the Files tab). Equal primary values
    /// tie-break by address then port, always ascending, so the poll reloads
    /// reorder identically instead of shuffling (`sorted` isn't stable).
    static func sorted(_ peers: [TorrentPeer], by key: PeerSortKey?, ascending: Bool) -> [TorrentPeer] {
        guard let key else { return peers }
        return peers.sorted { a, b in
            let order: ComparisonResult
            switch key {
            // Finder-style numeric-aware compare so IP addresses order by
            // their digit runs ("10.0.0.2" before "10.0.0.10"), not
            // lexicographically.
            case .address: order = a.address.localizedStandardCompare(b.address)
            case .client: order = a.clientName.localizedCaseInsensitiveCompare(b.clientName)
            case .flags: order = a.flagStr.localizedCaseInsensitiveCompare(b.flagStr)
            case .progress: order = compare(a.progress, b.progress)
            case .down: order = compare(a.rateToClient, b.rateToClient)
            case .up: order = compare(a.rateToPeer, b.rateToPeer)
            }
            if order != .orderedSame {
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            let byAddress = a.address.localizedStandardCompare(b.address)
            if byAddress != .orderedSame { return byAddress == .orderedAscending }
            return a.port < b.port
        }
    }
}

// MARK: - torrent-add

/// The torrent named in a `torrent-add` response (under `torrent-added` or
/// `torrent-duplicate`).
struct AddedTorrent: Decodable, Sendable {
    let id: Int?
    let name: String?
    let hashString: String?
}

/// Decoded `arguments` for `torrent-add`. Exactly one of these is present.
struct AddArguments: Decodable, Sendable {
    let added: AddedTorrent?
    let duplicate: AddedTorrent?

    enum CodingKeys: String, CodingKey {
        case added = "torrent-added"
        case duplicate = "torrent-duplicate"
    }
}

/// Outcome of an add request, surfaced to the UI.
struct AddOutcome: Sendable {
    let name: String
    let duplicate: Bool
}

/// Decoded `arguments` for `free-space`.
struct FreeSpaceArguments: Decodable, Sendable {
    let path: String
    let sizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size-bytes"
    }
}

// MARK: - Files sorting

/// Sortable columns of the Files tab. Raw values match `FileColumn` identifiers
/// (which are the `NSSortDescriptor` keys). Sorting itself lives in
/// `TorrentFileTree.sorted` — folder nodes compare by their aggregates.
enum TorrentFileSortKey: String, Sendable {
    case name, size, progress, priority
}
