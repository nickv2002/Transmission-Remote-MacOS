import Foundation

/// Lightweight verification logging, gated by the `TR_PERF_LOG=1` environment
/// variable (off by default). Used to capture cold-start resolve/paint timings
/// and first-fetch payload size for before/after comparison. Emitted via `NSLog`
/// so it shows in Console.app even when the app is launched via `open`.
let trPerfLogEnabled = ProcessInfo.processInfo.environment["TR_PERF_LOG"] == "1"
func perfLog(_ message: @autoclosure () -> String) {
    if trPerfLogEnabled { NSLog("[perf] %@", message()) }
}

/// Errors surfaced by `TransmissionClient`.
enum TransmissionError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case connectionFailed(String)
    case httpError(Int)
    case rpcError(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL in the config is invalid."
        case .authenticationFailed:
            return "Authentication failed — check the username and password."
        case .connectionFailed(let detail):
            return "Connection failed — \(detail)"
        case .httpError(let code):
            return "The server returned HTTP \(code)."
        case .rpcError(let message):
            return "The server reported an error: \(message)"
        case .decodingFailed(let detail):
            return "Could not read the server response: \(detail)"
        }
    }
}

/// Talks to a single Transmission daemon over JSON-RPC. Handles HTTP Basic auth
/// and the CSRF `X-Transmission-Session-Id` 409 dance (see `rpc.pas`).
actor TransmissionClient: ServerOptionsService {
    private let endpoint: URL
    private let authHeader: String?
    private let session: URLSession
    private var sessionId: String?

    private static let sessionIdHeader = "X-Transmission-Session-Id"

    init(server: ServerConfig, timeout: TimeInterval = 15,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        var components = URLComponents()
        components.scheme = server.useHTTPS ? "https" : "http"
        components.host = server.host
        components.port = server.port
        components.path = server.rpcPath
        guard let url = components.url else {
            throw TransmissionError.invalidURL
        }
        self.endpoint = url

        if let user = server.username, !user.isEmpty {
            let raw = "\(user):\(server.password ?? "")"
            let encoded = Data(raw.utf8).base64EncodedString()
            self.authHeader = "Basic \(encoded)"
        } else {
            self.authHeader = nil
        }

        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Typed wrappers

    func fetchSession() async throws -> SessionInfo {
        let response: RPCResponse<SessionInfo> = try await send(method: "session-get", arguments: [:])
        guard let info = response.arguments else {
            throw TransmissionError.decodingFailed("missing session arguments")
        }
        return info
    }

    func fetchServerOptions() async throws -> ServerOptionsSnapshot {
        let response: RPCResponse<ServerOptionsSnapshot> = try await send(method: "session-get", arguments: [:])
        guard let options = response.arguments else {
            throw TransmissionError.decodingFailed("missing server options")
        }
        return options
    }

    func setServerOptions(_ changes: [ServerOption: ServerOptionValue]) async throws {
        guard !changes.isEmpty else { return }
        let arguments = Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value.jsonValue) })
        try await sendIgnoringResult(method: "session-set", arguments: arguments)
    }

    func testPeerPort() async throws -> Bool {
        try await testPeerPort(protocol: .automatic).isOpen
    }

    func testPeerPort(protocol choice: PeerPortProtocol) async throws -> PeerPortResult {
        let arguments: [String: Any] = choice == .automatic ? [:] : ["ip_protocol": choice.rawValue]
        let response: RPCResponse<PeerPortResult> = try await send(method: "port-test", arguments: arguments)
        guard let result = response.arguments else { throw TransmissionError.decodingFailed("missing port-test result") }
        if choice != .automatic, let actual = result.ipProtocol, actual != choice.rawValue {
            throw TransmissionError.decodingFailed("the server tested a different IP protocol")
        }
        return result
    }



    func fetchBandwidthGroups() async throws -> [BandwidthGroup] {
        struct Result: Decodable { let group: [BandwidthGroup] }
        let response: RPCResponse<Result> = try await send(method: "group-get", arguments: [:])
        guard let groups = response.arguments?.group else { throw TransmissionError.decodingFailed("missing bandwidth groups") }
        return groups
    }

    func setBandwidthGroup(name: String, changes: [BandwidthGroup.Field: ServerOptionValue]) async throws {
        guard !changes.isEmpty else { return }
        var arguments = Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value.jsonValue) })
        arguments["name"] = name
        try await sendIgnoringResult(method: "group-set", arguments: arguments)
    }

    struct TorrentGroup: Decodable, Sendable, Equatable {
        let hashString: String
        let group: String
    }

    func fetchTorrentGroups(hashes: [String]) async throws -> [TorrentGroup] {
        guard !hashes.isEmpty else { return [] }
        struct Result: Decodable { let torrents: [TorrentGroup] }
        let response: RPCResponse<Result> = try await send(method: "torrent-get", arguments: ["ids": hashes, "fields": ["hashString", "group"]])
        guard let torrents = response.arguments?.torrents else { throw TransmissionError.decodingFailed("missing torrent groups") }
        return torrents
    }

    /// Torrent hashes avoid reusing numeric IDs if a daemon restarts while a sheet is open.
    func assignBandwidthGroup(_ name: String, baseline: [TorrentGroup]) async throws {
        guard !baseline.isEmpty else { return }
        let hashes = baseline.map(\.hashString)
        let latest = try await fetchTorrentGroups(hashes: hashes)
        guard Set(latest.map(\.hashString)) == Set(hashes), latest.allSatisfy({ torrent in
            baseline.contains { $0.hashString == torrent.hashString && ($0.group == torrent.group || torrent.group == name) }
        }) else { throw ServerOptionsError(message: "The selected torrents changed on the server. Reopen the group selector.") }
        let changed = latest.filter { $0.group != name }.map(\.hashString)
        guard !changed.isEmpty else { return }
        try await sendIgnoringResult(method: "torrent-set", arguments: ["ids": changed, "group": name])
        let verified = try await fetchTorrentGroups(hashes: changed)
        guard Set(verified.map(\.hashString)) == Set(changed), verified.allSatisfy({ $0.group == name }) else {
            throw ServerOptionsError(message: "The group assignment could not be verified. Reopen the selector to inspect the current assignments.")
        }
    }

    /// Sets (or clears, with nil) the regular speed limit for one direction in
    /// KB/s. Like the legacy app, this also leaves turtle mode so the new limit
    /// is the one in force.
    func setSpeedLimit(_ direction: SpeedDirection, kbps: Int?) async throws {
        try await sendIgnoringResult(
            method: "session-set", arguments: Self.speedLimitArguments(direction, kbps: kbps))
    }

    /// Turns turtle ("alternative speed") mode on or off.
    func setAltSpeedEnabled(_ enabled: Bool) async throws {
        try await sendIgnoringResult(method: "session-set", arguments: ["alt-speed-enabled": enabled])
    }

    /// Sets the turtle-mode limit for one direction in KB/s.
    func setAltSpeed(_ direction: SpeedDirection, kbps: Int) async throws {
        try await sendIgnoringResult(
            method: "session-set", arguments: ["alt-speed-\(direction.rawValue)": kbps])
    }

    nonisolated static func speedLimitArguments(_ direction: SpeedDirection, kbps: Int?) -> [String: Any] {
        var args: [String: Any] = [
            "speed-limit-\(direction.rawValue)-enabled": kbps != nil,
            "alt-speed-enabled": false,
        ]
        if let kbps { args["speed-limit-\(direction.rawValue)"] = kbps }
        return args
    }

    func fetchTorrents(fields: [String] = Torrent.requestedFields) async throws -> [Torrent] {
        let args: [String: Any] = ["fields": fields]
        let response: RPCResponse<TorrentListArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents ?? []
    }

    /// An RPC call that just takes a list of torrent ids and returns nothing.
    private func idsAction(_ method: String, ids: [Int]) async throws {
        try await sendIgnoringResult(method: method, arguments: ["ids": ids])
    }

    func start(ids: [Int]) async throws {
        try await idsAction("torrent-start", ids: ids)
    }

    func stop(ids: [Int]) async throws {
        try await idsAction("torrent-stop", ids: ids)
    }

    func startNow(ids: [Int]) async throws {
        try await idsAction("torrent-start-now", ids: ids)
    }

    func rename(id: Int, path: String, name: String) async throws {
        try await sendIgnoringResult(
            method: "torrent-rename-path",
            arguments: ["ids": [id], "path": path, "name": name]
        )
    }

    func setLocation(ids: [Int], location: String, move: Bool) async throws {
        try await sendIgnoringResult(
            method: "torrent-set-location",
            arguments: ["ids": ids, "location": location, "move": move]
        )
    }

    func verify(ids: [Int]) async throws {
        try await idsAction("torrent-verify", ids: ids)
    }

    func reannounce(ids: [Int]) async throws {
        try await idsAction("torrent-reannounce", ids: ids)
    }

    /// Where in the queue to move the given torrents.
    enum QueueMove: String {
        case top = "queue-move-top"
        case up = "queue-move-up"
        case down = "queue-move-down"
        case bottom = "queue-move-bottom"
    }

    func queueMove(ids: [Int], to move: QueueMove) async throws {
        try await sendIgnoringResult(method: move.rawValue, arguments: ["ids": ids])
    }

    func setBandwidthPriority(ids: [Int], priority: BandwidthPriority) async throws {
        try await sendIgnoringResult(
            method: "torrent-set",
            arguments: ["ids": ids, "bandwidthPriority": priority.rawValue]
        )
    }

    /// Fetch the file list for one torrent (`files` + `fileStats`). Kept separate
    /// from the list poll because these arrays are heavy and only needed for the
    /// selected torrent.
    func fetchFiles(id: Int) async throws -> [TorrentFile] {
        let args: [String: Any] = ["ids": [id], "fields": ["id", "files", "fileStats"]]
        let response: RPCResponse<TorrentFilesArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents.first?.files ?? []
    }

    /// Fetch the peer list for one torrent (`peers`). Kept separate from the
    /// list poll for the same reason as `fetchFiles` — the array is heavy and
    /// only needed for the selected torrent.
    func fetchPeers(id: Int) async throws -> [TorrentPeer] {
        let args: [String: Any] = ["ids": [id], "fields": ["id", "peers"]]
        let response: RPCResponse<TorrentPeersArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents.first?.peers ?? []
    }

    /// The piece bitfield (`pieces` + `pieceCount` + `pieceSize`) for one
    /// torrent, feeding the Info tab's piece map. On demand, like `fetchPeers`,
    /// since the bitfield grows with the torrent and only the selected one
    /// needs it. Nil when the daemon returns no such torrent.
    func fetchPieces(id: Int) async throws -> TorrentPieces? {
        let args: [String: Any] = ["ids": [id], "fields": ["id", "pieces", "pieceCount", "pieceSize"]]
        let response: RPCResponse<TorrentPiecesArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents.first
    }

    /// Per-tracker announce/scrape state for one torrent. On demand, like
    /// `fetchPeers`, to keep the list poll light.
    func fetchTrackers(id: Int) async throws -> [TrackerStatsInfo] {
        let args: [String: Any] = ["ids": [id], "fields": ["id", "trackerStats"]]
        let response: RPCResponse<TorrentTrackersArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents.first?.trackerStats ?? []
    }

    func setFilesWanted(id: Int, fileIndices: [Int], wanted: Bool) async throws {
        guard !fileIndices.isEmpty else { return }
        let key = wanted ? "files-wanted" : "files-unwanted"
        try await sendIgnoringResult(method: "torrent-set", arguments: ["ids": [id], key: fileIndices])
    }

    func setFilePriority(id: Int, fileIndices: [Int], priority: FilePriority) async throws {
        guard !fileIndices.isEmpty else { return }
        let key: String
        switch priority {
        case .low: key = "priority-low"
        case .normal: key = "priority-normal"
        case .high: key = "priority-high"
        }
        try await sendIgnoringResult(method: "torrent-set", arguments: ["ids": [id], key: fileIndices])
    }

    func remove(ids: [Int], deleteLocalData: Bool) async throws {
        try await sendIgnoringResult(
            method: "torrent-remove",
            arguments: ["ids": ids, "delete-local-data": deleteLocalData]
        )
    }

    /// Add a torrent from base64 `.torrent` contents (`metainfo`) or a
    /// magnet/URL (`filename`). Returns the resulting torrent name and whether the
    /// daemon reported it as a duplicate.
    func addTorrent(metainfoBase64: String?, filename: String?,
                    downloadDir: String?, paused: Bool) async throws -> AddOutcome {
        var args: [String: Any] = ["paused": paused]
        if let metainfoBase64 { args["metainfo"] = metainfoBase64 }
        if let filename { args["filename"] = filename }
        if let downloadDir, !downloadDir.isEmpty { args["download-dir"] = downloadDir }

        let response: RPCResponse<AddArguments> = try await send(method: "torrent-add", arguments: args)
        if let dup = response.arguments?.duplicate {
            return AddOutcome(name: dup.name ?? "torrent", duplicate: true)
        }
        return AddOutcome(name: response.arguments?.added?.name ?? "torrent", duplicate: false)
    }

    /// Free space (bytes) for a server path. Returns nil if the daemon can't
    /// report it. Mirrors the legacy "Free disk space" display.
    func freeSpace(path: String) async throws -> Int64? {
        let response: RPCResponse<FreeSpaceArguments> = try await send(
            method: "free-space", arguments: ["path": path])
        return response.arguments?.sizeBytes
    }

    // MARK: - Core

    /// A response whose `arguments` we don't need to inspect.
    private struct EmptyArguments: Decodable, Sendable {}

    private func sendIgnoringResult(method: String, arguments: [String: Any]) async throws {
        let _: RPCResponse<EmptyArguments> = try await send(method: method, arguments: arguments)
    }

    /// POSTs `{ method, arguments }`. On HTTP 409 captures the session id and
    /// retries once. Decodes the typed envelope and verifies `result == "success"`.
    private func send<Arguments: Decodable>(
        method: String,
        arguments: [String: Any],
        timeout: TimeInterval? = nil
    ) async throws -> RPCResponse<Arguments> {
        let body = try JSONSerialization.data(withJSONObject: [
            "method": method,
            "arguments": arguments,
        ])

        let (data, http) = try await perform(body: body, allowRetry: true, timeout: timeout)

        if trPerfLogEnabled, method == "torrent-get" {
            perfLog("torrent-get response: \(data.count) bytes")
        }

        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401: throw TransmissionError.authenticationFailed
            default: throw TransmissionError.httpError(http.statusCode)
            }
        }

        let decoded: RPCResponse<Arguments>
        do {
            decoded = try JSONDecoder().decode(RPCResponse<Arguments>.self, from: data)
        } catch {
            throw TransmissionError.decodingFailed(error.localizedDescription)
        }

        guard decoded.result == "success" else {
            throw TransmissionError.rpcError(decoded.result)
        }
        return decoded
    }

    /// Max 409 retries. Normally one round-trip fixes it (empty/stale session id
    /// → daemon hands back the current one), but under concurrent RPCs the daemon
    /// can rotate the id again between our retry being built and sent, so allow a
    /// couple more attempts rather than hard-failing on the first re-rotation.
    private static let maxSessionRetries = 3

    private func perform(body: Data, allowRetry: Bool, timeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            var request = URLRequest(url: endpoint)
            if let timeout { request.timeoutInterval = timeout }
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let authHeader {
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            }
            if let sessionId {
                request.setValue(sessionId, forHTTPHeaderField: Self.sessionIdHeader)
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw TransmissionError.connectionFailed(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw TransmissionError.connectionFailed("non-HTTP response")
            }

            // CSRF: capture the session id from the 409 and replay, using whatever
            // id the daemon reports as current at retry time (not a stale snapshot).
            if http.statusCode == 409, allowRetry, attempt < Self.maxSessionRetries,
               let newId = http.value(forHTTPHeaderField: Self.sessionIdHeader) {
                sessionId = newId
                attempt += 1
                continue
            }

            return (data, http)
        }
    }
}
