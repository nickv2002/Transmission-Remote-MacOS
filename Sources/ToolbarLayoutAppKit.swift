import AppKit

extension NSWindow {
    /// The saved title and label settings own the toolbar presentation.
    func apply(toolbarLayout layout: ToolbarLayout) {
        let toolbarShown = toolbar?.isVisible ?? true
        titleVisibility = layout.showsTitle || !toolbarShown ? .visible : .hidden
        toolbarStyle = layout.showsTitle ? .expanded : .unified
        toolbar?.displayMode = layout.showsLabels ? .iconAndLabel : .iconOnly
    }
}

extension NSToolbar {
    /// Call `handler` whenever the toolbar is shown or hidden (View ▸ Show Toolbar).
    func observeVisibility(_ handler: @escaping @MainActor () -> Void) -> NSKeyValueObservation {
        observe(\.isVisible) { _, _ in MainActor.assumeIsolated { handler() } }
    }
}
