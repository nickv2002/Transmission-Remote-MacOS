import AppKit
import Testing

actor FeatureService: ServerOptionsService {
    var snapshot = ServerOptionsFixtures.snapshot
    var groups = [BandwidthGroup(name: "Background", honorsSessionLimits: true, downEnabled: true, down: 500, upEnabled: false, up: 100)]
    var groupWrites: [[BandwidthGroup.Field: ServerOptionValue]] = []
    var portChoices: [PeerPortProtocol] = []
    var failWrites = false
    var ignoreGroupWrites = false
    var failGroupReadback = false
    func configure(fail: Bool = false, ignore: Bool = false, readback: Bool = false) {
        failWrites = fail; ignoreGroupWrites = ignore; failGroupReadback = readback
    }
    func replace(_ value: ServerOptionsSnapshot) { snapshot = value }
    func replaceGroups(_ value: [BandwidthGroup]) { groups = value }
    func fetchServerOptions() async throws -> ServerOptionsSnapshot { snapshot }
    func setServerOptions(_ changes: [ServerOption: ServerOptionValue]) async throws {
        for (key, value) in changes { snapshot.values[key] = value }
    }
    func testPeerPort() async throws -> Bool { false }
    func testPeerPort(protocol choice: PeerPortProtocol) async throws -> PeerPortResult {
        portChoices.append(choice)
        return PeerPortResult(isOpen: choice == .ipv4, ipProtocol: choice == .automatic ? nil : choice.rawValue)
    }

    func fetchBandwidthGroups() async throws -> [BandwidthGroup] {
        if failGroupReadback && !groupWrites.isEmpty { throw ServerOptionsError(message: "Offline") }
        return groups
    }
    func setBandwidthGroup(name: String, changes: [BandwidthGroup.Field: ServerOptionValue]) async throws {
        groupWrites.append(changes)
        if !ignoreGroupWrites {
            var value = groups.first { $0.name == name } ?? BandwidthGroup(name: name, honorsSessionLimits: true, downEnabled: false, down: 0, upEnabled: false, up: 0)
            for (key, field) in changes {
                switch (key, field) {
                case (.honors, .bool(let b)): value.honorsSessionLimits = b
                case (.downEnabled, .bool(let b)): value.downEnabled = b
                case (.upEnabled, .bool(let b)): value.upEnabled = b
                case (.down, .int(let n)): value.down = n
                case (.up, .int(let n)): value.up = n
                default: break
                }
            }
            groups.removeAll { $0.name == name }
            groups.append(value)
        }
        if failWrites { throw ServerOptionsError(message: "Lost response") }
    }
}

@Suite("Modern session settings")
struct ModernOptionsTests {
    @Test func trackersPreserveTiersAndAllowClearing() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.defaultTrackers, text: "udp://tracker.invalid:80/announce\n\nhttps://tracker.invalid/announce")
        #expect(try editor.patch()[.defaultTrackers] == .string("udp://tracker.invalid:80/announce\n\nhttps://tracker.invalid/announce"))
        editor.set(.defaultTrackers, text: "")
        #expect(try editor.patch()[.defaultTrackers] == .string(""))
    }
    @Test(arguments: ["file:///tmp/tracker", "http://", "https://tracker.invalid/a b", "https://tracker.invalid/\0", "ftp://tracker.invalid/a"])
    func rejectsInvalidTrackerLines(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.defaultTrackers, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }
    @Test func modernTransportsReplaceLegacyToggleWithoutSendingBoth() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        #expect(!editor.isEditable(.utp))
        editor.set(.utp, text: "false")
        editor.set(.transports, text: "tcp,utp")
        #expect(try editor.patch() == [.transports: .strings(["tcp", "utp"])])
    }
    @Test(arguments: ServerTransports.allCases)
    func transportChoicesEncodeOrderedArrays(_ choice: ServerTransports) throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.transports, text: choice.rawValue)
        #expect(try editor.parsed(.transports) == .strings(choice.protocols))
    }
    @Test func unknownFutureTransportIsPreservedUntilExplicitlyChanged() throws {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.transports] = .strings(["future", "tcp"])
        var editor = ServerOptionsEditor(snapshot)
        #expect(!editor.isDirty)
        editor.set(.up, text: "200")
        #expect(try editor.patch() == [.up: .int(200)])
    }
    @Test func enablingScriptRequiresPathAndPreservesWhitespace() throws {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.addedScriptEnabled] = .bool(false)
        snapshot.values[.addedScript] = .string("")
        var editor = ServerOptionsEditor(snapshot)
        editor.set(.addedScriptEnabled, text: "true")
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
        editor.set(.addedScript, text: "/scripts/added script ")
        #expect(try editor.patch()[.addedScript] == .string("/scripts/added script "))
    }
    @Test(arguments: ["0", "-1", "2147483648", "1.5", "oops"])
    func invalidBruteForceThresholdsFail(_ value: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.bruteForceThreshold, text: value)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }
    @Test func capabilitiesUseRPCVersionsNotProductVersionGuessing() {
        var snapshot = ServerOptionsSnapshot(version: "custom", values: [:])
        #expect(!snapshot.supportsGroups && !snapshot.supportsPortProtocol)
        snapshot.rpcVersion = 17
        #expect(snapshot.supportsGroups && !snapshot.supportsPortProtocol)
        snapshot.rpcVersion = nil
        snapshot.rpcSemver = "6.0.1"
        #expect(snapshot.supportsGroups && snapshot.supportsPortProtocol)
        snapshot.rpcSemver = "5.3.0"
        #expect(snapshot.supportsGroups && !snapshot.supportsPortProtocol)
    }
    @Test func missingPortProtocolIsReportedAsUnconfirmed() {
        #expect(PeerPortResult(isOpen: false, ipProtocol: nil).description(requested: .ipv6).contains("unconfirmed"))
    }
}

