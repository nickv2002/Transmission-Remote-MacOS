import AppKit

/// The Info tab's piece map (`PieceMapView`, the row above the info grid):
/// the legacy app's "Downloaded" bar — classic progress plus a map of which
/// pieces the daemon has.
///
/// The bitfield is fetched on demand per selected torrent, like the Peers tab:
/// only while the Info tab is visible and exactly one torrent is selected,
/// refreshed on each poll. The classic bar and percentage come from the list
/// poll itself (`updatePieceMap`, called from `updateDetail`), so they track
/// progress even before the bitfield arrives.
extension MainWindowController {
    /// Refresh the piece map's bitfield for the current main-table selection.
    /// Cheap to call on every poll, selection change, and tab switch — mirrors
    /// `loadPeersIfNeeded`.
    func loadPiecesIfNeeded() {
        let isInfoTabVisible = detailTabView.selectedTabViewItem?.identifier as? String == "info"
        let selection = selectedTorrents
        guard PieceMapView.isActive(enabled: showPieceMap, infoTabVisible: isInfoTabVisible,
                                    selectionCount: selection.count),
              let torrent = selection.first else {
            if piecesTorrentId != nil || pieces != nil {
                piecesFetchTask?.cancel()
                piecesTorrentId = nil
                pieces = nil
                updatePieceMap()
            }
            return
        }

        // Changed torrent: drop the stale map immediately so we don't show
        // another torrent's pieces while the new ones load.
        if piecesTorrentId != torrent.id {
            piecesTorrentId = torrent.id
            pieces = nil
            updatePieceMap()
        }

        guard let client = refresh.activeClient else { return }
        let id = torrent.id
        piecesFetchTask?.cancel()
        piecesFetchTask = Task { @MainActor in
            do {
                let fetched = try await client.fetchPieces(id: id)
                guard !Task.isCancelled, self.piecesTorrentId == id else { return }
                self.pieces = fetched
                self.updatePieceMap()
            } catch {
                // Silent: the list poll surfaces connection errors already.
            }
        }
    }

    /// Push the selected torrent's progress (from the list poll) and its
    /// fetched bitfield (if it belongs to that torrent) into the row; collapse
    /// it for an empty or multi-torrent selection.
    func updatePieceMap() {
        guard PieceMapView.isActive(enabled: showPieceMap, infoTabVisible: true,
                                    selectionCount: selectedTorrents.count),
              let t = selectedTorrents.first else {
            pieceMap.update(progress: nil, pieces: nil, color: .controlAccentColor)
            return
        }
        pieceMap.update(progress: t.displayProgress,
                        pieces: piecesTorrentId == t.id ? pieces : nil,
                        color: progressColor(for: t))
    }
}
