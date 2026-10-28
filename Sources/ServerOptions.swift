import Foundation

/// Writable session settings, including the legacy µTP fallback. Keep wire names separate
/// from connection preferences. Presence in session-get is the capability check.
enum ServerOption: String, CaseIterable, Sendable {
    case downloadDir = "download-dir"
    case incompleteEnabled = "incomplete-dir-enabled"
    case incompleteDir = "incomplete-dir"
    case renamePartial = "rename-partial-files"
    case cacheSize = "cache-size-mb"
    case ratioEnabled = "seedRatioLimited"
    case ratio = "seedRatioLimit"
    case idleEnabled = "idle-seeding-limit-enabled"
    case idleMinutes = "idle-seeding-limit"
    case peerPort = "peer-port"
    case randomPort = "peer-port-random-on-start"
    case portForwarding = "port-forwarding-enabled"
    case encryption
    case globalPeers = "peer-limit-global"
    case torrentPeers = "peer-limit-per-torrent"
    case pex = "pex-enabled"
    case dht = "dht-enabled"
    case lpd = "lpd-enabled"
    case utp = "utp-enabled"
    case downEnabled = "speed-limit-down-enabled"
    case down = "speed-limit-down"
    case upEnabled = "speed-limit-up-enabled"
    case up = "speed-limit-up"
    case altEnabled = "alt-speed-enabled"
    case altDown = "alt-speed-down"
    case altUp = "alt-speed-up"
    case scheduleEnabled = "alt-speed-time-enabled"
    case scheduleBegin = "alt-speed-time-begin"
    case scheduleEnd = "alt-speed-time-end"
    case scheduleDays = "alt-speed-time-day"
    case downloadQueueEnabled = "download-queue-enabled"
    case downloadQueue = "download-queue-size"
    case seedQueueEnabled = "seed-queue-enabled"
    case seedQueue = "seed-queue-size"
    case stalledEnabled = "queue-stalled-enabled"
    case stalledMinutes = "queue-stalled-minutes"

    case startAdded = "start-added-torrents"
    case sequential = "sequential_download"
    case trashOriginal = "trash-original-torrent-files"
    case defaultTrackers = "default-trackers"
    case transports = "preferred_transports"
    case bruteForce = "anti-brute-force-enabled"
    case bruteForceThreshold = "anti-brute-force-threshold"
    case requestQueue = "reqq"
    case addedScriptEnabled = "script-torrent-added-enabled"
    case addedScript = "script-torrent-added-filename"
    case doneScriptEnabled = "script-torrent-done-enabled"
    case doneScript = "script-torrent-done-filename"
    case seededScriptEnabled = "script-torrent-done-seeding-enabled"
    case seededScript = "script-torrent-done-seeding-filename"

    /// The server tab a setting lives on (Settings ▸ <server> ▸ Transfers / Speed /
    /// Network / Advanced). Connection is the fifth tab, but it's stored on this Mac.
    enum Pane: String, CaseIterable, Sendable {
        case transfers = "Transfers", speed = "Speed", network = "Network", advanced = "Advanced"
    }

    /// Progressive disclosure. Essential groups are always shown at the top of a
    /// tab; common groups sit below and can be collapsed; advanced settings live
    /// on the Advanced tab.
    enum Tier: Int, Comparable, CaseIterable, Sendable {
        case essential, common, advanced
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    enum Kind: Sendable {
        case boolean, integer(ClosedRange<Int>), decimal, directory, encryption, time, days, scriptPath, trackers, transports
    }

    struct Definition: Sendable {
        let key: ServerOption
        let title: String
        let kind: Kind
        let pane: Pane
        let tier: Tier
        let group: String
        var dependency: ServerOption? = nil
        var dependencyValue: Bool = true
    }

