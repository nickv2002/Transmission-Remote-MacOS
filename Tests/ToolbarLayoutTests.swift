import AppKit
import XCTest

@MainActor
final class ToolbarLayoutTests: XCTestCase {
    func testDefaultLayoutShowsTitleAndLabelRowWithoutTooltips() {
        let l = ToolbarLayout.default
        XCTAssertTrue(l.showsTitle)
        XCTAssertFalse(l.showsToolTips)
    }

    func testHidingLabelsKeepsTheTitleAndUsesTooltips() {
        let l = ToolbarLayout(titleBar: .full, showsLabels: false)
        XCTAssertTrue(l.showsTitle)
        XCTAssertTrue(l.showsToolTips)
    }

    func testHiddenTitleBarKeepsLabelChoice() {
        let labelled = ToolbarLayout(titleBar: .hidden, showsLabels: true)
        XCTAssertFalse(labelled.showsTitle)
    }

    func testTitleBarDisplayNamesAreDistinctAndOrdered() {
        XCTAssertEqual(TitleBarStyle.allCases.map(\.displayName), ["Full", "Hidden"])
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
        XCTAssertEqual(popup.selectedCase(default: TitleBarStyle.hidden), .hidden)
    }
}
