import Foundation

/// Detects clickable web links in free text (torrent comments). Foundation-only
/// so it is unit-testable without AppKit.
///
/// Deliberately protocol-only: only spans that literally start with `http://` or
/// `https://` count as links. The text detector also matches bare domains
/// ("rutracker.org") and silently synthesises an `http://` URL for them — those
/// are rejected, along with every other scheme (magnets, mailto, ftp…), to keep
/// false positives out of user comments.
enum LinkText {
    struct Link: Equatable {
        let range: NSRange
        let url: URL
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Non-overlapping http(s) links in `text`, in order.
    static func links(in text: String) -> [Link] {
        guard let detector else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            // The detector reports bare domains with a synthesised http:// URL;
            // require the matched text itself to carry the scheme.
            guard let url = match.url, TorrentLink.isWebURL(ns.substring(with: match.range)) else { return nil }
            return Link(range: match.range, url: url)
        }
    }
}
