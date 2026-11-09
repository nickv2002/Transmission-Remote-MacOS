import AppKit

/// Style changes can temporarily reset AppKit's display mode. Those resets are
/// not user choices and must not overwrite the saved preference.
@MainActor private var isApplyingLayout = false

extension NSWindow {
    /// The saved title and label settings own the toolbar presentation.
    func apply(toolbarLayout layout: ToolbarLayout) {
        let wasApplying = isApplyingLayout
        isApplyingLayout = true
        defer { isApplyingLayout = wasApplying }
        let toolbarShown = toolbar?.isVisible ?? true
        titleVisibility = layout.showsTitle || !toolbarShown ? .visible : .hidden
        toolbarStyle = layout.showsTitle ? .expanded : .unified
        toolbar?.displayMode = layout.showsLabels ? .iconAndLabel : .iconOnly
    }
}

extension NSToolbar {
    /// Keep the native toolbar picker, View menu and General settings in sync.
    func observeLayoutChanges(current: @escaping @MainActor () -> ToolbarLayout,
                              onChange: @escaping @MainActor (ToolbarLayout) -> Void)
        -> NSKeyValueObservation {
        observe(\.displayMode) { toolbar, _ in
            MainActor.assumeIsolated {
                guard !isApplyingLayout else { return }
                // Normalize a legacy/programmatic Text Only selection even when
                // labels were already on, without leaving grouped controls in it.
                if toolbar.displayMode == .labelOnly {
                    toolbar.displayMode = .iconAndLabel
                    return
                }
                var layout = current()
                layout.showsLabels = toolbar.displayMode != .iconOnly
                if layout != current() { onChange(layout) }
            }
        }
    }

    /// Call `handler` whenever the toolbar is shown or hidden (View ▸ Show Toolbar).
    func observeVisibility(_ handler: @escaping @MainActor () -> Void) -> NSKeyValueObservation {
        observe(\.isVisible) { _, _ in MainActor.assumeIsolated { handler() } }
    }
}

/// AppKit exposes one switch for the entire display-mode picker. Keep that
/// picker and filter its unsupported mode when either native menu opens.
/// Match the mode tags and owning window, never localized titles or private
/// classes/selectors. If AppKit changes the menu structure, leave it untouched.
@MainActor
final class ToolbarDisplayModeMenuFilter: NSObject {
    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuWillTrack(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuWillTrack(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        hideTextOnly(in: menu)
    }

    func hideTextOnly(in menu: NSMenu) {
        guard let window, window.toolbar?.allowsDisplayModeCustomization == true else { return }
        let modes: [NSToolbar.DisplayMode] = [.iconAndLabel, .iconOnly, .labelOnly]
        let entries = modes.compactMap { mode -> NSMenuItem? in
            let matches = menu.items.filter { $0.tag == mode.rawValue && !$0.isSeparatorItem }
            return matches.count == 1 ? matches.first : nil
        }
        guard entries.count == modes.count, let action = entries.first?.action,
              entries.allSatisfy({ item in
                  item.action == action && item.submenu == nil && item.view == nil &&
                  (NSApp.target(forAction: action, to: item.target, from: item) as? NSWindow) === window
              }) else { return }

        // The palette popup contains only modes. The context menu additionally
        // offers the public window action for opening Customize Toolbar.
        let customize = #selector(NSWindow.runToolbarCustomizationPalette(_:))
        let isContextMenu = menu.items.contains {
            $0.action == customize &&
            (NSApp.target(forAction: customize, to: $0.target, from: $0) as? NSWindow) === window
        }
        guard menu.items.count == modes.count || isContextMenu else { return }
        entries.last?.isHidden = true
    }
}
