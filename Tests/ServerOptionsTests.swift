import Foundation
import Testing

enum ServerOptionsFixtures {
    static var snapshot: ServerOptionsSnapshot {
        var values: [ServerOption: ServerOptionValue] = [:]
        for field in ServerOption.definitions {
            switch field.kind {
            case .boolean: values[field.key] = .bool(true)
            case .integer: values[field.key] = .int(100)
            case .decimal: values[field.key] = .decimal(2)
            case .directory, .scriptPath: values[field.key] = .string("/downloads")
            case .trackers: values[field.key] = .string("https://tracker.invalid/announce")
            case .transports: values[field.key] = .strings(["utp", "tcp"])
            case .encryption: values[field.key] = .string("preferred")
            case .time: values[field.key] = .int(540)
            case .days: values[field.key] = .int(127)
            }
        }
        values[.randomPort] = .bool(false)
        return ServerOptionsSnapshot(version: "4.1.4", values: values, rpcVersion: 19, rpcSemver: "6.0.1")
    }

    static func json(_ snapshot: ServerOptionsSnapshot) throws -> Data {
        var object = Dictionary(uniqueKeysWithValues: snapshot.values.map { ($0.key.rawValue, $0.value.jsonValue) })
        object["version"] = snapshot.version
        object["rpc-version"] = snapshot.rpcVersion
        object["rpc-version-semver"] = snapshot.rpcSemver
        object["future-setting"] = ["arbitrary": true]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func alternative(_ key: ServerOption) -> String {
        switch key.definition.kind {
        case .boolean: return key == .randomPort ? "true" : "false"
        case .integer: return "123"
        case .decimal: return "3.5"
        case .directory, .scriptPath: return "/downloads/Films with spaces/é"
        case .trackers: return "udp://tracker.invalid:80/announce\n\nhttps://tracker2.invalid/announce"
        case .transports: return "tcp,utp"
        case .encryption: return "required"
        case .time: return "23:45"
        case .days: return "62"
        }
    }
}

@Suite("Server Options model")
struct ServerOptionsModelTests {
    @Test func schemaHasCurrentRPCParity() {
        #expect(ServerOption.allCases.count == 50)
        #expect(ServerOption.definitions.count == 50)
        #expect(Set(ServerOption.definitions.map(\.key)) == Set(ServerOption.allCases))
        #expect(ServerOption.Pane.allCases.map(\.rawValue) == ["Transfers", "Speed", "Network", "Advanced"])
    }

    @Test func decodesEveryFieldAndIgnoresUnknownFields() throws {
        let snapshot = ServerOptionsFixtures.snapshot
        let decoded = try JSONDecoder().decode(ServerOptionsSnapshot.self, from: ServerOptionsFixtures.json(snapshot))
        #expect(decoded == snapshot)
    }

    @Test(arguments: ServerOption.allCases)
    func eachSettingProducesOnlyItsIntendedWireChange(_ key: ServerOption) throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        if key == .utp {
            var old = ServerOptionsFixtures.snapshot
            old.values.removeValue(forKey: .transports)
            editor = ServerOptionsEditor(old)
        }
        editor.set(key, text: ServerOptionsFixtures.alternative(key))
        let patch = try editor.patch()
        #expect(Set(patch.keys) == [key])
        #expect(patch[key] != editor.baseline.values[key])
        let json = try JSONSerialization.data(withJSONObject: [key.rawValue: patch[key]!.jsonValue])
        #expect(!json.isEmpty)
    }

    @Test func noChangesProduceNoWrite() throws {
        let editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        #expect(!editor.isDirty)
        #expect(try editor.patch().isEmpty)
    }