    /// Declaration order is display order. A dependent field always shares its
    /// parent's pane, tier and group (tested), so disclosure never hides a parent
    /// while showing its child.
    static let definitions: [Definition] = [
        // Transfers
        .init(key: .downloadDir, title: "Default download folder", kind: .directory, pane: .transfers, tier: .essential, group: "Downloads"),
        .init(key: .startAdded, title: "Start new torrents automatically", kind: .boolean, pane: .transfers, tier: .essential, group: "Downloads"),
        .init(key: .ratioEnabled, title: "Stop seeding at a ratio", kind: .boolean, pane: .transfers, tier: .essential, group: "Seeding"),
        .init(key: .ratio, title: "Seed ratio", kind: .decimal, pane: .transfers, tier: .essential, group: "Seeding", dependency: .ratioEnabled),
        .init(key: .idleEnabled, title: "Stop seeding when inactive", kind: .boolean, pane: .transfers, tier: .essential, group: "Seeding"),
        .init(key: .idleMinutes, title: "Inactive for (minutes)", kind: .integer(1...2_147_483_647), pane: .transfers, tier: .essential, group: "Seeding", dependency: .idleEnabled),
        .init(key: .downloadQueueEnabled, title: "Limit active downloads", kind: .boolean, pane: .transfers, tier: .essential, group: "Queue"),
        .init(key: .downloadQueue, title: "Download queue size", kind: .integer(0...2_147_483_647), pane: .transfers, tier: .essential, group: "Queue", dependency: .downloadQueueEnabled),
        .init(key: .seedQueueEnabled, title: "Limit active seeds", kind: .boolean, pane: .transfers, tier: .essential, group: "Queue"),
        .init(key: .seedQueue, title: "Seeding queue size", kind: .integer(0...2_147_483_647), pane: .transfers, tier: .essential, group: "Queue", dependency: .seedQueueEnabled),
        .init(key: .incompleteEnabled, title: "Use a separate folder for incomplete files", kind: .boolean, pane: .transfers, tier: .common, group: "Incomplete downloads"),
        .init(key: .incompleteDir, title: "Incomplete folder", kind: .directory, pane: .transfers, tier: .common, group: "Incomplete downloads", dependency: .incompleteEnabled),
        .init(key: .renamePartial, title: "Add .part extension to incomplete files", kind: .boolean, pane: .transfers, tier: .common, group: "Incomplete downloads"),
        .init(key: .sequential, title: "Download new torrents sequentially", kind: .boolean, pane: .transfers, tier: .common, group: "Incomplete downloads"),
        .init(key: .stalledEnabled, title: "Exclude stalled torrents from queue limits", kind: .boolean, pane: .transfers, tier: .common, group: "Stalled torrents"),
        .init(key: .stalledMinutes, title: "Stalled after (minutes)", kind: .integer(1...2_147_483_647), pane: .transfers, tier: .common, group: "Stalled torrents", dependency: .stalledEnabled),
        // Speed
        .init(key: .downEnabled, title: "Limit download speed", kind: .boolean, pane: .speed, tier: .essential, group: "Speed limits"),
        .init(key: .down, title: "Download (kB/s)", kind: .integer(0...2_147_483_647), pane: .speed, tier: .essential, group: "Speed limits", dependency: .downEnabled),
        .init(key: .upEnabled, title: "Limit upload speed", kind: .boolean, pane: .speed, tier: .essential, group: "Speed limits"),
        .init(key: .up, title: "Upload (kB/s)", kind: .integer(0...2_147_483_647), pane: .speed, tier: .essential, group: "Speed limits", dependency: .upEnabled),
        .init(key: .altEnabled, title: "Use alternative speed limits (turtle mode)", kind: .boolean, pane: .speed, tier: .essential, group: "Turtle mode"),
        .init(key: .altDown, title: "Alternative download (kB/s)", kind: .integer(0...2_147_483_647), pane: .speed, tier: .essential, group: "Turtle mode"),
        .init(key: .altUp, title: "Alternative upload (kB/s)", kind: .integer(0...2_147_483_647), pane: .speed, tier: .essential, group: "Turtle mode"),
        .init(key: .scheduleEnabled, title: "Schedule alternative limits", kind: .boolean, pane: .speed, tier: .common, group: "Schedule"),
        .init(key: .scheduleBegin, title: "From (24-hour time)", kind: .time, pane: .speed, tier: .common, group: "Schedule", dependency: .scheduleEnabled),
        .init(key: .scheduleEnd, title: "Until (24-hour time)", kind: .time, pane: .speed, tier: .common, group: "Schedule", dependency: .scheduleEnabled),
        .init(key: .scheduleDays, title: "Days", kind: .days, pane: .speed, tier: .common, group: "Schedule", dependency: .scheduleEnabled),
        // Network
        .init(key: .peerPort, title: "Incoming peer port", kind: .integer(1...65535), pane: .network, tier: .essential, group: "Incoming port", dependency: .randomPort, dependencyValue: false),
        .init(key: .randomPort, title: "Choose a random port on server startup", kind: .boolean, pane: .network, tier: .essential, group: "Incoming port"),
        .init(key: .portForwarding, title: "Enable port forwarding (UPnP / NAT-PMP)", kind: .boolean, pane: .network, tier: .essential, group: "Incoming port"),
        .init(key: .encryption, title: "Encryption", kind: .encryption, pane: .network, tier: .common, group: "Peers"),
        .init(key: .globalPeers, title: "Global peer limit", kind: .integer(0...65535), pane: .network, tier: .common, group: "Peers"),
        .init(key: .torrentPeers, title: "Per-torrent peer limit", kind: .integer(0...65535), pane: .network, tier: .common, group: "Peers"),
        // Advanced
        .init(key: .pex, title: "Enable Peer Exchange (PEX)", kind: .boolean, pane: .advanced, tier: .advanced, group: "Peer discovery"),
        .init(key: .dht, title: "Enable distributed hash table (DHT)", kind: .boolean, pane: .advanced, tier: .advanced, group: "Peer discovery"),
        .init(key: .lpd, title: "Enable local peer discovery", kind: .boolean, pane: .advanced, tier: .advanced, group: "Peer discovery"),
        .init(key: .transports, title: "Peer transports", kind: .transports, pane: .advanced, tier: .advanced, group: "Peer discovery"),
        .init(key: .utp, title: "Enable µTP", kind: .boolean, pane: .advanced, tier: .advanced, group: "Peer discovery"),
        .init(key: .trashOriginal, title: "Delete .torrent files added from the server’s watch folder", kind: .boolean, pane: .advanced, tier: .advanced, group: "Watch folder"),
        .init(key: .cacheSize, title: "Disk cache (MiB)", kind: .integer(0...2_147_483_647), pane: .advanced, tier: .advanced, group: "Performance"),
        .init(key: .requestQueue, title: "Queued requests per peer", kind: .integer(1...2_147_483_647), pane: .advanced, tier: .advanced, group: "Performance"),
        .init(key: .bruteForce, title: "Enable RPC brute-force protection", kind: .boolean, pane: .advanced, tier: .advanced, group: "Authentication"),
        .init(key: .bruteForceThreshold, title: "Failed authentication threshold", kind: .integer(1...2_147_483_647), pane: .advanced, tier: .advanced, group: "Authentication", dependency: .bruteForce),
        .init(key: .defaultTrackers, title: "Default trackers", kind: .trackers, pane: .advanced, tier: .advanced, group: "Default trackers"),
        .init(key: .addedScriptEnabled, title: "Run a script when a torrent is added", kind: .boolean, pane: .advanced, tier: .advanced, group: "Server scripts"),
        .init(key: .addedScript, title: "Torrent added script", kind: .scriptPath, pane: .advanced, tier: .advanced, group: "Server scripts", dependency: .addedScriptEnabled),
        .init(key: .doneScriptEnabled, title: "Run a script when downloading finishes", kind: .boolean, pane: .advanced, tier: .advanced, group: "Server scripts"),
        .init(key: .doneScript, title: "Download finished script", kind: .scriptPath, pane: .advanced, tier: .advanced, group: "Server scripts", dependency: .doneScriptEnabled),
        .init(key: .seededScriptEnabled, title: "Run a script when seeding finishes", kind: .boolean, pane: .advanced, tier: .advanced, group: "Server scripts"),
        .init(key: .seededScript, title: "Seeding finished script", kind: .scriptPath, pane: .advanced, tier: .advanced, group: "Server scripts", dependency: .seededScriptEnabled),
    ]

