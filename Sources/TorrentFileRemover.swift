import Foundation

/// Remove a successfully-added `.torrent` file from disk, either by moving it to
/// the Trash (recoverable) or deleting it permanently, per the user's choice.
/// Foundation-only so it's unit-testable without AppKit.
func removeTorrentFile(at url: URL, method: TorrentFileRemoval) throws {
    switch method {
    case .trash:
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    case .delete:
        try FileManager.default.removeItem(at: url)
    }
}
