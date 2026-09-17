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
    }

    var status: TorrentStatus { TorrentStatus(rawValue: statusRaw) ?? .stopped }

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
        "seedRatioMode",
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
        "queuePosition", "bandwidthPriority",
    ]
}

/// One tracker entry from a torrent's `trackers` array (we only need the URL).
struct TrackerInfo: Codable, Sendable, Equatable {
    let announce: String
}

/// One entry from a torrent's `trackerStats` array — swarm-wide seeder/leecher
/// counts as last reported by that tracker (`-1` means "unknown").
struct TrackerStatsInfo: Codable, Sendable, Equatable {
    let seederCount: Int
    let leecherCount: Int
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
