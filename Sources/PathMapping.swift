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
    /// Whether `local` was typed as an `smb://host/share/subpath` reference
    /// (Finder's Connect-to-Server form) rather than a literal filesystem path —
    /// resolved lazily to its current mount point by `effectiveMappings`.
    static func isSMBReference(_ s: String) -> Bool {
        s.hasPrefix("smb://")
    }

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

/// Longest-prefix-match lookup shared by `mapRemoteToLocal`/`mapLocalToRemote`
/// (below) so a future edge-case fix — the trailing-slash guard, the tie-break —
/// only needs to change once instead of being hand-copied on both sides. An exact
/// match on `key` wins outright; otherwise the longest matching `/`-prefix wins
/// (not list order), so a more specific mapping (e.g. `/video/4k`) always beats a
/// broader one (e.g. `/video`) regardless of which line it's on. A prefix match is
/// guarded by a trailing `/`, so `/var` does not match `/var2`. Case-sensitive.
private func longestPrefixMatch(_ input: String, in pairs: [(key: String, value: String)]) -> String? {
    let fn = input.trimmingCharacters(in: .whitespaces)
    guard !fn.isEmpty else { return nil }
    var best: (prefixLength: Int, value: String)?
    for (rawKey, rawValue) in pairs {
        let key = rawKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        if key == fn { return value }
        let keyWithSlash = key.hasSuffix("/") ? key : key + "/"
        if fn.hasPrefix(keyWithSlash), best == nil || keyWithSlash.count > best!.prefixLength {
            let remainder = fn.dropFirst(keyWithSlash.count)
            let base = value.hasSuffix("/") ? String(value.dropLast()) : value
            best = (keyWithSlash.count, base + "/" + remainder)
        }
    }
    return best?.value
}

extension ServerConfig {
    /// `pathMappings` with any `smb://` local value substituted for its
    /// currently-resolved mount point (via `SMBMountResolver`); entries that
    /// don't currently resolve to a mount are left as-is (surfaced downstream as
    /// `.notMounted`). Resolved lazily on every call, not cached — mount points
    /// move (stale `/Volumes/Share-1` suffixes, different path after reboot).
    func effectiveMappings(mounts: [SMBMountResolver.MountEntry] = SMBMountResolver.currentMounts()) -> [PathMapping] {
        pathMappings.map { mapping in
            guard PathMapping.isSMBReference(mapping.local),
                  let resolved = SMBMountResolver.resolveMountPoint(forSMBReference: mapping.local, mounts: mounts)
            else { return mapping }
            return PathMapping(remote: mapping.remote, local: resolved)
        }
    }

    /// True when `remotePath` matches a mapping at all, resolved or not — used to
    /// gate Reveal/Open menu enablement so an unmounted `smb://` mapping still
    /// routes through to the actionable `.notMounted` toast instead of leaving
    /// the menu item silently disabled.
    func hasPathMapping(forRemotePath remotePath: String) -> Bool {
        longestPrefixMatch(remotePath, in: pathMappings.map { ($0.remote, $0.local) }) != nil
    }

    /// Translate a remote absolute path to a local one using this server's
    /// mappings. Returns `nil` when no mapping applies.
    ///
    /// Ported from `main.pas` `MapRemoteToLocal`, but strengthened to match
    /// `mapLocalToRemote`'s longest-prefix-wins tie-break: both sides use `/` on
    /// macOS, so the Pascal `FixSeparators` step reduces to a trim.
    func mapRemoteToLocal(_ remotePath: String, mounts: [SMBMountResolver.MountEntry] = SMBMountResolver.currentMounts()) -> String? {
        longestPrefixMatch(remotePath, in: effectiveMappings(mounts: mounts).map { ($0.remote, $0.local) })
    }

    /// Translate a local absolute path back to a remote one — the inverse of
    /// `mapRemoteToLocal`, used by Move's "Browse…" local folder picker. Longest
    /// matching local-side prefix wins (not "last matching entry", unlike the
    /// legacy Pascal `SelectRemoteFolder`, which lacked a break and let list order
    /// decide ties on overlapping mappings).
    func mapLocalToRemote(_ localPath: String, mounts: [SMBMountResolver.MountEntry] = SMBMountResolver.currentMounts()) -> String? {
        longestPrefixMatch(localPath, in: effectiveMappings(mounts: mounts).map { ($0.local, $0.remote) })
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
        /// An `smb://` mapping matched the remote path, but that share isn't
        /// currently mounted anywhere on this Mac.
        case notMounted(shareURL: String)
        /// No mapping matched this remote path at all.
        case unmapped
    }

    /// Resolve a remote path to a `LocalPathResolution`, checking existence via
    /// `fileExists` (injectable so this is unit-testable without touching the real
    /// filesystem; defaults to `FileManager.default.fileExists`).
    func resolveLocalPath(forRemotePath remotePath: String,
                           mounts: [SMBMountResolver.MountEntry] = SMBMountResolver.currentMounts(),
                           fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LocalPathResolution {
        guard let rawMapping = longestPrefixMatch(remotePath, in: pathMappings.map { ($0.remote, $0.local) })
        else { return .unmapped }

        if PathMapping.isSMBReference(rawMapping),
           SMBMountResolver.resolveMountPoint(forSMBReference: rawMapping, mounts: mounts) == nil {
            // Trigger-a-mount must target the share root, not the full resolved
            // subpath — opening a deep subpath mounts *that folder* as its own
            // volume instead of the actual share.
            let shareURL = SMBMountResolver.shareRootReference(rawMapping) ?? rawMapping
            return .notMounted(shareURL: shareURL)
        }

        guard let local = mapRemoteToLocal(remotePath, mounts: mounts) else { return .unmapped }
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
