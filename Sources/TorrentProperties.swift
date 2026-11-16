import Foundation

/// One per-torrent setting shown in Torrent ▸ Properties… The raw value is the
/// `torrent-set` key; `readKey` is the `torrent-get` field it is read from
/// (they differ only for the peer limit).
enum TorrentProperty: String, CaseIterable, Sendable {
    case downloadLimited, downloadLimit, uploadLimited, uploadLimit, honorsSessionLimits
    case seedRatioMode, seedRatioLimit, seedIdleMode, seedIdleLimit
    case peerLimit = "peer-limit"
    case trackerList

    enum Kind: Sendable, Equatable {
        case boolean, integer(ClosedRange<Int>), decimal, mode, trackers
    }

    var readKey: String { self == .peerLimit ? "maxConnectedPeers" : rawValue }

    var kind: Kind {
        switch self {
        case .downloadLimited, .uploadLimited, .honorsSessionLimits: .boolean
        case .downloadLimit, .uploadLimit: .integer(0...2_147_483_647)
        case .seedRatioMode, .seedIdleMode: .mode
        case .seedRatioLimit: .decimal
        // The daemon stores both as 16-bit values; larger numbers would not read back.
        case .seedIdleLimit: .integer(1...65_535)
        case .peerLimit: .integer(1...65_535)
        case .trackerList: .trackers
        }
    }

    /// The flag or mode that must be on for this value to apply.
    var companion: TorrentProperty? {
        switch self {
        case .downloadLimit: .downloadLimited
        case .uploadLimit: .uploadLimited
        case .seedRatioLimit: .seedRatioMode
        case .seedIdleLimit: .seedIdleMode
        default: nil
        }
    }

    /// The companion value that makes this value apply (`true`, or mode 1 = this torrent's own limit).
    var companionActiveText: String { companion?.kind == .mode ? String(SeedRatioMode.single.rawValue) : "true" }

    /// Labels match the server Speed tab where the setting has a server counterpart.
    var title: String {
        switch self {
        case .downloadLimited: ServerOption.downEnabled.definition.title
        case .downloadLimit: ServerOption.down.definition.title
        case .uploadLimited: ServerOption.upEnabled.definition.title
        case .uploadLimit: ServerOption.up.definition.title
        case .honorsSessionLimits: "Honor server speed limits"
        case .seedRatioMode: "Seed ratio limit"
        case .seedRatioLimit: "Stop at ratio"
        case .seedIdleMode: "Idle seeding limit"
        case .seedIdleLimit: "Stop when idle for (minutes)"
        case .peerLimit: "Peer limit"
        case .trackerList: "Trackers"
        }
    }
}

/// The `torrent-get` fields behind the Properties sheet. Fetched on demand when
/// the sheet opens, never in the poll.
struct TorrentProperties: Decodable, Sendable, Equatable {
    var hashString: String
    var name: String
    var downloadLimit: Int?
    var downloadLimited: Bool?
    var uploadLimit: Int?
    var uploadLimited: Bool?
    var honorsSessionLimits: Bool?
    var seedRatioMode: Int?
    var seedRatioLimit: Double?
    var seedIdleMode: Int?
    var seedIdleLimit: Int?
    var maxConnectedPeers: Int?
    /// One announce URL per line, a blank line between tiers (rpc 17+).
    var trackerList: String?

    static let requestedFields = ["hashString", "name"] + TorrentProperty.allCases.map(\.readKey)

