import Foundation

/// Preset speed limits (KB/s) offered in the speed-limit menus. Client-side and
/// per server, like the legacy app's per-connection `DownSpeeds`/`UpSpeeds`; the
/// limits themselves live on the daemon.
enum SpeedPresets {
    /// The legacy app's default list, minus its leading 0 (our menu has an
    /// explicit "Unlimited" entry instead).
    static let defaults = [10, 25, 50, 100, 250, 500, 750, 1000, 2500, 5000, 7000]

    /// Parses a comma/space/newline separated list: drops non-numbers and
    /// non-positive values, dedupes, sorts ascending.
    static func parse(_ text: String) -> [Int] {
        let tokens = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        return Array(Set(tokens.compactMap { Int($0) }.filter { $0 > 0 })).sorted()
    }

    static func format(_ presets: [Int]) -> String {
        presets.map(String.init).joined(separator: ", ")
    }

    /// Menu values for a direction: the presets plus the daemon's current value
    /// if it isn't one of them, so an off-list limit still shows as checked.
    static func menuValues(presets: [Int], current: Int?) -> [Int] {
        guard let current, current > 0, !presets.contains(current) else { return presets }
        return (presets + [current]).sorted()
    }

    /// "500 KB/s" / "1.5 MB/s" using the daemon's decimal scale, so the text
    /// matches the web UI rather than a 1024-based formatter.
    static func label(kbps: Int) -> String {
        if kbps >= 1000 {
            let mb = Double(kbps) / 1000
            return mb == mb.rounded() ? "\(Int(mb)) MB/s" : String(format: "%.1f MB/s", mb)
        }
        return "\(kbps) KB/s"
    }
}
