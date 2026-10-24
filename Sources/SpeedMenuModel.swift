import Foundation

/// What choosing a speed-limit menu item does.
enum SpeedMenuAction: Equatable, Sendable {
    /// Regular ("fast") limit for a direction; nil = unlimited.
    case setLimit(SpeedDirection, Int?)
    /// Turtle-mode ("slow") limit for a direction.
    case setTurtleLimit(SpeedDirection, Int)
    case setTurtleEnabled(Bool)
    case editPresets
}

struct SpeedMenuEntry: Equatable, Sendable {
    let title: String
    let action: SpeedMenuAction
    let checked: Bool
}

/// One submenu (or, with no `entries`, a lone item) of the speed-limit menu.
struct SpeedMenuGroup: Equatable, Sendable {
    let title: String
    let entries: [SpeedMenuEntry]
    /// A group with no submenu, e.g. the turtle toggle: `entries` has one item
    /// and it is shown inline.
    let inline: Bool
}

/// Foundation-only description of the speed-limit menu, shared by the toolbar
/// pull-down and the Server menu so they never disagree. AppKit just renders it.
enum SpeedMenuModel {
    static let unlimitedTitle = "Unlimited"

    static func groups(session: SessionInfo, server: ServerConfig) -> [SpeedMenuGroup] {
        let normal = session.normalLimits
        let turtle = session.turtleLimits
        let isTurtle = session.isTurtleOn

        func regular(_ dir: SpeedDirection, title: String, presets: [Int]) -> SpeedMenuGroup {
            let current = normal[dir]
            // Checkmark follows the regular limit only while turtle isn't overriding it.
            var entries = [SpeedMenuEntry(
                title: unlimitedTitle, action: .setLimit(dir, nil),
                checked: !isTurtle && current == nil)]
            for value in SpeedPresets.menuValues(presets: presets, current: current) {
                entries.append(SpeedMenuEntry(
                    title: SpeedPresets.label(kbps: value), action: .setLimit(dir, value),
                    checked: !isTurtle && current == value))
            }
            return SpeedMenuGroup(title: title, entries: entries, inline: false)
        }

        func turtleGroup(_ dir: SpeedDirection, title: String, presets: [Int]) -> SpeedMenuGroup {
            let current = turtle[dir]
            let entries = SpeedPresets.menuValues(presets: presets, current: current).map {
                SpeedMenuEntry(
                    title: SpeedPresets.label(kbps: $0), action: .setTurtleLimit(dir, $0),
                    checked: current == $0)
            }
            return SpeedMenuGroup(title: title, entries: entries, inline: false)
        }

        let turtleValues = [turtle.down, turtle.up].map { $0.map { SpeedPresets.label(kbps: $0) } ?? "—" }
        let toggle = SpeedMenuEntry(
            title: "Turtle Mode (↓ \(turtleValues[0])  ↑ \(turtleValues[1]))",
            action: .setTurtleEnabled(!isTurtle), checked: isTurtle)

        return [
            regular(.down, title: "Download Limit", presets: server.downSpeedPresets),
            regular(.up, title: "Upload Limit", presets: server.upSpeedPresets),
            SpeedMenuGroup(title: toggle.title, entries: [toggle], inline: true),
            turtleGroup(.down, title: "Turtle Download Limit", presets: server.downSpeedPresets),
            turtleGroup(.up, title: "Turtle Upload Limit", presets: server.upSpeedPresets),
        ]
    }

    /// Short status-bar suffix for a direction: " (500 KB/s)" when a limit is in
    /// force, "" when unlimited, with a turtle marker when turtle mode applies.
    static func statusSuffix(session: SessionInfo?, direction: SpeedDirection) -> String {
        guard let session else { return "" }
        guard let limit = session.effectiveLimits[direction] else { return "" }
        return " (\(session.isTurtleOn ? "🐢 " : "")\(SpeedPresets.label(kbps: limit)))"
    }
}
