import AppKit

/// Compact whole-server speed graph for the status bar: download (green) and
/// upload (blue) over the last few minutes of polls, both on one shared scale.
/// Right-click opens the speed-limit menu, like the legacy status-bar panels.
final class RateSparklineView: NSView {
    private var history = RateHistory()
    /// Supplies the context menu on right-click (rebuilt each time so it's current).
    var menuProvider: (() -> NSMenu)?

    func update(_ history: RateHistory) {
        self.history = history
        let d = history.down.last ?? 0, u = history.up.last ?? 0
        toolTip = "↓ \(Formatters.speed(d).nonEmpty ?? "0")   ↑ \(Formatters.speed(u).nonEmpty ?? "0")  — click for speed limits"
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 16) }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// Left-click opens the same menu, so the graph reads as a control.
    override func mouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Width reserved at the left for the "↓ ↑" key.
    private static let keyWidth: CGFloat = 26

    override func draw(_ dirtyRect: NSRect) {
        // Key: coloured arrows say what the two lines are, even when idle.
        let key = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        key.append(NSAttributedString(string: "↓", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
        key.append(NSAttributedString(string: "↑", attributes: [.font: font, .foregroundColor: NSColor.systemBlue]))
        let size = key.size()
        key.draw(at: NSPoint(x: 2, y: (bounds.height - size.height) / 2))

        let plotRect = NSRect(x: Self.keyWidth, y: 0, width: bounds.width - Self.keyWidth, height: bounds.height)
        NSColor.separatorColor.setStroke()
        let frame = NSBezierPath(roundedRect: plotRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        frame.lineWidth = 1
        frame.stroke()

        // Idle baseline so an empty graph still looks like a graph.
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plotRect.minX + 3, y: plotRect.minY + 3))
        base.line(to: NSPoint(x: plotRect.maxX - 3, y: plotRect.minY + 3))
        NSColor.tertiaryLabelColor.setStroke()
        base.lineWidth = 1
        base.stroke()

        let peak = max(history.down.max() ?? 0, history.up.max() ?? 0)
        guard peak > 0 else { return }
        plot(history.down, color: .systemGreen, peak: peak, in: plotRect)
        plot(history.up, color: .systemBlue, peak: peak, in: plotRect)
    }

    private func plot(_ samples: [Int64], color: NSColor, peak: Int64, in rect: NSRect) {
        guard samples.count > 1 else { return }
        let inset: CGFloat = 3
        let w = rect.width - inset * 2, h = rect.height - inset * 2
        // Right-align the newest sample so a short history grows in from the right.
        let step = w / CGFloat(history.capacity - 1)
        let path = NSBezierPath()
        for (i, v) in samples.enumerated() {
            let x = rect.maxX - inset - CGFloat(samples.count - 1 - i) * step
            let point = NSPoint(x: x, y: rect.minY + inset + h * CGFloat(v) / CGFloat(peak))
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        color.setStroke()
        path.lineWidth = 1.2
        path.stroke()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
