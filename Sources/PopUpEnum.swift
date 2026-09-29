import AppKit

/// An enum choice shown as a popup item.
protocol DisplayNamed {
    var displayName: String { get }
}

extension TorrentFileRemoval: DisplayNamed {}
extension TitleBarStyle: DisplayNamed {}

/// Popup ⇄ `CaseIterable` enum bridging, so every enum-backed popup (Settings,
/// the Add sheet) shares one index mapping instead of hand-rolling it.
extension NSPopUpButton {
    /// Replace the items with one per case, in `allCases` order.
    func configure<E: CaseIterable & DisplayNamed>(for type: E.Type) {
        removeAllItems()
        addItems(withTitles: type.allCases.map(\.displayName))
    }

    /// Select the item for `value` (the first item if it isn't a case).
    func select<E: CaseIterable & Equatable>(_ value: E) {
        selectItem(at: Array(E.allCases).firstIndex(of: value) ?? 0)
    }

    /// The case for the selected item, or `fallback` if the index is out of range.
    func selectedCase<E: CaseIterable>(default fallback: E) -> E {
        let cases = Array(E.allCases)
        let index = indexOfSelectedItem
        return cases.indices.contains(index) ? cases[index] : fallback
    }
}
