import AppKit

/// True while `apply(toolbarLayout:)` runs. Changing the style or title can make
/// AppKit reset the display mode transiently; that must not read as a user choice.
@MainActor private var isApplyingLayout = false

/// AppKit side of `ToolbarLayout`: maps the layout onto a window and watches the
/// toolbar's own display-mode control, so both directions are unit-testable.
extension NSWindow {
    /// Title row, toolbar style, and display mode for `layout`. The style must be
    /// `.expanded` or `.unified`: `.unifiedCompact` makes AppKit drop the
    /// display-mode controls (palette *Show:* popup, right-click menu), so icon-only
    /// couldn't be undone. A hidden toolbar forces the title visible, since a hidden
    /// title with no toolbar leaves a blank bar.
    func apply(toolbarLayout layout: ToolbarLayout) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let toolbarShown = toolbar?.isVisible ?? true
        titleVisibility = layout.showsTitle || !toolbarShown ? .visible : .hidden
        toolbarStyle = layout.showsTitle ? .expanded : .unified
        toolbar?.displayMode = layout.showsLabels ? .iconAndLabel : .iconOnly
    }
}

extension NSToolbar {
    /// Report the layout implied by a *user* change to the display mode (palette
    /// popup or right-click menu). `current` is the layout already applied, so the
    /// mode writes made inside `apply(toolbarLayout:)` are ignored.
    func observeLayoutChanges(current: @escaping @MainActor () -> ToolbarLayout,
                              onChange: @escaping @MainActor (ToolbarLayout) -> Void)
        -> NSKeyValueObservation {
        observe(\.displayMode) { toolbar, _ in
            MainActor.assumeIsolated {
                guard !isApplyingLayout else { return }
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
