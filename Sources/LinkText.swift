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
    /// Non-overlapping http(s) links in `text`, in order.
    static func links(in text: String) -> [NSTextCheckingResult] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let full = NSRange(location: 0, length: text.utf16.count)
        return detector.matches(in: text, options: [], range: full).filter { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return false }
            // The detector reports bare domains with a synthesised http:// URL;
            // require the matched text itself to carry the scheme.
            let matched = (text as NSString).substring(with: match.range).lowercased()
            return matched.hasPrefix("http://") || matched.hasPrefix("https://")
        }
    }
}