    /// One heading-and-fields block on a server tab.
    struct Group: Equatable, Sendable {
        let name: String
        let pane: Pane
        let tier: Tier
        let keys: [ServerOption]
        /// Essential groups are always open; the rest have a disclosure triangle.
        var isCollapsible: Bool { tier != .essential }
        /// Common groups start collapsed (progressive disclosure). On the
        /// Advanced tab only the long, rarely touched groups start collapsed.
        var isExpandedByDefault: Bool {
            switch tier {
            case .essential: true
            case .common: false
            case .advanced: !Self.collapsedAdvanced.contains(name)
            }
        }
        static let collapsedAdvanced: Set<String> = ["Default trackers", "Server scripts"]
    }

    /// Groups in display order, derived from `definitions`.
    static let groups: [Group] = {
        var result: [Group] = []
        for field in definitions {
            if let last = result.last, last.name == field.group, last.pane == field.pane {
                result[result.count - 1] = Group(name: last.name, pane: last.pane, tier: last.tier, keys: last.keys + [field.key])
            } else {
                result.append(Group(name: field.group, pane: field.pane, tier: field.tier, keys: [field.key]))
            }
        }
        return result
    }()

    static func groups(in pane: Pane) -> [Group] { groups.filter { $0.pane == pane } }

    var definition: Definition { Self.definitions.first { $0.key == self }! }
    var group: Group { Self.groups.first { $0.keys.contains(self) }! }
}

enum ServerEncryption: String, CaseIterable, Sendable {
    case tolerated, preferred, required
    var displayName: String {
        switch self {
        case .tolerated: "Allow encryption"
        case .preferred: "Prefer encryption"
        case .required: "Require encryption"
        }
    }
}

enum ServerOptionValue: Equatable, Sendable {
    case bool(Bool), int(Int), decimal(Double), string(String), strings([String])

