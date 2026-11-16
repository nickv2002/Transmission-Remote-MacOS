import AppKit
import Testing

/// An in-memory daemon for the Properties session: `torrent-set` writes into the
/// stored torrents unless `ignoreWrites` is set.
actor PropertiesService: TorrentPropertiesService {
    var snapshot: ServerOptionsSnapshot
    var torrents: [TorrentProperties]
    var writes: [(hashes: [String], arguments: [TorrentProperty: ServerOptionValue])] = []
    var ignoreWrites = false
    /// Applied to the stored torrents just before the next read (another client's edit).
    var remoteEdit: (@Sendable (inout [TorrentProperties]) -> Void)?

    init(rpcVersion: Int = 17, torrents: [TorrentProperties]) {
        snapshot = ServerOptionsSnapshot(version: "4.0.6", values: [.ratioEnabled: .bool(true), .ratio: .decimal(2),
                                                                   .idleEnabled: .bool(false), .idleMinutes: .int(30)],
                                         rpcVersion: rpcVersion)
        self.torrents = torrents
    }

    func configure(ignoreWrites: Bool = false, remoteEdit: (@Sendable (inout [TorrentProperties]) -> Void)? = nil) {
        self.ignoreWrites = ignoreWrites
        self.remoteEdit = remoteEdit
    }

    func fetchServerOptions() async throws -> ServerOptionsSnapshot { snapshot }
    func fetchTorrentProperties(hashes: [String]) async throws -> [TorrentProperties] {
        if let remoteEdit { remoteEdit(&torrents); self.remoteEdit = nil }
        return torrents.filter { hashes.contains($0.hashString) }
    }
    func setTorrentProperties(hashes: [String], arguments: [TorrentProperty: ServerOptionValue]) async throws {
        writes.append((hashes, arguments))
        guard !ignoreWrites else { return }
        for index in torrents.indices where hashes.contains(torrents[index].hashString) {
            for (key, value) in arguments {
                switch (key, value) {
                case (.downloadLimited, .bool(let b)): torrents[index].downloadLimited = b
                case (.downloadLimit, .int(let n)): torrents[index].downloadLimit = n
                case (.uploadLimited, .bool(let b)): torrents[index].uploadLimited = b
                case (.uploadLimit, .int(let n)): torrents[index].uploadLimit = n
                case (.honorsSessionLimits, .bool(let b)): torrents[index].honorsSessionLimits = b
                case (.seedRatioMode, .int(let n)): torrents[index].seedRatioMode = n
                case (.seedRatioLimit, .decimal(let d)): torrents[index].seedRatioLimit = d
                case (.seedIdleMode, .int(let n)): torrents[index].seedIdleMode = n
                case (.seedIdleLimit, .int(let n)): torrents[index].seedIdleLimit = n
                case (.peerLimit, .int(let n)): torrents[index].maxConnectedPeers = n
                // Mimic the daemon: it stores trackers in its own canonical form.
                case (.trackerList, .string(let s)): torrents[index].trackerList = s + "\n"
                default: break
                }
            }
        }
    }
}

enum PropertiesFixtures {
    static func torrent(_ hash: String, down: Int = 100, downLimited: Bool = false, ratioMode: Int = 0,
                        ratio: Double = 2, trackers: String = "udp://a.invalid:80/announce\n\nhttps://b.invalid/announce") -> TorrentProperties {
        TorrentProperties(hashString: hash, name: "Torrent \(hash)", downloadLimit: down, downloadLimited: downLimited,
                          uploadLimit: 50, uploadLimited: false, honorsSessionLimits: true, seedRatioMode: ratioMode,
                          seedRatioLimit: ratio, seedIdleMode: 0, seedIdleLimit: 30, maxConnectedPeers: 50,
                          trackerList: trackers)
    }
    static func editor(_ torrents: [TorrentProperties], idle: Bool = true, trackers: Bool = true) -> TorrentPropertiesEditor {
        TorrentPropertiesEditor(torrents, supportsSeedIdle: idle, supportsTrackerList: trackers)
    }
}

@Suite("Torrent properties editor")
struct TorrentPropertiesEditorTests {
    typealias F = PropertiesFixtures

