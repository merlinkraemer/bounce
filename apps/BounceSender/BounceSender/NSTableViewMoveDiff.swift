import AppKit

extension NSTableView {
    /// Animates a pure permutation (same ID set, different order — e.g. a
    /// drag-reorder) with `moveRow(at:to:)` in one update batch. Returns false
    /// without touching the table when the ID sets differ or nothing moved —
    /// callers fall back to `reloadData()`.
    ///
    /// `offset` maps the ID-space indices onto table-row indices. Tables with a
    /// fixed header row (row 0) must pass `headerRow + 1`; without it the move
    /// batch would shift the header into the list.
    @discardableResult
    func applyMoves<ID: Hashable>(from oldIDs: [ID], to newIDs: [ID], offset: Int = 0) -> Bool {
        guard oldIDs.count == newIDs.count,
              Set(oldIDs) == Set(newIDs),
              oldIDs != newIDs else { return false }

        var working = oldIDs
        beginUpdates()
        for (targetIndex, id) in newIDs.enumerated() {
            guard let currentIndex = working.firstIndex(of: id),
                  currentIndex != targetIndex else { continue }
            moveRow(at: currentIndex + offset, to: targetIndex + offset)
            working.remove(at: currentIndex)
            working.insert(id, at: targetIndex)
        }
        endUpdates()
        return true
    }
}