    var jsonValue: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .decimal(let value): value
        case .string(let value): value
        case .strings(let value): value
        }
    }

    func text(for key: ServerOption) -> String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value):
            if case .time = key.definition.kind {
                return String(format: "%02d:%02d", value / 60, value % 60)
            }
            return String(value)
        case .decimal(let value): return String(value)
        case .string(let value): return value
        case .strings(let value): return value.joined(separator: ",")
        }
    }
}

struct ServerOptionsSnapshot: Decodable, Sendable, Equatable {
    var version: String
    var values: [ServerOption: ServerOptionValue]
    var rpcVersion: Int?
    var rpcSemver: String?

    var supportsGroups: Bool { (rpcVersion ?? 0) >= 17 || semverAtLeast(5, 3) }
    var supportsPortProtocol: Bool { (rpcVersion ?? 0) >= 18 || semverAtLeast(6, 0) }
    private func semverAtLeast(_ major: Int, _ minor: Int) -> Bool {
        let parts = (rpcSemver ?? "").split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 && (parts[0] > major || (parts[0] == major && parts[1] >= minor))
    }

    init(version: String, values: [ServerOption: ServerOptionValue], rpcVersion: Int? = nil, rpcSemver: String? = nil) {
        self.version = version
        self.values = values
        self.rpcVersion = rpcVersion
        self.rpcSemver = rpcSemver
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        version = try c.decode(String.self, forKey: Key("version"))
        rpcVersion = try c.decodeIfPresent(Int.self, forKey: Key("rpc-version"))
        rpcSemver = try c.decodeIfPresent(String.self, forKey: Key("rpc-version-semver"))
        values = [:]
        for field in ServerOption.definitions {
            let key = Key(field.key.rawValue)
            guard c.contains(key), try !c.decodeNil(forKey: key) else { continue }
            switch field.kind {
            case .boolean: values[field.key] = .bool(try c.decode(Bool.self, forKey: key))
            case .integer, .time, .days: values[field.key] = .int(try c.decode(Int.self, forKey: key))
            case .transports: values[field.key] = .strings(try c.decode([String].self, forKey: key))
            case .decimal: values[field.key] = .decimal(try c.decode(Double.self, forKey: key))
            case .directory, .encryption, .scriptPath, .trackers: values[field.key] = .string(try c.decode(String.self, forKey: key))
            }
        }
    }
}

