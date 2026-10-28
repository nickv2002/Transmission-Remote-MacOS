import XCTest

final class SettingsEditorTests: XCTestCase {
    private func sample() -> AppConfig {
        AppConfig(
            servers: [
                ServerConfig(name: "A", host: "a.local", port: 9091,
                             useHTTPS: false, rpcPath: "/transmission/rpc",
                             username: "u", password: "p"),
                ServerConfig(name: "B", host: "b.local", port: 8080,
                             useHTTPS: true, rpcPath: "/rpc"),
            ],
            refreshSeconds: 4, currentServer: "A")
    }

    private func server(_ name: String, host: String = "h") -> ServerConfig {
        ServerConfig(name: name, host: host, port: 9091,
                     useHTTPS: false, rpcPath: "/transmission/rpc")
    }

    // MARK: - Dirty / save

    func testFreshEditorNotDirty() {
        let e = SettingsEditor(sample())
        XCTAssertFalse(e.isDirty)
    }

    func testEditMakesDirtyAndSaveClears() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "changed.local"), normalizeName: true)
        XCTAssertTrue(e.isDirty)
        let saved = e.save()
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(saved.servers[0].host, "changed.local")
        XCTAssertEqual(e.servers[0].host, "changed.local")
    }

    func testPathMappingsFlowThroughUpdateAndSave() {
        var e = SettingsEditor(sample())
        var edited = server("A", host: "a.local")
        edited.pathMappings = [PathMapping(remote: "/video", local: "/Volumes/Video")]
        e.updateServer(at: 0, to: edited, normalizeName: true)
        XCTAssertTrue(e.isDirty)               // a mappings change makes the editor dirty
        let saved = e.save()
        XCTAssertEqual(saved.servers[0].pathMappings,
                       [PathMapping(remote: "/video", local: "/Volumes/Video")])
        XCTAssertFalse(e.isDirty)
    }

    func testResetRevertsToBaseline() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "x"), normalizeName: true)
        XCTAssertTrue(e.isDirty)
        e.reset(to: sample())
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(e.servers[0].host, "a.local")
    }

    // MARK: - Add

    func testAddServerAppendsUniqueName() {
        var e = SettingsEditor(sample())
        let i = e.addServer()
        XCTAssertEqual(i, 2)
        XCTAssertEqual(e.serverCount, 3)
        XCTAssertEqual(e.servers[2].name, "New Server")
        XCTAssertTrue(e.isDirty)
    }

    func testAddServerDisambiguatesName() {
        var e = SettingsEditor(AppConfig(servers: [server("New Server")],
                                         refreshSeconds: 4, currentServer: "New Server"))
        let i = e.addServer()
        XCTAssertEqual(e.servers[i].name, "New Server 2")
        let j = e.addServer()
        XCTAssertEqual(e.servers[j].name, "New Server 3")
    }

    // MARK: - Move

    private func three() -> SettingsEditor {
        SettingsEditor(AppConfig(servers: [server("A"), server("B"), server("C")],
                                 refreshSeconds: 4, currentServer: "A"))
    }

    func testMoveServerDown() {
        var e = three()
        XCTAssertEqual(e.moveServer(from: 0, to: 3), 2)   // drop after last
        XCTAssertEqual(e.serverNames, ["B", "C", "A"])
        // Reordering applies at once: nothing is left pending.
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(e.savedConfig.serverNames, ["B", "C", "A"])
    }

    func testMoveServerUp() {
        var e = three()
        XCTAssertEqual(e.moveServer(from: 2, to: 0), 0)
        XCTAssertEqual(e.serverNames, ["C", "A", "B"])
    }

    func testMoveToSamePositionKeepsOrderAndNotDirty() {
        var e = three()
        XCTAssertEqual(e.moveServer(from: 1, to: 2), 1)   // just below itself
        XCTAssertEqual(e.serverNames, ["A", "B", "C"])
        XCTAssertFalse(e.isDirty)
    }

    func testMoveKeepsDefaultServer() {
        var e = three()
        e.moveServer(from: 0, to: 3)
        XCTAssertEqual(e.currentServer, "A")
    }

    func testMoveInvalidIndexIsNoOp() {
        var e = three()
        XCTAssertNil(e.moveServer(from: 5, to: 0))
        XCTAssertNil(e.moveServer(from: 0, to: 4))
        XCTAssertEqual(e.serverNames, ["A", "B", "C"])
    }

    // MARK: - Remove

    func testRemoveServer() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 1)
        XCTAssertEqual(e.serverCount, 1)
        XCTAssertEqual(e.servers[0].name, "A")
    }

    func testRemoveLastServerIsNoOp() {
        var e = SettingsEditor(AppConfig(servers: [server("only")],
                                         refreshSeconds: 4, currentServer: "only"))
        e.removeServer(at: 0)
        XCTAssertEqual(e.serverCount, 1)
        XCTAssertFalse(e.isDirty)
    }

    func testRemoveInvalidIndexIsNoOp() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 9)
        XCTAssertEqual(e.serverCount, 2)
    }

    func testRemovingDefaultRepointsToFirst() {
        var e = SettingsEditor(sample())   // default = "A" at index 0
        e.removeServer(at: 0)
        XCTAssertEqual(e.serverCount, 1)
        XCTAssertEqual(e.currentServer, "B")   // fell back to first remaining
    }

    func testDeleteThenSave() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 1)
        let saved = e.save()
        XCTAssertEqual(saved.servers.count, 1)
        XCTAssertEqual(saved.servers.first?.name, "A")
        XCTAssertFalse(e.isDirty)
    }

    // MARK: - Update (normalize on end-edit)

    func testUpdateTrimsAndKeepsNonEmptyName() {
        var e = SettingsEditor(sample())
        let stored = e.updateServer(at: 0, to: server("  Renamed  "), normalizeName: true)
        XCTAssertEqual(stored.name, "Renamed")
        XCTAssertEqual(e.servers[0].name, "Renamed")
    }

    func testUpdateEmptyNameFallsBackToOld() {
        var e = SettingsEditor(sample())
        let stored = e.updateServer(at: 0, to: server("   "), normalizeName: true)
        XCTAssertEqual(stored.name, "A")
    }

    func testUpdateDuplicateNameRejectedOnNormalize() {
        var e = SettingsEditor(sample())
        // Try to rename B → "A" (collides) — should keep "B".
        let stored = e.updateServer(at: 1, to: server("A"), normalizeName: true)
        XCTAssertEqual(stored.name, "B")
        XCTAssertEqual(e.servers[1].name, "B")
    }

    func testRenamingDefaultFollowsTheRename() {
        var e = SettingsEditor(sample())   // default "A"
        e.updateServer(at: 0, to: server("A2"), normalizeName: true)
        XCTAssertEqual(e.currentServer, "A2")
    }

    func testUpdatePreservesOtherFields() {
        var e = SettingsEditor(sample())
        var s = server("A")
        s.host = "newhost"; s.port = 1234; s.useHTTPS = true; s.username = "x"; s.password = "y"
        e.updateServer(at: 0, to: s, normalizeName: true)
        XCTAssertEqual(e.servers[0].host, "newhost")
        XCTAssertEqual(e.servers[0].port, 1234)
        XCTAssertTrue(e.servers[0].useHTTPS)
        XCTAssertEqual(e.servers[0].username, "x")
        XCTAssertEqual(e.servers[0].password, "y")
    }

    // MARK: - Update (live, no normalize)

    func testLiveUpdateTakesRawNameEvenIfDuplicate() {
        var e = SettingsEditor(sample())
        // Live (per-keystroke) sync allows a transient duplicate / raw value.
        e.updateServer(at: 1, to: server("A"), normalizeName: false)
        XCTAssertEqual(e.servers[1].name, "A")
    }

    // MARK: - Default server + refresh

    func testSetDefaultServer() {
        var e = SettingsEditor(sample())
        e.setDefaultServer("B")
        XCTAssertEqual(e.currentServer, "B")
        // Make Default applies at once.
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(e.savedConfig.currentServer, "B")
    }

    func testSetRefreshSecondsClampedInNormalized() {
        var e = SettingsEditor(sample())
        e.setRefreshSeconds(0)
        XCTAssertEqual(e.normalized().refreshSeconds, 1)   // clamped to >= 1
        e.setRefreshSeconds(30)
        XCTAssertEqual(e.normalized().refreshSeconds, 30)
    }

    // General-pane setters apply immediately (write through to both `working`
    // and `savedBaseline`), so they never register as a server-pane dirty edit —
    // this is the fix for the bug where toggling a General checkbox used to
    // enable the Servers pane's "Save Server" button.

    func testSetAutoCheckForUpdatesAppliesImmediately() {
        var e = SettingsEditor(sample())
        XCTAssertTrue(e.autoCheckForUpdates)
        XCTAssertFalse(e.isDirty)
        let applied = e.setAutoCheckForUpdates(false)
        XCTAssertFalse(e.autoCheckForUpdates)
        XCTAssertFalse(applied.autoCheckForUpdates)
        XCTAssertFalse(e.isDirty)   // still not dirty: it's already the baseline
    }

    func testSetRemoveTorrentFileSettingsAppliesImmediately() {
        var e = SettingsEditor(sample())
        XCTAssertEqual(e.removeTorrentFileMethod, .none)
        let applied = e.setRemoveTorrentFileMethod(.delete)
        XCTAssertEqual(applied.removeTorrentFileMethod, .delete)
        XCTAssertFalse(e.isDirty)
    }

    func testSetAddSettingsAppliesImmediately() {
        var e = SettingsEditor(sample())
        XCTAssertTrue(e.showAddOptions)
        XCTAssertFalse(e.addLinksFromClipboard)
        e.setShowAddOptions(false)
        let applied = e.setAddLinksFromClipboard(true)
        XCTAssertFalse(applied.showAddOptions)
        XCTAssertTrue(applied.addLinksFromClipboard)
        XCTAssertFalse(e.isDirty)
    }

    private static let iconOnly = ToolbarLayout(titleBar: .full, showsLabels: false)

    func testSetToolbarLayoutAppliesImmediatelyAndSurvivesSave() {
        var e = SettingsEditor(sample())
        XCTAssertEqual(e.toolbarLayout, .default)
        let applied = e.setToolbarLayout(Self.iconOnly)
        XCTAssertEqual(applied.toolbarLayout, Self.iconOnly)
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(e.save().toolbarLayout, Self.iconOnly)
    }

    func testEveryImmediateSetterLeavesEditorClean() {
        var e = SettingsEditor(sample())
        e.setAutoCheckForUpdates(false)
        e.setRemoveTorrentFileMethod(.trash)
        e.setShowAddOptions(false)
        e.setAddLinksFromClipboard(true)
        e.setToolbarLayout(Self.iconOnly)
        XCTAssertFalse(e.isDirty)
        let saved = e.save()
        XCTAssertFalse(saved.autoCheckForUpdates)
        XCTAssertEqual(saved.removeTorrentFileMethod, .trash)
        XCTAssertFalse(saved.showAddOptions)
        XCTAssertTrue(saved.addLinksFromClipboard)
        XCTAssertEqual(saved.toolbarLayout, Self.iconOnly)
    }

    /// The bug regression test: a General edit must never enable the Servers
    /// pane's dirty/Save-button gating, while a genuine server edit still does.
    func testGeneralEditDoesNotDirtyServerPane() {
        var e = SettingsEditor(sample())
        e.setAutoCheckForUpdates(false)
        e.setRefreshSeconds(30)
        e.setShowAddOptions(false)
        XCTAssertFalse(e.isDirty)
        e.updateServer(at: 0, to: server("A", host: "changed.local"), normalizeName: true)
        XCTAssertTrue(e.isDirty)
    }

    func testAddSettingsSurviveOpenAndUnrelatedSave() {
        var config = sample()
        config.showAddOptions = false
        config.addLinksFromClipboard = true
        var e = SettingsEditor(config)
        XCTAssertFalse(e.isDirty)
        e.setRefreshSeconds(9)
        let saved = e.save()
        XCTAssertFalse(saved.showAddOptions)
        XCTAssertTrue(saved.addLinksFromClipboard)
    }

    func testFilesFoldersFirstDefaultsOnAppliesImmediatelyAndSurvivesSave() {
        var e = SettingsEditor(sample())
        XCTAssertTrue(e.filesFoldersFirst)
        let applied = e.setFilesFoldersFirst(false)
        XCTAssertFalse(applied.filesFoldersFirst)
        XCTAssertFalse(e.isDirty)
        e.setRefreshSeconds(9)
        XCTAssertFalse(e.save().filesFoldersFirst)
    }

    func testShowPieceMapDefaultsOnAppliesImmediatelyAndSurvivesSave() {
        var e = SettingsEditor(sample())
        XCTAssertTrue(e.showPieceMap)
        let applied = e.setShowPieceMap(false)
        XCTAssertFalse(applied.showPieceMap)
        XCTAssertFalse(e.isDirty)
        e.setRefreshSeconds(9)
        XCTAssertFalse(e.save().showPieceMap)
    }

    func testRemoveTorrentFileSettingsSurviveOpenAndUnrelatedSave() {
        // The editor rebuilds AppConfig when it opens and on save; the removal
        // setting must carry through both rather than reset to its default.
        var config = sample()
        config.removeTorrentFileMethod = .delete
        var e = SettingsEditor(config)
        XCTAssertFalse(e.isDirty)
        e.setRefreshSeconds(9)
        let saved = e.save()
        XCTAssertEqual(saved.removeTorrentFileMethod, .delete)
    }

    // MARK: - General setters never leak pending server edits

    func testGeneralSetterReturnsBaselineNotPendingServerEdits() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "dirty.local"), normalizeName: true)
        let added = e.addServer()
        XCTAssertTrue(e.isDirty)
        XCTAssertFalse(e.isSaved(e.servers[added].id))

        let baselineServers = e.savedConfig.servers
        let returned = e.setAutoCheckForUpdates(false)
        XCTAssertEqual(returned.servers, baselineServers)
        XCTAssertEqual(returned.servers.count, 2)
        XCTAssertEqual(returned.servers[0].host, "a.local")
        XCTAssertFalse(returned.autoCheckForUpdates)
        // The working copy keeps its pending edits.
        XCTAssertEqual(e.servers[0].host, "dirty.local")
        XCTAssertEqual(e.serverCount, 3)
    }

    func testEveryGeneralSetterReturnsBaselineServers() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 1, to: server("B", host: "dirty.local"), normalizeName: true)
        _ = e.addServer()
        let baselineServers = e.savedConfig.servers
        XCTAssertEqual(e.setRefreshSeconds(12).servers, baselineServers)
        XCTAssertEqual(e.setShowAddOptions(false).servers, baselineServers)
        XCTAssertEqual(e.setAddLinksFromClipboard(true).servers, baselineServers)
        XCTAssertEqual(e.setFilesFoldersFirst(false).servers, baselineServers)
        XCTAssertEqual(e.setShowPieceMap(false).servers, baselineServers)
        XCTAssertEqual(e.setRemoveTorrentFileMethod(.delete).servers, baselineServers)
        XCTAssertEqual(e.setToolbarLayout(Self.iconOnly).servers, baselineServers)
        XCTAssertEqual(e.setRefreshSeconds(12).refreshSeconds, 12)
        XCTAssertEqual(e.setRefreshSeconds(0).refreshSeconds, 1)   // still clamped
    }

    // MARK: - Name clash uses the committed name

    func testLiveRenameThenClashingNormalizeRevertsToSavedName() {
        var e = SettingsEditor(sample())   // A, B (both saved)
        // Live typing overwrites B's working name with the clashing "A" ...
        e.updateServer(at: 1, to: server("A"), normalizeName: false)
        // ... and the end-of-edit normalize must still refuse it, reverting to "B".
        let stored = e.updateServer(at: 1, to: server("A"), normalizeName: true)
        XCTAssertEqual(stored.name, "B")
        XCTAssertEqual(e.servers[1].name, "B")
        XCTAssertEqual(e.servers[0].name, "A")
    }

    func testClashingLiveRenameOfUnsavedServerRevertsToItsLastName() {
        var e = SettingsEditor(sample())
        let i = e.addServer()   // "New Server"
        e.updateServer(at: i, to: server("New Server"), normalizeName: true)
        e.updateServer(at: i, to: server("A"), normalizeName: false)   // live: clashes with A
        let stored = e.updateServer(at: i, to: server("A"), normalizeName: true)
        XCTAssertEqual(stored.name, "New Server")
        XCTAssertNotEqual(e.servers[0].name, e.servers[i].name)
    }

    func testClashingRenameKeepsDefaultOnTheSavedName() {
        var e = SettingsEditor(sample())   // default "A"
        e.updateServer(at: 1, to: server("A"), normalizeName: false)
        e.updateServer(at: 1, to: server("A"), normalizeName: true)
        XCTAssertEqual(e.currentServer, "A")
        XCTAssertEqual(e.servers[1].name, "B")
    }

    // MARK: - Undo of remove keeps pending edits out of the baseline

    func testRestoreDoesNotPersistPendingEditsOfTheRemovedServer() {
        var e = SettingsEditor(sample())   // default "A" at index 0
        e.updateServer(at: 0, to: server("A", host: "dirty.local"), normalizeName: true)
        // Only the removed server itself is dirty, so removal is allowed.
        XCTAssertTrue(e.canRemoveServer(at: 0))
        let removed = e.removeServer(at: 0)
        XCTAssertEqual(removed?.host, "dirty.local")
        XCTAssertEqual(e.savedConfig.serverNames, ["B"])

        e.restoreServer(removed!, at: 0, saved: true, wasDefault: true)
        // The working copy comes back with its edit ...
        XCTAssertEqual(e.servers[0].host, "dirty.local")
        XCTAssertEqual(e.currentServer, "A")
        // ... but the baseline gets the pre-removal saved version, not the edit.
        XCTAssertEqual(e.savedConfig.servers[0].host, "a.local")
        XCTAssertEqual(e.savedConfig.serverNames, ["A", "B"])
        XCTAssertEqual(e.savedConfig.currentServer, "A")
        XCTAssertTrue(e.isDirty)
        XCTAssertEqual(e.save().servers[0].host, "dirty.local")   // applied only when saved
    }

    func testRestoreOfCleanRemovedServerLeavesEditorClean() {
        var e = SettingsEditor(sample())
        let before = e.savedConfig.servers
        let removed = e.removeServer(at: 1)
        e.restoreServer(removed!, at: 1, saved: true, wasDefault: false)
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(e.savedConfig.servers, before)
    }

    // MARK: - Removal guard while another server has pending edits

    func testRemoveRefusedWhileAnotherServerIsDirty() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "dirty.local"), normalizeName: true)
        XCTAssertFalse(e.canRemoveServer(at: 1))
        XCTAssertNil(e.removeServer(at: 1))
        XCTAssertEqual(e.serverNames, ["A", "B"])
        XCTAssertEqual(e.savedConfig.serverNames, ["A", "B"])
        XCTAssertEqual(e.servers[0].host, "dirty.local")
    }

    func testRemoveAllowedAfterSaveAndForTheDirtyServerItself() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 1, to: server("B", host: "dirty.local"), normalizeName: true)
        XCTAssertTrue(e.canRemoveServer(at: 1))     // its own edit is fine
        XCTAssertFalse(e.canRemoveServer(at: 0))    // ... but not the other one
        e.save()
        XCTAssertTrue(e.canRemoveServer(at: 0))
        XCTAssertNotNil(e.removeServer(at: 0))
        XCTAssertFalse(e.canRemoveServer(at: 9))
    }

    func testCannotRemoveLastServerEvenWhenClean() {
        let e = SettingsEditor(AppConfig(servers: [server("only")],
                                         refreshSeconds: 4, currentServer: "only"))
        XCTAssertFalse(e.canRemoveServer(at: 0))
    }

    // MARK: - Combined scenario

    func testChangeAddRemoveThenSaveRoundTrip() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 1)   // remove original "B" while nothing else is pending
        e.updateServer(at: 0, to: server("A", host: "edited"), normalizeName: true)
        let i = e.addServer()
        e.updateServer(at: i, to: server("C", host: "c.local"), normalizeName: true)
        e.setDefaultServer("C")
        e.setRefreshSeconds(10)
        let saved = e.save()

        XCTAssertEqual(saved.servers.map(\.name), ["A", "C"])
        XCTAssertEqual(saved.servers[0].host, "edited")
        XCTAssertEqual(saved.currentServer, "C")
        XCTAssertEqual(saved.refreshSeconds, 10)
        XCTAssertFalse(e.isDirty)
    }
}
