import Foundation
import SwiftData

@Model
public final class Track {
    #Index<Track>([\.lastTouchedAt])

    public var id: UUID
    public var name: String
    public var artist: String = ""
    public var createdAt: Date
    public var updatedAt: Date

    /// Embedded cover art (JPEG/PNG) extracted from audio file metadata, or
    /// user-supplied via the track edit modal. Nil = render placeholder.
    /// External storage keeps the blob out of every Track fetch — inline it
    /// made all-tracks @Query drag full artwork through SQLite per row.
    @Attribute(.externalStorage)
    public var artwork: Data?

    /// Cheap change signal for `artwork`, stored so manifest builds and sync
    /// comparisons never fault the blob. Nil = no artwork. Kept in lockstep
    /// with the bytes via `setArtwork(_:)`; lazily backfilled from the bytes
    /// for rows that predate this property (see `resolvedArtworkRevision()`).
    public var artworkRevision: Int64?

    /// Beats per minute, when extracted from ID3 BPM tag.
    public var bpm: Double?

    /// Where this track was originally created. Used for sync authority.
    public var origin: TrackOrigin {
        get { TrackOrigin(rawValue: originRaw) ?? .mac }
        set { originRaw = newValue.rawValue }
    }
    /// Stored raw value for SwiftData predicates.
    public var originRaw: String = "mac"

    /// Import processing lifecycle. Defaults to `.complete` so any existing
    /// rows from before this property existed (and any track created without
    /// going through the optimistic-import path) read as fully imported.
    public var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .complete }
        set { processingStateRaw = newValue.rawValue }
    }
    /// Stored raw value for SwiftData predicates.
    public var processingStateRaw: String = "complete"

    /// User-supplied working title for this version. Nil = use `name` (date-stem).
    /// Versions sharing a normalized `workingTitle` form a sibling group in the Songs view.
    public var workingTitle: String?

    /// User-facing title: the working title when non-empty, otherwise the
    /// original filename. Every list and editor surface renders this so a
    /// rename saved to `workingTitle` propagates to the tracklists.
    public var displayTitle: String {
        let trimmed = workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return name
    }

    /// Sibling discriminator within a working-title group (1, 2, 3…). Nil until joined.
    public var versionNumber: Int?

    /// Frozen/released flag. Surfaced in the Releases tab.
    public var isReleased: Bool = false

    /// Long-form recording flag. Surfaced in the Sets shelf independently of
    /// the release lifecycle state.
    public var isSet: Bool = false

    /// Optional recording calendar day in canonical `yyyy-MM-dd` form.
    /// This is deliberately separate from activity and version timestamps.
    public var recordingDateString: String?

    /// Most recent activity across this Track and its Versions. Used for Songs-tab sectioning.
    /// Sentinel `.distantPast` triggers one-shot backfill on first launch after migration.
    public var lastTouchedAt: Date = Date.distantPast

    @Relationship(deleteRule: .cascade)
    public var versions: [Version]

    @Relationship(deleteRule: .cascade)
    public var notes: [Note]

    public var visibleNotes: [Note] {
        notes.filter { !$0.isSoftDeleted }
    }

    public var hasVisibleNotes: Bool {
        notes.contains(where: { !$0.isSoftDeleted })
    }

    public var latestVersion: Version? {
        // max(by:) is O(n) without allocating a sorted copy on every row render.
        versions.max(by: { $0.addedAt < $1.addedAt })
    }

    public var latestVersionLabel: String {
        (latestVersion?.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var latestVersionDate: Date? {
        latestVersion?.addedAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        artist: String = "",
        artwork: Data? = nil,
        bpm: Double? = nil,
        origin: TrackOrigin = .mac,
        processingState: ProcessingState = .complete,
        workingTitle: String? = nil,
        versionNumber: Int? = nil,
        isReleased: Bool = false,
        isSet: Bool = false,
        recordingDateString: String? = nil,
        lastTouchedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artwork = artwork
        self.artworkRevision = LibraryManifest.artworkRevision(for: artwork)
        self.bpm = bpm
        self.originRaw = origin.rawValue
        self.processingStateRaw = processingState.rawValue
        self.workingTitle = workingTitle
        self.versionNumber = versionNumber
        self.isReleased = isReleased
        self.isSet = isSet
        self.recordingDateString = RecordingDate.validate(recordingDateString)
        self.lastTouchedAt = lastTouchedAt ?? updatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versions = []
        self.notes = []
    }

    public var recordingDate: Date? {
        get { RecordingDate.date(from: recordingDateString) }
        set { recordingDateString = newValue.map { RecordingDate.string(from: $0) } }
    }

    public func setRecordingDate(_ value: String?) {
        recordingDateString = RecordingDate.validate(value)
    }

    /// Single write path for artwork bytes — keeps `artworkRevision` in
    /// lockstep so sync never faults the blob to detect a change.
    /// Deliberately does not touch `updatedAt`: sync-applied artwork must not
    /// look like a fresh local edit.
    public func setArtwork(_ data: Data?) {
        artwork = data
        artworkRevision = LibraryManifest.artworkRevision(for: data)
    }

    /// Returns the stored artwork revision, deriving (and persisting) it from
    /// the bytes for legacy rows that predate `artworkRevision`. Cleared
    /// artwork always reports nil because `setArtwork(nil)` nils both fields.
    public func resolvedArtworkRevision() -> Int64? {
        if let artworkRevision { return artworkRevision }
        guard artwork != nil else { return nil }
        let revision = LibraryManifest.artworkRevision(for: artwork)
        artworkRevision = revision
        return revision
    }
}