@Suite("Server feature operations", .serialized)
@MainActor
struct ServerFeatureOperationTests {
    @Test func protocolTestsAreCapabilityGatedAndDoNotSaveDrafts() async throws {
        let service = FeatureService()
        var old = ServerOptionsFixtures.snapshot
        old.rpcVersion = 16
        old.rpcSemver = nil
        await service.replace(old)
        let session = ServerOptionsSession(service: service)
        try await session.load()
        await #expect(throws: ServerOptionsError.self) { try await session.testPort(protocol: .ipv6) }
        #expect(await service.portChoices.isEmpty)
        var modern = ServerOptionsFixtures.snapshot
        modern.rpcVersion = 19
        await service.replace(modern)
        try await session.load()
        session.set(.peerPort, text: "54321")
        #expect(try await session.testPort(protocol: .ipv4).isOpen)
        #expect(try await !session.testPort(protocol: .ipv6).isOpen)
        #expect(session.editor?.text(.peerPort) == "54321")
        #expect(await service.snapshot.values[.peerPort] == modern.values[.peerPort])
    }
    @Test func groupSavesOnlyChangedFieldsAndVerifies() async throws {
        let service = FeatureService()
        let session = BandwidthGroupSession(service: service)
        try await session.load()
        session.editor.draft[.down] = "777"
        try await session.save()
        #expect(await service.groupWrites == [[.down: .int(777)]])
        #expect(!session.editor.isDirty && !session.needsReload)
        try await session.save()
        #expect(await service.groupWrites.count == 1)
    }
    @Test func groupDetectsConflictsAndPreservesUnrelatedChanges() async throws {
        let service = FeatureService()
        let session = BandwidthGroupSession(service: service)
        try await session.load()
        session.editor.draft[.down] = "777"
        var remote = try #require(await service.groups.first)
        remote.down = 888
        await service.replaceGroups([remote])
        await #expect(throws: ServerOptionsError.self) { try await session.save() }
        #expect(await service.groupWrites.isEmpty)
        remote.down = 500
        remote.up = 321
        await service.replaceGroups([remote])
        try await session.save()
        #expect(session.editor.baseline?.up == 321)
    }
    @Test(arguments: ["lost reply", "ignored write", "failed readback"])
    func uncertainGroupWritesRequireReload(_ mode: String) async throws {
        let service = FeatureService()
        let session = BandwidthGroupSession(service: service)
        try await session.load()
        session.editor.draft[.down] = "777"
        await service.configure(fail: mode == "lost reply", ignore: mode == "ignored write", readback: mode == "failed readback")
        await #expect(throws: (any Error).self) { try await session.save() }
        #expect(session.needsReload)
        await #expect(throws: ServerOptionsError.self) { try await session.save() }
        #expect(await service.groupWrites.count == 1)
    }
    @Test func newGroupRejectsDuplicateAndCanCreate() async throws {
        let service = FeatureService()
        let session = BandwidthGroupSession(service: service)
        try await session.load()
        session.select(nil)
        session.editor.name = "Background"
        await #expect(throws: ServerOptionsError.self) { try await session.save() }
        #expect(await service.groupWrites.isEmpty)
        session.editor.name = "New group"
        try await session.save()
        #expect(session.editor.baseline?.name == "New group")
        #expect(await service.groupWrites.first?.count == 5)
    }
    @Test func groupCannotActivateRemotelyChangedCompanionLimit() throws {
        let group = BandwidthGroup(name: "Slow", honorsSessionLimits: true, downEnabled: false, down: 100, upEnabled: false, up: 100)
        var editor = BandwidthGroupEditor(group)
        editor.draft[.downEnabled] = "true"
        var remote = group
        remote.down = 10000
        #expect(throws: ServerOptionsError.self) { try editor.checkedPatch(latest: remote) }
    }
    @Test func nativeGroupEditorShowsValuesAndDependenciesWithoutSaving() async throws {
        _ = NSApplication.shared
        let service = FeatureService()
        let controller = BandwidthGroupsWindowController(serverName: "Fixture", service: service)
        try await controller.session.load()
        controller.render()
        #expect(controller.nameField.stringValue == "Background")
        #expect(!controller.nameField.isEnabled)
        #expect(controller.controls[.down]?.isEnabled == true)
        #expect(controller.controls[.up]?.isEnabled == false)
        let toggle = try #require(controller.controls[.upEnabled] as? NSButton)
        toggle.performClick(nil)
        #expect(controller.controls[.up]?.isEnabled == true)
        #expect(controller.session.editor.isDirty)
        #expect(await service.groupWrites.isEmpty)
    }
}
