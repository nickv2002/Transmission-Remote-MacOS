import AppKit
import Testing

/// The unified Settings window's server tabs, driven against a stub service.
/// Ported from the standalone Server Options window tests: the accessibility
/// identifiers and controls are the same, now embedded in Settings ▸ <server>.
@Suite("Server Settings native controls", .serialized)
@MainActor
struct ServerSettingsWindowTests {
    private static let server = ServerConfig(name: "Isolated test server", host: "127.0.0.1", port: 19091,
                                             useHTTPS: false, rpcPath: "/transmission/rpc")

    private func controller(service: OptionsStub = OptionsStub(), servers: [ServerConfig] = [Self.server],
                            failing: Bool = false) async throws -> SettingsWindowController {
        _ = NSApplication.shared
        SettingsWindowController.remembersUIState = false
        let c = SettingsWindowController(config: AppConfig(servers: servers, refreshSeconds: 4, currentServer: servers[0].name))
        c.serviceProvider = { _ in
            if failing { throw ServerOptionsError(message: "Connection refused.") }
            return .init(service: service, endpoint: "http://127.0.0.1:19091")
        }
        c.route(to: .server(servers[0].id), tab: .transfers)
        try await waitUntil { failing ? c.remote[servers[0].id]?.load != .loading : c.form.session?.editor != nil }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    private func type(_ text: String, into field: NSTextField, _ c: SettingsWindowController) {
        field.stringValue = text
        c.form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    @Test func allSettingsHaveNativeControlsAndFiveServerTabs() async throws {
        let c = try await controller()
        #expect(c.tabView.tabViewItems.map(\.label) == ["Connection", "Transfers", "Speed", "Network", "Advanced"])
        #expect(Set(c.form.controls.keys) == Set(ServerOption.allCases))
        #expect(c.form.controls.keys.allSatisfy { !$0.rawValue.hasPrefix("blocklist") })
        #expect(c.form.controls[.scheduleDays]?.count == 7)
        #expect(c.form.controls[.encryption]?.first is NSPopUpButton)
        #expect(c.form.controls[.downloadDir]?.first is NSTextField)
        #expect(c.form.controls[.incompleteEnabled]?.first is NSButton)
        #expect(c.nameLabel.stringValue == "Isolated test server")
        #expect(c.window?.title == "Settings — Isolated test server")
    }

    @Test func checkboxDependenciesAndValuesStayInSync() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let toggle = try #require(c.form.controls[.downEnabled]?.first as? NSButton)
        #expect(c.form.controls[.down]?.first?.isEnabled == true)
        toggle.performClick(nil)
        #expect(c.form.session?.editor?.flag(.downEnabled) == false)
        #expect(c.form.controls[.down]?.first?.isEnabled == false)
        #expect(c.form.controls[.down]?.first?.stringValue == "100")
        #expect(await service.writes.isEmpty)
        #expect(c.applyButton.isEnabled)
        toggle.performClick(nil)
        #expect(c.form.controls[.down]?.first?.isEnabled == true)
        #expect(c.form.session?.editor?.isDirty == false)
        #expect(!c.applyButton.isEnabled)
    }

    @Test func dayButtonsEncodeSundayAsBitZero() async throws {
        let c = try await controller()
        let days = try #require(c.form.controls[.scheduleDays])
        #expect(days.map(\.tag) == [1, 2, 3, 4, 5, 6, 0])
        for control in days {
            let button = try #require(control as? NSButton)
            if button.tag != 0 { button.performClick(nil) }
        }
        #expect(c.form.session?.editor?.text(.scheduleDays) == "1")
        #expect(try c.form.session?.editor?.patch()[.scheduleDays] == .int(1))
    }

    @Test func unsupportedControlsAreDisabled() async throws {
        let service = OptionsStub()
        await service.replace(ServerOptionsSnapshot(version: "old", values: [.downloadDir: .string("/data")]))
        let c = try await controller(service: service)
        #expect(c.form.controls[.downloadDir]?.first?.isEnabled == true)
        #expect(c.form.controls[.downEnabled]?.first?.isEnabled == false)
        #expect(c.form.controls[.down]?.first?.isEnabled == false)
        #expect(c.form.controls[.down]?.first?.toolTip == "Not supported by this server.")
    }

    @Test func newlyAvailableFieldsLoseUnavailablePlaceholderAfterReload() async throws {
        let service = OptionsStub()
        await service.replace(ServerOptionsSnapshot(version: "old", values: [.downloadDir: .string("/data")]))
        let c = try await controller(service: service)
        let path = try #require(c.form.controls[.addedScript]?.first as? NSTextField)
        #expect(path.placeholderString == "Unavailable")
        var available = ServerOptionsFixtures.snapshot
        available.values[.addedScript] = .string("")
        await service.replace(available)
        try await c.form.session?.load()
        c.form.render()
        #expect(path.isEnabled)
        #expect(path.stringValue.isEmpty)
        #expect(path.placeholderString == "/path/on/server")
        #expect(path.toolTip == nil)
    }

    @Test func typingAndSwitchingTabsDoNotSaveOrDiscard() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let field = try #require(c.form.controls[.downloadDir]?.first as? NSTextField)
        type("/data/new destination", into: field, c)
        c.selectTab(.network)
        c.selectTab(.connection)
        c.selectTab(.transfers)
        #expect(c.form.session?.editor?.text(.downloadDir) == "/data/new destination")
        #expect(field.stringValue == "/data/new destination")
        #expect(c.window?.isDocumentEdited == true)
        #expect(c.isDirty(Self.server.id))
        #expect(await service.writes.isEmpty)
    }