    @Test func decodesTorrentGetFieldsIncludingPeerLimitReadKey() throws {
        let json = #"{"hashString":"abc","name":"Linux ISO","downloadLimit":250,"downloadLimited":true,"uploadLimit":10,"uploadLimited":false,"honorsSessionLimits":false,"seedRatioMode":1,"seedRatioLimit":1.5,"seedIdleMode":2,"seedIdleLimit":45,"maxConnectedPeers":80,"trackerList":"udp://t.invalid:80\n"}"#
        let t = try JSONDecoder().decode(TorrentProperties.self, from: Data(json.utf8))
        #expect(t.value(.downloadLimit) == .int(250))
        #expect(t.value(.honorsSessionLimits) == .bool(false))
        #expect(t.value(.seedRatioLimit) == .decimal(1.5))
        #expect(t.value(.peerLimit) == .int(80))
        #expect(t.value(.seedIdleMode) == .int(2))
        // An old daemon without the newer fields still decodes.
        let old = try JSONDecoder().decode(TorrentProperties.self, from: Data(#"{"hashString":"x","name":"n","downloadLimit":1}"#.utf8))
        #expect(old.trackerList == nil && old.seedIdleMode == nil)
        #expect(TorrentProperties.requestedFields.contains("maxConnectedPeers"))
        #expect(!TorrentProperties.requestedFields.contains("peer-limit"))
    }

    @Test func detectsMixedValuesAcrossTorrents() {
        let editor = F.editor([F.torrent("a", down: 100), F.torrent("b", down: 200, downLimited: false)])
        #expect(editor.baseline[.downloadLimit] == .mixed)
        #expect(editor.isMixed(.downloadLimit))
        #expect(editor.text(.downloadLimit) == "")
        #expect(editor.baseline[.downloadLimited] == .value(.bool(false)))
        #expect(!editor.isDirty)
    }

    @Test func patchContainsOnlyChangedKeys() throws {
        var editor = F.editor([F.torrent("a")])
        editor.set(.uploadLimited, text: "true")
        editor.set(.uploadLimit, text: "75")
        editor.set(.peerLimit, text: "50") // unchanged value
        editor.set(.seedRatioLimit, text: "2.0") // same number, different text
        #expect(try editor.patch() == [.uploadLimited: .bool(true), .uploadLimit: .int(75)])
    }

    @Test func tickingALimitWhileTheValueIsMixedSendsOnlyTheFlag() throws {
        var editor = F.editor([F.torrent("a", down: 100), F.torrent("b", down: 200)])
        editor.set(.downloadLimited, text: "true")
        #expect(try editor.patch() == [.downloadLimited: .bool(true)])
        // Typing then clearing a mixed field returns it to "unchanged".
        editor.set(.downloadLimit, text: "300")
        #expect(try editor.patch()[.downloadLimit] == .int(300))
        editor.set(.downloadLimit, text: "")
        #expect(try editor.patch() == [.downloadLimited: .bool(true)])
    }

    @Test func choosingStopAtRatioWhileTheRatioIsMixedSendsOnlyTheMode() throws {
        var editor = F.editor([F.torrent("a", ratio: 1), F.torrent("b", ratio: 3)])
        editor.set(.seedRatioMode, text: String(SeedRatioMode.single.rawValue))
        #expect(try editor.patch() == [.seedRatioMode: .int(1)])
    }

    @Test func valueBehindAnOffCompanionIsNotSent() throws {
        var editor = F.editor([F.torrent("a")])
        editor.set(.downloadLimit, text: "999")
        #expect(!editor.isEditable(.downloadLimit))
        #expect(try editor.patch().isEmpty)
        editor.set(.downloadLimited, text: "true")
        #expect(try editor.patch() == [.downloadLimited: .bool(true), .downloadLimit: .int(999)])
    }

    @Test(arguments: [
        (TorrentProperty.uploadLimit, "-1"), (.uploadLimit, "2147483648"), (.uploadLimit, "fast"),
        (.seedRatioLimit, "1,000.5"), (.seedRatioLimit, "-2"), (.seedIdleLimit, "0"),
        (.peerLimit, "0"), (.peerLimit, "65536"), (.trackerList, "ftp://tracker.invalid/announce"),
    ])
    func rejectsInvalidInput(_ property: TorrentProperty, _ text: String) {
        var editor = F.editor([F.torrent("a", ratioMode: 1)])
        editor.set(.uploadLimited, text: "true")
        editor.set(.seedIdleMode, text: "1")
        editor.set(property, text: text)
        #expect(editor.validationError?.hasPrefix(property.title) == true)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test func emptyNonMixedFieldIsAValidationError() {
        var editor = F.editor([F.torrent("a")])
        editor.set(.peerLimit, text: "")
        #expect(editor.validationError != nil)
    }

    @Test func trackerTextNormalizesForComparisonAndSending() throws {
        #expect(TrackerListText.tiers("  udp://a.invalid:80 \r\n\n\n\nhttps://b.invalid\n\n") == [["udp://a.invalid:80"], ["https://b.invalid"]])
        #expect(TrackerListText.normalized("a\n\n\n b \nc\n") == "a\n\nb\nc")
        // Duplicates collapse for comparison (first occurrence wins) …
        #expect(TrackerListText.tiers("a\nb\n\na\nc") == [["a", "b"], ["c"]])
        #expect(TrackerListText.duplicate(in: "a\n\n a ") == "a")
        var editor = F.editor([F.torrent("a")])
        // Extra blank lines and trailing spaces only: not a change.
        editor.set(.trackerList, text: "udp://a.invalid:80/announce  \n\n\n\nhttps://b.invalid/announce\n")
        #expect(!editor.isDirty)
        editor.set(.trackerList, text: "udp://a.invalid:80/announce\nhttps://c.invalid/announce\n\n\nhttps://b.invalid/announce")
        #expect(try editor.patch() == [.trackerList: .string("udp://a.invalid:80/announce\nhttps://c.invalid/announce\n\nhttps://b.invalid/announce")])
    }

    @Test func duplicateTrackerIsRejectedWithAClearMessage() {
        var editor = F.editor([F.torrent("a")])
        editor.set(.trackerList, text: "https://c.invalid/announce\n\nhttps://c.invalid/announce")
        #expect(editor.validationError?.contains("https://c.invalid/announce is listed more than once") == true)
        #expect(editor.invalidProperty == .trackerList)
    }

    @Test func trackersAreEditableOnlyForOneTorrentOnRPC17() {
        #expect(F.editor([F.torrent("a")]).supports(.trackerList))
        let several = F.editor([F.torrent("a"), F.torrent("b")])
        #expect(!several.supports(.trackerList))
        #expect(several.trackersUnavailableReason?.contains("one torrent") == true)
        let old = F.editor([F.torrent("a")], trackers: false)
        #expect(!old.supports(.trackerList))
        #expect(old.trackersUnavailableReason?.contains("4.0") == true)
        var blocked = several
        blocked.set(.trackerList, text: "https://x.invalid/announce")
        #expect(!blocked.isDirty)
    }

    @Test func seedIdleIsOfferedOnlyFromRPC10() {
        let snapshot = ServerOptionsSnapshot(version: "2.0", values: [:], rpcVersion: 9)
        #expect(!snapshot.supportsSeedIdle && !snapshot.supportsTrackerList)
        let editor = F.editor([F.torrent("a")], idle: snapshot.supportsSeedIdle, trackers: snapshot.supportsTrackerList)
        #expect(!editor.supports(.seedIdleMode) && !editor.supports(.seedIdleLimit))
        #expect(ServerOptionsSnapshot(version: "2.1", values: [:], rpcVersion: 10).supportsSeedIdle)
    }

    @Test func serverDefaultLabelsShowTheSessionValues() {
        let on = ServerSeedDefaults(ServerOptionsSnapshot(version: "4", values: [.ratioEnabled: .bool(true), .ratio: .decimal(2.5),
                                                                                  .idleEnabled: .bool(true), .idleMinutes: .int(30)]))
        #expect(on.ratioTitle == "Server default (2.5)")
        #expect(on.idleTitle == "Server default (30 min)")
        let off = ServerSeedDefaults(ServerOptionsSnapshot(version: "4", values: [.ratioEnabled: .bool(false), .idleEnabled: .bool(false)]))
        #expect(off.ratioTitle == "Server default (no limit)")
        #expect(ServerSeedDefaults().idleTitle == "Server default")
    }

    @Test func serverDefaultTrackersKeepTheirExactValidationAndOutput() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        // Unchanged rule: a whole-text trim, but a space inside a line is still rejected.
        editor.set(.defaultTrackers, text: " udp://a.invalid:80/announce\n\n\n https://b.invalid/announce")
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
        editor.set(.defaultTrackers, text: " udp://a.invalid:80/announce\n\n\nhttps://b.invalid/announce\n")
        #expect(try editor.patch()[.defaultTrackers] == .string("udp://a.invalid:80/announce\n\n\nhttps://b.invalid/announce"))
    }
}

@Suite("Torrent properties session", .serialized)
@MainActor
struct TorrentPropertiesSessionTests {
    typealias F = PropertiesFixtures

