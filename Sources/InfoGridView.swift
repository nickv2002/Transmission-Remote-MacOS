import AppKit

/// Non-editable value view used when a value contains clickable links. Renders
/// an attributed string whose `.link` spans open on click (the card routes the
/// clicks, so the text view itself never becomes first responder) and reports
/// its wrapped-text height through `intrinsicContentSize`, keeping the card's
/// `fittingSize`-based layout unchanged.
@MainActor
final class LinkTextView: NSTextView {
    convenience init() { self.init(frame: .zero, textContainer: nil) }

    /// `init(frame:textContainer:)` with a nil container does NOT build the
    /// default text system (unlike `init(frame:)`), so wire storage → layout
    /// manager → container by hand.
    override init(frame frameRect: NSRect, textContainer tc: NSTextContainer?) {
        let container = tc ?? NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(lm)
        super.init(frame: frameRect, textContainer: container)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        isRichText = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()   // the wrap width may have changed
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: tc).height))
    }
}

/// One field in the info grid: a tiny gray uppercase caption above a value.
/// Clicking anywhere on the card copies the value to the pasteboard and calls
/// `onCopy` (so the owner can show a "Copied: …" toast). Shows a pointing-hand
/// cursor over the whole card. The value wraps to the card's width, or truncates
/// to one line for `truncate` fields like the name (still copyable in full).
///
/// When a non-truncating value contains http(s) links (`LinkText.links`), the
/// value renders through `LinkTextView` instead: link spans are highlighted and
/// a click **on a link** opens it (`onOpenLink`, default: the default browser)
/// instead of copying; every other click still copies the whole value.
///
/// Laid out internally with Auto Layout but positioned by its parent with an
/// explicit frame, so it reports the right height for any width via `fittingSize`.
@MainActor
final class InfoCardView: NSView {
    private let caption = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private lazy var linkView = LinkTextView()
    private var usingLinks = false
    private var truncates = false
    private var activeValueConstraints: [NSLayoutConstraint] = []

    /// Called with the copied value after a click.
    var onCopy: ((String) -> Void)?
    /// Called with a URL clicked inside the value. Defaults to opening it in the
    /// default browser; tests override it.
    var onOpenLink: ((URL) -> Void)?