    init(hashString: String, name: String, downloadLimit: Int? = nil, downloadLimited: Bool? = nil,
         uploadLimit: Int? = nil, uploadLimited: Bool? = nil, honorsSessionLimits: Bool? = nil,
         seedRatioMode: Int? = nil, seedRatioLimit: Double? = nil, seedIdleMode: Int? = nil,
         seedIdleLimit: Int? = nil, maxConnectedPeers: Int? = nil, trackerList: String? = nil) {
        self.hashString = hashString
        self.name = name
        self.downloadLimit = downloadLimit
        self.downloadLimited = downloadLimited
        self.uploadLimit = uploadLimit
        self.uploadLimited = uploadLimited
        self.honorsSessionLimits = honorsSessionLimits
        self.seedRatioMode = seedRatioMode
        self.seedRatioLimit = seedRatioLimit
        self.seedIdleMode = seedIdleMode
        self.seedIdleLimit = seedIdleLimit
        self.maxConnectedPeers = maxConnectedPeers
        self.trackerList = trackerList
    }

    func value(_ property: TorrentProperty) -> ServerOptionValue? {
        switch property {
        case .downloadLimited: downloadLimited.map { .bool($0) }
        case .downloadLimit: downloadLimit.map { .int($0) }
        case .uploadLimited: uploadLimited.map { .bool($0) }
        case .uploadLimit: uploadLimit.map { .int($0) }
        case .honorsSessionLimits: honorsSessionLimits.map { .bool($0) }
        case .seedRatioMode: seedRatioMode.map { .int($0) }
        case .seedRatioLimit: seedRatioLimit.map { .decimal($0) }
        case .seedIdleMode: seedIdleMode.map { .int($0) }
        case .seedIdleLimit: seedIdleLimit.map { .int($0) }
        case .peerLimit: maxConnectedPeers.map { .int($0) }
        case .trackerList: trackerList.map { .string($0) }
        }
    }

    /// Readback equality: decimals within tolerance, trackers by normalized tiers.
    static func same(_ property: TorrentProperty, _ a: ServerOptionValue?, _ b: ServerOptionValue?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if property == .trackerList, case .string(let x) = a, case .string(let y) = b {
            return TrackerListText.tiers(x) == TrackerListText.tiers(y)
        }
        return ServerOptionValue.matches(a, b)
    }
}