    @Test func routingIntoTheOpenWindowKeepsEdits() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        type("/data/kept", into: try #require(c.form.controls[.downloadDir]?.first as? NSTextField), c)
        c.route(to: .server(Self.server.id), tab: .speed)
        c.route(to: nil)
        #expect(c.selectedTab == .speed)
        #expect(c.form.session?.editor?.text(.downloadDir) == "/data/kept")
        #expect(await service.writes.isEmpty)
    }

    @Test func reopeningAHiddenWindowKeepsUnsavedEdits() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let config = AppConfig(servers: [Self.server], refreshSeconds: 4, currentServer: Self.server.name)
        type("/data/still here", into: try #require(c.form.controls[.downloadDir]?.first as? NSTextField), c)
        c.window?.orderOut(nil)   // closed-looking: minimized and hidden windows aren't visible either
        c.reopen(with: config)
        #expect(c.form.session?.editor?.text(.downloadDir) == "/data/still here")
        #expect(c.isDirty(Self.server.id))
        // With nothing pending, reopening re-seeds from the saved config.
        c.revertSettings(nil)
        try await waitUntil { !c.working }   // Revert refetches the server's values
        var renamed = Self.server
        renamed.name = "Renamed elsewhere"
        c.reopen(with: AppConfig(servers: [renamed], refreshSeconds: 4, currentServer: renamed.name))
        #expect(c.editor.servers.first?.name == "Renamed elsewhere")
        #expect(await service.writes.isEmpty)
    }

