import AppKit
import XCTest

/// Settings ▸ General ▸ Advanced: the opt-in peer-country checkbox and the
/// DB-IP attribution links. (Toggling is not exercised here: it would hit the
/// real download and the real Application Support file via `GeoIPStore.shared`.)
@MainActor
final class PeerCountrySettingTests: XCTestCase {
    private func controller(showPeerCountry: Bool) -> SettingsWindowController {
        SettingsWindowController(config: AppConfig(servers: [.localhost], refreshSeconds: 4,
                                                   showPeerCountry: showPeerCountry))
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView?, where match: @escaping (T) -> Bool) -> T? {
        guard let root else { return nil }
        if let v = root as? T, match(v) { return v }
        return root.subviews.lazy.compactMap { self.find(type, in: $0, where: match) }.first
    }

    func testCheckboxReflectsConfigAndDefaultsOff() throws {
        let title = "Show peer countries in the Peers tab"
        let off = try XCTUnwrap(find(NSButton.self, in: controller(showPeerCountry: false).window?.contentView) { $0.title == title })
        XCTAssertEqual(off.state, .off)
        let on = try XCTUnwrap(find(NSButton.self, in: controller(showPeerCountry: true).window?.contentView) { $0.title == title })
        XCTAssertEqual(on.state, .on)
        XCTAssertFalse(AppConfig(servers: [.localhost], refreshSeconds: 4).showPeerCountry)
    }

    func testAttributionHasClickableDBIPLinks() throws {
        let field = try XCTUnwrap(find(NSTextField.self, in: controller(showPeerCountry: false).window?.contentView) {
            $0.stringValue.hasPrefix("Country data:")
        })
        XCTAssertTrue(field.isSelectable)
        XCTAssertTrue(field.allowsEditingTextAttributes)
        var links: [String: String] = [:]
        let text = field.attributedStringValue
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let url = value as? URL { links[(text.string as NSString).substring(with: range)] = url.absoluteString }
        }
        XCTAssertEqual(links["DB-IP.com"], "https://db-ip.com")
        XCTAssertEqual(links["CC BY 4.0"], "https://creativecommons.org/licenses/by/4.0/")
        XCTAssertNotNil(links["IP to Country Lite"])
    }
}
