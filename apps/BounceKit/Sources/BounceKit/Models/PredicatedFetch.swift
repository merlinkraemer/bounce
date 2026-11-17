import Foundation
import SwiftData

public extension ModelContext {
    /// Fetches a single row by id with a predicated, `fetchLimit = 1` query —
    /// use this instead of `fetch(FetchDescriptor<T>())?.first(where: { $0.id == id })`,
    /// which materializes (and faults) the entire table just to find one row.
    ///
    /// Deliberately NOT generic: SwiftData's `#Predicate` macro is unreliable
    /// inside a function generic over the model type — it can miscompile and
    /// trap at runtime (SIGTRAP deep in CoreData's predicate translation)
    /// instead of throwing a catchable error. One concrete overload per type
    /// keeps the macro expansion bound to a real, non-generic model type.
    func fetchByID(_ type: Track.Type, id: UUID) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func fetchByID(_ type: Version.Type, id: UUID) -> Version? {
        var descriptor = FetchDescriptor<Version>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func fetchByID(_ type: Playlist.Type, id: UUID) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func fetchByID(_ type: PlaylistFolder.Type, id: UUID) -> PlaylistFolder? {
        var descriptor = FetchDescriptor<PlaylistFolder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}
