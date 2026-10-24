import AppKit

/// Speed-limit control: the toolbar pull-down beside the server switcher and the
/// matching submenu in the Server menu. Both render `SpeedMenuModel`, so they
/// can't disagree. The limits live on the daemon (`session-set`); only the preset
/// lists are per-server client settings.
extension MainWindowController {
    /// Builds the menu for the active server's current session. Items are
    /// disabled until the first handshake provides a session.
    func makeSpeedLimitsMenu() -> NSMenu {
        let menu = NSMenu(title: "Speed Limits")
        menu.autoenablesItems = false
        let session = refresh.session

        if let session {
            for group in SpeedMenuModel.groups(session: session, server: refresh.activeServerConfig) {
                if group.inline {
                    for entry in group.entries { menu.addItem(speedItem(for: entry)) }
                    continue
                }
                if group.title == "Turtle Download Limit" { menu.addItem(.separator()) }
                let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: group.title)
                sub.autoenablesItems = false
                for entry in group.entries { sub.addItem(speedItem(for: entry)) }
                parent.submenu = sub
                menu.addItem(parent)
            }
            menu.addItem(.separator())
        } else {
            let waiting = menu.addItem(withTitle: "Connecting…", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(.separator())
        }
        let edit = menu.addItem(withTitle: "Edit Presets…", action: #selector(editSpeedPresets(_:)), keyEquivalent: "")
        edit.target = self
        edit.isEnabled = true
        return menu
    }

    private func speedItem(for entry: SpeedMenuEntry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(speedMenuItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.action
        item.state = entry.checked ? .on : .off
        item.isEnabled = true
        return item
    }

    @objc func speedMenuItemChosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SpeedMenuAction else { return }
        if action == .editPresets { editSpeedPresets(sender); return }
        Task { @MainActor in
            let error = await refresh.updateSession { client in
                switch action {
                case .setLimit(let dir, let kbps): try await client.setSpeedLimit(dir, kbps: kbps)
                case .setTurtleLimit(let dir, let kbps): try await client.setAltSpeed(dir, kbps: kbps)
                case .setTurtleEnabled(let on): try await client.setAltSpeedEnabled(on)
                case .editPresets: break
                }
            }
            if let error { showToast("Speed limit change failed: \(error)") }
        }
    }

    @objc func editSpeedPresets(_ sender: Any?) {
        onEditPresets?()
    }

    func makeSpeedLimitsItem(identifier: NSToolbarItem.Identifier, live: Bool) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "Speed Limits"
        item.isBordered = true
        item.showsIndicator = true
        item.menu = makeSpeedLimitsMenu()
        item.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Speed Limits")
        if live {
            speedLimitsItem = item
            updateSpeedLimitsItem()
        }
        return item
    }

    /// Refresh the toolbar item's menu, icon, and tooltip from the current session.
    func updateSpeedLimitsItem() {
        guard let item = speedLimitsItem else { return }
        item.menu = makeSpeedLimitsMenu()
        let session = refresh.session
        let symbol: String
        if session?.isTurtleOn == true {
            symbol = "tortoise.fill"
        } else if let limits = session?.normalLimits, limits.down != nil || limits.up != nil {
            symbol = "gauge.with.needle.fill"
        } else {
            symbol = "speedometer"
        }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Speed Limits")
            ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Speed Limits")
        if toolbarLayout.showsToolTips {
            item.toolTip = speedSummary(session)
        } else {
            item.toolTip = nil
        }
    }

    /// "Speed limits — ↓ 500 KB/s  ↑ unlimited" (turtle noted when active).
    func speedSummary(_ session: SessionInfo?) -> String {
        guard let session else { return "Speed Limits" }
        let l = session.effectiveLimits
        func text(_ v: Int?) -> String { v.map { SpeedPresets.label(kbps: $0) } ?? "unlimited" }
        let mode = session.isTurtleOn ? "Turtle mode — " : "Speed limits — "
        return "\(mode)↓ \(text(l.down))  ↑ \(text(l.up))"
    }
}
