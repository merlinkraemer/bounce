import Foundation
import SwiftData

extension Track {
    /// Soft-delete a note so its tombstone can sync across devices.
    /// Bumps `updatedAt` so list views reorder correctly.
    public func removeNote(_ note: Note, in context: ModelContext) {
        note.isSoftDeleted = true
        note.updatedAt = .now
        updatedAt = .now
        try? context.save()
    }
}
