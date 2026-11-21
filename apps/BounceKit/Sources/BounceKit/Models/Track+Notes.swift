import Foundation
import SwiftData

extension Track {
    public var firstVersion: Version? {
        versions.min(by: { $0.addedAt < $1.addedAt })
    }

    /// Notes saved without a version belong to the first (oldest) version.
    public func owningVersionID(of note: Note) -> UUID? {
        note.versionID ?? firstVersion?.id
    }

    public func visibleNotes(forVersion versionID: UUID?) -> [Note] {
        let legacyOwnerID = firstVersion?.id
        return notes.filter { note in
            !note.isSoftDeleted && (note.versionID ?? legacyOwnerID) == versionID
        }
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