    @Test func appliesOnlyChangesByCapturedHashesAndVerifies() async throws {
        let service = PropertiesService(torrents: [F.torrent("a", down: 100), F.torrent("b", down: 200), F.torrent("c")])
        let session = TorrentPropertiesSession(service: service, hashes: ["a", "b"])
        try await session.load()
        #expect(session.defaults.ratioTitle == "Server default (2)")
        session.set(.downloadLimited, text: "true")
        session.set(.peerLimit, text: "120")
        try await session.apply()
        let writes = await service.writes
        #expect(writes.count == 1)
        #expect(writes.first?.hashes == ["a", "b"])
        #expect(writes.first?.arguments == [.downloadLimited: .bool(true), .peerLimit: .int(120)])
        #expect(session.editor?.baseline[.downloadLimited] == .value(.bool(true)))
        #expect(session.editor?.baseline[.downloadLimit] == .mixed)
        #expect(!session.needsReload)
    }

    @Test func trackerReadbackComparesNormalizedText() async throws {
        let service = PropertiesService(torrents: [F.torrent("a")])
        let session = TorrentPropertiesSession(service: service, hashes: ["a"])
        try await session.load()
        session.set(.trackerList, text: "https://new.invalid/announce")
        try await session.apply()
        #expect(await service.torrents[0].trackerList == "https://new.invalid/announce\n")
        #expect(!session.needsReload)
    }

