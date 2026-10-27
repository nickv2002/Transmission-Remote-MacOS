import XCTest

final class SpeedLimitTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionInfo {
        try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
    }

    private let server = ServerConfig(name: "S", host: "h", port: 9091, useHTTPS: false, rpcPath: "/r",
                                      downSpeedPresets: [100, 500], upSpeedPresets: [50])

    // MARK: SessionInfo

    func testSessionDecodesSpeedFields() throws {
        let s = try decode("""
        {"version":"4.1.2","speed-limit-down":500,"speed-limit-down-enabled":true,
         "speed-limit-up":50,"speed-limit-up-enabled":false,
         "alt-speed-enabled":true,"alt-speed-down":80,"alt-speed-up":20,
         "units":{"speed-bytes":1000}}
        """)
        XCTAssertEqual(s.normalLimits, SpeedLimits(down: 500, up: nil))
        XCTAssertEqual(s.turtleLimits, SpeedLimits(down: 80, up: 20))
        XCTAssertTrue(s.isTurtleOn)
        XCTAssertEqual(s.effectiveLimits, SpeedLimits(down: 80, up: 20))
        XCTAssertEqual(s.speedBytes, 1000)
    }

    func testSessionToleratesMissingSpeedFields() throws {
        let s = try decode(#"{"version":"2.9"}"#)
        XCTAssertEqual(s.normalLimits, SpeedLimits(down: nil, up: nil))
        XCTAssertFalse(s.isTurtleOn)
    }

    func testSessionRoundTrips() throws {
        let s = SessionInfo(version: "4", speedLimitDown: 5, speedLimitDownEnabled: true, altSpeedEnabled: false, speedBytes: 1000)
        let back = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.speedLimitDown, 5)
        XCTAssertEqual(back.speedBytes, 1000)
    }

    // MARK: session-set arguments

    func testSetLimitLeavesTurtleAndEnables() {
        let a = TransmissionClient.speedLimitArguments(.down, kbps: 250)
        XCTAssertEqual(a["speed-limit-down"] as? Int, 250)
        XCTAssertEqual(a["speed-limit-down-enabled"] as? Bool, true)
        XCTAssertEqual(a["alt-speed-enabled"] as? Bool, false)
    }

    func testClearLimitDisablesWithoutValue() {
        let a = TransmissionClient.speedLimitArguments(.up, kbps: nil)
        XCTAssertEqual(a["speed-limit-up-enabled"] as? Bool, false)
        XCTAssertNil(a["speed-limit-up"])
    }

    // MARK: Presets

    func testPresetParseSortsDedupesAndDropsJunk() {
        XCTAssertEqual(SpeedPresets.parse("500, 100 abc 0 -5\n100,250"), [100, 250, 500])
        XCTAssertEqual(SpeedPresets.format([100, 250]), "100, 250")
    }

    func testOffListCurrentValueIsAdded() {
        XCTAssertEqual(SpeedPresets.menuValues(presets: [100, 500], current: 300), [100, 300, 500])
        XCTAssertEqual(SpeedPresets.menuValues(presets: [100, 500], current: 500), [100, 500])
        XCTAssertEqual(SpeedPresets.menuValues(presets: [100], current: nil), [100])
    }

    func testLabelsUseDecimalScale() {
        XCTAssertEqual(SpeedPresets.label(kbps: 500), "500 KB/s")
        XCTAssertEqual(SpeedPresets.label(kbps: 1000), "1 MB/s")
        XCTAssertEqual(SpeedPresets.label(kbps: 2500), "2.5 MB/s")
    }

    func testServerConfigPresetDefaultsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"host":"h"}"#.utf8))
        XCTAssertEqual(old.downSpeedPresets, SpeedPresets.defaults)
        let back = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(server))
        XCTAssertEqual(back.downSpeedPresets, [100, 500])
        XCTAssertEqual(back.upSpeedPresets, [50])
    }

    // MARK: Menu model

    func testMenuChecksUnlimitedWhenNoLimit() {
        let g = SpeedMenuModel.groups(session: SessionInfo(version: "4"), server: server)
        let down = g[0].entries
        XCTAssertEqual(down.map(\.title), ["Unlimited", "100 KB/s", "500 KB/s"])
        XCTAssertEqual(down.map(\.checked), [true, false, false])
    }

    func testMenuChecksCurrentAndOffListLimit() {
        let s = SessionInfo(version: "4", speedLimitDown: 300, speedLimitDownEnabled: true)
        let down = SpeedMenuModel.groups(session: s, server: server)[0].entries
        XCTAssertEqual(down.map(\.title), ["Unlimited", "100 KB/s", "300 KB/s", "500 KB/s"])
        XCTAssertEqual(down.map(\.checked), [false, false, true, false])
    }

    func testDisabledLimitWithStoredValueChecksUnlimited() {
        let s = SessionInfo(version: "4", speedLimitDown: 500, speedLimitDownEnabled: false)
        XCTAssertTrue(SpeedMenuModel.groups(session: s, server: server)[0].entries[0].checked)
    }

    func testTurtleOnUnchecksRegularAndChecksToggle() {
        let s = SessionInfo(version: "4", speedLimitDown: 500, speedLimitDownEnabled: true,
                            altSpeedEnabled: true, altSpeedDown: 100, altSpeedUp: 50)
        let g = SpeedMenuModel.groups(session: s, server: server)
        XCTAssertFalse(g[0].entries.contains { $0.checked })
        XCTAssertTrue(g[2].entries[0].checked)
        XCTAssertEqual(g[2].entries[0].action, .setTurtleEnabled(false))
        XCTAssertEqual(g[2].title, "Turtle Mode (↓ 100 KB/s  ↑ 50 KB/s)")
        XCTAssertEqual(g[3].entries.first { $0.checked }?.action, .setTurtleLimit(.down, 100))
    }

    func testStatusSuffix() {
        let limited = SessionInfo(version: "4", speedLimitDown: 500, speedLimitDownEnabled: true)
        XCTAssertEqual(SpeedMenuModel.statusSuffix(session: limited, direction: .down), " (500 KB/s)")
        XCTAssertEqual(SpeedMenuModel.statusSuffix(session: limited, direction: .up), "")
        XCTAssertEqual(SpeedMenuModel.statusSuffix(session: nil, direction: .down), "")
        let turtle = SessionInfo(version: "4", altSpeedEnabled: true, altSpeedDown: 50, altSpeedUp: 20)
        XCTAssertEqual(SpeedMenuModel.statusSuffix(session: turtle, direction: .up), " (🐢 20 KB/s)")
    }

    // MARK: Rate history

    func testRateHistoryCapsAndClears() {
        var h = RateHistory(capacity: 3)
        for i in 1...5 { h.append(down: Int64(i), up: Int64(i * 10)) }
        XCTAssertEqual(h.down, [3, 4, 5])
        XCTAssertEqual(h.up, [30, 40, 50])
        h.removeAll()
        XCTAssertEqual(h.count, 0)
    }

    // MARK: Upgrade safety

    func testLoadingPreSpeedLimitPreferencesOnlyAddsServerIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preferences.json")
        let original = Data(#"{"servers":[{"name":"N5","host":"10.0.1.2","port":9091,"useHTTPS":false,"rpcPath":"/transmission/rpc","username":"u","password":"p","pathMappings":[]}],"currentServer":"N5","refreshSeconds":4}"#.utf8)
        try original.write(to: url)

        let config = try PreferencesStore.load(storeURL: url, legacyURL: nil)

        // The one permitted rewrite: minted server ids are added, nothing else changes.
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
            .mutableCopy() as! NSMutableDictionary
        let servers = try XCTUnwrap(stored["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.first?["id"] as? String, config.servers.first?.id.uuidString)
        stored["servers"] = servers.map { $0.filter { $0.key != "id" } }
        XCTAssertEqual(stored, try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary),
                       "launch must not otherwise rewrite existing preferences")
        let reloaded = try PreferencesStore.load(storeURL: url, legacyURL: nil)
        XCTAssertEqual(reloaded.servers.first?.id, config.servers.first?.id)
        let s = try XCTUnwrap(config.servers.first)
        XCTAssertEqual([s.name, s.host, s.username, s.password], ["N5", "10.0.1.2", "u", "p"])
        XCTAssertEqual(config.currentServer, "N5")
        XCTAssertEqual(config.refreshSeconds, 4)
        XCTAssertEqual(s.downSpeedPresets, SpeedPresets.defaults)
    }
}