    var displayedValue: String { usingLinks ? linkView.string : label.stringValue }
    /// Nothing to copy for an empty value or the "—" placeholder.
    private var isCopyable: Bool { !displayedValue.isEmpty && displayedValue != "—" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        addSubview(caption)
        addSubview(label)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        activateValueConstraints(for: label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(caption captionText: String, value valueText: String,
                   truncate: Bool, onCopy: @escaping (String) -> Void) {
        caption.stringValue = captionText.uppercased()
        truncates = truncate
        label.lineBreakMode = truncate ? .byTruncatingTail : .byWordWrapping
        label.maximumNumberOfLines = truncate ? 1 : 0
        self.onCopy = onCopy
        setValue(valueText)
    }

    func setValue(_ text: String) {
        let links = truncates ? [] : LinkText.links(in: text)
        if links.isEmpty {
            label.stringValue = text
            showValue(label)
        } else {
            linkView.textStorage?.setAttributedString(Self.linked(text, links: links))
            showValue(linkView)
        }
    }

    private func showValue(_ view: NSView) {
        let useLinks = view === linkView
        if useLinks, !usingLinks {
            addSubview(linkView)
            label.isHidden = true
            activateValueConstraints(for: linkView)
            usingLinks = true
        } else if !useLinks, usingLinks {
            linkView.isHidden = true
            label.isHidden = false
            activateValueConstraints(for: label)
            usingLinks = false
        }
    }

    private func activateValueConstraints(for view: NSView) {
        NSLayoutConstraint.deactivate(activeValueConstraints)
        activeValueConstraints = [
            view.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 1),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(activeValueConstraints)
    }

    /// The value text with http(s) links styled as clickable spans.
    private static func linked(_ text: String, links: [NSTextCheckingResult]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        for match in links {
            guard let url = match.url else { continue }
            s.addAttribute(.link, value: url, range: match.range)
            s.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range)
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
        }
        return s
    }

    /// The URL under a point in this card's coordinate space, or nil when the
    /// point misses every link span.
    func linkURL(atCardPoint point: NSPoint) -> URL? {
        guard usingLinks else { return nil }
        let local = linkView.convert(point, from: self)
        guard linkView.bounds.contains(local),
              let lm = linkView.layoutManager, let tc = linkView.textContainer
        else { return nil }
        lm.ensureLayout(for: tc)
        let index = lm.characterIndex(for: local, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < (linkView.textStorage?.length ?? 0),
              let url = linkView.textStorage?.attribute(.link, at: index, effectiveRange: nil) as? URL
        else { return nil }
        return url
    }

    override func layout() {
        super.layout()
        label.preferredMaxLayoutWidth = bounds.width
    }

    /// Height this card needs at the given width.
    func height(forWidth width: CGFloat) -> CGFloat {
        frame = NSRect(x: 0, y: 0, width: width, height: 1)
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    // The whole card is the click target — grab clicks anywhere inside it, not just
    // over the value label.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        if isCopyable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        // A click on a link span opens it; every other click copies the value.
        let point = convert(event.locationInWindow, from: nil)
        if let url = linkURL(atCardPoint: point) {
            if let onOpenLink { onOpenLink(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        guard isCopyable else { return }
        let text = displayedValue
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        onCopy?(text)
    }
}

/// One info field: a caption, its display value, whether it spans the full width
/// (long strings) or sits in the multi-column grid (short stats), how many columns
/// it occupies, and whether the value truncates to one line. Pure data so the
/// field list is unit-testable without instantiating any views.
struct InfoField: Equatable {
    let caption: String
    let value: String
    let fullWidth: Bool
    var truncate: Bool = false
    var span: Int = 1
    /// Force this field onto a fresh row even if the current one has room.
    var breakBefore: Bool = false
}

/// The torrent Info pane: an adaptive multi-column card grid (up to four columns
/// when wide, fewer when narrow). The name spans two columns; other short stats
/// take one; long fields (error, location, comment, hash) span the full width and
/// wrap. Clicking any card copies its value.
///
/// Laid out manually by reflowing on `layout()` and reporting height through
/// `intrinsicContentSize`. This imposes **no minimum width**, so the enclosing
/// split view can be resized freely — unlike an `NSGridView` whose fixed column
/// widths would lock the split divider.
@MainActor
final class InfoGridView: NSView {
    /// Called with the copied value after a card is clicked, so the owner can
    /// show a "Copied: <value>" toast.
    var onCopy: ((String) -> Void)?

    private struct Item {
        let view: NSView
        let fullWidth: Bool
        let span: Int
        let breakBefore: Bool
    }

    private var items: [Item] = []
    private var cardsByCaption: [String: InfoCardView] = [:]
    private var contentHeight: CGFloat = 0
    private var laidOutRowCount = 0

    /// Identity of what's currently rendered, so polls that don't change the
    /// structure update values in place instead of rebuilding.
    private var currentTorrentId: Int?
    private var currentSelectionIds: Set<Int> = []
    private var currentSignature: [String] = []

    private static let maxColumns = 4
    private static let minColumnWidth: CGFloat = 170
    private static let gutter: CGFloat = 12
    private static let rowGap: CGFloat = 8

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    // MARK: - Update

    /// Render the selected torrents, or a placeholder when nothing is selected.
    /// Reuses the existing cards (updating only their values) when the structure
    /// is unchanged, so the ~4s poll doesn't rebuild the grid each time.
    func update(with torrents: [Torrent]) {
        switch torrents.count {
        case 0:
            showPlaceholder("No torrent selected.")
        case 1:
            let t = torrents[0]
            let fields = Self.fields(for: t)
            let signature = fields.map { ($0.fullWidth ? "W·" : "S·") + $0.caption }
            if currentTorrentId == t.id, signature == currentSignature {
                for f in fields { cardsByCaption[f.caption]?.setValue(f.value) }
                needsLayout = true
                return
            }
            rebuild(fields: fields)
            currentTorrentId = t.id
            currentSelectionIds = []
            currentSignature = signature
        default:
            let fields = Self.fields(for: torrents)
            let signature = fields.map { ($0.fullWidth ? "W·" : "S·") + $0.caption }
            let ids = Set(torrents.map(\.id))
            if currentSelectionIds == ids, signature == currentSignature {
                for f in fields { cardsByCaption[f.caption]?.setValue(f.value) }
                needsLayout = true
                return
            }
            rebuild(fields: fields)
            currentTorrentId = nil
            currentSelectionIds = ids
            currentSignature = signature
        }
    }

    // MARK: - Layout

    /// Columns that fit at the given width (1...maxColumns).
    private func columnCount(forWidth width: CGFloat) -> Int {
        let fit = Int((width + Self.gutter) / (Self.minColumnWidth + Self.gutter))
        return max(1, min(Self.maxColumns, fit))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        let cols = columnCount(forWidth: width)
        let colWidth = max(1, (width - Self.gutter * CGFloat(cols - 1)) / CGFloat(cols))

        var y: CGFloat = 0
        var rowCount = 0
        var run: [(view: NSView, span: Int, breakBefore: Bool)] = []   // short cards awaiting packing

        func widthForSpan(_ span: Int) -> CGFloat {
            CGFloat(span) * colWidth + CGFloat(span - 1) * Self.gutter
        }

        func flushRun() {
            guard !run.isEmpty else { return }
            var col = 0
            var rowStartY = y
            var rowHeight: CGFloat = 0
            for (view, rawSpan, breakBefore) in run {
                let span = max(1, min(rawSpan, cols))
                if col > 0, breakBefore || col + span > cols {   // wrap to next row
                    y = rowStartY + rowHeight + Self.rowGap
                    rowStartY = y
                    rowHeight = 0
                    col = 0
                    rowCount += 1
                }
                let x = CGFloat(col) * (colWidth + Self.gutter)
                let w = widthForSpan(span)
                let h = (view as? InfoCardView)?.height(forWidth: w) ?? 0
                view.frame = NSRect(x: x, y: rowStartY, width: w, height: h)
                rowHeight = max(rowHeight, h)
                col += span
            }
            y = rowStartY + rowHeight + Self.rowGap        // finalize the last row
            rowCount += 1
            run.removeAll()
        }

        for item in items {
            if item.fullWidth {
                flushRun()
                let v = item.view
                let h = (v as? InfoCardView)?.height(forWidth: width) ?? {
                    v.frame = NSRect(x: 0, y: y, width: width, height: 1)
                    v.layoutSubtreeIfNeeded()
                    return v.fittingSize.height
                }()
                v.frame = NSRect(x: 0, y: y, width: width, height: h)
                y += h + Self.rowGap
                rowCount += 1
            } else {
                run.append((item.view, item.span, item.breakBefore))
            }
        }
        flushRun()

        laidOutRowCount = rowCount
        let newHeight = max(0, y - Self.rowGap)
        if abs(newHeight - contentHeight) > 0.5 {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Build

    private func clear() {
        for item in items { item.view.removeFromSuperview() }
        items.removeAll()
        cardsByCaption.removeAll()
    }

    private func showPlaceholder(_ text: String) {
        guard placeholderText != text else { return }
        clear()
        currentTorrentId = nil
        currentSelectionIds = []
        currentSignature = []
        placeholderText = text
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        items = [Item(view: label, fullWidth: true, span: 1, breakBefore: false)]
        needsLayout = true
    }

    private func rebuild(fields: [InfoField]) {
        clear()
        placeholderText = nil
        for field in fields {
            items.append(Item(view: makeCard(field), fullWidth: field.fullWidth,
                              span: field.span, breakBefore: field.breakBefore))
        }
        needsLayout = true
    }

    private func makeCard(_ field: InfoField) -> InfoCardView {
        let card = InfoCardView()
        card.configure(caption: field.caption, value: field.value, truncate: field.truncate) {
            [weak self] copied in self?.onCopy?(copied)
        }
        addSubview(card)
        cardsByCaption[field.caption] = card
        return card
    }

    // MARK: - Test hooks

    /// Currently-displayed placeholder text, or nil when showing a torrent.
    private(set) var placeholderText: String?
    /// Number of rows produced by the most recent layout pass.
    var renderedRowCount: Int { laidOutRowCount }
    /// The displayed value for a caption, or nil if absent.
    func renderedValue(forCaption caption: String) -> String? {
        cardsByCaption[caption]?.displayedValue
    }
    /// The card for a caption, so tests can exercise click-to-copy.
    func renderedCard(forCaption caption: String) -> InfoCardView? {
        cardsByCaption[caption]
    }

    // MARK: - Field list

    /// Build the ordered field list for a torrent. Pure — no view dependencies —
    /// so it is unit-testable directly.
    static func fields(for t: Torrent) -> [InfoField] {
        func dash(_ s: String) -> String { s.isEmpty ? "—" : s }

        var fields: [InfoField] = []
        func short(_ caption: String, _ value: String, truncate: Bool = false,
                   span: Int = 1, breakBefore: Bool = false) {
            fields.append(InfoField(caption: caption, value: value, fullWidth: false,
                                    truncate: truncate, span: span, breakBefore: breakBefore))
        }
        func wide(_ caption: String, _ value: String) {
            fields.append(InfoField(caption: caption, value: value, fullWidth: true))
        }

        // Top row: name and location share it, two columns each. Name truncates to
        // one line (copyable in full); location wraps so the deep folder stays visible.
        short("Name", t.name, truncate: true, span: 2)
        short("Location", t.downloadDir, span: 2)
        if t.hasError { wide("Error", "[\(t.errorCode)] \(t.errorString)") }

        short("Status", t.statusDisplayName)
        short("Progress", Formatters.percent(t.displayProgress))
        short("Ratio", Formatters.ratio(t.uploadRatio))
        // "want" only differs when some files are unwanted; omit the noise otherwise.
        let size = t.sizeWhenDone == t.totalSize
            ? Formatters.size(t.totalSize)
            : "\(Formatters.size(t.totalSize)) (want \(Formatters.size(t.sizeWhenDone)))"
        short("Size", size)
        short("Downloaded", Formatters.size(t.downloadedEver))
        short("Uploaded", Formatters.size(t.uploadedEver))
        short("Priority", t.bandwidthPriority.displayName)
        short("Queue", "\(t.queuePosition + 1)")
        short("Download ↓", dash(Formatters.speed(t.rateDownload)))
        short("Upload ↑", dash(Formatters.speed(t.rateUpload)))
        short("ETA", dash(t.etaDisplay))
        short("Peers", "\(t.peersConnected) connected (↓\(t.peersSendingToUs) ↑\(t.peersGettingFromUs))")
        if let host = t.trackerHost { short("Tracker", host) }
        short("Added", Formatters.dateTime(t.addedDate))
        if t.doneDate > 0 { short("Completed", Formatters.dateTime(t.doneDate)) }
        short("Last activity", Formatters.dateTime(t.activityDate))
        // Bottom row: comment + hash share it, two columns each (mirrors name/location).
        if !t.comment.isEmpty {
            short("Comment", t.comment, span: 2, breakBefore: true)
            short("Hash", t.hashString, span: 2)
        } else {
            short("Hash", t.hashString, span: 2, breakBefore: true)
        }
        return fields
    }

    /// Build the ordered field list for a multi-torrent selection. Pure — no view
    /// dependencies — so it is unit-testable directly.
    static func fields(for torrents: [Torrent]) -> [InfoField] {
        var fields: [InfoField] = []
        func short(_ caption: String, _ value: String, span: Int = 1) {
            fields.append(InfoField(caption: caption, value: value, fullWidth: false, span: span))
        }
        func wide(_ caption: String, _ value: String) {
            fields.append(InfoField(caption: caption, value: value, fullWidth: true))
        }

        // Status breakdown: active states first, then stopped.
        let statusOrder: [TorrentStatus] = [.downloading, .seeding, .checking,
                                             .checkWait, .downloadWait, .seedWait, .stopped]
        let grouped = Dictionary(grouping: torrents) { $0.status }
        let statusSummary = statusOrder.compactMap { status -> String? in
            guard let count = grouped[status]?.count, count > 0 else { return nil }
            return "\(count) \(status.displayName.lowercased())"
        }.joined(separator: " · ")

        let errorCount = torrents.filter { $0.hasError }.count

        let totalSize = torrents.reduce(Int64(0)) { $0 + $1.totalSize }
        let totalSizeWhenDone = torrents.reduce(Int64(0)) { $0 + $1.sizeWhenDone }
        let totalLeft = torrents.reduce(Int64(0)) { $0 + $1.leftUntilDone }
        let overallProgress = totalSizeWhenDone > 0
            ? Double(totalSizeWhenDone - totalLeft) / Double(totalSizeWhenDone) : 0

        let totalDown = torrents.reduce(Int64(0)) { $0 + $1.downloadedEver }
        let totalUp = torrents.reduce(Int64(0)) { $0 + $1.uploadedEver }
        let rateDown = torrents.reduce(Int64(0)) { $0 + $1.rateDownload }
        let rateUp = torrents.reduce(Int64(0)) { $0 + $1.rateUpload }

        let totalPeers = torrents.reduce(0) { $0 + $1.peersConnected }
        let totalSending = torrents.reduce(0) { $0 + $1.peersSendingToUs }
        let totalGetting = torrents.reduce(0) { $0 + $1.peersGettingFromUs }

        let earliestAdded = torrents.map(\.addedDate).min() ?? 0
        let latestActivity = torrents.map(\.activityDate).max() ?? 0

        short("Torrents", "\(torrents.count) selected", span: 2)
        short("Status", statusSummary.isEmpty ? "—" : statusSummary, span: 2)
        if errorCount > 0 { wide("Errors", "\(errorCount) with errors") }

        short("Total Size", Formatters.size(totalSize))
        short("Progress", Formatters.percent(overallProgress))
        short("Total Downloaded", Formatters.size(totalDown))
        short("Total Uploaded", Formatters.size(totalUp))
        short("Download ↓", rateDown > 0 ? Formatters.speed(rateDown) : "—")
        short("Upload ↑", rateUp > 0 ? Formatters.speed(rateUp) : "—")
        short("Peers", "\(totalPeers) connected (↓\(totalSending) ↑\(totalGetting))")
        short("Earliest Added", Formatters.dateTime(earliestAdded))
        short("Latest Activity", Formatters.dateTime(latestActivity))

        return fields
    }
}
