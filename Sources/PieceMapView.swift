import AppKit

/// The Info tab's "Pieces" row — the legacy app's `pbDownloaded` paint box: a
/// thin classic progress bar on top and, beneath it, a map of which pieces the
/// daemon already has, with the percentage to the right (legacy
/// `txDownProgress`). The map downsamples the bitfield to the bar's backing
/// pixels (`TorrentPieces.coverage`); a column's tint fades with the share of
/// its pieces present, so sparse pieces stay visible where the legacy
/// `StretchDraw` would have dropped them.
///
/// The classic bar updates from the list poll's progress every refresh; the
/// map is fed by the on-demand `pieces` fetch (`loadPiecesIfNeeded`) and draws
/// an empty track until it arrives. With no single torrent selected the row
/// collapses to zero height (including its bottom padding) so the grid below
/// moves up.
@MainActor
final class PieceMapView: NSView {
    /// Space between this row and the info grid below it when shown — the
    /// grid's own row gap, so the row reads as its first line.
    static let bottomPadding: CGFloat = 8

    private let caption = NSTextField(labelWithString: "PIECES")
    private let percentLabel = NSTextField(labelWithString: "")
    private let bars = BarsView()
    /// Zero-height constraint, active while no single torrent is selected.
    private lazy var collapsed = heightAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        bars.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        addSubview(bars)
        addSubview(percentLabel)
        // The bottom padding is what gives the row its height; it yields to the
        // required `collapsed` (height 0) constraint instead of conflicting with it.
        let bottom = bars.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomPadding)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bars.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 3),
            bars.leadingAnchor.constraint(equalTo: leadingAnchor),
            bars.heightAnchor.constraint(equalToConstant: BarsView.height),
            bottom,
            percentLabel.leadingAnchor.constraint(equalTo: bars.trailingAnchor, constant: 8),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 48),
            percentLabel.centerYAnchor.constraint(equalTo: bars.centerYAnchor),
        ])
        update(progress: nil, pieces: nil, color: .controlAccentColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show `progress` (0…1) on the classic bar and `pieces` on the map, both
    /// tinted `color` (the list's state colour). `progress == nil` collapses the
    /// row (nothing, or several torrents, selected).
    func update(progress: Double?, pieces: TorrentPieces?, color: NSColor) {
        guard let progress else {
            isHidden = true
            collapsed.isActive = true
            toolTip = nil
            return
        }
        isHidden = false
        collapsed.isActive = false
        bars.progress = min(max(progress, 0), 1)
        bars.pieces = pieces
        bars.fillColor = color
        bars.needsDisplay = true
        percentLabel.stringValue = Formatters.percent(progress, precise: true)
        toolTip = pieces?.summary
        bars.setAccessibilityValue(percentLabel.stringValue)
        bars.setAccessibilityHelp(pieces?.summary)
    }

    // MARK: - Test hooks

    /// Whether the row is collapsed (no single torrent selected).
    var isCollapsed: Bool { collapsed.isActive }
    /// The percentage text shown at the right.
    var renderedPercent: String { percentLabel.stringValue }
    /// Number of map columns drawn by the last draw pass (0 before any draw).
    var renderedColumnCount: Int { bars.cachedColumns }

    /// The drawn bars: classic progress on top, the piece map below.
    private final class BarsView: NSView {
        static let height: CGFloat = 24
        private static let progressBarHeight: CGFloat = 6
        private static let gap: CGFloat = 4

        var progress: Double = 0
        var pieces: TorrentPieces?
        var fillColor: NSColor = .controlAccentColor

        private(set) var cachedColumns = 0
        private var cachedPieces: TorrentPieces?
        private var cachedCoverage: [Double] = []

        override var wantsUpdateLayer: Bool { false }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }

        override func draw(_ dirtyRect: NSRect) {
            drawProgressBar()
            drawPieceMap()
        }

        private func drawProgressBar() {
            let h = Self.progressBarHeight
            let rect = NSRect(x: 0, y: bounds.maxY - h, width: bounds.width, height: h)
            let radius = h / 2
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            guard progress > 0 else { return }
            var fill = rect
            fill.size.width = max(h, rect.width * CGFloat(progress))
            fillColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }

        private func drawPieceMap() {
            let rect = NSRect(x: 0, y: 0, width: bounds.width,
                              height: bounds.height - Self.progressBarHeight - Self.gap)
            guard rect.width > 0, rect.height > 0 else { return }
            let radius: CGFloat = 3
            let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.quaternaryLabelColor.setFill()
            outline.fill()

            if let pieces, pieces.pieceCount > 0 {
                let scale = window?.backingScaleFactor ?? 2
                let columns = max(1, Int((rect.width * scale).rounded(.down)))
                if columns != cachedColumns || pieces != cachedPieces {
                    cachedColumns = columns
                    cachedPieces = pieces
                    cachedCoverage = pieces.coverage(columns: columns)
                }
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                let columnWidth = rect.width / CGFloat(columns)
                // Fill runs of equal coverage as one rect — a complete torrent is a
                // single fill, not one per pixel.
                var runStart = 0
                while runStart < columns {
                    let coverage = cachedCoverage[runStart]
                    var runEnd = runStart + 1
                    while runEnd < columns, cachedCoverage[runEnd] == coverage { runEnd += 1 }
                    if coverage > 0 {
                        // Any presence shows at least a quarter tint, so a lone
                        // piece in a busy column doesn't vanish.
                        let alpha = 0.25 + 0.75 * coverage
                        fillColor.withAlphaComponent(alpha).setFill()
                        NSRect(x: rect.minX + CGFloat(runStart) * columnWidth, y: rect.minY,
                               width: CGFloat(runEnd - runStart) * columnWidth, height: rect.height).fill()
                    }
                    runStart = runEnd
                }
                NSGraphicsContext.restoreGraphicsState()
            }

            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            border.lineWidth = 1
            border.stroke()
        }
    }
}
