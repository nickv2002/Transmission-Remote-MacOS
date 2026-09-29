import AppKit

/// True while `apply(toolbarLayout:)` runs. Changing the style or title can make
/// AppKit reset the display mode transiently; that must not read as a user choice.
@MainActor private var isApplyingLayout = false

/// AppKit side of `ToolbarLayout`: maps the layout onto a window and watches the
/// toolbar's own display-mode control, so both directions are unit-testable.
extension NSWindow {
    /// Title row, toolbar style, and display mode for `layout`. Compact must be
    /// `.unified`: `.unifiedCompact` makes AppKit drop the display-mode controls
    /// (palette *Show:* popup, right-click menu), so Compact couldn't be undone.
    func apply(toolbarLayout layout: ToolbarLayout) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        titleVisibility = layout.showsTitle ? .visible : .hidden
        toolbarStyle = layout.isCompact ? .unified : .expanded
        toolbar?.displayMode = layout.isCompact ? .iconOnly : .iconAndLabel
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
                let layout = ToolbarLayout(iconOnly: toolbar.displayMode == .iconOnly)
                if layout != current() { onChange(layout) }
            }
        }
    }
}