    @Test func remoteChangeToAnEditedKeyBlocksApply() async throws {
        let service = PropertiesService(torrents: [F.torrent("a")])
        let session = TorrentPropertiesSession(service: service, hashes: ["a"])
        try await session.load()
        session.set(.downloadLimited, text: "true")
        // Another client changes the limit this flag would switch on.
        await service.configure(remoteEdit: { $0[0].downloadLimit = 5 })
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.isEmpty)
        #expect(!session.needsReload)
    }

    @Test func removedTorrentBlocksApply() async throws {
        let service = PropertiesService(torrents: [F.torrent("a"), F.torrent("b")])
        let session = TorrentPropertiesSession(service: service, hashes: ["a", "b"])
        try await session.load()
        session.set(.honorsSessionLimits, text: "false")
        await service.configure(remoteEdit: { $0.removeLast() })
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.isEmpty)
    }

    @Test func unretainedWriteRequiresReopening() async throws {
        let service = PropertiesService(torrents: [F.torrent("a")])
        await service.configure(ignoreWrites: true)
        let session = TorrentPropertiesSession(service: service, hashes: ["a"])
        try await session.load()
        session.set(.uploadLimited, text: "true")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(session.needsReload)
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.count == 1)
    }

    @Test func missingTorrentFailsLoad() async {
        let service = PropertiesService(torrents: [F.torrent("a")])
        let session = TorrentPropertiesSession(service: service, hashes: ["a", "gone"])
        await #expect(throws: ServerOptionsError.self) { try await session.load() }
        #expect(session.editor == nil)
    }
}

@Suite("Torrent properties pane", .serialized)
@MainActor
struct TorrentPropertiesPaneTests {
    typealias F = PropertiesFixtures

    private func target(_ service: PropertiesService, _ hashes: [String]) -> TorrentPropertiesPane.Target {
        .init(service: service, hashes: hashes, serverID: nil)
    }

    private func loaded(_ torrents: [TorrentProperties], hashes: [String], rpc: Int = 17,
                        ignoreWrites: Bool = false) async -> (TorrentPropertiesPane, PropertiesService) {
        let service = PropertiesService(rpcVersion: rpc, torrents: torrents)
        if ignoreWrites { await service.configure(ignoreWrites: true) }
        let pane = TorrentPropertiesPane()
        host(pane)
        pane.retarget(target(service, hashes))
        try? await settle(pane)
        return (pane, service)
    }

