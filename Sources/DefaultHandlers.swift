import AppKit
import UniformTypeIdentifiers

/// Which app macOS opens `magnet:` links and `.torrent` files with, and asking it
/// to make this app the default (Settings → General). Registering the scheme and
/// document type in `Info.plist` makes this app *eligible*, but if another
/// torrent client (the legacy Transmission Remote GUI, official Transmission, …)
/// already claims them, clicks keep going there until the user switches.
@MainActor
enum DefaultHandlers {
    enum Kind: CaseIterable {
        case magnetLinks
        case torrentFiles

        var title: String {
            switch self {
            case .magnetLinks: return "Open magnet: links with:"
            case .torrentFiles: return "Open .torrent files with:"
            }
        }
    }

    /// Who currently handles `kind`, for display: this app, another app's
    /// name, or nil when nothing is registered.
    enum Status: Equatable {
        case thisApp
        case other(String)
        case none
    }

    private static let torrentType = UTType("org.bittorrent.torrent") ?? UTType(filenameExtension: "torrent")

    static func status(of kind: Kind) -> Status {
        let workspace = NSWorkspace.shared
        let appURL: URL?
        switch kind {
        case .magnetLinks:
            appURL = URL(string: "magnet:").flatMap { workspace.urlForApplication(toOpen: $0) }
        case .torrentFiles:
            appURL = torrentType.flatMap { workspace.urlForApplication(toOpen: $0) }
        }
        guard let appURL else { return .none }
        // Compare by bundle id, not path: a Debug build and the installed
        // Release build share an id and are the same app for this purpose.
        if let id = Bundle(url: appURL)?.bundleIdentifier, id == Bundle.main.bundleIdentifier {
            return .thisApp
        }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return .other(name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }

    /// Ask macOS to make this app the default for `kind`. The system may show
    /// its own confirmation prompt; throws if the change was refused.
    static func makeDefault(_ kind: Kind) async throws {
        let workspace = NSWorkspace.shared
        let app = Bundle.main.bundleURL
        switch kind {
        case .magnetLinks:
            try await workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet")
        case .torrentFiles:
            guard let torrentType else { return }
            try await workspace.setDefaultApplication(at: app, toOpen: torrentType)
        }
    }
}