    @Test func numericFormattingDoesNotCountAsAChange() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: " 00100 ")
        editor.set(.ratio, text: "2.000")
        #expect(!editor.isDirty)
        #expect(try editor.patch().isEmpty)
    }

    @Test func missingAndNullFieldsRemainUnsupported() throws {
        let data = Data(#"{"version":"2.9","download-dir":"/data","cache-size-mb":null}"#.utf8)
        let snapshot = try JSONDecoder().decode(ServerOptionsSnapshot.self, from: data)
        var editor = ServerOptionsEditor(snapshot)
        #expect(editor.supports(.downloadDir))
        #expect(!editor.supports(.cacheSize))
        #expect(!editor.supports(.downEnabled))
        editor.set(.downEnabled, text: "true")
        #expect(try editor.patch().isEmpty)
    }

    @Test(arguments: [
        #"{"version":"4","speed-limit-down":"100"}"#,
        #"{"version":"4","speed-limit-down":true}"#,
        #"{"version":"4","speed-limit-down-enabled":1}"#,
        #"{"version":"4","speed-limit-down":1.5}"#,
        #"{"speed-limit-down":100}"#,
    ])
    func malformedResponsesFailWithoutInventingDefaults(_ json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ServerOptionsSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: ["", "-1", "3.5", "abc", "2147483648", "9999999999999999999999999", "10oops"])
    func rejectsInvalidIntegerInput(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test(arguments: ["0", "65536", "-1", "22.5"])
    func rejectsInvalidPort(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.peerPort, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test(arguments: ["nan", "inf", "-0.01", "1e999", "3oops"])
    func rejectsInvalidRatio(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.ratio, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test(arguments: ["24:00", "12:60", "9:30", "09:3", "abc", "12:00:00", "-1:00"])
    func rejectsInvalidTime(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.scheduleBegin, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test func midnightAndOvernightSchedulesUseMinutesAndDayMask() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.scheduleBegin, text: "23:59")
        editor.set(.scheduleEnd, text: "00:00")
        editor.set(.scheduleDays, text: "65") // Sunday + Saturday
        let patch = try editor.patch()
        #expect(patch[.scheduleBegin] == .int(1439))
        #expect(patch[.scheduleEnd] == .int(0))
        #expect(patch[.scheduleDays] == .int(65))
    }

    @Test(arguments: ["0", "128", "-1"])
    func activeScheduleRequiresValidDays(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.scheduleDays, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test func enablingScheduleValidatesExistingCompanionValues() {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.scheduleEnabled] = .bool(false)
        snapshot.values[.scheduleDays] = .int(0)
        var editor = ServerOptionsEditor(snapshot)
        editor.set(.scheduleEnabled, text: "true")
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test func enablingIncompleteFolderRequiresPath() {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.incompleteEnabled] = .bool(false)
        snapshot.values[.incompleteDir] = .string("")
        var editor = ServerOptionsEditor(snapshot)
        editor.set(.incompleteEnabled, text: "true")
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test func inactiveValuesAreNotWrittenOrValidated() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.scheduleBegin, text: "unfinished")
        editor.set(.scheduleEnabled, text: "false")
        #expect(try editor.patch() == [.scheduleEnabled: .bool(false)])
    }

    @Test func zeroSpeedAndZeroQueueAreValid() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: "0")
        editor.set(.downloadQueue, text: "0")
        #expect(try editor.patch() == [.down: .int(0), .downloadQueue: .int(0)])
    }

    @Test func unknownEncryptionIsPreservedUntilExplicitlyEdited() throws {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.encryption] = .string("future-mode")
        var editor = ServerOptionsEditor(snapshot)
        editor.set(.down, text: "123")
        #expect(try editor.patch() == [.down: .int(123)])
    }

    @Test func remoteWindowsAndUnicodePathsArePreserved() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.downloadDir, text: #"D:\Downloads\Música"#)
        #expect(try editor.patch()[.downloadDir] == .string(#"D:\Downloads\Música"#))
    }

    @Test func untouchedServerStringsNeverCreateEdits() throws {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.downloadDir] = .string("/data/folder with trailing space ")
        snapshot.values[.incompleteDir] = .string(" relative-folder")
        var editor = ServerOptionsEditor(snapshot)
        #expect(!editor.isDirty)
        #expect(try editor.patch().isEmpty)
        editor.set(.down, text: "200")
        #expect(try editor.patch() == [.down: .int(200)])
    }

    @Test func editedFolderPathsPreserveSignificantWhitespace() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.downloadDir, text: "/data/folder ")
        editor.set(.incompleteDir, text: " relative-folder")
        #expect(try editor.patch() == [.downloadDir: .string("/data/folder "),
                                      .incompleteDir: .string(" relative-folder")])
    }

    @Test(arguments: ["", " \t ", "/data\n", "/data\r", "/data\0"])
    func invalidFolderPathsAreNotSilentlyCleaned(_ text: String) {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.downloadDir, text: text)
        #expect(throws: ServerOptionsError.self) { try editor.patch() }
    }

    @Test func unrelatedRemoteChangeIsPreserved() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: "200")
        var latest = editor.baseline
        latest.values[.downloadDir] = .string("/someone-else")
        #expect(try editor.checkedPatch(against: latest) == [.down: .int(200)])
    }

    @Test func sameFieldConflictBlocksWrite() {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: "200")
        var latest = editor.baseline
        latest.values[.down] = .int(300)
        #expect(throws: ServerOptionsError.self) { try editor.checkedPatch(against: latest) }
    }

    @Test func alreadyAppliedChangeDoesNotWriteAgain() throws {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: "200")
        var latest = editor.baseline
        latest.values[.down] = .int(200)
        #expect(try editor.checkedPatch(against: latest).isEmpty)
    }

    @Test func disappearedCapabilityBlocksWrite() {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: "200")
        var latest = editor.baseline
        latest.values[.down] = nil
        #expect(throws: ServerOptionsError.self) { try editor.checkedPatch(against: latest) }
    }

    @Test func remotelyChangedEnableFlagBlocksDependentEdit() {
        var editor = ServerOptionsEditor(ServerOptionsFixtures.snapshot)
        editor.set(.down, text: "200")
        var latest = editor.baseline
        latest.values[.downEnabled] = .bool(false)
        #expect(throws: ServerOptionsError.self) { try editor.checkedPatch(against: latest) }
    }

    @Test func enablingWithRemotelyChangedPathBlocksWrite() {
        var snapshot = ServerOptionsFixtures.snapshot
        snapshot.values[.incompleteEnabled] = .bool(false)
        var editor = ServerOptionsEditor(snapshot)
        editor.set(.incompleteEnabled, text: "true")
        var latest = snapshot
        latest.values[.incompleteDir] = .string("/remote-change")
        #expect(throws: ServerOptionsError.self) { try editor.checkedPatch(against: latest) }
    }
}