struct ServerOptionsError: LocalizedError, Sendable {
    var message: String
    var fields: [ServerOption] = []
    var errorDescription: String? { message }
}

/// Draft values are strings so invalid or partially typed input is never
/// silently coerced to zero. Missing fields stay unavailable, never defaulted.
struct ServerOptionsEditor: Sendable {
    private(set) var baseline: ServerOptionsSnapshot
    private(set) var draft: [ServerOption: String]

    init(_ snapshot: ServerOptionsSnapshot) {
        baseline = snapshot
        draft = [:]
        for (key, value) in snapshot.values { draft[key] = value.text(for: key) }
    }


    func supports(_ key: ServerOption) -> Bool { baseline.values[key] != nil }
    func text(_ key: ServerOption) -> String { draft[key] ?? "" }
    func flag(_ key: ServerOption) -> Bool { text(key) == "true" }

    func isEditable(_ key: ServerOption) -> Bool {
        guard supports(key) else { return false }
        if key == .utp && supports(.transports) { return false }
        let field = key.definition
        guard let dependency = field.dependency else { return true }
        // Older servers may lack random-on-start but still support a fixed port.
        if key == .peerPort, !supports(dependency) { return true }
        return supports(dependency) && flag(dependency) == field.dependencyValue
    }

    mutating func set(_ key: ServerOption, text: String) {
        guard supports(key) else { return }
        draft[key] = text
    }

    var changedKeys: [ServerOption] {
        ServerOption.allCases.filter { key in
            guard isEditable(key) else { return false }
            // Merely opening the editor must never normalize server values.
            // Preserve unchanged strings and future values verbatim.
            guard text(key) != baseline.values[key]?.text(for: key) else { return false }
            if let value = try? parsed(key) { return value != baseline.values[key] }
            return true
        }
    }

    var isDirty: Bool { !changedKeys.isEmpty }

    /// True when any of `keys` has an unsaved edit.
    func hasEdits(in keys: [ServerOption]) -> Bool {
        keys.contains { draft[$0] != nil && draft[$0] != baseline.values[$0]?.text(for: $0) }
    }

    /// Take server values that changed elsewhere (e.g. a limit picked from the
    /// speed menu, seen by the poll) into both the baseline and the draft — but
    /// only when none of those settings has an unsaved edit here. Returns
    /// `.conflict` (and changes nothing) when one does, so the caller can ask
    /// for a Revert (which refetches); the conflict check in `checkedPatch` still blocks a stale Apply.
    enum AbsorbResult: Equatable { case unchanged, updated, conflict }

    mutating func absorb(_ values: [ServerOption: ServerOptionValue]) -> AbsorbResult {
        let changed = values.filter { supports($0.key) && baseline.values[$0.key] != $0.value }
        guard !changed.isEmpty else { return .unchanged }
        if hasEdits(in: Array(changed.keys)) { return .conflict }
        for (key, value) in changed {
            baseline.values[key] = value
            draft[key] = value.text(for: key)
        }
        return .updated
    }

