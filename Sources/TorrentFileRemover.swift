import Foundation

/// Remove a successfully-added `.torrent` file from disk, either by moving it to
/// the Trash (recoverable) or deleting it permanently, per the user's choice.
/// Foundation-only so it's unit-testable without AppKit. Returns the file's
/// resulting location in the Trash (`.trash`), or `nil` when permanently deleted,
/// so callers such as tests can locate and clean up the trashed copy.
@discardableResult
func removeTorrentFile(at url: URL, method: TorrentFileRemoval) throws -> URL? {
    switch method {
    case .trash:
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    case .delete:
        try FileManager.default.removeItem(at: url)
        return nil
    }
}
