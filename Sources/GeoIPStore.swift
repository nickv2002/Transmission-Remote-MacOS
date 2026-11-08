import Foundation

extension Notification.Name {
    /// Posted on the main actor when `GeoIPStore.shared` finishes loading,
    /// downloading or removing its database.
    static let geoIPDatabaseDidChange = Notification.Name("GeoIPDatabaseDidChange")
}

/// Owns the optional country database used for the Peers tab's Country column.
/// Nothing is bundled or fetched unless the user turns the setting on: the
/// monthly DB-IP Lite file is downloaded to Application Support, parsed into a
/// `GeoIPDatabase`, and deleted again when the setting is turned off.
@MainActor
final class GeoIPStore {
    static let shared = GeoIPStore()

    enum State: Equatable {
        case absent
        case loading
        case downloading
        case ready(date: Date, ranges: Int)
        case failed(String)
    }

    private(set) var state: State = .absent { didSet { NotificationCenter.default.post(name: .geoIPDatabaseDidChange, object: self) } }
    private(set) var database: GeoIPDatabase?

    private let directory: () -> URL
    private let fetch: @Sendable (URL) async throws -> Data
    private let now: () -> Date
    private var task: Task<Void, Never>?

    init(directory: @escaping () -> URL = { PreferencesStore.supportDirectory },
         now: @escaping () -> Date = Date.init,
         fetch: @escaping @Sendable (URL) async throws -> Data = GeoIPStore.defaultFetch) {
        self.directory = directory
        self.now = now
        self.fetch = fetch
    }

    var fileURL: URL { directory().appendingPathComponent("dbip-country-lite.csv.gz", isDirectory: false) }
    var isBusy: Bool { state == .downloading || state == .loading }

    /// The monthly download URL for `date`'s calendar month (UTC).
    static func downloadURL(for date: Date) -> URL {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: date)
        let name = String(format: "dbip-country-lite-%04d-%02d.csv.gz", c.year!, c.month!)
        return URL(string: "https://download.db-ip.com/free/\(name)")!
    }

    /// Current month, then the previous one (a new month's file can lag).
    static func candidateURLs(now: Date) -> [URL] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let previous = cal.date(byAdding: .month, value: -1, to: now) ?? now
        return [downloadURL(for: now), downloadURL(for: previous)]
    }

    nonisolated static func defaultFetch(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let (data, response) = try await URLSession(configuration: config).data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func country(for address: String) -> String? { database?.country(for: address) }

    /// Loads an existing file from disk, if any. Cheap no-op when none exists.
    func loadIfPresent() {
        guard database == nil, !isBusy, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        state = .loading
        let url = fileURL
        task = Task {
            let loaded = await Task.detached { () -> (GeoIPDatabase, Date)? in
                guard let data = try? Data(contentsOf: url), let db = GeoIPDatabase(gzipped: data) else { return nil }
                let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
                return (db, date)
            }.value
            if let loaded {
                database = loaded.0
                state = .ready(date: loaded.1, ranges: loaded.0.count)
            } else {
                state = .failed("The saved database couldn't be read.")
            }
        }
    }

    /// Downloads (or re-downloads) the database, replacing the file only after
    /// the new one parses.
    func download() {
        guard state != .downloading else { return }
        task?.cancel()
        state = .downloading
        let urls = Self.candidateURLs(now: now())
        let fetch = self.fetch
        let target = fileURL
        task = Task {
            var lastError = "Download failed."
            for url in urls {
                do {
                    let data = try await fetch(url)
                    let parsed = await Task.detached { GeoIPDatabase(gzipped: data) }.value
                    guard let parsed else { lastError = "The downloaded file wasn't a valid database."; continue }
                    if Task.isCancelled { return }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                    database = parsed
                    state = .ready(date: Date(), ranges: parsed.count)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    lastError = "Download failed: \(error.localizedDescription)"
                }
            }
            if !Task.isCancelled { state = .failed(lastError) }
        }
    }

    /// Deletes the file and drops the table from memory.
    func remove() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: fileURL)
        database = nil
        state = .absent
    }
}