    /// Controls only react to `performClick` inside a window; this one is never shown.
    private static var hosts: [NSWindow] = []
    private func host(_ pane: TorrentPropertiesPane) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        Self.hosts.append(window)
    }

    /// Waits for the load a retarget started.
    private func settle(_ pane: TorrentPropertiesPane) async throws {
        for _ in 0..<200 where pane.working { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func showsNothingUntilATorrentIsSelectedAndHasNoKeyEquivalents() async throws {
        let empty = TorrentPropertiesPane()
        #expect(empty.header.stringValue == "No torrent selected")
        #expect(empty.checkboxes.values.allSatisfy { !$0.isEnabled })
        #expect(!empty.applyButton.isEnabled && !empty.revertButton.isEnabled)
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        #expect(w.header.stringValue == "Torrent a")
        #expect(w.applyButton.keyEquivalent.isEmpty && w.revertButton.keyEquivalent.isEmpty)
        let (several, _) = await loaded([F.torrent("a"), F.torrent("b")], hashes: ["a", "b"])
        #expect(several.header.stringValue == "2 torrents")
    }

    @Test func mixedCheckboxBecomesTwoStateAfterTheFirstClickAndSendsOnlyTheFlag() async throws {
        let (w, service) = await loaded([F.torrent("a", down: 100, downLimited: false),
                                         F.torrent("b", down: 200, downLimited: true)], hashes: ["a", "b"])
        let box = try #require(w.checkboxes[.downloadLimited])
        #expect(box.allowsMixedState && box.state == .mixed)
        let field = try #require(w.fields[.downloadLimit])
        #expect(field.stringValue.isEmpty && field.placeholderString == "Mixed")
        #expect(!w.applyButton.isEnabled && !w.revertButton.isEnabled)
        box.performClick(nil)
        #expect(!box.allowsMixedState && box.state == .on)
        #expect(w.applyButton.isEnabled && w.revertButton.isEnabled)
        box.performClick(nil)
        #expect(box.state == .off)
        box.performClick(nil)
        #expect(await w.applyNow())
        let writes = await service.writes
        #expect(writes.first?.arguments == [.downloadLimited: .bool(true)])
        #expect(await service.torrents.map(\.downloadLimit) == [100, 200])
    }

    @Test func multipleSelectionEditsEverythingExceptTrackers() async throws {
        let (w, service) = await loaded([F.torrent("a"), F.torrent("b")], hashes: ["a", "b"])
        for property in [TorrentProperty.downloadLimited, .uploadLimited, .honorsSessionLimits] {
            #expect(w.checkboxes[property]?.isEnabled == true)
        }
        #expect(w.fields[.peerLimit]?.isEnabled == true)
        #expect(w.popups[.seedRatioMode]?.isEnabled == true)
        #expect(!w.trackers.isEnabled)
        #expect(!w.trackersReason.isHidden)
        #expect(w.trackersReason.stringValue == "Trackers can be edited for one torrent at a time.")
        let peers = try #require(w.fields[.peerLimit])
        peers.stringValue = "75"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: peers)
        #expect(await w.applyNow())
        let writes = await service.writes
        #expect(writes.first?.hashes == ["a", "b"])
        #expect(writes.first?.arguments == [.peerLimit: .int(75)])
    }

    @Test func singleSelectionKeepsTrackersEditable() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        #expect(w.trackers.isEnabled && w.trackersReason.isHidden)
    }

    @Test func applyKeepsTheTargetAndRebaselinesFromTheReadback() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        var applied = 0
        w.onApplied = { applied += 1 }
        w.checkboxes[.honorsSessionLimits]?.performClick(nil)
        #expect(await w.applyNow())
        #expect(applied == 1)
        #expect(w.target?.hashes == ["a"])
        #expect(w.session?.editor?.baseline[.honorsSessionLimits] == .value(.bool(false)))
        #expect(w.session?.editor?.isDirty == false)
        #expect(!w.applyButton.isEnabled && !w.revertButton.isEnabled)
        #expect(w.status.stringValue == "Applied and verified.")
        #expect(w.checkboxes[.honorsSessionLimits]?.state == .off)
    }

    @Test func revertDiscardsEditsAndRefetches() async throws {
        let (w, service) = await loaded([F.torrent("a")], hashes: ["a"])
        let peers = try #require(w.fields[.peerLimit])
        peers.stringValue = "99"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: peers)
        #expect(w.session?.editor?.isDirty == true)
        await service.configure(remoteEdit: { $0[0].maxConnectedPeers = 77 })
        await w.revertNow()
        #expect(w.session?.editor?.isDirty == false)
        #expect(peers.stringValue == "77")
        #expect(await service.writes.isEmpty)
    }

    @Test func mixedPopupItemIsRemovedOncePicked() async throws {
        let (w, _) = await loaded([F.torrent("a", ratioMode: 0), F.torrent("b", ratioMode: 2)], hashes: ["a", "b"])
        let popup = try #require(w.popups[.seedRatioMode])
        #expect(popup.titleOfSelectedItem == "Mixed")
        #expect(popup.selectedItem?.isEnabled == false)
        #expect(popup.itemTitles.first == "Server default (2)")
        popup.selectItem(at: 1)
        _ = popup.target?.perform(popup.action, with: popup)
        #expect(!popup.itemTitles.contains("Mixed"))
        #expect(try w.session?.editor?.patch() == [.seedRatioMode: .int(1)])
    }

    @Test func peersAndTrackersAreAlwaysVisibleSections() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        let peers = try #require(w.fields[.peerLimit])
        #expect(!peers.isHiddenOrHasHiddenAncestor && peers.stringValue == "50")
        #expect(!w.trackers.isHiddenOrHasHiddenAncestor && w.trackers.isEnabled)
        #expect(w.trackers.stringValue.contains("https://b.invalid/announce"))
        #expect(w.trackersReason.isHidden)
        for control in [w.fields[.downloadLimit], w.fields[.peerLimit], w.popups[.seedIdleMode]] {
            #expect(control?.accessibilityLabel()?.isEmpty == false)
        }
        #expect(w.trackers.textView.accessibilityLabel()?.contains("Trackers") == true)
    }

    @Test func buttonsStayInsideThePaneAndTheContentScrolls() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        let view = w.view
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.contains(w.applyButton.convert(w.applyButton.bounds, to: view)))
        #expect(view.bounds.contains(w.revertButton.convert(w.revertButton.bounds, to: view)))
        #expect(view.subviews.contains { $0 is NSScrollView })
        if let dir = ProcessInfo.processInfo.environment["PROPERTIES_RENDER_DIR"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.appearance = NSAppearance(named: .aqua)
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/pane.png"))
        }
    }

    @Test func paneIsFlexibleInWidthAndUsesTheContentBackground() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        // As the tab view places it: a frame-sized subview of a container.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        w.view.removeFromSuperview()
        container.addSubview(w.view)
        w.view.frame = container.bounds
        container.layoutSubtreeIfNeeded()
        let scroll0 = try #require(w.view.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(w.view.frame.width == 300 && scroll0.frame.width == 300,
                "the content's fixed-width controls must not widen the pane")
        w.view.frame.size.width = 900
        container.layoutSubtreeIfNeeded()
        #expect(scroll0.frame.width == 900)
        let scroll = try #require(w.view.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.drawsBackground && scroll.backgroundColor == .controlBackgroundColor)
        #expect(w.view.wantsUpdateLayer)
    }

    @Test func oldServerHidesIdleAndDisablesTrackers() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"], rpc: 9)
        #expect(w.popups[.seedIdleMode]?.isEnabled == false)
        #expect(w.popups[.seedIdleMode]?.superview?.isHidden == true)
        #expect(!w.trackers.isEnabled)
        #expect(!w.trackersReason.isHidden)
    }

    @Test func sameSelectionIsANoOpAndANewOneRetargets() async throws {
        let (w, service) = await loaded([F.torrent("a", down: 100), F.torrent("b", down: 200)], hashes: ["a"])
        let session = w.session
        w.retarget(target(service, ["a"]))
        #expect(w.session === session)
        w.retarget(target(service, ["b"]))
        try await settle(w)
        #expect(w.session !== session)
        #expect(w.header.stringValue == "Torrent b")
        #expect(w.fields[.downloadLimit]?.stringValue == "200")
        w.retarget(nil)
        #expect(w.header.stringValue == "No torrent selected")
        #expect(w.checkboxes.values.allSatisfy { !$0.isEnabled })
    }

    @Test func retargetingWithEditsAsksAndKeepEditingReselectsTheOldRows() async throws {
        let (w, service) = await loaded([F.torrent("a"), F.torrent("b")], hashes: ["a"])
        var asked: [Bool] = []
        var kept: [[String]] = []
        w.onKeepEditing = { kept.append($0) }
        w.confirmClose = { quitting, done in asked.append(quitting); done(.keepEditing) }
        w.checkboxes[.honorsSessionLimits]?.performClick(nil)
        w.retarget(target(service, ["b"]))
        #expect(asked == [false] && kept == [["a"]])
        #expect(w.target?.hashes == ["a"] && w.session?.editor?.isDirty == true)
        w.confirmClose = { _, done in done(.discard) }
        w.retarget(target(service, ["b"]))
        try await settle(w)
        #expect(w.target?.hashes == ["b"] && w.session?.editor?.isDirty != true)
        #expect(await service.writes.isEmpty)
    }

    @Test func retargetingWithEditsCanApplyFirst() async throws {
        let (w, service) = await loaded([F.torrent("a"), F.torrent("b")], hashes: ["a"])
        w.confirmClose = { _, done in done(.apply) }
        w.checkboxes[.honorsSessionLimits]?.performClick(nil)
        w.retarget(target(service, ["b"]))
        for _ in 0..<200 where w.target?.hashes != ["b"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(w.target?.hashes == ["b"])
        let writes = await service.writes
        #expect(writes.count == 1 && writes.first?.hashes == ["a"])
    }

    @Test func failedApplyWhileRetargetingKeepsTheOldRows() async throws {
        let (w, service) = await loaded([F.torrent("a"), F.torrent("b")], hashes: ["a"], ignoreWrites: true)
        var kept: [[String]] = []
        w.onKeepEditing = { kept.append($0) }
        w.confirmClose = { _, done in done(.apply) }
        w.checkboxes[.uploadLimited]?.performClick(nil)
        w.retarget(target(service, ["b"]))
        for _ in 0..<200 where kept.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kept == [["a"]])
        #expect(w.target?.hashes == ["a"])
    }

    @Test func retargetingDuringLoadNeverRendersTheStaleTorrent() async throws {
        let service = PropertiesService(torrents: [F.torrent("a", down: 100), F.torrent("b", down: 200)])
        let w = TorrentPropertiesPane()
        host(w)
        w.retarget(target(service, ["a"]))
        #expect(w.loading)
        w.retarget(target(service, ["b"]))
        try await settle(w)
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.header.stringValue == "Torrent b")
        #expect(w.fields[.downloadLimit]?.stringValue == "200")
    }

    @Test func resetDropsEditsWithoutAsking() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        var asked = 0
        w.confirmClose = { _, done in asked += 1; done(.keepEditing) }
        w.checkboxes[.honorsSessionLimits]?.performClick(nil)
        w.reset()
        #expect(asked == 0 && w.target == nil && !w.hasUnsavedEdits)
    }

    @Test func failedLoadSaysSoAndRevertRetries() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["missing"])
        #expect(w.header.stringValue == "Couldn’t load properties")
        #expect(w.status.textColor == .systemRed)
        #expect(w.revertButton.isEnabled && !w.applyButton.isEnabled)
    }

    @Test(arguments: [TorrentPropertiesPane.CloseChoice.apply, .discard, .keepEditing])
    func quittingWithEditsAsksFirst(_ choice: TorrentPropertiesPane.CloseChoice) async throws {
        let (w, service) = await loaded([F.torrent("a")], hashes: ["a"])
        var asked: [Bool] = []
        w.confirmClose = { quitting, done in asked.append(quitting); done(choice) }
        // Nothing edited: quit straight away without asking.
        var replies: [Bool] = []
        w.confirmQuit { replies.append($0) }
        #expect(replies == [true] && asked.isEmpty)
        w.checkboxes[.honorsSessionLimits]?.performClick(nil)
        let reply: Bool = await withCheckedContinuation { continuation in
            w.confirmQuit { continuation.resume(returning: $0) }
        }
        #expect(asked == [true])
        #expect(reply == (choice != .keepEditing))
        #expect(await service.writes.count == (choice == .apply ? 1 : 0))
    }

    @Test func unverifiedApplyDoesNotAskWhenRetargeting() async throws {
        let (w, service) = await loaded([F.torrent("a"), F.torrent("b")], hashes: ["a"], ignoreWrites: true)
        var asked = 0
        w.confirmClose = { _, done in asked += 1; done(.keepEditing) }
        w.checkboxes[.uploadLimited]?.performClick(nil)
        #expect(await !w.applyNow())
        #expect(w.session?.needsReload == true)
        #expect(w.revertButton.isEnabled)
        w.retarget(target(service, ["b"]))
        #expect(asked == 0 && w.target?.hashes == ["b"])
    }

    @Test func invalidEntryDisablesApply() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"])
        let peers = try #require(w.fields[.peerLimit])
        peers.stringValue = "0"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: peers)
        #expect(!w.applyButton.isEnabled)
        #expect(w.status.stringValue.hasPrefix("Peer limit"))
        peers.stringValue = "60"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: peers)
        #expect(w.applyButton.isEnabled)
        #expect(w.status.stringValue.isEmpty)
    }

    @Test func valueFieldBehindServerDefaultShowsTheServerValueNotAStaleOne() async throws {
        let (w, _) = await loaded([F.torrent("a", ratioMode: 0, ratio: 5)], hashes: ["a"])
        let ratio = try #require(w.fields[.seedRatioLimit])
        #expect(ratio.stringValue.isEmpty && ratio.placeholderString == "2")
        let popup = try #require(w.popups[.seedRatioMode])
        popup.selectItem(at: 1)
        _ = popup.target?.perform(popup.action, with: popup)
        #expect(ratio.stringValue == "5" && ratio.isEnabled)
        popup.selectItem(at: 2)
        _ = popup.target?.perform(popup.action, with: popup)
        #expect(ratio.stringValue.isEmpty && ratio.placeholderString == nil)
    }

    @Test func longStatusWrapsInsideThePane() async throws {
        let (w, _) = await loaded([F.torrent("a")], hashes: ["a"], ignoreWrites: true)
        w.checkboxes[.uploadLimited]?.performClick(nil)
        _ = await w.applyNow()
        #expect(w.status.stringValue.contains("could not be fully verified"))
        let view = w.view
        view.layoutSubtreeIfNeeded()
        let frame = w.status.convert(w.status.bounds, to: view)
        #expect(view.bounds.contains(frame))
        #expect(frame.height > 20, "the long message wraps onto several lines")
        #expect(!frame.intersects(w.revertButton.convert(w.revertButton.bounds, to: view)))
    }
}

