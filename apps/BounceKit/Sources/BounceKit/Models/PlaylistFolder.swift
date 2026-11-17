import Foundation
import SwiftData

@Model
public final class PlaylistFolder {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date = Date.now
    /// Tombstone: see `Playlist.isSoftDeleted`.
    /// Named `isSoftDeleted` to avoid shadowing SwiftData's `PersistentModel.isDeleted`.
    @Attribute(originalName: "isDeleted")
    public var isSoftDeleted: Bool = false

    @Relationship(deleteRule: .cascade)
    public var playlists: [Playlist]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.playlists = []
    }
}