actor OptionsStub: ServerOptionsService {
    var snapshot = ServerOptionsFixtures.snapshot
    var writes: [[ServerOption: ServerOptionValue]] = []
    var reads = 0
    var portTests = 0
    var rejectWrite = false
    var ignoreWrite = false
    var failAfterWrite = false
    var ignoredKeys: Set<ServerOption> = []
    var failReadAt: Int?
    var delay: Duration = .zero

    func configure(rejectWrite: Bool = false, ignoreWrite: Bool = false, failReadAt: Int? = nil,
                   delay: Duration = .zero, failAfterWrite: Bool = false, ignoredKeys: Set<ServerOption> = []) {
        self.rejectWrite = rejectWrite
        self.ignoreWrite = ignoreWrite
        self.failReadAt = failReadAt
        self.delay = delay
        self.failAfterWrite = failAfterWrite
        self.ignoredKeys = ignoredKeys
    }
    func replace(_ snapshot: ServerOptionsSnapshot) { self.snapshot = snapshot }
    func fetchServerOptions() async throws -> ServerOptionsSnapshot {
        reads += 1
        if reads == failReadAt { throw ServerOptionsError(message: "Read failed") }
        if delay != .zero { try await Task.sleep(for: delay) }
        return snapshot
    }
    func setServerOptions(_ changes: [ServerOption: ServerOptionValue]) async throws {
        writes.append(changes)
        if rejectWrite { throw ServerOptionsError(message: "Write failed") }
        if !ignoreWrite { snapshot.values.merge(changes.filter { !ignoredKeys.contains($0.key) }) { _, new in new } }
        if failAfterWrite { throw ServerOptionsError(message: "Response lost after write") }
    }
    func testPeerPort() async throws -> Bool { portTests += 1; return true }
}