    func parsed(_ key: ServerOption) throws -> ServerOptionValue {
        let raw = text(key).trimmingCharacters(in: .whitespacesAndNewlines)
        func invalid(_ detail: String) -> ServerOptionsError {
            ServerOptionsError(message: "\(key.definition.title): \(detail)", fields: [key])
        }
        switch key.definition.kind {
        case .boolean:
            guard raw == "true" || raw == "false" else { throw invalid("choose on or off.") }
            return .bool(raw == "true")
        case .integer(let range):
            guard let number = Int(raw), range.contains(number) else {
                throw invalid("enter a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return .int(number)
        case .decimal:
            // Accept the user's decimal separator without allowing grouping,
            // NaN, infinity, or partial NumberFormatter parses.
            let separator = Locale.current.decimalSeparator ?? "."
            let normalized = separator == "." ? raw : raw.replacingOccurrences(of: separator, with: ".")
            guard let number = Double(normalized), number.isFinite, number >= 0, number <= Double(Float.greatestFiniteMagnitude) else {
                throw invalid("enter a finite, non-negative ratio.")
            }
            return .decimal(number)
        case .directory, .scriptPath:
            let path = text(key)
            guard !raw.isEmpty, !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
                throw invalid("enter a path on the server without line breaks.")
            }
            return .string(path)
        case .transports:
            guard let choice = ServerTransports(rawValue: raw) else { throw invalid("choose supported peer transports.") }
            return .strings(choice.protocols)
        case .trackers:
            let normalized = text(key).replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            for line in normalized.components(separatedBy: "\n") where !line.isEmpty {
                guard !line.contains(where: { $0.isWhitespace || $0.isNewline }), !line.contains("\0"),
                      let url = URLComponents(string: line), ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty else {
                    throw invalid("use one HTTP, HTTPS or UDP tracker URL per line, with blank lines between tiers.")
                }
            }
            return .string(normalized)
        case .encryption:
            guard ServerEncryption(rawValue: raw) != nil else { throw invalid("choose a supported encryption mode.") }
            return .string(raw)
        case .time:
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else {
                throw invalid("enter a 24-hour time such as 09:30.")
            }
            return .int(hour * 60 + minute)
        case .days:
            guard let mask = Int(raw), (1...127).contains(mask) else { throw invalid("select at least one day.") }
            return .int(mask)
        }
    }

    func patch() throws -> [ServerOption: ServerOptionValue] {
        var result: [ServerOption: ServerOptionValue] = [:]
        for key in changedKeys { result[key] = try parsed(key) }
        // Enabling an option must also validate its now-active values, even
        // when they were not edited (e.g. an empty incomplete folder).
        for field in ServerOption.definitions where isEditable(field.key) {
            if let dependency = field.dependency, result[dependency] != nil {
                _ = try parsed(field.key)
            }
        }
        return result
    }

    /// Optimistic conflict detection. RPC has no compare-and-swap; the final
    /// readback still checks each value actually accepted by the daemon.
    func checkedPatch(against latest: ServerOptionsSnapshot) throws -> [ServerOption: ServerOptionValue] {
        let changes = try patch()
        var conflicts: Set<ServerOption> = []
        for (key, desired) in changes {
            let current = latest.values[key]
            if current == nil || (current != baseline.values[key] && current != desired) { conflicts.insert(key) }
            if let dependency = key.definition.dependency, changes[dependency] == nil,
               latest.values[dependency] != baseline.values[dependency] { conflicts.insert(dependency) }
        }
        // Do not enable a setting with a companion value changed by another client.
        for field in ServerOption.definitions where isEditable(field.key) {
            if let dependency = field.dependency, changes[dependency] != nil, changes[field.key] == nil,
               latest.values[field.key] != baseline.values[field.key] { conflicts.insert(field.key) }
        }
        if !conflicts.isEmpty {
            let ordered = ServerOption.allCases.filter { conflicts.contains($0) }
            throw ServerOptionsError(message: "These settings changed on the server: " + ordered.map { $0.definition.title }.joined(separator: ", ") + ". Click Revert to load the server’s current values, then make your changes again.", fields: ordered)
        }
        return changes.filter { latest.values[$0.key] != $0.value }
    }
}

protocol ServerOptionsService: Sendable {
    func fetchServerOptions() async throws -> ServerOptionsSnapshot
    func setServerOptions(_ changes: [ServerOption: ServerOptionValue]) async throws
    func testPeerPort() async throws -> Bool
    func testPeerPort(protocol choice: PeerPortProtocol) async throws -> PeerPortResult
    func fetchBandwidthGroups() async throws -> [BandwidthGroup]
    func setBandwidthGroup(name: String, changes: [BandwidthGroup.Field: ServerOptionValue]) async throws
}

/// A window holds one service for its entire lifetime. Switching the main
/// window's server never retargets this editor or an in-flight write.
@MainActor
final class ServerOptionsSession {
    let service: any ServerOptionsService
    private(set) var editor: ServerOptionsEditor?
    private(set) var isBusy = false
    private(set) var needsReload = false