    @Test func revertDiscardsEditsAndLoadsTheServersCurrentValues() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        #expect(!c.revertButton.isEnabled)
        type("/data/discard me", into: try #require(c.form.controls[.downloadDir]?.first as? NSTextField), c)
        c.connectionPane.downPresetsField.stringValue = "1, 2"
        c.connectionPane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                           object: c.connectionPane.downPresetsField))
        #expect(c.revertButton.isEnabled)
        var changed = ServerOptionsFixtures.snapshot
        changed.values[.down] = .int(777)   // changed by another client meanwhile
        await service.replace(changed)
        let reads = await service.reads
        c.revertSettings(nil)
        try await waitUntil { !c.working && c.form.session?.editor?.text(.down) == "777" }
        #expect(await service.reads > reads, "Revert refetches, covering what Reload did")
        #expect(c.form.session?.editor?.text(.downloadDir) != "/data/discard me")
        #expect(c.connectionPane.downPresetsField.stringValue == SpeedPresets.format(Self.server.downSpeedPresets))
        #expect(!c.isDirty(Self.server.id))
        #expect(await service.writes.isEmpty)
        #expect(!c.revertButton.isEnabled)
    }

    @Test func revertClearsAFailedWriteSoApplyWorksAgain() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        type("250", into: try #require(c.form.controls[.down]?.first as? NSTextField), c)
        await service.configure(rejectWrite: true)
        c.applySettings(nil)
        try await waitUntil { !c.working }
        #expect(c.form.session?.needsReload == true)
        #expect(c.statusLabel.stringValue.contains("Revert"))
        await service.configure()
        c.revertSettings(nil)
        try await waitUntil { !c.working && c.form.session?.needsReload == false }
        #expect(c.revertButton.isEnabled == false)
        type("260", into: try #require(c.form.controls[.down]?.first as? NSTextField), c)
        #expect(c.applyButton.isEnabled)
    }

    @Test func makeDefaultFooterButtonAppliesImmediately() async throws {
        let other = ServerConfig(name: "Other", host: "127.0.0.2", port: 1, useHTTPS: false, rpcPath: "/r")
        let c = try await controller(servers: [Self.server, other])
        var saved: [AppConfig] = []
        c.onChange = { saved.append($0) }
        #expect(c.defaultButton.title == "Default")
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let footer = [c.addButtonForTesting, c.removeButton, c.defaultButton]
        // Constraints act on the alignment rect (the frame adds the bezel's inset).
        #expect(Set(footer.map { $0.alignmentRect(forFrame: $0.frame).height }) == [SettingsWindowController.footerButtonHeight])
        #expect(Set(footer.map(\.frame.height)).count == 1)
        #expect(c.defaultButton.frame.minX > c.removeButton.frame.maxX + 20, "Default is right-justified")
        #expect(c.defaultButton.accessibilityLabel() == "Make this the default server")
        #expect(c.defaultButton.toolTip == "Make this the default server")
        #expect(!c.defaultButton.isEnabled, "the selected server is already the default")
        c.route(to: .server(other.id))
        #expect(c.defaultButton.isEnabled)
        c.defaultButton.performClick(nil)
        #expect(saved.last?.currentServer == "Other")
        #expect(!c.defaultButton.isEnabled)
        c.route(to: .general)
        #expect(!c.defaultButton.isEnabled)
        // An unsaved new server can't be the default yet.
        let index = c.editor.addServer()
        c.sidebar.reloadData()
        c.route(to: .server(c.editor.servers[index].id), tab: .connection)
        #expect(!c.defaultButton.isEnabled)
    }

    @Test func testConnectionLivesInTheConnectionFormAndWorksWhenBlocked() async throws {
        let c = try await controller(failing: true)
        let button = c.connectionPane.testButton
        #expect(button.isDescendant(of: c.connectionPane.view))
        #expect(button.accessibilityIdentifier() == "server-settings-test-connection")
        #expect(button.isEnabled, "offline server")
        let index = c.editor.addServer()
        c.sidebar.reloadData()
        c.route(to: .server(c.editor.servers[index].id), tab: .connection)
        #expect(button.isEnabled, "unsaved new server")
        #expect(!button.isHiddenOrHasHiddenAncestor)
    }

    @Test func applyButtonCommitsAndRefreshesControls() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        var applied = 0
        c.onApplied = { _ in applied += 1 }
        let field = try #require(c.form.controls[.downloadDir]?.first as? NSTextField)
        type("/data/new destination", into: field, c)
        c.applySettings(nil)
        try await waitUntil { c.form.session?.editor?.isDirty == false && !c.working }
        #expect(await service.writes == [[.downloadDir: .string("/data/new destination")]])
        #expect(field.stringValue == "/data/new destination")
        #expect(c.window?.isDocumentEdited == false)
        #expect(applied == 1)
    }

    @Test func returnAndEscapeNeverApplyOrRevert() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        #expect(c.applyButton.keyEquivalent.isEmpty)
        #expect(c.revertButton.keyEquivalent.isEmpty)
        type("/data/typed", into: try #require(c.form.controls[.downloadDir]?.first as? NSTextField), c)
        let window = try #require(c.window)
        for key in ["\r", "\u{1b}"] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: key == "\r" ? 36 : 53))
            #expect(!window.performKeyEquivalent(with: event))
        }
        #expect(await service.writes.isEmpty)
        #expect(c.form.session?.editor?.text(.downloadDir) == "/data/typed")
    }

    @Test func applyWritesTheServerBeforeSavingPresetsAndAFailureKeepsBoth() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        var saved: [AppConfig] = []
        c.onChange = { saved.append($0) }
        c.selectTab(.speed)
        c.connectionPane.downPresetsField.stringValue = "11, 22"
        c.connectionPane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                           object: c.connectionPane.downPresetsField))
        type("250", into: try #require(c.form.controls[.down]?.first as? NSTextField), c)

        await service.configure(rejectWrite: true)
        c.applySettings(nil)
        try await waitUntil { !c.working }
        #expect(saved.isEmpty, "nothing is saved on this Mac when the server write fails")
        #expect(c.editor.isServerDirty(Self.server.id))
        #expect(c.form.session?.editor?.text(.down) == "250")
        #expect(c.statusLabel.textColor == .systemRed)

        await service.configure()
        try await c.form.session?.load()   // the failed write requires a reload
        type("250", into: try #require(c.form.controls[.down]?.first as? NSTextField), c)
        c.applySettings(nil)
        try await waitUntil { !c.working && !saved.isEmpty }
        #expect(await service.writes.last == [.down: .int(250)])
        #expect(saved.last?.servers.first?.downSpeedPresets == [11, 22])
        #expect(!c.isDirty(Self.server.id))
    }

    @Test func layoutAllTabsInLightAndDarkAtMinimumSize() async throws {
        let c = try await controller()
        let window = try #require(c.window)
        window.setContentSize(NSSize(width: 760, height: 560))
        for group in c.form.groupViews.values { group.setExpanded(true) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for pane in ServerOption.Pane.allCases {
                c.selectTab(.init(pane))
                let content = try #require(window.contentView)
                content.layoutSubtreeIfNeeded()
                for field in ServerOption.definitions where field.pane == pane {
                    for control in c.form.controls[field.key] ?? [] where !control.isHiddenOrHasHiddenAncestor {
                        #expect(control.bounds.width > 10)
                        #expect(control.bounds.height > 10)
                        #expect(!control.hasAmbiguousLayout)
                    }
                }
            }
        }
    }

    @Test func trackerEditorExposesNativeTextAccessibilityAndKeepsMultilineDraft() async throws {
        let c = try await controller()
        let area = try #require(c.form.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        #expect(area.accessibilityRole() == .group)
        #expect(area.accessibilityChildren()?.first as? NSTextView === area.textView)
        area.textView.string = "https://tracker.invalid/one\n\nudp://tracker.invalid:80/two"
        area.textDidChange(Notification(name: NSText.didChangeNotification, object: area.textView))
        #expect(c.form.session?.editor?.text(.defaultTrackers) == area.textView.string)
        #expect(c.form.session?.editor?.isDirty == true)
    }

    /// Replaces `enteringAdvancedDoesNotAutomaticallyFocusTrackers`: that test
    /// expected the next key view after the section picker to be the tracker
    /// editor, but the key loop reached a button first (it failed before this
    /// change). Default trackers now starts collapsed, so the premise changed.
    @Test func advancedTabStartsWithTrackersCollapsedAndFocusesNothing() async throws {
        let c = try await controller()
        let window = try #require(c.window)
        let area = try #require(c.form.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        c.showWindow(nil)
        defer { window.orderOut(nil) }
        c.selectTab(.advanced)
        #expect(!(window.firstResponder is NSTextView))
        #expect(c.form.groupViews["Default trackers"]?.isExpanded == false)
        #expect(c.form.groupViews["Server scripts"]?.isExpanded == false)
        #expect(c.form.groupViews["Performance"]?.isExpanded == true)
        #expect(area.isHiddenOrHasHiddenAncestor)
        c.form.reveal(.defaultTrackers)
        #expect(!area.isHiddenOrHasHiddenAncestor)
        // Explicitly focusing the editor permits ordinary keyboard editing.
        #expect(window.makeFirstResponder(area.textView))
        c.selectTab(.transfers)
        c.selectTab(.advanced)
        #expect(window.firstResponder !== area.textView)
    }

    @Test func invalidTrackersExpandTheirGroupAndReceiveFocusWithoutWriting() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let window = try #require(c.window)
        let area = try #require(c.form.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        c.showWindow(nil)
        defer { window.orderOut(nil) }
        c.form.session?.set(.defaultTrackers, text: "not a tracker URL")
        c.applySettings(nil)
        try await waitUntil { window.firstResponder === area.textView }
        #expect(c.selectedTab == .advanced)
        #expect(c.form.groupViews["Default trackers"]?.isExpanded == true)
        #expect(c.form.session?.editor?.isDirty == true)
        #expect(await service.writes.isEmpty)
    }

    @Test func tabPickerPreservesDraftsAndTracksSelection() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        #expect(c.tabView.tabViewType == .noTabsNoBorder)
        #expect(c.tabPicker.segmentCount == 5)
        c.form.session?.set(.downloadDir, text: "/data/unsaved")
        c.tabPicker.selectedSegment = 4
        #expect(c.tabPicker.sendAction(c.tabPicker.action!, to: c.tabPicker.target))
        #expect(c.tabView.selectedTabViewItem?.label == "Advanced")
        #expect(c.window?.firstResponder !== c.tabPicker)
        c.selectTab(.network)
        #expect(c.tabPicker.selectedSegment == 3)
        #expect(c.form.session?.editor?.text(.downloadDir) == "/data/unsaved")
        #expect(await service.writes.isEmpty)
    }

    @Test func eachServerRemembersItsTab() async throws {
        let other = ServerConfig(name: "Other", host: "127.0.0.2", port: 1, useHTTPS: false, rpcPath: "/r")
        let c = try await controller(servers: [Self.server, other])
        c.selectTab(.network)
        c.route(to: .server(other.id), tab: .speed)
        #expect(c.selectedTab == .speed)
        #expect(!c.notActiveLabel.isHidden || c.activeServerID() == nil)
        c.route(to: .server(Self.server.id))
        #expect(c.selectedTab == .network)
        c.route(to: .general)
        #expect(c.window?.title == "Settings")
    }

    @Test func offlineServerBlocksServerTabsButKeepsPresetsEditable() async throws {
        let c = try await controller(failing: true)
        let id = Self.server.id
        #expect(c.remote[id]?.load == .failed("Connection refused."))
        c.selectTab(.speed)
        let blocker = try #require(c.form.paneViews[.speed].flatMap { find(SettingsBlockerView.self, in: $0) })
        #expect(!blocker.isHidden)
        #expect(blocker.message.stringValue.contains("Can’t reach Isolated test server"))
        #expect(!blocker.retryButton.isHidden)
        #expect(c.form.groupViews["Speed limits"]?.isHidden == true)
        #expect(c.form.groupViews["Menu presets"]?.isHidden == false)
        #expect(c.connectionPane.downPresetsField.isEnabled)

        // Retry with a working server unblocks the tab.
        let service = OptionsStub()
        c.serviceProvider = { _ in .init(service: service, endpoint: "http://127.0.0.1:19091") }
        blocker.retryButton.performClick(nil)
        try await waitUntil { c.remote[id]?.load == .loaded }
        #expect(blocker.isHidden)
        #expect(c.form.groupViews["Speed limits"]?.isHidden == false)
        #expect(c.stateLabel.stringValue.contains("Connected"))
    }

    @Test func unsavedNewServerAsksToApplyTheConnectionFirst() async throws {
        let c = try await controller()
        let index = c.editor.addServer()
        let id = c.editor.servers[index].id
        c.sidebar.reloadData()
        c.route(to: .server(id), tab: .transfers)
        let blocker = try #require(c.form.paneViews[.transfers].flatMap { find(SettingsBlockerView.self, in: $0) })
        #expect(!blocker.isHidden)
        #expect(blocker.message.stringValue.hasPrefix("Apply the connection first"))
        #expect(c.applyButton.isEnabled)   // a new server is itself an unsaved edit
        #expect(c.remote[id] == nil)       // nothing to connect to yet
    }

    @Test func speedLimitsChangedFromTheMenuFollowUneditedFields() async throws {
        let c = try await controller()
        let field = try #require(c.form.controls[.down]?.first as? NSTextField)
        c.sessionObserved(SessionInfo(version: "4", speedLimitDown: 4321), serverID: Self.server.id)
        #expect(field.stringValue == "4321")
        #expect(!c.isDirty(Self.server.id))
        type("5", into: try #require(c.form.controls[.up]?.first as? NSTextField), c)
        c.sessionObserved(SessionInfo(version: "4", speedLimitDown: 1, speedLimitUp: 9), serverID: Self.server.id)
        #expect(field.stringValue == "4321")
        #expect(c.statusLabel.stringValue.contains("changed on the server"))
    }

    @Test func clickingFormBackgroundEndsEditingWithoutSavingOrLosingDraft() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let window = try #require(c.window)
        c.showWindow(nil)
        defer { window.orderOut(nil) }
        let field = try #require(c.form.controls[.downloadDir]?.first as? NSTextField)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        editor.string = "/data/unsaved edit"
        c.form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        // A genuine mouse event over blank header space, not a direct focus call.
        let blank = c.serverView.convert(NSPoint(x: c.serverView.bounds.maxX - 3, y: c.serverView.bounds.maxY - 4), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: blank,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(click)
        #expect(window.firstResponder !== editor)
        #expect(field.stringValue == "/data/unsaved edit")
        #expect(c.form.session?.editor?.text(.downloadDir) == "/data/unsaved edit")
        #expect(await service.writes.isEmpty)
    }

    // xctest is a background-only tool and cannot become the key application.
    // Exercise real native key handling in the standalone AppKit test runner;
    // scripts/test-server-options.sh runs this same test with an active window.
    @Test(.enabled(if: ProcessInfo.processInfo.processName != "xctest",
                   "Requires a foreground AppKit host; run scripts/test-server-options.sh"))
    func keyboardSelectionKeepsNativeKeyboardFocus() async throws {
        let c = try await controller()
        let window = try #require(c.window)
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        c.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); NSApp.setActivationPolicy(policy) }
        for _ in 0..<50 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(NSApp.isActive)
        #expect(window.isKeyWindow)
        c.selectTab(.advanced)
        #expect(window.makeFirstResponder(c.tabPicker))
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123))
        c.tabPicker.keyDown(with: left)
        // Native segmented controls move focus with arrows and activate with Space.
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        c.tabPicker.keyDown(with: space)
        #expect(c.tabPicker.selectedSegment == 3)
        #expect(c.tabView.selectedTabViewItem?.label == "Network")
        #expect(window.firstResponder === c.tabPicker)
        #expect(!c.tabPicker.isKeyboardSelection)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView { return find(type, in: doc) }
        return nil
    }
}
