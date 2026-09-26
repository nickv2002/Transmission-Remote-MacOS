import AppKit

/// AppleScript-visible wrapper around one `Torrent` snapshot. Instances are
/// created fresh from the current `torrents`/`selectedTorrents` array on every
/// access — there's no persistent object identity to keep, since the whole list
/// is replaced on each ~4s poll (`MainWindowController.applyTorrents`). The
/// explicit `@objc(ScriptableTorrent)` name is required: Swift's default
/// ObjC-visible name for a class is module-qualified, which would make Cocoa
/// Scripting unable to find the `cocoa class="ScriptableTorrent"` the sdef names.
@objc(ScriptableTorrent)
final class ScriptableTorrent: NSObject, NSCopying {
    let torrent: Torrent

    init(_ torrent: Torrent) {
        self.torrent = torrent
        super.init()
    }

    /// Cocoa Scripting copies each element when a list-of-`torrent` property
    /// (`selection`) is set via AppleScript — without this, `set selection to
    /// {...}` crashes with "unrecognized selector -copyWithZone:".
    func copy(with zone: NSZone? = nil) -> Any {
        ScriptableTorrent(torrent)
    }

    /// A unique-id specifier keyed on `hashString` (stable across daemon
    /// restarts), relative to the app's `torrents` to-many property — the
    /// standard Cocoa Scripting pattern for app-owned elements with no window/
    /// document container of their own.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        // Cocoa Scripting only ever resolves specifiers on the main thread, even
        // though `objectSpecifier` itself is a nonisolated NSObject property.
        let app = MainActor.assumeIsolated { NSApplication.shared }
        guard let appDescription = app.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "torrents",
            uniqueID: torrent.hashString)
    }

    @objc var id: String { torrent.hashString }
    @objc var name: String { torrent.name }
    @objc var status: String { torrent.status.displayName.lowercased() }
    @objc var progress: Double { torrent.displayProgress }
    @objc var downloadRate: Int { Int(torrent.rateDownload) }
    @objc var uploadRate: Int { Int(torrent.rateUpload) }
    @objc var eta: Int { torrent.eta }
    @objc var size: Int { Int(torrent.totalSize) }
    @objc var downloadDir: String { torrent.downloadDir }
    @objc var priority: String { torrent.bandwidthPriority.displayName.lowercased() }
    @objc var errorMessage: String { torrent.errorString }
}

/// Pure helpers shared by the script command implementations below.
enum ScriptingSupport {
    static func priority(fromName name: String) -> BandwidthPriority? {
        switch name.lowercased() {
        case "low": return .low
        case "normal": return .normal
        case "high": return .high
        default: return nil
        }
    }

    static func queueMove(fromName name: String) -> TransmissionClient.QueueMove? {
        switch name.lowercased() {
        case "top": return .top
        case "up": return .up
        case "down": return .down
        case "bottom": return .bottom
        default: return nil
        }
    }
}

// MARK: - Shared command plumbing

/// Base class for every scripted verb below. `NSScriptCommand.
/// performDefaultImplementation()` is declared `nonisolated` on the (ObjC)
/// superclass, but every command body here touches main-actor state
/// (`AppDelegate.windowController`, `RefreshController`, `TransmissionClient`)
/// and needs to capture `self` across an `async` gap to call
/// `resumeExecution(withResult:)` later. Marking the class `@MainActor` makes
/// `self` itself main-actor-isolated, so those captures don't "cross" actors;
/// subclasses override `run()` (main-actor-isolated) instead of
/// `performDefaultImplementation()` (which just bridges into it).
@MainActor
class MainActorScriptCommand: NSScriptCommand {
    /// Override in each concrete command. Scripted actions never show UI: use
    /// `suspendExecution()`/`resumeExecution(withResult:)` around the async RPC
    /// call rather than any sheet/alert the equivalent menu action would show.
    func run() {}

    final override nonisolated func performDefaultImplementation() -> Any? {
        // `self` is statically nonisolated here (matching the ObjC superclass's
        // nonisolated method), even though the class is `@MainActor` and this is
        // only ever actually called on the main thread by AppKit's script
        // dispatch — hence the explicit escape hatch to hand it to `run()`.
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated { command.run() }
        return nil
    }