    init(service: any ServerOptionsService) { self.service = service }

    func set(_ key: ServerOption, text: String) {
        guard !isBusy else { return }
        editor?.set(key, text: text)
    }

    /// Discard drafts without a round trip: back to the last loaded values.
    func revert() {
        guard !isBusy, let editor else { return }
        self.editor = ServerOptionsEditor(editor.baseline)
    }

    /// See `ServerOptionsEditor.absorb`. Never while a request is in flight.
    @discardableResult
    func absorb(_ values: [ServerOption: ServerOptionValue]) -> ServerOptionsEditor.AbsorbResult {
        guard !isBusy, !needsReload, editor != nil else { return .unchanged }
        return editor!.absorb(values)
    }

    func load() async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let snapshot = try await service.fetchServerOptions()
        editor = ServerOptionsEditor(snapshot)
        needsReload = false
    }

    func apply() async throws {
        guard !isBusy, let editor else { return }
        guard !needsReload else { throw ServerOptionsError(message: "Click Revert to load the server’s current values before applying again.") }
        _ = try editor.patch()
        isBusy = true
        defer { isBusy = false }
        let latest = try await service.fetchServerOptions()
        let changes = try editor.checkedPatch(against: latest)
        if changes.isEmpty {
            self.editor = ServerOptionsEditor(latest)
            return
        }
        // A timeout or RPC error can occur after a write takes effect. Require
        // an explicit reload rather than retrying an uncertain write blindly.
        needsReload = true
        do {
            try await service.setServerOptions(changes)
            let verified = try await service.fetchServerOptions()
            let mismatches = ServerOption.allCases.filter { key in
                changes[key].map { verified.values[key] != $0 } ?? false
            }
            guard mismatches.isEmpty else {
                throw ServerOptionsError(message: "The server did not retain these values: " + mismatches.map { $0.definition.title }.joined(separator: ", ") + ". Click Revert to see its current settings.", fields: mismatches)
            }
            self.editor = ServerOptionsEditor(verified)
            needsReload = false
        } catch {
            throw ServerOptionsError(message: "The save could not be fully verified. \(error.localizedDescription) Click Revert before trying again.",
                                     fields: (error as? ServerOptionsError)?.fields ?? [])
        }
    }

    func testPort() async throws -> Bool {
        guard !isBusy else { throw ServerOptionsError(message: "Wait for the current request to finish.") }
        isBusy = true
        defer { isBusy = false }
        return try await service.testPeerPort()
    }

    func testPort(protocol choice: PeerPortProtocol) async throws -> PeerPortResult {
        guard !isBusy else { throw ServerOptionsError(message: "Wait for the current request to finish.") }
        guard choice == .automatic || editor?.baseline.supportsPortProtocol == true else {
            throw ServerOptionsError(message: "This server supports automatic port testing only.")
        }
        isBusy = true
        defer { isBusy = false }
        return try await service.testPeerPort(protocol: choice)
    }



}

