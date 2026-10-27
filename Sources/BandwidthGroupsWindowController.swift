import AppKit

@MainActor
final class BandwidthGroupsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let session: BandwidthGroupSession
    var onClose: (() -> Void)?
    let groupPicker = NSPopUpButton()
    let nameField = NSTextField()
    private(set) var controls: [BandwidthGroup.Field: NSControl] = [:]
    private let saveButton = NSButton(title: "Apply Group", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let newButton = NSButton(title: "New Group", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Loading bandwidth groups…")
    private var working = false

    init(serverName: String, service: any ServerOptionsService) {
        session = BandwidthGroupSession(service: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Bandwidth Groups — \(serverName)"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
        groupPicker.target = self
        groupPicker.action = #selector(selectGroup(_:))
        groupPicker.setAccessibilityLabel("Bandwidth group")
        groupPicker.setAccessibilityIdentifier("bandwidth-group-picker")
        stack.addArrangedSubview(groupPicker)
        groupPicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        nameField.delegate = self
        nameField.placeholderString = "New group name"
        nameField.setAccessibilityLabel("Group name")
        nameField.setAccessibilityIdentifier("bandwidth-group-name")
        stack.addArrangedSubview(nameField)
        nameField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for field in BandwidthGroup.Field.allCases {
            let control: NSControl
            if field.isBoolean {
                control = NSButton(checkboxWithTitle: field.title, target: self, action: #selector(edit(_:)))
                stack.addArrangedSubview(control)
            } else {
                let label = NSTextField(labelWithString: field.title + ":")
                let input = NSTextField()
                input.delegate = self
                input.widthAnchor.constraint(equalToConstant: 120).isActive = true
                let row = NSStackView(views: [label, input])
                row.spacing = 12
                stack.addArrangedSubview(row)
                control = input
            }
            control.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            control.setAccessibilityIdentifier("bandwidth-group-\(field.rawValue)")
            control.setAccessibilityLabel(field.title)
            controls[field] = control
        }
        let note = NSTextField(wrappingLabelWithString: "Assign torrents using Bandwidth Group… in the Torrent menu. Transmission does not provide group deletion or renaming through RPC.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let buttons = NSStackView(views: [newButton, reloadButton, saveButton])
        for (button, selector) in [(newButton, #selector(newGroup(_:))), (reloadButton, #selector(reload(_:))), (saveButton, #selector(save(_:)))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = selector
        }
        saveButton.keyEquivalent = "\r"
        stack.addArrangedSubview(buttons)
        window.contentView = root
        updateEnabled()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadGroups() {
        performOperation("Loading bandwidth groups…") { [self] in
            try await session.load()
            render()
            return "Changes apply only when you click Apply Group."
        }
    }
    func render() {
        groupPicker.removeAllItems()
        groupPicker.addItems(withTitles: session.groups.map(\.name))
        if let group = session.editor.baseline { groupPicker.selectItem(withTitle: group.name) }
        else { groupPicker.addItem(withTitle: "New group (unsaved)"); groupPicker.selectItem(at: groupPicker.numberOfItems - 1) }
        nameField.stringValue = session.editor.name
        for (field, control) in controls {
            if let button = control as? NSButton { button.state = session.editor.draft[field] == "true" ? .on : .off }
            else { control.stringValue = session.editor.draft[field] ?? "" }
        }
        updateEnabled()
    }
    private func updateEnabled() {
        groupPicker.isEnabled = !working && !session.needsReload
        nameField.isEnabled = !working && !session.needsReload && session.editor.baseline == nil
        for (field, control) in controls {
            let toggle: BandwidthGroup.Field? = field == .down ? .downEnabled : field == .up ? .upEnabled : nil
            control.isEnabled = !working && !session.needsReload && (toggle.map { session.editor.draft[$0] == "true" } ?? true)
        }
        saveButton.isEnabled = !working && !session.needsReload && session.editor.isDirty
        reloadButton.isEnabled = !working
        newButton.isEnabled = !working && !session.needsReload
        window?.isDocumentEdited = session.editor.isDirty
    }
    @objc private func edit(_ sender: NSControl) {
        guard !working, let raw = sender.identifier?.rawValue, let field = BandwidthGroup.Field(rawValue: raw) else { return }
        session.editor.draft[field] = (sender as? NSButton).map { $0.state == .on ? "true" : "false" } ?? sender.stringValue
        updateEnabled()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !working, let field = notification.object as? NSTextField else { return }
        if field === nameField { session.editor.name = field.stringValue; updateEnabled() }
        else { edit(field) }
    }
    @objc private func selectGroup(_ sender: Any?) {
        let index = groupPicker.indexOfSelectedItem
        guard session.groups.indices.contains(index) else { return }
        guard confirmDiscard() else { render(); return }
        session.select(session.groups[index])
        render()
    }
    @objc private func newGroup(_ sender: Any?) {
        guard confirmDiscard() else { return }
        session.select(nil)
        render()
        window?.makeFirstResponder(nameField)
    }
    @objc private func reload(_ sender: Any?) { if confirmDiscard() { loadGroups() } }
    @objc func save(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        performOperation("Saving and verifying group…") { [self] in
            try await session.save()
            render()
            return "Group saved and verified."
        }
    }
    private func performOperation(_ message: String, action: @escaping @MainActor () async throws -> String) {
        guard !working else { return }
        working = true
        status.stringValue = message
        status.textColor = .secondaryLabelColor
        updateEnabled()
        Task { [self] in
            do { status.stringValue = try await action() }
            catch {
                status.stringValue = error.localizedDescription + (session.needsReload ? " Reload before trying again." : "")
                status.textColor = .systemRed
            }
            working = false
            updateEnabled()
        }
    }
    private func confirmDiscard() -> Bool {
        guard !working else { return false }
        guard session.editor.isDirty || session.needsReload else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved group edits?"
        alert.informativeText = "Settings already accepted by the server remain in effect."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func canQuit() -> Bool { confirmDiscard() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
