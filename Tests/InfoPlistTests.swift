import XCTest

/// Hermetic check on the app's ATS exception. The app talks to LAN/VPN daemons over
/// plain HTTP (CLAUDE.md "Hosts & ATS"). The test runner's ATS comes from the `xctest`
/// tool, not from this bundle, so the runner can't exercise `NSAllowsArbitraryLoads`.
/// This reads the app's `Info.plist` and asserts the key the app relies on is set.
final class InfoPlistTests: XCTestCase {
    func testAppAllowsArbitraryLoadsForLANDaemons() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let ats = plist?["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertEqual(ats?["NSAllowsArbitraryLoads"] as? Bool, true,
                       "without this, plain-HTTP daemons on named hosts (e.g. n5.local) fail ATS")
    }
}