extension SessionInfo {
    /// The speed settings the main window's poll already reads, as server-option
    /// values, so Settings can follow limits changed from the speed menus.
    var speedOptionValues: [ServerOption: ServerOptionValue] {
        var values: [ServerOption: ServerOptionValue] = [:]
        if let speedLimitDownEnabled { values[.downEnabled] = .bool(speedLimitDownEnabled) }
        if let speedLimitDown { values[.down] = .int(speedLimitDown) }
        if let speedLimitUpEnabled { values[.upEnabled] = .bool(speedLimitUpEnabled) }
        if let speedLimitUp { values[.up] = .int(speedLimitUp) }
        if let altSpeedEnabled { values[.altEnabled] = .bool(altSpeedEnabled) }
        if let altSpeedDown { values[.altDown] = .int(altSpeedDown) }
        if let altSpeedUp { values[.altUp] = .int(altSpeedUp) }
        return values
    }
}

/// Foundation-only rules behind one server's row in Settings: whether its
/// server tabs can be used, whether it has unsaved edits, and in what order
/// Apply commits them. Connection details and presets are stored on this Mac;
/// everything on the Transfers / Speed / Network / Advanced tabs is stored on
/// the server.
enum ServerSettingsScope {
    /// The five tabs shown for a selected server.
    enum Tab: String, CaseIterable, Sendable {
        case connection = "Connection", transfers = "Transfers", speed = "Speed", network = "Network", advanced = "Advanced"
        var pane: ServerOption.Pane? { ServerOption.Pane(rawValue: rawValue) }
        init(_ pane: ServerOption.Pane) { self = Tab(rawValue: pane.rawValue)! }
    }

    /// Where a group of settings is stored, shown as a tag on its heading.
    enum Storage: String, Sendable {
        case server = "Stored on the server"
        case mac = "Stored on this Mac"
        var help: String {
            switch self {
            case .server: "Stored by the Transmission daemon and shared by every client connected to it."
            case .mac: "Stored in this app's preferences on this Mac only."
            }
        }
    }

    /// The remote-values load state for one server.
    enum Load: Equatable, Sendable {
        case notLoaded, loading, loaded, failed(String)
    }

    /// What the server tabs show.
    enum Availability: Equatable, Sendable {
        /// A server added in this window and not applied yet: there is nothing to connect to.
        case unsavedNewServer
        case connecting
        case offline(String)
        case ready
    }

    static func availability(isSaved: Bool, load: Load) -> Availability {
        guard isSaved else { return .unsavedNewServer }
        switch load {
        case .notLoaded, .loading: return .connecting
        case .failed(let message): return .offline(message)
        case .loaded: return .ready
        }
    }

    /// One dirty flag per server row: local (connection, presets) or remote edits.
    static func isDirty(localDirty: Bool, remoteDirty: Bool) -> Bool { localDirty || remoteDirty }

    enum ApplyPlan: Equatable, Sendable {
        case nothing
        case localOnly
        /// Server-side first; local fields only after it succeeds.
        case remoteThenLocal
        case remoteOnly
        case blocked(String)
    }

    static func plan(localDirty: Bool, remoteDirty: Bool, remoteNeedsReload: Bool) -> ApplyPlan {
        if remoteNeedsReload && remoteDirty {
            return .blocked("Click Revert to load the server’s current values before applying again.")
        }
        switch (remoteDirty, localDirty) {
        case (false, false): return .nothing
        case (false, true): return .localOnly
        case (true, true): return .remoteThenLocal
        case (true, false): return .remoteOnly
        }
    }

    /// Run a plan. `remote` is the conflict-checked, verified `session-set`; if it
    /// throws, `local` never runs, so nothing is saved on this Mac and every edit
    /// (remote drafts and local fields) is kept for another try.
    @MainActor
    static func apply(_ plan: ApplyPlan, remote: () async throws -> Void, local: () -> Void) async throws {
        switch plan {
        case .nothing: return
        case .blocked(let message): throw ServerOptionsError(message: message)
        case .localOnly: local()
        case .remoteOnly: try await remote()
        case .remoteThenLocal:
            try await remote()
            local()
        }
    }
}
