import AppKit

/// The Connection tab's custom-headers editor: a two-column table (Name, and
/// Value in a secure field) with +/− buttons beneath, like the Settings sidebar.
///
/// Edits update the model and report through `onChange` on every keystroke.
/// The table is reloaded only when rows are added, removed or loaded, never
/// mid-edit (which would end the edit). A row whose name is invalid is tinted
/// red with the problem as its tooltip; the form controller blocks Apply on
/// `validationError`.
@MainActor
final class CustomHeadersTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onChange: (([CustomHeader]) -> Void)?

    private(set) var headers: [CustomHeader] = []
    let tableView = HeadersTableView()
    let addButton = NSButton()
    let removeButton = NSButton()
    private(set) var view = NSView()

    private static let nameColumn = NSUserInterfaceItemIdentifier("header-name")
    private static let valueColumn = NSUserInterfaceItemIdentifier("header-value")

    var isEnabled = true {
        didSet {
            tableView.isEnabled = isEnabled
            addButton.isEnabled = isEnabled
            updateRemoveButton()
        }
    }

    override init() {
        super.init()
        view = build()
    }

    private func build() -> NSView {
        for (id, title, width) in [(Self.nameColumn, "Name", 175.0), (Self.valueColumn, "Value", 105.0)] {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.onDelete = { [weak self] in self?.removeHeaders() }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 19
        tableView.setAccessibilityIdentifier("server-headers-table")
        tableView.setAccessibilityLabel("Custom headers")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .smallSquare
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add header")
        addButton.target = self
        addButton.action = #selector(addHeader)
        addButton.setAccessibilityIdentifier("server-headers-add")
        removeButton.bezelStyle = .smallSquare
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove header")
        removeButton.target = self
        removeButton.action = #selector(removeHeaders)
        removeButton.setAccessibilityIdentifier("server-headers-remove")
        removeButton.isEnabled = false

        let container = NSView()
        for v in [scroll, addButton, removeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 300),
            scroll.heightAnchor.constraint(equalToConstant: 92),
            addButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -1),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: -1),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Show `headers` (on load or Revert). Ends any edit in progress.
    func load(_ headers: [CustomHeader]) {
        self.headers = headers
        tableView.reloadData()
        updateRemoveButton()
    }

    /// The first problem as a message, or nil when every row is valid.
    var validationError: String? { HeaderValidation.validationMessage(for: headers) }

    // MARK: - Add / remove

    @objc func addHeader() {
        headers.append(CustomHeader(name: "", value: ""))
        let row = headers.count - 1
        tableView.reloadData()
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        if tableView.window != nil {
            tableView.editColumn(tableView.column(withIdentifier: Self.nameColumn), row: row, with: nil, select: true)
        }
        onChange?(headers)
    }

    @objc func removeHeaders() {
        let rows = tableView.selectedRowIndexes.filteredIndexSet { headers.indices.contains($0) }
        guard !rows.isEmpty else { return }
        tableView.window?.makeFirstResponder(nil)   // end an edit in a row about to go
        for row in rows.reversed() { headers.remove(at: row) }
        tableView.reloadData()
        updateRemoveButton()
        onChange?(headers)
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = isEnabled && !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { headers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, headers.indices.contains(row) else { return nil }
        let isValue = id == Self.valueColumn
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HeaderCellView)
            ?? makeCell(identifier: id, secure: isValue)
        cell.textField?.stringValue = isValue ? headers[row].value : headers[row].name
        if !isValue { tint(cell, row: row) }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, secure: Bool) -> HeaderCellView {
        let field = secure ? NSSecureTextField() : NSTextField()
        field.identifier = identifier
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = secure ? "value" : "X-Header-Name"
        field.delegate = self
        field.setAccessibilityLabel(secure ? "Header value" : "Header name")
        return HeaderCellView(identifier: identifier, field: field)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateRemoveButton() }

    /// Per keystroke: update just this row's model (and its tint), no reload.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        guard headers.indices.contains(row) else { return }
        if field.identifier == Self.valueColumn {
            headers[row].value = field.stringValue
        } else {
            headers[row].name = field.stringValue
        }
        retintNames()
        onChange?(headers)
    }

    /// Validity of one name can depend on the others (duplicates), so recheck all visible rows.
    private func retintNames() {
        let column = tableView.column(withIdentifier: Self.nameColumn)
        guard column >= 0 else { return }
        for row in headers.indices {
            if let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? HeaderCellView {
                tint(cell, row: row)
            }
        }
    }

    private func tint(_ cell: HeaderCellView, row: Int) {
        let issue = HeaderValidation.issue(at: row, in: headers)
        // An empty name on a just-added row isn't flagged red; the status line
        // still says what's missing.
        cell.isFlagged = issue != nil && issue != .emptyName
        cell.textField?.toolTip = issue.map { HeaderValidation.message(for: $0, name: headers[row].name) }
    }
}

/// One header table cell: a borderless text field filling the cell. An invalid
/// name is drawn red, except on a selected row with the emphasized (accent)
/// highlight, where red would be unreadable; there it follows the row's
/// selected-text color like every other cell, and the tooltip and status line
/// still give the reason. The row view sets `backgroundStyle` whenever the
/// selection or its emphasis changes, so the color tracks both.
final class HeaderCellView: NSTableCellView {
    var isFlagged = false { didSet { if isFlagged != oldValue { updateColor() } } }

    init(identifier: NSUserInterfaceItemIdentifier, field: NSTextField) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        textField?.textColor = isFlagged && backgroundStyle != .emphasized ? .systemRed : .controlTextColor
    }
}

/// The headers table, where Delete and Forward Delete remove the selected rows
/// like any Mac list (outside a cell edit, which keeps those keys for text).
final class HeadersTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.unicodeScalars.first.map({ $0.value == 0x7F || $0.value == 0xF728 }) == true,
           !selectedRowIndexes.isEmpty {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}
