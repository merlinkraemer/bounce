import Foundation
import SwiftData

@Model
public final class Playlist {
    public var id: UUID
    public var name: String
    public var sortIndex: Int?
    public var coverImagePath: String?
    @Attribute(.externalStorage)
    public var coverImageData: Data?
    /// Cheap change signal for `coverImageData`, stored so manifest builds and
    /// sync comparisons never fault the blob. Nil = no cover. Kept in lockstep
    /// with the bytes via `setCoverImage(_:)`; lazily backfilled from the bytes
    /// for rows that predate this property (see `resolvedCoverRevision()`).
    public var coverRevision: Int64?
    public var artist: String?
    public var playlistDescription: String?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Tombstone flag. Named `isSoftDeleted` to avoid shadowing
    /// SwiftData's `PersistentModel.isDeleted` which triggers real deletion.
    @Attribute(originalName: "isDeleted")
    public var isSoftDeleted: Bool = false

    /// Frozen/released flag. Surfaced in the Mac Releases grid.
    public var isReleased: Bool = false

    @Relationship(deleteRule: .cascade)
    public var entries: [PlaylistEntry]

    @Relationship(deleteRule: .nullify)
    public var folder: PlaylistFolder?

    public init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int? = nil,
        coverImagePath: String? = nil,
        coverImageData: Data? = nil,
        artist: String? = nil,
        playlistDescription: String? = nil,
        notes: String? = nil,
        isReleased: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.coverImagePath = coverImagePath
        self.coverImageData = coverImageData
        self.coverRevision = LibraryManifest.artworkRevision(for: coverImageData)
        self.artist = artist
        self.playlistDescription = playlistDescription
        self.notes = notes
        self.isReleased = isReleased
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = []
    }

    /// Single write path for cover bytes — keeps `coverRevision` in lockstep
    /// so sync never needs to fault the blob to detect a change.
    /// Deliberately does not touch `updatedAt`: sync-applied covers must not
    /// look like fresh local edits (last-write-wins would ping-pong).
    public func setCoverImage(_ data: Data?) {
        coverImageData = data
        coverRevision = LibraryManifest.artworkRevision(for: data)
    }

    /// Returns the stored cover revision, deriving (and persisting) it from the
    /// bytes for legacy rows that predate `coverRevision`. Cleared covers always
    /// report nil because `setCoverImage(nil)` nils both fields.
    public func resolvedCoverRevision() -> Int64? {
        if let coverRevision { return coverRevision }
        guard coverImageData != nil else { return nil }
        let revision = LibraryManifest.artworkRevision(for: coverImageData)
        coverRevision = revision
        return revision
    }
}
