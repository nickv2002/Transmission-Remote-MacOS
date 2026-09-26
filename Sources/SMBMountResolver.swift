import Foundation

/// Resolves an `smb://host/share/subpath` reference (the same string Finder's
/// Connect-to-Server takes) to the local `/Volumes/...` path it's *currently*
/// mounted at, so a `PathMapping`'s local side can be typed as an SMB address
/// instead of requiring the user to hunt down the mount point by hand
/// (ported motivation: issue #12).
///
/// Pure and Foundation-only — the mount list is injected, so resolution is
/// unit-tested without a real network mount.
enum SMBMountResolver {
    /// One currently-mounted network volume.
    struct MountEntry: Equatable {
        /// The URL macOS would use to remount this volume (e.g.
        /// `smb://user@host/share`), from `.volumeURLForRemountingKey`.
        let remountURL: URL
        /// Its local mount point (e.g. `/Volumes/Share-1`).
        let mountPoint: String
    }

    /// The live mount list, read via `FileManager`. No raw `statfs`/`getfsstat`
    /// needed — `.volumeURLForRemountingKey` already gives the remount URL for
    /// every mounted volume, network or local.
    static func currentMounts() -> [MountEntry] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLForRemountingKey],
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url in
            guard let remount = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting
            else { return nil }
            return MountEntry(remountURL: remount, mountPoint: url.path)
        }
    }

    /// A parsed `host`/`share`/`subpath` triple, normalized so a user-typed
    /// reference and a mount's remount URL can be compared on the same shape.
    struct Reference: Equatable {
        let host: String
        let share: String
        let subpath: String
    }

    /// Parse an `smb://[user@]host/share[/subpath]` string (scheme required).
    /// Strips any embedded username, lowercases and normalizes the host
    /// (trailing dot, `.local`/Bonjour `._smb._tcp.local` suffixes), and
    /// lowercases the share name for case-insensitive comparison (SMB share
    /// names are case-insensitive).
    static func parseSMBReference(_ s: String) -> Reference? {
        guard let decoded = s.removingPercentEncoding,
              let components = URLComponents(string: decoded),
              components.scheme?.lowercased() == "smb",
              var host = components.host?.lowercased(), !host.isEmpty
        else { return nil }

        if host.hasSuffix(".") { host.removeLast() }
        for suffix in ["._smb._tcp.local", ".local"] {
            if host.hasSuffix(suffix) { host.removeLast(suffix.count) }
        }

        let pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let share = pathParts.first else { return nil }

        let subpath = pathParts.dropFirst().joined(separator: "/")
        return Reference(host: host, share: share.lowercased(), subpath: subpath)
    }

    /// Truncate an `smb://[user@]host/share/subpath` reference down to just
    /// `smb://[user@]host/share` — the actual mountable resource. Passing a deep
    /// subpath straight to `NSWorkspace.open`/the automounter mounts *that
    /// subfolder* as its own volume (e.g. mounting `/Volumes/09` instead of
    /// `/Volumes/Undupe` for `smb://host/Undupe/2026/09`) instead of mounting the
    /// share itself, so any "trigger a mount" affordance must use this, not the
    /// full resolved reference. Preserves the original scheme/userinfo/host
    /// casing (unlike `parseSMBReference`, which normalizes for comparison).
    static func shareRootReference(_ s: String) -> String? {
        guard var components = URLComponents(string: s),
              components.scheme?.lowercased() == "smb",
              let host = components.host, !host.isEmpty
        else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let share = parts.first else { return nil }
        components.path = "/" + share
        return components.string
    }

    /// Resolve an `smb://...` reference to its current local mount point (with
    /// any subpath from the reference appended), or `nil` if nothing mounted
    /// matches. Matches on exact host+share first; if no host matches but
    /// exactly one mounted share has the same share name, matches on that
    /// alone (typed hostnames commonly differ from what Finder actually
    /// resolved — e.g. Bonjour name vs `.local` vs IP).
    static func resolveMountPoint(forSMBReference ref: String, mounts: [MountEntry] = currentMounts()) -> String? {
        guard let target = parseSMBReference(ref) else { return nil }

        let parsedMounts = mounts.compactMap { mount -> (Reference, String)? in
            guard let parsed = parseSMBReference(mount.remountURL.absoluteString) else { return nil }
            return (parsed, mount.mountPoint)
        }

        let exact = parsedMounts.first { $0.0.host == target.host && $0.0.share == target.share }
        let mountPoint: String
        if let exact {
            mountPoint = exact.1
        } else {
            let shareNameMatches = parsedMounts.filter { $0.0.share == target.share }
            guard shareNameMatches.count == 1 else { return nil }
            mountPoint = shareNameMatches[0].1
        }

        return target.subpath.isEmpty ? mountPoint : mountPoint + "/" + target.subpath
    }
}
