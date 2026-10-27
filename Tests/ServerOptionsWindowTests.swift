import AppKit
import Testing

@Suite("Server Options native controls", .serialized)
@MainActor
struct ServerOptionsWindowTests {
    private func controller(service: OptionsStub = OptionsStub()) async throws -> ServerOptionsWindowController {
        _ = NSApplication.shared
        let server = ServerConfig(name: "Isolated test server", host: "127.0.0.1", port: 19091,
                                  useHTTPS: false, rpcPath: "/transmission/rpc")
        let controller = ServerOptionsWindowController(server: server, service: service)
        try await controller.session.load()
        controller.renderValues()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func allSettingsHaveNativeControlsAndFiveTabs() async throws {
        let c = try await controller()
        #expect(c.tabView.tabViewItems.map(\.label) == ["Download", "Network", "Bandwidth", "Queue", "Advanced"])
        #expect(Set(c.controls.keys) == Set(ServerOption.allCases))
        #expect(c.controls.keys.allSatisfy { !$0.rawValue.hasPrefix("blocklist") })
        #expect(c.controls[.scheduleDays]?.count == 7)
        #expect(c.controls[.encryption]?.first is NSPopUpButton)
        #expect(c.controls[.downloadDir]?.first is NSTextField)
        #expect(c.controls[.incompleteEnabled]?.first is NSButton)
    }

    @Test func checkboxDependenciesAndValuesStayInSync() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let toggle = try #require(c.controls[.downEnabled]?.first as? NSButton)
        #expect(c.controls[.down]?.first?.isEnabled == true)
        toggle.performClick(nil)
        #expect(c.session.editor?.flag(.downEnabled) == false)
        #expect(c.controls[.down]?.first?.isEnabled == false)
        #expect(c.controls[.down]?.first?.stringValue == "100")
        #expect(await service.writes.isEmpty)
        toggle.performClick(nil)
        #expect(c.controls[.down]?.first?.isEnabled == true)
        #expect(c.session.editor?.isDirty == false)
    }

    @Test func dayButtonsEncodeSundayAsBitZero() async throws {
        let c = try await controller()
        let days = try #require(c.controls[.scheduleDays])
        #expect(days.map(\.tag) == [1, 2, 3, 4, 5, 6, 0])
        for control in days {
            let button = try #require(control as? NSButton)
            if button.tag != 0 { button.performClick(nil) }
        }
        #expect(c.session.editor?.text(.scheduleDays) == "1")
        #expect(try c.session.editor?.patch()[.scheduleDays] == .int(1))
    }

    @Test func unsupportedControlsAreDisabled() async throws {
        let service = OptionsStub()
        await service.replace(ServerOptionsSnapshot(version: "old", values: [.downloadDir: .string("/data")]))
        let c = try await controller(service: service)
        #expect(c.controls[.downloadDir]?.first?.isEnabled == true)
        #expect(c.controls[.downEnabled]?.first?.isEnabled == false)
        #expect(c.controls[.down]?.first?.isEnabled == false)
        #expect(c.controls[.down]?.first?.toolTip == "Not supported by this server.")
    }

    @Test func newlyAvailableFieldsLoseUnavailablePlaceholderAfterReload() async throws {
        let service = OptionsStub()
        await service.replace(ServerOptionsSnapshot(version: "old", values: [.downloadDir: .string("/data")]))
        let c = try await controller(service: service)
        let path = try #require(c.controls[.addedScript]?.first as? NSTextField)
        #expect(path.placeholderString == "Unavailable")
        var available = ServerOptionsFixtures.snapshot
        available.values[.addedScript] = .string("")
        await service.replace(available)
        try await c.session.load()
        c.renderValues()
        #expect(path.isEnabled)
        #expect(path.stringValue.isEmpty)
        #expect(path.placeholderString == "/path/on/server")
        #expect(path.toolTip == nil)
    }

