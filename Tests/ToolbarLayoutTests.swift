import AppKit
import XCTest

final class ToolbarLayoutTests: XCTestCase {
    func testDefaultLayoutShowsTitleAndLabelRowWithoutTooltips() {
        let l = ToolbarLayout.default
        XCTAssertFalse(l.isCompact)
        XCTAssertTrue(l.showsTitle)
        XCTAssertTrue(l.hasLabelRow)
        XCTAssertFalse(l.showsToolTips)
        XCTAssertFalse(l.serverIconIsAppIcon)
    }

    func testCompactLayoutHidesTitleAndUsesTooltipsAndAppIcon() {
        let l = ToolbarLayout.compact
        XCTAssertTrue(l.isCompact)
        XCTAssertFalse(l.showsTitle)
        XCTAssertFalse(l.hasLabelRow)
        XCTAssertTrue(l.showsToolTips)
        XCTAssertTrue(l.serverIconIsAppIcon)
    }

    func testIconOnlyDisplayModeMapsToCompact() {
        XCTAssertEqual(ToolbarLayout(iconOnly: true), .compact)
        XCTAssertEqual(ToolbarLayout(iconOnly: false), .default)
    }

    func testDisplayNamesAreDistinctAndOrdered() {
        XCTAssertEqual(ToolbarLayout.allCases.map(\.displayName), ["Default", "Compact"])
    }

    // MARK: - PopUpEnum

    func testConfigureAddsOneItemPerCaseInOrder() {
        let popup = NSPopUpButton()
        popup.configure(for: TorrentFileRemoval.self)
        XCTAssertEqual(popup.itemTitles, TorrentFileRemoval.allCases.map(\.displayName))
        popup.configure(for: TorrentFileRemoval.self)   // idempotent, no duplicates
        XCTAssertEqual(popup.numberOfItems, TorrentFileRemoval.allCases.count)
    }

    func testSelectAndSelectedCaseRoundTrip() {
        let popup = NSPopUpButton()
        popup.configure(for: TorrentFileRemoval.self)
        for method in TorrentFileRemoval.allCases {
            popup.select(method)
            XCTAssertEqual(popup.selectedCase(default: TorrentFileRemoval.none), method)
        }
    }

    func testSelectedCaseFallsBackWhenNothingSelected() {
        let popup = NSPopUpButton()   // no items: index is -1
        XCTAssertEqual(popup.selectedCase(default: ToolbarLayout.compact), .compact)
    }
}
