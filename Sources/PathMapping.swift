import Foundation

/// One remote→local path-mapping rule for a server. The remote daemon reports a
/// torrent's `downloadDir` as a path on *its* filesystem (e.g. `/video/...`); a
/// mapping rewrites that prefix to a path the Mac can open (e.g. `/Volumes/Video`).
///
/// Ported from the legacy app's per-connection `PathMap` (`main.pas`
/// `MapRemoteToLocal`). Stored per `ServerConfig`; edited as `remote=local` lines
/// in the Settings screen.
struct PathMapping: Codable, Sendable, Equatable {
    var remote: String
    var local: String
}

extension PathMapping {
    /// Parse the Settings text editor's contents (one `remote=local` per line) into
    /// mappings. Splits each line on the **first** `=`, trims both sides, and drops
    /// blank or `=`-less lines (mirrors the Pascal load that purges empty values).
    static func parse(_ text: String) -> [PathMapping] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let remote = line[..<eq].trimmingCharacters(in: .whitespaces)
            let local = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !remote.isEmpty, !local.isEmpty else { return nil }
            return PathMapping(remote: remote, local: local)
        }
    }

    /// Render mappings back to editor text — one `remote=local` per line.
    static func format(_ mappings: [PathMapping]) -> String {
        mappings.map { "\($0.remote)=\($0.local)" }.joined(separator: "\n")
    }
}

extension ServerConfig {
    /// Translate a remote absolute path to a local one using this server's
    /// mappings. An exact match on a mapping's remote side wins outright;
    /// otherwise the longest matching remote-side prefix wins (not list order),
    /// so a more specific mapping (e.g. `/video/4k`) always beats a broader one
    /// (e.g. `/video`) regardless of which line it's on. Returns `nil` when no
    /// mapping applies.
    ///
    /// Ported from `main.pas` `MapRemoteToLocal`, but strengthened to match
    /// `mapLocalToRemote`'s longest-prefix-wins tie-break below: the remainder of
    /// the remote path is appended to the local base of the best (longest)
    /// matching mapping. A prefix match is guarded by a trailing `/`, so `/var`
    /// does not match `/var2`. Case-sensitive. Both sides use `/` on macOS, so
    /// the Pascal `FixSeparators` step reduces to a trim.
    func mapRemoteToLocal(_ remotePath: String) -> String? {
        let fn = remotePath.trimmingCharacters(in: .whitespaces)
        guard !fn.isEmpty else { return nil }
        var best: (prefixLength: Int, local: String)?
        for mapping in pathMappings {
            let remote = mapping.remote.trimmingCharacters(in: .whitespaces)
            guard !remote.isEmpty else { continue }
            let local = mapping.local.trimmingCharacters(in: .whitespaces)
            if remote == fn { return local }
            let remoteWithSlash = remote.hasSuffix("/") ? remote : remote + "/"
            if fn.hasPrefix(remoteWithSlash), best == nil || remoteWithSlash.count > best!.prefixLength {
                let remainder = fn.dropFirst(remoteWithSlash.count)
                let base = local.hasSuffix("/") ? String(local.dropLast()) : local
                best = (remoteWithSlash.count, base + "/" + remainder)
            }
        }
        return best?.local
    }

    /// Translate a local absolute path back to a remote one — the inverse of
    /// `mapRemoteToLocal`, used by Move's "Browse…" local folder picker. An
    /// exact match on a mapping's local side returns its remote side outright;
    /// otherwise the longest matching local-side prefix wins (not "last
    /// matching entry", unlike the legacy Pascal `SelectRemoteFolder`, which
    /// lacked a break and let list order decide ties on overlapping mappings).
    func mapLocalToRemote(_ localPath: String) -> String? {
        let fn = localPath.trimmingCharacters(in: .whitespaces)
        guard !fn.isEmpty else { return nil }
        var best: (prefixLength: Int, remote: String)?
        for mapping in pathMappings {
            let local = mapping.local.trimmingCharacters(in: .whitespaces)
            guard !local.isEmpty else { continue }
            let remote = mapping.remote.trimmingCharacters(in: .whitespaces)
            if local == fn { return remote }
            let localWithSlash = local.hasSuffix("/") ? local : local + "/"
            if fn.hasPrefix(localWithSlash), best == nil || localWithSlash.count > best!.prefixLength {
                let remainder = fn.dropFirst(localWithSlash.count)
                let base = remote.hasSuffix("/") ? String(remote.dropLast()) : remote
                best = (localWithSlash.count, base + "/" + remainder)
            }
        }
        return best?.remote
    }

    /// The three ways a remote path can resolve to something usable on this Mac —
    /// used by Reveal/Open, Quick Look, and drag-out-to-Finder, all of which need
    /// to distinguish "no mapping configured" from "mapping resolved, but nothing
    /// is there locally" (not mounted, wrong path, etc.) for their toast wording.
    enum LocalPathResolution: Equatable {
        /// A mapping matched and the local file/folder exists at `path`.
        case available(path: String)
        /// A mapping matched but nothing exists locally at `path` right now.
        case notFound(path: String)
        /// No mapping matched this remote path at all.
        case unmapped
    }

    /// Resolve a remote path to a `LocalPathResolution`, checking existence via
    /// `fileExists` (injectable so this is unit-testable without touching the real
    /// filesystem; defaults to `FileManager.default.fileExists`).
    func resolveLocalPath(forRemotePath remotePath: String,
                           fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LocalPathResolution {
        guard let local = mapRemoteToLocal(remotePath) else { return .unmapped }
        return fileExists(local) ? .available(path: local) : .notFound(path: local)
    }
}

/// Whether a file's own POSIX permission bits will make macOS refuse to hand it
/// to another process via the pasteboard — confirmed live against a real network
/// share: an owner-only file (mode 600) fails to drag out to Finder (Console:
/// "Sandbox extension creation failed: client lacks entitlements?" / "Failed to
/// get a sandbox extension"), tried both as a plain file `NSURL` and as an
/// `NSFilePromiseProvider`, while a group/other-readable file (664) on the same
/// server drags out fine. This app carries no sandbox entitlements to satisfy
/// whatever extension macOS wants to vend for a restricted-permission file in
/// either direction, so no drag technique available to a plain, non-sandboxed
/// AppKit app gets around it — the fix has to be the file's own permissions
/// (e.g. on whatever server/share populated it), not this app's code.
enum PathPermissions {
    /// Whether this POSIX mode lacks group AND other read bits (owner-only).
    static func blocksCrossProcessDrag(posixPermissions mode: Int) -> Bool {
        (mode & 0o044) == 0
    }

    /// Reads the real file's mode; `nil` (can't stat it) is treated as
    /// non-blocking, since the file-existence check upstream already handles
    /// "missing" as its own case.
    static func blocksCrossProcessDrag(atPath path: String) -> Bool {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        else { return false }
        return blocksCrossProcessDrag(posixPermissions: mode)
    }
}