@Suite("Server Options save lifecycle")
@MainActor
struct ServerOptionsSessionTests {
    @Test func loadAndDraftDoNotWrite() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "200")
        #expect(await service.writes.isEmpty)
        #expect(session.editor?.isDirty == true)
    }

    @Test func applyChecksAndVerifiesOnlyChangedValues() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "200")
        try await session.apply()
        #expect(await service.writes == [[.down: .int(200)]])
        #expect(await service.reads == 3)
        #expect(session.editor?.text(.down) == "200")
        #expect(session.editor?.isDirty == false)
        #expect(!session.needsReload)
    }

    @Test func invalidDraftDoesNotContactServer() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "nope")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.reads == 1)
        #expect(await service.writes.isEmpty)
    }

    @Test(arguments: [true, false])
    func failedOrIgnoredWriteRequiresReload(_ reject: Bool) async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        await service.configure(rejectWrite: reject, ignoreWrite: !reject)
        session.set(.down, text: "200")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(session.needsReload)
        #expect(session.editor?.text(.down) == "200")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.count == 1)
        try await session.load()
        #expect(!session.needsReload)
    }

    @Test func readbackFailureDoesNotClaimSaveSuccess() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        await service.configure(failReadAt: 3)
        session.set(.down, text: "200")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(session.needsReload)
        #expect(session.editor?.isDirty == true)
        #expect(await service.snapshot.values[.down] == .int(200))
    }

    @Test func partialWriteReportsAffectedFieldsAndReloadReflectsActualValues() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        await service.configure(ignoredKeys: [.up])
        session.set(.down, text: "200")
        session.set(.up, text: "300")
        do {
            try await session.apply()
            Issue.record("A partial save must not report success")
        } catch let error as ServerOptionsError {
            #expect(error.fields == [.up])
        }
        #expect(session.needsReload)
        #expect(session.editor?.text(.up) == "300")
        #expect(await service.snapshot.values[.down] == .int(200))
        #expect(await service.snapshot.values[.up] == .int(100))
        try await session.load()
        #expect(!session.needsReload)
        #expect(session.editor?.text(.down) == "200")
        #expect(session.editor?.text(.up) == "100")
    }

    @Test func lostWriteResponseRequiresReloadAndNeverBlindlyRetries() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        await service.configure(failAfterWrite: true)
        session.set(.down, text: "200")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(session.needsReload)
        #expect(await service.snapshot.values[.down] == .int(200))
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.count == 1)
        try await session.load()
        #expect(!session.needsReload)
        #expect(session.editor?.isDirty == false)
        #expect(session.editor?.text(.down) == "200")
    }

    @Test func preflightFailurePreservesDraftWithoutWrite() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        await service.configure(failReadAt: 2)
        session.set(.down, text: "200")
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.isEmpty)
        #expect(!session.needsReload)
        #expect(session.editor?.text(.down) == "200")
    }

    @Test func conflictDoesNotWriteAndPreservesDraft() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "200")
        var changed = ServerOptionsFixtures.snapshot
        changed.values[.down] = .int(300)
        await service.replace(changed)
        await #expect(throws: ServerOptionsError.self) { try await session.apply() }
        #expect(await service.writes.isEmpty)
        #expect(session.editor?.text(.down) == "200")
    }

    @Test func secondServerDoesNotRetargetExistingEditor() async throws {
        let first = OptionsStub()
        let second = OptionsStub()
        let firstWindow = ServerOptionsSession(service: first)
        let secondWindow = ServerOptionsSession(service: second)
        try await firstWindow.load()
        firstWindow.set(.down, text: "200")
        try await secondWindow.load()
        secondWindow.set(.down, text: "300")
        try await firstWindow.apply()
        #expect(await first.writes == [[.down: .int(200)]])
        #expect(await second.writes.isEmpty)
        #expect(secondWindow.editor?.text(.down) == "300")
    }

    @Test func concurrentApplyAndEditsAreBounded() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "200")
        await service.configure(delay: .milliseconds(50))
        let applying = Task { try await session.apply() }
        while !session.isBusy { await Task.yield() }
        session.set(.down, text: "300")
        try await session.apply()
        try await applying.value
        #expect(await service.writes == [[.down: .int(200)]])
        #expect(session.editor?.text(.down) == "200")
    }

    @Test func failedReloadKeepsUnsavedDraft() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "200")
        await service.configure(failReadAt: 2)
        await #expect(throws: ServerOptionsError.self) { try await session.load() }
        #expect(session.editor?.text(.down) == "200")
        #expect(!session.isBusy)
    }

    @Test func portTestNeverAppliesDraft() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.peerPort, text: "12345")
        #expect(try await session.testPort())
        #expect(await service.portTests == 1)
        #expect(await service.writes.isEmpty)
        #expect(session.editor?.text(.peerPort) == "12345")
    }
}
