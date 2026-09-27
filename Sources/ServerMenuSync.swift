import Foundation

/// Decides whether the Server menu's `NSMenuItem`s can be updated in place
/// (safe while `NSMenuTrackingSession` may still hold references to them) or
/// need a full structural rebuild.
enum ServerMenuSync {
    /// - Parameters:
    ///   - existingNames: server names read off the menu's current items, in
    ///     item order.
    ///   - available: the live list of configured server names, in order.
    /// - Returns: `true` when the two lists are identical (same names, same
    ///   order) and non-empty, meaning only `.state` needs updating; `false`
    ///   when items must be removed/re-added.
    static func canUpdateInPlace(existingNames: [String], available: [String]) -> Bool {
        !existingNames.isEmpty && existingNames == available
    }
}
