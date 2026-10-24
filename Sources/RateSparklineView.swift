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
        toolTip = "↓ \(Formatters.speed(d).nonEmpty ?? "0")   ↑ \(Formatters.speed(u).nonEmpty ?? "0")  — right-click for speed limits"
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 16) }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let peak = max(history.down.max() ?? 0, history.up.max() ?? 0)
        guard peak > 0 else { return }
        plot(history.down, color: .systemGreen, peak: peak)
        plot(history.up, color: .systemBlue, peak: peak)
    }

    private func plot(_ samples: [Int64], color: NSColor, peak: Int64) {
        guard samples.count > 1 else { return }
        let inset: CGFloat = 2
        let w = bounds.width - inset * 2, h = bounds.height - inset * 2
        // Right-align the newest sample so a short history grows in from the right.
        let step = w / CGFloat(history.capacity - 1)
        let path = NSBezierPath()
        for (i, v) in samples.enumerated() {
            let x = bounds.width - inset - CGFloat(samples.count - 1 - i) * step
            let point = NSPoint(x: x, y: inset + h * CGFloat(v) / CGFloat(peak))
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
