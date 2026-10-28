import Foundation
import Testing

@Suite("Unified Settings: tiers, scope and per-server saving")
@MainActor
struct ServerSettingsScopeTests {
    // MARK: Tier mapping

    @Test func everyFieldHasExactlyOnePaneTierAndGroup() {
        #expect(ServerOption.definitions.count == ServerOption.allCases.count)
        #expect(Set(ServerOption.definitions.map(\.key)).count == ServerOption.allCases.count)
        let grouped = ServerOption.groups.flatMap(\.keys)
        #expect(grouped.count == ServerOption.allCases.count)
        #expect(Set(grouped) == Set(ServerOption.allCases))
    }

    @Test func tierCountsMatchTheDesign() {
        let counts = Dictionary(grouping: ServerOption.definitions, by: \.tier).mapValues(\.count)
        #expect(counts[.essential] == 20)
        #expect(counts[.common] == 13)
        #expect(counts[.advanced] == 17)
        // Advanced settings live only on the Advanced tab, and only there.
        #expect(ServerOption.definitions.allSatisfy { ($0.tier == .advanced) == ($0.pane == .advanced) })
    }

    @Test func queueSettingsMergedIntoTransfers() {
        for key in [ServerOption.downloadQueueEnabled, .downloadQueue, .seedQueueEnabled, .seedQueue, .stalledEnabled, .stalledMinutes] {
            #expect(key.definition.pane == .transfers)
        }
    }

    @Test func noDependentFieldIsMoreHiddenThanItsParent() {
        for field in ServerOption.definitions {
            guard let parent = field.dependency?.definition else { continue }
            #expect(field.pane == parent.pane, "\(field.key)")
            #expect(field.tier == parent.tier, "\(field.key)")
            #expect(field.group == parent.group, "\(field.key)")
        }
    }

    @Test func disclosureDefaults() {
        for group in ServerOption.groups {
            switch group.tier {
            case .essential:
                #expect(!group.isCollapsible)
                #expect(group.isExpandedByDefault)
            case .common:
                #expect(group.isCollapsible)
                #expect(!group.isExpandedByDefault)
            case .advanced:
                #expect(group.isCollapsible)
                #expect(group.isExpandedByDefault == !["Default trackers", "Server scripts"].contains(group.name))
            }
        }
        // Group names are unique, so they can key the remembered expansion state.
        #expect(Set(ServerOption.groups.map(\.name)).count == ServerOption.groups.count)
    }

    @Test func essentialGroupsComeFirstOnEachTab() {
        for pane in ServerOption.Pane.allCases {
            let tiers = ServerOption.groups(in: pane).map(\.tier)
            #expect(tiers == tiers.sorted(), "\(pane)")
        }
    }

