import AppKit
import Testing

@Suite("Toolbar integration", .serialized)
@MainActor
struct ToolbarControllerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27))
    func goldenGateSegmentHitAreasMatchTheDisplayedControl() throws {
        let c = MainWindowController(config: .default)
        let window = try #require(c.window)
        defer { window.close() }
        let toolbar = try #require(window.toolbar)
        toolbar.autosavesConfiguration = false
        for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
        toolbar.insertItem(withItemIdentifier: .init("serverControls"), at: 0)
        toolbar.displayMode = .iconAndLabel
        window.orderBack(nil)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let group = try #require(toolbar.items.first as? NativeToolbarGroup)
        let control = group.control
        let segments = try #require(control.cell?.accessibilityChildren() as? [NSAccessibilityElement])
        try #require(segments.count == 3)
        let drawn = window.convertToScreen(control.convert(control.bounds, to: nil))
        let hitArea = segments.reduce(NSRect.null) { $0.union($1.accessibilityFrame()) }
        #expect(drawn.width > 0 && drawn.height > 0)
        #expect(abs(hitArea.midX - drawn.midX) < 0.5)
        #expect(abs(hitArea.midY - drawn.midY) < 0.5)
    }

    @Test func itemCustomizationAndSavedLabelSettingAreIndependent() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let toolbar = try #require(c.window?.toolbar)
        #expect(toolbar.allowsUserCustomization)
        #expect(!toolbar.allowsDisplayModeCustomization)
        for title: TitleBarStyle in [.hidden, .full] {
            for labels in [false, true] {
                c.applyToolbarLayout(ToolbarLayout(titleBar: title, showsLabels: labels))
                #expect(toolbar.displayMode == (labels ? .iconAndLabel : .iconOnly))
            }
        }
    }

    @Test func nativeGroupsKeepActionsAndMenusForToolbarAndPalette() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let toolbar = try #require(c.window?.toolbar)
        for live in [true, false] {
            func item(_ id: String) throws -> NSToolbarItem {
                try #require(c.toolbar(toolbar, itemForItemIdentifier: .init(id), willBeInsertedIntoToolbar: live))
            }
            for (id, labels) in [("transferControls", ["Start", "Stop", "Force Start"]),
                                 ("torrentControls", ["Rename", "Move", "Verify"]),
                                 ("serverControls", ["Server", "Speed Limits", "Server Settings"])] {
                let group = try #require(try item(id) as? NativeToolbarGroup)
                #expect(group.subitems.map(\.label) == labels)
                if id == "serverControls" {
                    let server = try #require(group.subitems.first as? NSMenuToolbarItem)
                    #expect(server.title == c.refresh.currentServerName)
                    #expect(server.menu.items.map(\.title) == c.refresh.availableServerNames)
                    let speed = try #require(group.subitems[1] as? NSMenuToolbarItem)
                    #expect(speed.menu.items.last?.title == "Edit Presets…")
                    var opened = false
                    c.onServerSettings = { opened = true }
                    let settings = group.subitems[2]
                    #expect(c.validateToolbarItem(settings))
                    #expect(group.control.menu(forSegment: 0) === server.menu)
                    #expect(group.control.menu(forSegment: 1) === speed.menu)
                    group.performAction(at: 2)
                    #expect(opened)
                } else {
                    for member in group.subitems {
                        #expect(member.target === c && member.action != nil)
                        #expect(!c.validateToolbarItem(member))
                    }
                }
            }
            let add = try #require(try item("add") as? NSMenuToolbarItem)
            #expect(add.menu.items.map(\.title) == ["Add Torrent File…", "Add Magnet or URL…"])
            #expect(add.action == #selector(c.addFile(_:)))
            #expect(try item("remove").label == "Remove")
            #expect(try item("search") is NSSearchToolbarItem)
        }
    }

    @Test func serverOverflowExpandsToThreeUsableCommands() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let toolbar = try #require(c.window?.toolbar)
        let group = try #require(c.toolbar(toolbar, itemForItemIdentifier: .init("serverControls"),
                                           willBeInsertedIntoToolbar: true) as? NativeToolbarGroup)
        let menu = NSMenu()
        let entry = try #require(group.menuFormRepresentation?.copy() as? NSMenuItem)
        menu.addItem(entry)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(menu.items.map(\.title) == ["Server", "Speed Limits", "Server Settings"])
        #expect(menu.items[0].submenu?.items.first?.title == c.refresh.currentServerName)
        #expect(menu.items[1].submenu?.items.last?.title == "Edit Presets…")
        var opened = false
        c.onServerSettings = { opened = true }
        menu.performActionForItem(at: 2)
        #expect(opened)
        let speed = try #require(group.subitems[1] as? NSMenuToolbarItem)
        speed.menu = NSMenu()
        speed.menu.addItem(withTitle: "Updated preset", action: nil, keyEquivalent: "")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(menu.items.map(\.title) == ["Server", "Speed Limits", "Server Settings"])
        #expect(menu.items[1].submenu?.items.map(\.title) == ["Updated preset"])
    }

    @Test func refreshUpdatesLiveCopiesAfterPaletteAndRemoval() throws {
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let toolbar = try #require(c.window?.toolbar)
        // Exercise the real delegate and actual toolbar membership, not just helpers.
        for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
        toolbar.insertItem(withItemIdentifier: .init("serverControls"), at: 0)
        toolbar.insertItem(withItemIdentifier: .init("speedLimits"), at: 1)
        _ = c.toolbar(toolbar, itemForItemIdentifier: .init("speedLimits"), willBeInsertedIntoToolbar: false)
        let live = ToolbarGroups.menuItems(in: toolbar.items, identifier: .init("speedLimits"))
        #expect(live.count == 2)
        live.forEach { $0.menu = NSMenu(title: "Stale") }
        c.updateSpeedLimitsItem()
        #expect(live.allSatisfy { $0.menu.items.last?.title == "Edit Presets…" })
        toolbar.removeItem(at: 1)
        c.updateSpeedLimitsItem()
        #expect(ToolbarGroups.menuItems(in: toolbar.items, identifier: .init("speedLimits")).count == 1)
        toolbar.insertItem(withItemIdentifier: .init("server"), at: 1)
        let servers = ToolbarGroups.menuItems(in: toolbar.items, identifier: .init("server"))
        #expect(servers.count == 2)
        servers.forEach { $0.title = "Stale" }
        c.updateServerPopup()
        #expect(servers.allSatisfy { $0.title == c.refresh.currentServerName })
    }

    @Test func savedClassicConfigurationIsCopiedOnceAndNeverOverwritten() throws {
        let name = "ToolbarMigrationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let c = MainWindowController(config: .default)
        defer { c.window?.close() }
        let oldKey = "NSToolbar Configuration MainToolbar4"
        let newKey = "NSToolbar Configuration " + ToolbarGroups.autosaveIdentifier
        let ids = c.toolbarDefaultItemIdentifiers(try #require(c.window?.toolbar))
        let original: [String: Any] = [
            "TB Item Identifiers": ["add", NSToolbarItem.Identifier.space.rawValue,
                                    "start", "stop", "forceStart", "rename", "move", "verify", "remove",
                                    NSToolbarItem.Identifier.flexibleSpace.rawValue, "server", "speedLimits",
                                    "serverOptions", NSToolbarItem.Identifier.flexibleSpace.rawValue, "search"],
            "TB Is Shown": false, "TB Display Mode": 2,
        ]
        defaults.set(original, forKey: oldKey)
        ToolbarGroups.migrateConfiguration(defaults: defaults)
        let copied = try #require(defaults.dictionary(forKey: newKey))
        #expect(copied["TB Item Identifiers"] as? [String] == ids.map(\.rawValue))
        #expect(copied["TB Is Shown"] as? Bool == false)
        #expect(NSDictionary(dictionary: defaults.dictionary(forKey: oldKey)!) == NSDictionary(dictionary: original))
        let custom: [String: Any] = ["TB Item Identifiers": ["search", "serverControls"]]
        defaults.set(custom, forKey: newKey)
        ToolbarGroups.migrateConfiguration(defaults: defaults)
        #expect(NSDictionary(dictionary: defaults.dictionary(forKey: newKey)!) == NSDictionary(dictionary: custom))
    }

    @Test func customizationMigrationPreservesPartialReorderedAndEmptyLayouts() {
        for ids in [["search", "stop", "start", "server"], [], ["rename", "move"], ["serverOptions", "speedLimits", "server"]] {
            #expect(ToolbarGroups.migrated(ids.map { .init($0) }).map(\.rawValue) == ids)
        }
    }
}
