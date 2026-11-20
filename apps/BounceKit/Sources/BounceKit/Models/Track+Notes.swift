import Foundation
import SwiftData

extension Track {
    /// Visible notes shown for `versionID`: the version's own notes plus legacy
    /// notes saved without a version.
    public func visibleNotes(forVersion versionID: UUID?) -> [Note] {
        notes.filter { !$0.isSoftDeleted && ($0.versionID == nil || $0.versionID == versionID) }
    }

    /// Soft-delete a note so its tombstone can sync across devices.
    /// Bumps `updatedAt` so list views reorder correctly.
    public func removeNote(_ note: Note, in context: ModelContext) {
        note.isSoftDeleted = true
        note.updatedAt = .now
        updatedAt = .now
        try? context.save()
    }
}
