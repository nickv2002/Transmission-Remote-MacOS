import AppKit
import XCTest

/// Settings ▸ General "Show piece map in the Info tab" checkbox: reflects the
/// config, and a click applies immediately through `onChange`.
@MainActor
final class PieceMapSettingTests: XCTestCase {
    private func checkbox(in controller: SettingsWindowController) -> NSButton? {
        func find(_ v: NSView?) -> NSButton? {
            guard let v else { return nil }
            if let b = v as? NSButton, b.title == "Show piece map in the Info tab" { return b }
            return v.subviews.lazy.compactMap(find).first
        }
        return find(controller.window?.contentView)
    }

    private func controller(showPieceMap: Bool) -> SettingsWindowController {
        SettingsWindowController(config: AppConfig(servers: [.localhost], refreshSeconds: 4,
                                                   showPieceMap: showPieceMap))
    }

    func testCheckboxReflectsConfig() throws {
        let on = try XCTUnwrap(checkbox(in: controller(showPieceMap: true)))
        XCTAssertEqual(on.state, .on)
        let off = try XCTUnwrap(checkbox(in: controller(showPieceMap: false)))
        XCTAssertEqual(off.state, .off)
    }

    func testTogglingAppliesImmediately() throws {
        let c = controller(showPieceMap: true)
        var applied: [AppConfig] = []
        c.onChange = { applied.append($0) }
        let box = try XCTUnwrap(checkbox(in: c))
        box.state = .on
        _ = box.sendAction(box.action, to: box.target)
        XCTAssertEqual(applied.last?.showPieceMap, true)
        box.state = .off
        _ = box.sendAction(box.action, to: box.target)
        XCTAssertEqual(applied.last?.showPieceMap, false)
    }
}