    @Test func tabsPairWithPanes() {
        #expect(ServerSettingsScope.Tab.allCases.map(\.rawValue) == ["Connection", "Transfers", "Speed", "Network", "Advanced"])
        #expect(ServerSettingsScope.Tab.connection.pane == nil)
        for pane in ServerOption.Pane.allCases { #expect(ServerSettingsScope.Tab(pane).pane == pane) }
    }

    // MARK: Availability and apply plan

    @Test func availability() {
        #expect(ServerSettingsScope.availability(isSaved: false, load: .loaded) == .unsavedNewServer)
        #expect(ServerSettingsScope.availability(isSaved: true, load: .notLoaded) == .connecting)
        #expect(ServerSettingsScope.availability(isSaved: true, load: .loading) == .connecting)
        #expect(ServerSettingsScope.availability(isSaved: true, load: .failed("x")) == .offline("x"))
        #expect(ServerSettingsScope.availability(isSaved: true, load: .loaded) == .ready)
    }

    @Test func applyPlan() {
        typealias S = ServerSettingsScope
        #expect(S.plan(localDirty: false, remoteDirty: false, remoteNeedsReload: false) == .nothing)
        #expect(S.plan(localDirty: true, remoteDirty: false, remoteNeedsReload: false) == .localOnly)
        #expect(S.plan(localDirty: false, remoteDirty: true, remoteNeedsReload: false) == .remoteOnly)
        #expect(S.plan(localDirty: true, remoteDirty: true, remoteNeedsReload: false) == .remoteThenLocal)
        if case .blocked = S.plan(localDirty: true, remoteDirty: true, remoteNeedsReload: true) {} else { Issue.record("expected blocked") }
        // A pending reload doesn't block saving presets or the connection.
        #expect(S.plan(localDirty: true, remoteDirty: false, remoteNeedsReload: true) == .localOnly)
        #expect(S.isDirty(localDirty: true, remoteDirty: false))
        #expect(!S.isDirty(localDirty: false, remoteDirty: false))
    }

    @Test func remoteRunsBeforeLocal() async throws {
        var order: [String] = []
        try await ServerSettingsScope.apply(.remoteThenLocal, remote: { order.append("remote") }, local: { order.append("local") })
        #expect(order == ["remote", "local"])
    }

    @Test func remoteFailureSavesNothingLocallyAndKeepsEveryEdit() async throws {
        let service = OptionsStub()
        await service.configure(rejectWrite: true)
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "321")

        var editor = SettingsEditor(AppConfig(servers: [ServerConfig(name: "A", host: "a", port: 1, useHTTPS: false, rpcPath: "/r")],
                                              refreshSeconds: 4, currentServer: "A"))
        let id = editor.servers[0].id
        var presets = editor.servers[0]
        presets.downSpeedPresets = [7, 8]
        editor.updateServer(at: 0, to: presets, normalizeName: true)
        var persisted: AppConfig?

        let plan = ServerSettingsScope.plan(localDirty: editor.isServerDirty(id), remoteDirty: session.editor?.isDirty == true,
                                            remoteNeedsReload: session.needsReload)
        #expect(plan == .remoteThenLocal)
        await #expect(throws: ServerOptionsError.self) {
            try await ServerSettingsScope.apply(plan, remote: { try await session.apply() },
                                                local: { persisted = editor.applyServer(id) })
        }
        #expect(persisted == nil)
        #expect(editor.isServerDirty(id))
        #expect(editor.servers[0].downSpeedPresets == [7, 8])
        #expect(session.editor?.text(.down) == "321")
        #expect(session.editor?.isDirty == true)
    }

    @Test func blockedPlanThrowsWithoutRunningEither() async {
        var ran = false
        await #expect(throws: ServerOptionsError.self) {
            try await ServerSettingsScope.apply(.blocked("Reload"), remote: { ran = true }, local: { ran = true })
        }
        #expect(!ran)
    }

    // MARK: Speed values seen by the poll

    @Test func pollUpdatesUneditedSpeedFieldsAndFlagsEditedOnes() async throws {
        let session = ServerOptionsSession(service: OptionsStub())
        try await session.load()
        let baseline = try #require(session.editor?.baseline.values[.down])
        #expect(session.absorb([.down: baseline]) == .unchanged)
        #expect(session.absorb([.down: .int(777)]) == .updated)
        #expect(session.editor?.text(.down) == "777")
        #expect(session.editor?.isDirty == false)

        session.set(.down, text: "5")
        #expect(session.absorb([.down: .int(888)]) == .conflict)
        #expect(session.editor?.text(.down) == "5")
        #expect(session.editor?.baseline.values[.down] == .int(777))
        // Unrelated speed fields with no edits still follow… only when no edited key changed.
        #expect(session.absorb([.down: .int(777), .up: .int(3)]) == .updated)
        #expect(session.editor?.text(.up) == "3")
        #expect(session.editor?.text(.down) == "5")
    }

    @Test func sessionInfoMapsToSpeedOptions() {
        let info = SessionInfo(version: "4", speedLimitDown: 10, speedLimitDownEnabled: true, speedLimitUp: 20,
                               speedLimitUpEnabled: false, altSpeedEnabled: true, altSpeedDown: 1, altSpeedUp: 2)
        #expect(info.speedOptionValues == [.down: .int(10), .downEnabled: .bool(true), .up: .int(20), .upEnabled: .bool(false),
                                           .altEnabled: .bool(true), .altDown: .int(1), .altUp: .int(2)])
        #expect(info.speedOptionValues.keys.allSatisfy { $0.definition.pane == .speed })
    }

    @Test func revertRestoresLoadedValues() async throws {
        let service = OptionsStub()
        let session = ServerOptionsSession(service: service)
        try await session.load()
        session.set(.down, text: "1")
        session.revert()
        #expect(session.editor?.isDirty == false)
        #expect(await service.writes.isEmpty)
    }

    // MARK: Per-server saving in SettingsEditor

    private func editor() -> SettingsEditor {
        func s(_ n: String) -> ServerConfig { ServerConfig(name: n, host: n.lowercased(), port: 1, useHTTPS: false, rpcPath: "/r") }
        return SettingsEditor(AppConfig(servers: [s("A"), s("B")], refreshSeconds: 4, currentServer: "A"))
    }

    @Test func applyingOneServerNeverPersistsAnother() {
        var e = editor()
        let a = e.servers[0].id, b = e.servers[1].id
        var editedA = e.servers[0]; editedA.host = "a2"
        var editedB = e.servers[1]; editedB.host = "b2"
        e.updateServer(at: 0, to: editedA, normalizeName: true)
        e.updateServer(at: 1, to: editedB, normalizeName: true)
        #expect(e.dirtyServerIDs == [a, b])
        let saved = e.applyServer(a)
        #expect(saved.server(id: a)?.host == "a2")
        #expect(saved.server(id: b)?.host == "b")
        #expect(!e.isServerDirty(a))
        #expect(e.isServerDirty(b))
        #expect(e.servers[1].host == "b2")   // B's draft survives
    }

    @Test func applyingARenamedDefaultCarriesTheDefault() {
        var e = editor()
        let a = e.servers[0].id
        var renamed = e.servers[0]; renamed.name = "Alpha"
        e.updateServer(at: 0, to: renamed, normalizeName: true)
        #expect(e.savedConfig.currentServer == "A")
        #expect(e.applyServer(a).currentServer == "Alpha")
    }

    @Test func revertDiscardsOneServerAndDropsAnUnsavedNewOne() {
        var e = editor()
        let a = e.servers[0].id
        var renamed = e.servers[0]; renamed.name = "Alpha"
        e.updateServer(at: 0, to: renamed, normalizeName: true)
        e.revertServer(a)
        #expect(e.servers[0].name == "A")
        #expect(e.currentServer == "A")
        #expect(!e.isDirty)

        let i = e.addServer()
        let new = e.servers[i].id
        #expect(!e.isSaved(new))
        #expect(e.isServerDirty(new))
        #expect(e.savedConfig.server(id: new) == nil)
        e.revertServer(new)
        #expect(e.serverCount == 2)
        #expect(!e.isDirty)
    }

    @Test func applyingANewServerSavesItInListOrder() {
        var e = editor()
        let i = e.addServer()
        let new = e.servers[i].id
        e.moveServer(from: i, to: 0)
        let saved = e.applyServer(new)
        #expect(saved.serverNames == ["New Server", "A", "B"])
        #expect(e.isSaved(new))
        #expect(!e.isDirty)
    }

    @Test func removingAppliesImmediatelyAndRestoreUndoesIt() {
        var e = editor()
        let removed = e.removeServer(at: 0)
        #expect(removed?.name == "A")
        #expect(e.savedConfig.serverNames == ["B"])
        #expect(e.savedConfig.currentServer == "B")
        #expect(!e.isDirty)
        e.restoreServer(removed!, at: 0, saved: true, wasDefault: true)
        #expect(e.serverNames == ["A", "B"])
        #expect(e.savedConfig.serverNames == ["A", "B"])
        #expect(e.savedConfig.currentServer == "A")
        #expect(!e.isDirty)
    }

    @Test func makeDefaultDuringAPendingRenameKeepsTheSavedName() {
        var e = editor()
        var renamed = e.servers[1]; renamed.name = "Beta"
        e.updateServer(at: 1, to: renamed, normalizeName: true)
        e.setDefaultServer("Beta")
        #expect(e.savedConfig.currentServer == "B")
        #expect(e.applyServer(e.servers[1].id).currentServer == "Beta")
    }

    /// Transmission 4.1's RPC has no watch-dir fields (rpc-spec 4.1), so only the
    /// trash flag is offered, with a caption saying where the watch folder is set.
    @Test func trashOriginalIsTheOnlyTorrentFileSetting() {
        #expect(ServerOption.trashOriginal.definition.title == "Delete .torrent files after they are added")
        #expect(ServerOption.trashOriginal.group.keys == [.trashOriginal])
        #expect(!ServerOption.allCases.contains { $0.rawValue.hasPrefix("watch") })
    }
}
