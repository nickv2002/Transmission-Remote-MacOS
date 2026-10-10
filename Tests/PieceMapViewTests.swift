import AppKit
import XCTest

/// The Info tab's piece-map row (`PieceMapView`): collapse/expand with the
/// selection, the percentage label, and the tooltip/accessibility summary.
@MainActor
final class PieceMapViewTests: XCTestCase {
    private func sized(_ view: PieceMapView, width: CGFloat = 400) -> PieceMapView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        host.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return view
    }

    func testIsActiveRequiresToggleInfoTabAndSingleSelection() {
        XCTAssertTrue(PieceMapView.isActive(enabled: true, infoTabVisible: true, selectionCount: 1))
        XCTAssertFalse(PieceMapView.isActive(enabled: false, infoTabVisible: true, selectionCount: 1),
                       "toggle off → no row, no fetch")
        XCTAssertFalse(PieceMapView.isActive(enabled: true, infoTabVisible: false, selectionCount: 1))
        XCTAssertFalse(PieceMapView.isActive(enabled: true, infoTabVisible: true, selectionCount: 0))
        XCTAssertFalse(PieceMapView.isActive(enabled: true, infoTabVisible: true, selectionCount: 2))
    }

    func testStartsCollapsedAndHidden() {
        let view = sized(PieceMapView())
        XCTAssertTrue(view.isCollapsed)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.frame.height, 0, accuracy: 0.5)
    }

    func testUpdateWithProgressExpandsAndShowsPercent() {
        let view = sized(PieceMapView())
        view.update(progress: 0.258, pieces: nil, color: .systemBlue)
        view.superview?.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isCollapsed)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.renderedPercent, "25.8%")
        XCTAssertGreaterThan(view.frame.height, PieceMapView.bottomPadding + 24,
                             "caption + bars + padding should take real height")
        XCTAssertNil(view.toolTip, "no bitfield yet → no piece summary")
    }

    func testUpdateWithPiecesSetsSummaryTooltip() {
        let view = sized(PieceMapView())
        let pieces = TorrentPieces(pieceCount: 4, pieceSize: 1_024, bitfield: Data([0xA0]))
        view.update(progress: 0.5, pieces: pieces, color: .systemGreen)
        XCTAssertEqual(view.toolTip, pieces.summary)
    }

    func testUpdateWithNilProgressCollapsesAgain() {
        let view = sized(PieceMapView())
        view.update(progress: 1, pieces: nil, color: .systemGreen)
        XCTAssertEqual(view.renderedPercent, "100.0%")
        view.update(progress: nil, pieces: nil, color: .systemGreen)
        view.superview?.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isCollapsed)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.frame.height, 0, accuracy: 0.5)
    }

    func testProgressIsClampedToPercentRange() {
        let view = sized(PieceMapView())
        view.update(progress: 1.7, pieces: nil, color: .systemGreen)
        XCTAssertEqual(view.renderedPercent, "100.0%")
        view.update(progress: -0.2, pieces: nil, color: .systemGreen)
        XCTAssertEqual(view.renderedPercent, "0.0%")
    }
}
