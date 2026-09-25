import Foundation

/// Recognizing torrent links in free text — a clicked/opened URL, dropped text,
/// or the clipboard. Foundation-only so it's unit-tested without AppKit. Ported
/// from the legacy app's `IsProtocolSupported` / `isHash` / `CheckClipboardLink`.
enum TorrentLink {
    /// A link that is unambiguously a torrent: a `magnet:` link, an http(s) URL
    /// whose path ends in `.torrent`, or a bare info-hash (40 hex or 32 base32
    /// characters, turned into a `magnet:?xt=urn:btih:` link). Returns nil for
    /// anything else. Strict enough to act on without the user asking — used for
    /// the clipboard pickup.
    static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMagnet(trimmed) { return trimmed }
        if isInfoHash(trimmed) { return "magnet:?xt=urn:btih:" + trimmed }
        if isWebURL(trimmed), let url = URL(string: trimmed),
           url.path.lowercased().hasSuffix(".torrent") {
            return trimmed
        }
        return nil
    }

    /// Looser than `normalize`: also accepts any http(s) URL, since a `.torrent`
    /// can be served from a URL without the extension. For text the user
    /// deliberately handed us (a drop, an opened URL, the Add Link field).
    static func acceptable(_ text: String) -> String? {
        if let link = normalize(text) { return link }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isWebURL(trimmed) ? trimmed : nil
    }

    /// A key identifying which torrent a link refers to: a magnet's lowercased
    /// `urn:btih:` hash when present (so two spellings of the same magnet
    /// match), otherwise the link itself.
    static func identity(of link: String) -> String {
        // Split the query by hand: browsers hand over magnets with unencoded
        // spaces that `URLComponents` rejects outright.
        guard isMagnet(link), let query = link.split(separator: "?", maxSplits: 1).last else { return link }
        let prefix = "xt=urn:btih:"
        for pair in query.split(separator: "&") where pair.lowercased().hasPrefix(prefix) {
            return pair.dropFirst(prefix.count).lowercased()
        }
        return link
    }

    static func isMagnet(_ text: String) -> Bool {
        text.lowercased().hasPrefix("magnet:")
    }

    private static func isWebURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
            && !text.contains(where: \.isWhitespace)
    }

    /// A BitTorrent v1 info-hash: 40 hex characters, or its 32-character base32 form.
    static func isInfoHash(_ text: String) -> Bool {
        switch text.count {
        case 40:
            return text.allSatisfy(\.isHexDigit)
        case 32:
            return text.uppercased().allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
        default:
            return false
        }
    }
}