    /// The RPC ids of the app's current `selection` — the target for every
    /// ids-only verb below, exactly like the toolbar/menu actions target the
    /// main window's selection. Callers script this as
    /// `set selection to {...}` followed by the verb.
    var targetTorrentIds: [Int] {
        (NSApp.delegate as? AppDelegate)?.windowController?.selectedTorrents.map(\.id) ?? []
    }

    func fail(_ message: String) {
        scriptErrorNumber = NSArgumentsWrongScriptError
        scriptErrorString = message
    }

    /// Runs an RPC action against `ids` (or `targetTorrentIds` when omitted),
    /// suspending the command until it completes and reporting failures via
    /// `scriptErrorNumber`/`scriptErrorString` so a caller's `on error` sees them.
    func runScriptedRPC(ids: [Int]? = nil, _ body: @escaping (TransmissionClient, [Int]) async throws -> Void) {
        let ids = ids ?? targetTorrentIds
        guard !ids.isEmpty else { return }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let controller = appDelegate.windowController,
              let client = controller.refresh.activeClient else {
            fail("Not connected to a Transmission server.")
            return
        }
        suspendExecution()
        Task { @MainActor in
            do {
                try await body(client, ids)
                controller.refresh.refreshNow()
                self.resumeExecution(withResult: nil)
            } catch {
                self.fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
                self.resumeExecution(withResult: nil)
            }
        }
    }
}

// MARK: - Simple ids-only commands

@objc(StartCommand)
final class StartCommand: MainActorScriptCommand {
    override func run() { runScriptedRPC { try await $0.start(ids: $1) } }
}

@objc(StopCommand)
final class StopCommand: MainActorScriptCommand {
    override func run() { runScriptedRPC { try await $0.stop(ids: $1) } }
}

@objc(ForceStartCommand)
final class ForceStartCommand: MainActorScriptCommand {
    override func run() { runScriptedRPC { try await $0.startNow(ids: $1) } }
}

@objc(VerifyCommand)
final class VerifyCommand: MainActorScriptCommand {
    override func run() { runScriptedRPC { try await $0.verify(ids: $1) } }
}

@objc(ReannounceCommand)
final class ReannounceCommand: MainActorScriptCommand {
    override func run() { runScriptedRPC { try await $0.reannounce(ids: $1) } }
}

// MARK: - Parameterized commands

@objc(RemoveCommand)
final class RemoveCommand: MainActorScriptCommand {
    override func run() {
        let deleteData = (evaluatedArguments?["deletingData"] as? Bool) ?? false
        runScriptedRPC { try await $0.remove(ids: $1, deleteLocalData: deleteData) }
    }
}

@objc(MoveCommand)
final class MoveCommand: MainActorScriptCommand {
    override func run() {
        guard let location = evaluatedArguments?["to"] as? String, !location.isEmpty else {
            fail("The “move” command requires a “to” location.")
            return
        }
        runScriptedRPC { try await $0.setLocation(ids: $1, location: location, move: true) }
    }
}

@objc(SetPriorityCommand)
final class SetPriorityCommand: MainActorScriptCommand {
    override func run() {
        guard let raw = evaluatedArguments?["to"] as? String,
              let priority = ScriptingSupport.priority(fromName: raw) else {
            fail("The “set priority” command requires a “to” of low, normal, or high.")
            return
        }
        runScriptedRPC { try await $0.setBandwidthPriority(ids: $1, priority: priority) }
    }
}

@objc(QueueMoveCommand)
final class QueueMoveCommand: MainActorScriptCommand {
    override func run() {
        guard let raw = evaluatedArguments?["to"] as? String,
              let move = ScriptingSupport.queueMove(fromName: raw) else {
            fail("The “queue move” command requires a “to” of top, up, down, or bottom.")
            return
        }
        runScriptedRPC { try await $0.queueMove(ids: $1, to: move) }
    }
}

