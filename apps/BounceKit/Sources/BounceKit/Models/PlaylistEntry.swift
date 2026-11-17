import Foundation
import SwiftData

@Model
public final class PlaylistEntry {
    public var id: UUID
    public var playlistID: UUID
    public var trackID: UUID
    public var versionID: UUID?
    public var position: Int

    public init(
        id: UUID = UUID(),
        playlistID: UUID,
        trackID: UUID,
        versionID: UUID? = nil,
        position: Int
    ) {
        self.id = id
        self.playlistID = playlistID
        self.trackID = trackID
        self.versionID = versionID
        self.position = position
    }
}

public extension ModelContext {
    /// Deletes every playlist slot that references `trackID`.
    ///
    /// `PlaylistEntry.trackID` is a plain scalar rather than a cascade
    /// `@Relationship` — deliberately, because on iOS an entry legitimately
    /// points at a track that hasn't downloaded yet. The cost is that deleting a
    /// `Track` does not auto-remove the entries referencing it, leaving dangling
    /// slots that sync to iOS and render forever as "Missing track". Call this
    /// immediately before deleting a track so the removal propagates: the changed
    /// entry set alters the manifest generation fingerprint, and iOS's un-gated
    /// entry reconciliation then drops the slot.
    func removePlaylistEntries(forTrackID trackID: UUID) {
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate { $0.trackID == trackID }
        )
        guard let entries = try? fetch(descriptor) else { return }
        for entry in entries {
            delete(entry)
        }
    }
}