@Suite("Torrent properties tab", .serialized)
@MainActor
struct TorrentPropertiesTabTests {
    typealias F = PropertiesFixtures

    private func selectTab(_ c: MainWindowController, _ id: String) throws {
        let item = try #require(c.detailTabView.tabViewItems.first { ($0.identifier as? String) == id })
        c.detailTabView.selectTabViewItem(item)
    }

    @Test func propertiesIsADetailTabHostingThePane() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let item = try #require(c.detailTabView.tabViewItems.first { ($0.identifier as? String) == "properties" })
        #expect(item.label == "Properties")
        #expect(item.view === c.propertiesPane.view)
        #expect(c.propertiesPane.header.stringValue == "No torrent selected")
    }

    @Test func contextMenuHasNoPropertiesItemBecauseItIsATab() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        #expect(!c.rowContextMenu().items.contains { $0.title == "Properties…" })
        // Sanity: an action that needs only a selection is enabled.
        c.refresh.onTorrents?([TorrentFactory.make()])
        c.tableView.selectRowIndexes([0], byExtendingSelection: false)
        let verify = try #require(c.rowContextMenu().items.first { $0.title == "Verify" })
        #expect(c.validateMenuItem(verify))
    }

    @Test func theTabFollowsTheSelection() async throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let service = PropertiesService(torrents: [F.torrent("a"), F.torrent("b")])
        let pane = c.propertiesPane
        // Another tab showing and nothing targeted: selection alone loads nothing.
        try selectTab(c, "info")
        pane.retarget(.init(service: service, hashes: ["a"], serverID: c.refresh.activeServerConfig.id))
        #expect(pane.target?.hashes == ["a"])
        // Selection moves on while another tab shows: the stale target is dropped.
        c.loadPropertiesIfNeeded()
        #expect(pane.target == nil)
        try selectTab(c, "properties")
        #expect(c.detailTabView.selectedTabViewItem?.identifier as? String == "properties")
    }

    @Test func showingTheTabDoesNotResizeAnyPane() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let window = try #require(c.window)
        func splits(_ view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
        }
        func widths() -> [[CGFloat]] {
            splits(window.contentView!).map { $0.arrangedSubviews.map { $0.frame.width } }
        }
        window.setContentSize(NSSize(width: 1600, height: 900))
        try selectTab(c, "peers")
        window.layoutIfNeeded()
        if let outer = splits(window.contentView!).first { outer.setPosition(345, ofDividerAt: 0) }
        window.layoutIfNeeded()
        let before = widths()
        let size = window.frame.size
        try selectTab(c, "properties")
        window.layoutIfNeeded()
        #expect(window.frame.size == size)
        #expect(widths() == before)
        #expect(c.propertiesPane.view.frame.width == c.detailTabView.contentRect.width)
    }

    @Test func serverChangeDropsATargetOpenedOnAnotherServer() async throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let service = PropertiesService(torrents: [F.torrent("a")])
        c.propertiesPane.retarget(.init(service: service, hashes: ["a"], serverID: UUID()))
        c.resetPropertiesForInactiveServer()
        #expect(c.propertiesPane.target == nil)
    }
}
