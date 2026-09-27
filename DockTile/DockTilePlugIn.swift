import AppKit

/// Loaded by the Dock (not the app) via the app's `NSDockTilePlugIn` Info.plist
/// key, so the freeform icon survives the app quitting. macOS 26+ masks a
/// non-squircle bundle icon into a gray squircle ("squircle jail"); a tile
/// `contentView` drawn from raw pixels isn't masked. Not allowed on the Mac App
/// Store — fine for our Developer ID distribution.
@objc(TRDockTilePlugIn)
final class DockTilePlugIn: NSObject, NSDockTilePlugIn {
    func setDockTile(_ dockTile: NSDockTile?) {
        // nil means the tile was removed from the Dock; nothing to tear down.
        guard let dockTile else { return }
        let url = Bundle(for: DockTilePlugIn.self).url(forResource: "DockIcon", withExtension: "png")
        // The protocol isn't main-actor annotated, so hop rather than assume.
        nonisolated(unsafe) let tile = dockTile
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let url, let image = NSImage(contentsOf: url) else { return }
                let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
                view.image = image
                view.imageScaling = .scaleProportionallyUpOrDown
                tile.contentView = view
                tile.display()
            }
        }
    }
}