/// Tracker-list text: one URL per line, blank lines between tiers. Shared by the
/// server's default trackers and a torrent's tracker list.
enum TrackerListText {
    /// The http/https/udp-per-line rule. Lines are checked as given; empty lines separate tiers.
    static func isValid(_ text: String) -> Bool {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").allSatisfy { line in
            line.isEmpty || isValidURL(line)
        }
    }

    static func isValidURL(_ line: String) -> Bool {
        guard !line.contains(where: { $0.isWhitespace || $0.isNewline }), !line.contains("\0"),
              let url = URLComponents(string: line), ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static let invalidMessage = "use one HTTP, HTTPS or UDP tracker URL per line, with blank lines between tiers."

    /// Trimmed lines grouped into tiers; runs of blank lines collapse, a repeated URL
    /// keeps only its first occurrence, and empty tiers vanish.
    static func tiers(_ text: String) -> [[String]] {
        var seen: Set<String> = []
        return rawTiers(text).map { tier in tier.filter { seen.insert($0).inserted } }.filter { !$0.isEmpty }
    }

    /// The first URL that appears more than once (in any tier), if any.
    static func duplicate(in text: String) -> String? {
        var seen: Set<String> = []
        return rawTiers(text).joined().first { !seen.insert($0).inserted }
    }

    private static func rawTiers(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else { current.append(line) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Canonical text for `tiers`.
    static func normalized(_ text: String) -> String {
        tiers(text).map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }
}

/// Server-wide seeding defaults, for the "Server default (…)" popup items.
struct ServerSeedDefaults: Sendable, Equatable {
    var ratio: String?
    var idle: String?
    /// The bare server value ("2", "30"), for the disabled value field's placeholder; nil when the server has no limit.
    var ratioValue: String?
    var idleValue: String?

    init(ratio: String? = nil, idle: String? = nil) {
        self.ratio = ratio
        self.idle = idle
    }

    init(_ snapshot: ServerOptionsSnapshot) {
        if case .bool(let enabled)? = snapshot.values[.ratioEnabled] {
            if !enabled { ratio = "no limit" }
            else if case .decimal(let value)? = snapshot.values[.ratio] { ratio = ServerDecimal.render(value); ratioValue = ratio }
        }
        if case .bool(let enabled)? = snapshot.values[.idleEnabled] {
            if !enabled { idle = "no limit" }
            else if case .int(let value)? = snapshot.values[.idleMinutes] { idle = "\(value) min"; idleValue = String(value) }
        }
    }

    var ratioTitle: String { ratio.map { "Server default (\($0))" } ?? "Server default" }
    var idleTitle: String { idle.map { "Server default (\($0))" } ?? "Server default" }
}

extension ServerOptionsSnapshot {
    /// Per-torrent `seedIdleMode` / `seedIdleLimit` (rpc 10, Transmission 2.10).
    var supportsSeedIdle: Bool { (rpcVersion ?? 0) >= 10 }
    /// Per-torrent `trackerList` (rpc 17, Transmission 4.0).
    var supportsTrackerList: Bool { (rpcVersion ?? 0) >= 17 }
}

/// Drafts for the Properties sheet over one or more torrents. A field whose
/// torrents disagree is `.mixed`; it stays untouched (each torrent keeps its own
/// value) until the user enters something. `patch()` holds only changed keys.
struct TorrentPropertiesEditor: Sendable {
    enum Baseline: Equatable, Sendable { case value(ServerOptionValue), mixed }

    let torrents: [TorrentProperties]
    /// Absent = not offered (unsupported by the server, or not editable here).
    let baseline: [TorrentProperty: Baseline]
    private(set) var draft: [TorrentProperty: String] = [:]
    /// Why the trackers can't be edited, or nil when they can.
    let trackersUnavailableReason: String?
    let supportsSeedIdle: Bool

    init(_ torrents: [TorrentProperties], supportsSeedIdle: Bool, supportsTrackerList: Bool) {
        self.torrents = torrents
        var baseline: [TorrentProperty: Baseline] = [:]
        for property in TorrentProperty.allCases {
            let values = torrents.map { $0.value(property) }
            guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { continue }
            let first = values[0]!
            baseline[property] = values.allSatisfy({ TorrentProperties.same(property, $0, first) }) ? .value(first) : .mixed
        }
        let idle = supportsSeedIdle && baseline[.seedIdleMode] != nil
        if !idle { baseline[.seedIdleMode] = nil; baseline[.seedIdleLimit] = nil }
        let reason: String? =
            torrents.count != 1 ? "Trackers can be edited for one torrent at a time."
            : !supportsTrackerList || baseline[.trackerList] == nil ? "Editing trackers needs Transmission 4.0 or later."
            : nil
        if reason != nil { baseline[.trackerList] = nil }
        self.baseline = baseline
        self.supportsSeedIdle = idle
        trackersUnavailableReason = reason
    }

    func supports(_ property: TorrentProperty) -> Bool { baseline[property] != nil }
    func isMixed(_ property: TorrentProperty) -> Bool { baseline[property] == .mixed && draft[property] == nil }

    /// The baseline value's text, or "" when mixed or unsupported.
    func baselineText(_ property: TorrentProperty) -> String {
        guard case .value(let value)? = baseline[property] else { return "" }
        return Self.text(value)
    }

    func text(_ property: TorrentProperty) -> String { draft[property] ?? baselineText(property) }

    static func text(_ value: ServerOptionValue) -> String {
        switch value {
        case .bool(let b): b ? "true" : "false"
        case .int(let n): String(n)
        case .decimal(let d): ServerDecimal.render(d)
        case .string(let s): s
        case .strings(let s): s.joined(separator: ",")
        }
    }

    /// An empty entry over a mixed field restores "mixed" (unchanged).
    mutating func set(_ property: TorrentProperty, text: String) {
        guard supports(property) else { return }
        if baseline[property] == .mixed, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft[property] = nil
        } else {
            draft[property] = text
        }
    }

    /// A value is editable unless its companion is definitely off (a mixed companion leaves it editable).
    func isEditable(_ property: TorrentProperty) -> Bool {
        guard supports(property) else { return false }
        guard let companion = property.companion else { return true }
        guard supports(companion) else { return false }
        return isMixed(companion) || text(companion) == property.companionActiveText
    }

    var changedKeys: [TorrentProperty] {
        TorrentProperty.allCases.filter { property in
            guard isEditable(property), let raw = draft[property] else { return false }
            guard case .value(let base)? = baseline[property] else { return true }
            if raw == Self.text(base) { return false }
            if let value = try? parsed(property) { return !TorrentProperties.same(property, base, value) }
            return true
        }
    }

    var isDirty: Bool { !changedKeys.isEmpty }

    func parsed(_ property: TorrentProperty) throws -> ServerOptionValue {
        let raw = text(property).trimmingCharacters(in: .whitespacesAndNewlines)
        func invalid(_ detail: String) -> ServerOptionsError { ServerOptionsError(message: "\(property.title): \(detail)") }
        switch property.kind {
        case .boolean:
            guard raw == "true" || raw == "false" else { throw invalid("choose on or off.") }
            return .bool(raw == "true")
        case .mode:
            guard let n = Int(raw), SeedRatioMode(rawValue: n) != nil else { throw invalid("choose a limit.") }
            return .int(n)
        case .integer(let range):
            guard let n = Int(raw), range.contains(n) else {
                throw invalid("enter a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return .int(n)
        case .decimal:
            guard let n = ServerDecimal.parse(raw), n <= Double(Float.greatestFiniteMagnitude) else {
                throw invalid("enter a finite, non-negative ratio.")
            }
            return .decimal(n)
        case .trackers:
            if let repeated = TrackerListText.duplicate(in: text(property)) {
                throw invalid("\(repeated) is listed more than once. List each tracker once.")
            }
            let normalized = TrackerListText.normalized(text(property))
            guard TrackerListText.isValid(normalized) else { throw invalid(TrackerListText.invalidMessage) }
            return .string(normalized)
        }
    }

    /// Only the changed keys. Turning a limit on while its value is still Mixed sends only the flag.
    func patch() throws -> [TorrentProperty: ServerOptionValue] {
        var result: [TorrentProperty: ServerOptionValue] = [:]
        for property in changedKeys { result[property] = try parsed(property) }
        return result
    }

    var validationError: String? {
        do { _ = try patch(); return nil } catch { return error.localizedDescription }
    }

    /// The first changed field whose entry is invalid (to reveal it).
    var invalidProperty: TorrentProperty? {
        changedKeys.first { (try? parsed($0)) == nil }
    }

    /// Optimistic conflict check against a fresh read: the same torrents, and no
    /// changed key (or the companion it depends on) altered by another client.
    func checkedPatch(latest: [TorrentProperties]) throws -> [TorrentProperty: ServerOptionValue] {
        let changes = try patch()
        let now = Dictionary(latest.map { ($0.hashString, $0) }, uniquingKeysWith: { a, _ in a })
        guard Set(now.keys) == Set(torrents.map(\.hashString)) else {
            throw ServerOptionsError(message: "The selected torrents changed on the server. Click Revert to reload them.")
        }
        var conflicts: [TorrentProperty] = []
        for property in TorrentProperty.allCases {
            let desired = changes[property]
            // A changed key, the flag/mode it depends on, or the value a changed flag/mode switches on.
            let related = TorrentProperty.allCases.contains { changes[$0] != nil && $0.companion == property }
                || property.companion.map { changes[$0] != nil } == true
            guard desired != nil || related else { continue }
            for before in torrents {
                let current = now[before.hashString]?.value(property)
                if TorrentProperties.same(property, before.value(property), current) { continue }
                if let desired, TorrentProperties.same(property, current, desired) { continue }
                conflicts.append(property)
                break
            }
        }
        guard conflicts.isEmpty else {
            throw ServerOptionsError(message: "These settings changed on the server: "
                + conflicts.map(\.title).joined(separator: ", ") + ". Click Revert to load the current values.")
        }
        return changes
    }

    /// Every changed key reads back as sent on every torrent.
    static func mismatches(_ changes: [TorrentProperty: ServerOptionValue], in readback: [TorrentProperties],
                           hashes: [String]) -> [TorrentProperty] {
        let byHash = Dictionary(readback.map { ($0.hashString, $0) }, uniquingKeysWith: { a, _ in a })
        return TorrentProperty.allCases.filter { property in
            guard let desired = changes[property] else { return false }
            return hashes.contains { !TorrentProperties.same(property, byHash[$0]?.value(property), desired) }
        }
    }
}

/// What the Properties sheet needs from the server.
protocol TorrentPropertiesService: Sendable {
    func fetchServerOptions() async throws -> ServerOptionsSnapshot
    func fetchTorrentProperties(hashes: [String]) async throws -> [TorrentProperties]
    func setTorrentProperties(hashes: [String], arguments: [TorrentProperty: ServerOptionValue]) async throws
}

/// One sheet's load / Apply. It holds the hashes captured when the sheet opened,
/// so a server switch or a daemon restart never retargets it.
@MainActor
final class TorrentPropertiesSession {
    let service: any TorrentPropertiesService
    let hashes: [String]
    private(set) var editor: TorrentPropertiesEditor?
    private(set) var defaults = ServerSeedDefaults()
    private var capabilities: (seedIdle: Bool, trackerList: Bool) = (false, false)
    private(set) var isBusy = false
    /// A write may have taken effect without being verified; Apply stays blocked.
    private(set) var needsReload = false

    init(service: any TorrentPropertiesService, hashes: [String]) {
        self.service = service
        self.hashes = hashes
    }

    func set(_ property: TorrentProperty, text: String) {
        guard !isBusy, !needsReload else { return }
        editor?.set(property, text: text)
    }

    func load() async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let options = try await service.fetchServerOptions()
        let torrents = try await service.fetchTorrentProperties(hashes: hashes)
        guard Set(torrents.map(\.hashString)) == Set(hashes) else {
            throw ServerOptionsError(message: "Some selected torrents are no longer available.")
        }
        let ordered = hashes.compactMap { hash in torrents.first { $0.hashString == hash } }
        defaults = ServerSeedDefaults(options)
        capabilities = (options.supportsSeedIdle, options.supportsTrackerList)
        editor = TorrentPropertiesEditor(ordered, supportsSeedIdle: capabilities.seedIdle,
                                         supportsTrackerList: capabilities.trackerList)
        needsReload = false
    }

    /// Conflict check, `torrent-set` with the changed keys only, then readback.
    func apply() async throws {
        guard !isBusy, let editor else { return }
        guard !needsReload else { throw ServerOptionsError(message: "Click Revert to load the current values before applying again.") }
        let initial = try editor.patch()
        guard !initial.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        let latest = try await service.fetchTorrentProperties(hashes: hashes)
        let changes = try editor.checkedPatch(latest: latest)
        needsReload = true
        do {
            try await service.setTorrentProperties(hashes: hashes, arguments: changes)
            let verified = try await service.fetchTorrentProperties(hashes: hashes)
            let wrong = TorrentPropertiesEditor.mismatches(changes, in: verified, hashes: hashes)
            guard wrong.isEmpty else {
                throw ServerOptionsError(message: "The server did not keep: " + wrong.map(\.title).joined(separator: ", ") + ".")
            }
            let ordered = hashes.compactMap { hash in verified.first { $0.hashString == hash } }
            self.editor = TorrentPropertiesEditor(ordered, supportsSeedIdle: capabilities.seedIdle,
                                                  supportsTrackerList: capabilities.trackerList)
            needsReload = false
        } catch {
            throw ServerOptionsError(message: "The change could not be fully verified. \(error.localizedDescription) Click Revert to load the current values.")
        }
    }
}