    @Test func typingAndSwitchingTabsDoNotSaveOrDiscard() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let field = try #require(c.controls[.downloadDir]?.first as? NSTextField)
        field.stringValue = "/data/new destination"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        c.tabView.selectTabViewItem(withIdentifier: "Network")
        c.tabView.selectTabViewItem(withIdentifier: "Download")
        #expect(c.session.editor?.text(.downloadDir) == "/data/new destination")
        #expect(field.stringValue == "/data/new destination")
        #expect(c.window?.isDocumentEdited == true)
        #expect(await service.writes.isEmpty)
    }

    @Test func applyButtonCommitsAndRefreshesControls() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let field = try #require(c.controls[.downloadDir]?.first as? NSTextField)
        field.stringValue = "/data/new destination"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        c.applyOptions(nil)
        for _ in 0..<100 {
            if c.session.editor?.isDirty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.writes == [[.downloadDir: .string("/data/new destination")]])
        #expect(field.stringValue == "/data/new destination")
        #expect(c.window?.isDocumentEdited == false)
    }

    @Test func layoutAllTabsInLightAndDarkAtMinimumSize() async throws {
        let c = try await controller()
        let window = try #require(c.window)
        window.setContentSize(NSSize(width: 680, height: 640))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for section in ServerOption.Section.allCases {
                c.tabView.selectTabViewItem(withIdentifier: section.rawValue)
                let content = try #require(window.contentView)
                content.layoutSubtreeIfNeeded()
                for field in ServerOption.definitions where field.section == section {
                    for control in c.controls[field.key] ?? [] where !control.isHiddenOrHasHiddenAncestor {
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
        let area = try #require(c.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        #expect(area.accessibilityRole() == .group)
        #expect(area.accessibilityChildren()?.first as? NSTextView === area.textView)
        area.textView.string = "https://tracker.invalid/one\n\nudp://tracker.invalid:80/two"
        area.textDidChange(Notification(name: NSText.didChangeNotification, object: area.textView))
        #expect(c.session.editor?.text(.defaultTrackers) == area.textView.string)
        #expect(c.session.editor?.isDirty == true)
    }

    @Test func enteringAdvancedDoesNotAutomaticallyFocusTrackers() async throws {
        let c = try await controller()
        let window = try #require(c.window)
        let area = try #require(c.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        c.showWindow(nil)
        defer { window.orderOut(nil) }
        c.tabView.selectTabViewItem(withIdentifier: "Advanced")
        #expect(window.firstResponder !== area.textView)
        window.recalculateKeyViewLoop()
        window.selectNextKeyView(c.sectionPicker)
        #expect(window.firstResponder === area.textView)
        // Explicitly focusing the editor must still permit ordinary keyboard editing.
        #expect(window.makeFirstResponder(area.textView))
        #expect(window.firstResponder === area.textView)
        c.tabView.selectTabViewItem(withIdentifier: "Download")
        c.tabView.selectTabViewItem(withIdentifier: "Advanced")
        #expect(window.firstResponder !== area.textView)
    }

    @Test func invalidTrackersStillReceiveValidationFocusWithoutWriting() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let window = try #require(c.window)
        let area = try #require(c.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        c.showWindow(nil)
        defer { window.orderOut(nil) }
        c.session.set(.defaultTrackers, text: "not a tracker URL")
        c.applyOptions(nil)
        for _ in 0..<100 {
            if window.firstResponder === area.textView { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.tabView.selectedTabViewItem?.label == "Advanced")
        #expect(window.firstResponder === area.textView)
        #expect(c.session.editor?.isDirty == true)
        #expect(await service.writes.isEmpty)
    }

    @Test func nativeSectionPickerPreservesDraftsAndTracksValidationSelection() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        #expect(c.tabView.tabViewType == .noTabsNoBorder)
        #expect(c.sectionPicker.segmentCount == 5)
        c.session.set(.downloadDir, text: "/data/unsaved")
        c.sectionPicker.selectedSegment = 4
        #expect(c.sectionPicker.sendAction(c.sectionPicker.action!, to: c.sectionPicker.target))
        #expect(c.tabView.selectedTabViewItem?.label == "Advanced")
        #expect(c.window?.firstResponder !== c.sectionPicker)
        c.tabView.selectTabViewItem(withIdentifier: "Network")
        #expect(c.sectionPicker.selectedSegment == 1)
        #expect(c.session.editor?.text(.downloadDir) == "/data/unsaved")
        #expect(await service.writes.isEmpty)
    }

    @Test func clickingFormBackgroundEndsEditingWithoutSavingOrLosingDraft() async throws {
        let service = OptionsStub()
        let c = try await controller(service: service)
        let window = try #require(c.window)
        let content = try #require(window.contentView)
        c.showWindow(nil)
        defer { window.orderOut(nil) }
        let field = try #require(c.controls[.downloadDir]?.first as? NSTextField)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        editor.string = "/data/unsaved edit"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        // A genuine mouse event over the outer form margin, not a direct focus call.
        let location = content.convert(NSPoint(x: 6, y: content.bounds.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(click)
        #expect(window.firstResponder !== editor)
        #expect(field.stringValue == "/data/unsaved edit")
        #expect(c.session.editor?.text(.downloadDir) == "/data/unsaved edit")
        #expect(await service.writes.isEmpty)

        c.tabView.selectTabViewItem(withIdentifier: "Advanced")
        let area = try #require(c.controls[.defaultTrackers]?.first as? ServerOptionsTextArea)
        #expect(window.makeFirstResponder(area.textView))
        area.stringValue = "https://tracker.invalid/announce"
        area.textDidChange(Notification(name: NSText.didChangeNotification, object: area.textView))
        window.sendEvent(click)
        #expect(window.firstResponder !== area.textView)
        #expect(c.session.editor?.text(.defaultTrackers) == "https://tracker.invalid/announce")
        #expect(await service.writes.isEmpty)
        // Dismissing focus does not remove the editor from ordinary keyboard access.
        #expect(window.makeFirstResponder(area.textView))
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
        c.tabView.selectTabViewItem(withIdentifier: "Advanced")
        #expect(window.makeFirstResponder(c.sectionPicker))
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123))
        c.sectionPicker.keyDown(with: left)
        // Native segmented controls move focus with arrows and activate with Space.
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        c.sectionPicker.keyDown(with: space)
        #expect(c.sectionPicker.selectedSegment == 3)
        #expect(c.tabView.selectedTabViewItem?.label == "Queue")
        #expect(window.firstResponder === c.sectionPicker)
        #expect(!c.sectionPicker.isKeyboardSelection)
    }

}