/// Renames the selected torrent — `torrent-rename-path` takes exactly one id,
/// unlike the other verbs, so exactly one torrent must be selected.
@objc(RenameCommand)
final class RenameCommand: MainActorScriptCommand {
    override func run() {
        guard let newName = evaluatedArguments?["to"] as? String, !newName.isEmpty else {
            fail("The “rename” command requires a “to” name.")
            return
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let controller = appDelegate.windowController,
              let client = controller.refresh.activeClient else {
            fail("Not connected to a Transmission server.")
            return
        }
        guard let torrent = controller.selectedTorrents.first, controller.selectedTorrents.count == 1 else {
            fail("“rename” applies to exactly one selected torrent.")
            return
        }
        suspendExecution()
        Task { @MainActor in
            do {
                try await client.rename(id: torrent.id, path: torrent.name, name: newName)
                controller.refresh.refreshNow()
                self.resumeExecution(withResult: nil)
            } catch {
                self.fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
                self.resumeExecution(withResult: nil)
            }
        }
    }
}

/// Adds a torrent straight to the daemon — never the options sheet or the
/// pending-add queue, so a script never blocks waiting on UI. `source` is
/// treated as a local file path when it resolves to one on disk, otherwise as a
/// magnet link / `.torrent` URL passed through to `torrent-add`'s `filename`.
@objc(AddCommand)
final class AddCommand: MainActorScriptCommand {
    override func run() {
        guard let source = directParameter as? String, !source.isEmpty else {
            fail("The “add” command requires a file path, URL, or magnet link.")
            return
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let controller = appDelegate.windowController,
              let client = controller.refresh.activeClient else {
            fail("Not connected to a Transmission server.")
            return
        }
        let destination = (evaluatedArguments?["destination"] as? String) ?? controller.refresh.defaultDownloadDir ?? ""
        let paused = (evaluatedArguments?["paused"] as? Bool) ?? false

        suspendExecution()
        Task { @MainActor in
            do {
                var metainfo: String?
                var filename: String?
                let expandedPath = (source as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expandedPath) {
                    metainfo = try Data(contentsOf: URL(fileURLWithPath: expandedPath)).base64EncodedString()
                } else if let url = URL(string: source), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                    metainfo = try Data(contentsOf: url).base64EncodedString()
                } else {
                    filename = source
                }
                let outcome = try await client.addTorrent(
                    metainfoBase64: metainfo, filename: filename,
                    downloadDir: destination, paused: paused)
                controller.refresh.refreshNow()
                self.resumeExecution(withResult: outcome.name as NSString)
            } catch {
                self.fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
                self.resumeExecution(withResult: nil)
            }
        }
    }
}

@objc(RefreshCommand)
final class RefreshCommand: MainActorScriptCommand {
    override func run() {
        (NSApp.delegate as? AppDelegate)?.windowController?.refresh.refreshNow()
    }
}

/// Switches the active server and suspends the command until the connection
/// resolves (`connected`/`failed`), so a script's next line (e.g. `get
/// torrents`) doesn't race the handshake and see a stale/empty list. Bounded by
/// a timeout so a persistently unreachable server can't hang the command forever.
@objc(ConnectToServerCommand)
final class ConnectToServerCommand: MainActorScriptCommand {
    private static let pollInterval: UInt64 = 200_000_000
    private static let timeoutPolls = 150 // ~30s

    override func run() {
        guard let name = directParameter as? String, !name.isEmpty else {
            fail("The “connect to server” command requires a server name.")
            return
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let controller = appDelegate.windowController else {
            fail("Not connected to a Transmission server.")
            return
        }
        guard controller.refresh.availableServerNames.contains(name) else {
            fail("No server named “\(name)” is configured.")
            return
        }
        if name != controller.refresh.currentServerName {
            controller.selectServer(name)
        }
        suspendExecution()
        Task { @MainActor in
            for _ in 0..<Self.timeoutPolls {
                switch controller.refresh.state {
                case .connected, .failed:
                    self.resumeExecution(withResult: nil)
                    return
                case .idle, .connecting:
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                }
            }
            self.fail("Timed out connecting to “\(name)”.")
            self.resumeExecution(withResult: nil)
        }
    }
}
