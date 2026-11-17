import CryptoKit
import Foundation

/// Sent from either device to describe available tracks/versions.
public struct LibraryManifest: Codable, Sendable {
    public var protocolVersion: Int
    public var senderID: UUID
    public var senderName: String
    public var generation: Int64
    public var generatedAt: Date
    public var originatingDevice: TrackOrigin
    public var tracks: [TrackManifestEntry]
    public var notes: [NoteManifestEntry]
    public var playlistFolders: [PlaylistFolderManifestEntry]
    public var playlists: [PlaylistManifestEntry]

    /// Protocol 6: playlist covers left the manifest — entries carry
    /// `coverRevision` and bytes move via `GET`/`POST /playlist-artwork/{id}`.
    public static let currentProtocolVersion = 6

    public init(
        protocolVersion: Int = LibraryManifest.currentProtocolVersion,
        senderID: UUID,
        senderName: String,
        generation: Int64,
        generatedAt: Date = .now,
        originatingDevice: TrackOrigin = .mac,
        tracks: [TrackManifestEntry],
        notes: [NoteManifestEntry] = [],
        playlistFolders: [PlaylistFolderManifestEntry] = [],
        playlists: [PlaylistManifestEntry] = []
    ) {
        self.protocolVersion = protocolVersion
        self.senderID = senderID
        self.senderName = senderName
        self.generation = generation
        self.generatedAt = generatedAt
        self.originatingDevice = originatingDevice
        self.tracks = tracks
        self.notes = notes
        self.playlistFolders = playlistFolders
        self.playlists = playlists
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case senderID
        case senderName
        case generation
        case generatedAt
        case originatingDevice
        case tracks
        case notes
        case playlistFolders
        case playlists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .now
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        self.senderID = try container.decode(UUID.self, forKey: .senderID)
        self.senderName = try container.decode(String.self, forKey: .senderName)
        self.generation = try container.decodeIfPresent(Int64.self, forKey: .generation)
            ?? Int64(generatedAt.timeIntervalSince1970 * 1_000)
        self.generatedAt = generatedAt
        self.originatingDevice = try container.decodeIfPresent(TrackOrigin.self, forKey: .originatingDevice) ?? .mac
        self.tracks = try container.decode([TrackManifestEntry].self, forKey: .tracks)
        self.notes = try container.decodeIfPresent([NoteManifestEntry].self, forKey: .notes) ?? []
        self.playlistFolders = try container.decodeIfPresent([PlaylistFolderManifestEntry].self, forKey: .playlistFolders) ?? []
        self.playlists = try container.decodeIfPresent([PlaylistManifestEntry].self, forKey: .playlists) ?? []
    }

    /// Cheap revision signal for cover art without embedding the blob in the
    /// manifest. Length + edge bytes → Int64; nil means no artwork.
    public static func artworkRevision(for data: Data?) -> Int64? {
        guard let data, !data.isEmpty else { return nil }
        var hasher = SHA256()
        update(&hasher, UInt64(data.count))
        update(&hasher, data.prefix(16))
        update(&hasher, data.suffix(16))
        let digest = hasher.finalize()
        return digest.prefix(8).reduce(into: Int64(0)) { partialResult, byte in
            partialResult = (partialResult << 8) | Int64(byte)
        }
    }

    /// Stable content fingerprint for `generation` without JSON-encoding the
    /// full payload. Mixes counts, IDs, revisions, timestamps, and other
    /// scalars so any real library change bumps generation.
    public static func generationFingerprint(
        tracks: [TrackManifestEntry],
        notes: [NoteManifestEntry],
        playlistFolders: [PlaylistFolderManifestEntry],
        playlists: [PlaylistManifestEntry]
    ) -> Int64 {
        var hasher = SHA256()
        Self.update(&hasher, UInt64(tracks.count))
        Self.update(&hasher, UInt64(notes.count))
        Self.update(&hasher, UInt64(playlistFolders.count))
        Self.update(&hasher, UInt64(playlists.count))

        for track in tracks {
            Self.update(&hasher, track.id)
            Self.update(&hasher, track.name)
            Self.update(&hasher, track.revision)
            Self.update(&hasher, track.updatedAt)
            Self.update(&hasher, track.isSoftDeleted)
            Self.update(&hasher, track.workingTitle)
            Self.update(&hasher, track.versionNumber.map(Int64.init))
            Self.update(&hasher, track.isReleased)
            Self.update(&hasher, track.isSet)
            Self.update(&hasher, track.recordingDateString)
            Self.update(&hasher, track.artworkRevision)
            Self.update(&hasher, UInt64(track.versions.count))
            for version in track.versions {
                Self.update(&hasher, version.id)
                Self.update(&hasher, version.trackID)
                Self.update(&hasher, version.label)
                Self.update(&hasher, version.fileSize)
                Self.update(&hasher, version.fileFormat)
                Self.update(&hasher, version.originalFilename)
                Self.update(&hasher, version.duration)
                Self.update(&hasher, version.revision)
                Self.update(&hasher, version.contentHash)
                Self.update(&hasher, version.sourceContentHash)
                Self.update(&hasher, version.isSoftDeleted)
            }
        }

        for note in notes {
            Self.update(&hasher, note.id)
            Self.update(&hasher, note.trackID)
            Self.update(&hasher, note.versionID)
            Self.update(&hasher, note.timestamp)
            Self.update(&hasher, note.type.rawValue)
            Self.update(&hasher, note.content)
            Self.update(&hasher, note.voiceFileSize)
            Self.update(&hasher, note.voiceFileSHA256)
            Self.update(&hasher, note.voiceDuration)
            Self.update(&hasher, note.updatedAt)
            Self.update(&hasher, note.createdOn.rawValue)
            Self.update(&hasher, note.isSoftDeleted)
        }

        for folder in playlistFolders {
            Self.update(&hasher, folder.id)
            Self.update(&hasher, folder.name)
            Self.update(&hasher, folder.updatedAt)
            Self.update(&hasher, folder.isSoftDeleted)
        }

        for playlist in playlists {
            Self.update(&hasher, playlist.id)
            Self.update(&hasher, playlist.name)
            Self.update(&hasher, playlist.sortIndex.map(Int64.init))
            Self.update(&hasher, playlist.coverImagePath)
            Self.update(&hasher, playlist.coverRevision)
            Self.update(&hasher, playlist.artist)
            Self.update(&hasher, playlist.playlistDescription)
            Self.update(&hasher, playlist.notes)
            Self.update(&hasher, playlist.folderID)
            Self.update(&hasher, playlist.updatedAt)
            Self.update(&hasher, playlist.isSoftDeleted)
            Self.update(&hasher, playlist.isReleased)
            Self.update(&hasher, UInt64(playlist.entries.count))
            for entry in playlist.entries {
                Self.update(&hasher, entry.id)
                Self.update(&hasher, entry.playlistID)
                Self.update(&hasher, entry.trackID)
                Self.update(&hasher, entry.versionID)
                Self.update(&hasher, Int64(entry.position))
            }
        }

        let digest = hasher.finalize()
        return digest.prefix(8).reduce(into: Int64(0)) { partialResult, byte in
            partialResult = (partialResult << 8) | Int64(byte)
        }
    }

    private static func update(_ hasher: inout SHA256, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
    }

    private static func update(_ hasher: inout SHA256, _ value: Int64) {
        update(&hasher, UInt64(bitPattern: value))
    }

    private static func update(_ hasher: inout SHA256, _ value: Int64?) {
        if let value {
            update(&hasher, UInt8(1))
            update(&hasher, value)
        } else {
            update(&hasher, UInt8(0))
        }
    }

    private static func update(_ hasher: inout SHA256, _ value: Double) {
        update(&hasher, value.bitPattern)
    }

    private static func update(_ hasher: inout SHA256, _ value: Double?) {
        if let value {
            update(&hasher, UInt8(1))
            update(&hasher, value)
        } else {
            update(&hasher, UInt8(0))
        }
    }

    private static func update(_ hasher: inout SHA256, _ value: Bool) {
        update(&hasher, value ? UInt8(1) : UInt8(0))
    }

    private static func update(_ hasher: inout SHA256, _ value: UInt8) {
        withUnsafeBytes(of: value) { hasher.update(bufferPointer: $0) }
    }

    private static func update(_ hasher: inout SHA256, _ value: Date) {
        update(&hasher, value.timeIntervalSince1970)
    }

    private static func update(_ hasher: inout SHA256, _ value: UUID) {
        withUnsafeBytes(of: value.uuid) { hasher.update(bufferPointer: $0) }
    }

    private static func update(_ hasher: inout SHA256, _ value: UUID?) {
        if let value {
            update(&hasher, UInt8(1))
            update(&hasher, value)
        } else {
            update(&hasher, UInt8(0))
        }
    }

    private static func update(_ hasher: inout SHA256, _ value: String) {
        hasher.update(data: Data(value.utf8))
        update(&hasher, UInt8(0))
    }

    private static func update(_ hasher: inout SHA256, _ value: String?) {
        if let value {
            update(&hasher, UInt8(1))
            update(&hasher, value)
        } else {
            update(&hasher, UInt8(0))
        }
    }

    private static func update(_ hasher: inout SHA256, _ value: some Collection<UInt8>) {
        if let buffer = value.withContiguousStorageIfAvailable({ $0 }) {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        } else {
            hasher.update(data: Data(value))
        }
    }
}

public struct PlaylistFolderManifestEntry: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isSoftDeleted: Bool

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        isSoftDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isSoftDeleted = isSoftDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt
        case isSoftDeleted = "isDeleted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
    }
}

public struct PlaylistManifestEntry: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var sortIndex: Int?
    public var coverImagePath: String?
    /// Legacy embedded cover bytes. Modern peers (protocol ≥ 6) leave this nil
    /// and signal changes via `coverRevision`; it is decoded for old peers and
    /// encoded only when explicitly set (iOS talking to a pre-6 Mac).
    public var coverImageData: Data?
    /// Cheap cover change signal (`LibraryManifest.artworkRevision`). Bytes move
    /// via `GET`/`POST /playlist-artwork/{id}` only on mismatch. Nil = no cover.
    public var coverRevision: Int64?
    public var artist: String?
    public var playlistDescription: String?
    public var notes: String?
    public var folderID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var isSoftDeleted: Bool
    public var isReleased: Bool
    public var entries: [PlaylistEntryManifestEntry]

    public init(
        id: UUID,
        name: String,
        sortIndex: Int? = nil,
        coverImagePath: String? = nil,
        coverImageData: Data? = nil,
        coverRevision: Int64? = nil,
        artist: String? = nil,
        playlistDescription: String? = nil,
        notes: String? = nil,
        folderID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        isSoftDeleted: Bool = false,
        isReleased: Bool = false,
        entries: [PlaylistEntryManifestEntry]
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.coverImagePath = coverImagePath
        self.coverImageData = coverImageData
        self.coverRevision = coverRevision ?? LibraryManifest.artworkRevision(for: coverImageData)
        self.artist = artist
        self.playlistDescription = playlistDescription
        self.notes = notes
        self.folderID = folderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isSoftDeleted = isSoftDeleted
        self.isReleased = isReleased
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sortIndex, coverImagePath, coverImageData, coverRevision
        case artist, playlistDescription, notes, folderID
        case createdAt, updatedAt, isSoftDeleted = "isDeleted", isReleased, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex)
        self.coverImagePath = try container.decodeIfPresent(String.self, forKey: .coverImagePath)
        // Legacy manifests (protocol < 6) embed the cover bytes. Keep them so
        // the apply path can use them directly — an old peer has no
        // /playlist-artwork endpoint to fetch from.
        self.coverImageData = try container.decodeIfPresent(Data.self, forKey: .coverImageData)
        if let revision = try container.decodeIfPresent(Int64.self, forKey: .coverRevision) {
            self.coverRevision = revision
        } else {
            self.coverRevision = LibraryManifest.artworkRevision(for: self.coverImageData)
        }
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist)
        self.playlistDescription = try container.decodeIfPresent(String.self, forKey: .playlistDescription)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
        self.isReleased = try container.decodeIfPresent(Bool.self, forKey: .isReleased) ?? false
        self.entries = try container.decodeIfPresent([PlaylistEntryManifestEntry].self, forKey: .entries) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sortIndex, forKey: .sortIndex)
        try container.encodeIfPresent(coverImagePath, forKey: .coverImagePath)
        // Embedded bytes ship only when a builder explicitly set them for a
        // legacy (pre-6) peer; modern manifests carry the revision scalar alone.
        try container.encodeIfPresent(coverImageData, forKey: .coverImageData)
        try container.encodeIfPresent(coverRevision, forKey: .coverRevision)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(playlistDescription, forKey: .playlistDescription)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isSoftDeleted, forKey: .isSoftDeleted)
        try container.encode(isReleased, forKey: .isReleased)
        try container.encode(entries, forKey: .entries)
    }
}

public struct PlaylistEntryManifestEntry: Codable, Sendable {
    public var id: UUID
    public var playlistID: UUID
    public var trackID: UUID
    public var versionID: UUID?
    public var position: Int

    public init(
        id: UUID,
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

public struct NoteManifestEntry: Codable, Sendable {
    public var id: UUID
    public var trackID: UUID
    public var versionID: UUID?
    public var timestamp: TimeInterval?
    public var type: NoteType
    public var content: String?
    public var voiceFilePath: String?
    public var voiceDuration: TimeInterval?
    /// Byte size of the voice .m4a on the originating device. Present only when the
    /// file exists and has been hashed; receivers use it together with `voiceFileSHA256`
    /// to decide whether they need to fetch the audio.
    public var voiceFileSize: Int64?
    /// SHA-256 of the voice .m4a. Presence means the originator can serve the file at
    /// `GET /voice-notes/<id>`; absence means metadata-only (file not yet uploaded /
    /// originator has no audio for this note).
    public var voiceFileSHA256: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var createdOn: DeviceRole
    public var isSoftDeleted: Bool

    public init(
        id: UUID,
        trackID: UUID,
        versionID: UUID? = nil,
        timestamp: TimeInterval? = nil,
        type: NoteType,
        content: String? = nil,
        voiceFilePath: String? = nil,
        voiceDuration: TimeInterval? = nil,
        voiceFileSize: Int64? = nil,
        voiceFileSHA256: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        createdOn: DeviceRole,
        isSoftDeleted: Bool = false
    ) {
        self.id = id
        self.trackID = trackID
        self.versionID = versionID
        self.timestamp = timestamp
        self.type = type
        self.content = content
        self.voiceFilePath = voiceFilePath
        self.voiceDuration = voiceDuration
        self.voiceFileSize = voiceFileSize
        self.voiceFileSHA256 = voiceFileSHA256
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdOn = createdOn
        self.isSoftDeleted = isSoftDeleted
    }

    /// True when the originator has a voice file ready to serve at `/voice-notes/<id>`.
    public var hasVoiceFile: Bool {
        voiceFileSHA256 != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case trackID
        case versionID
        case timestamp
        case type
        case content
        case voiceFilePath
        case voiceDuration
        case voiceFileSize
        case voiceFileSHA256
        case createdAt
        case updatedAt
        case createdOn
        case isSoftDeleted = "isDeleted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.trackID = try container.decode(UUID.self, forKey: .trackID)
        self.versionID = try container.decodeIfPresent(UUID.self, forKey: .versionID)
        self.timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
        self.type = try container.decode(NoteType.self, forKey: .type)
        self.content = try container.decodeIfPresent(String.self, forKey: .content)
        self.voiceFilePath = try container.decodeIfPresent(String.self, forKey: .voiceFilePath)
        self.voiceDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .voiceDuration)
        self.voiceFileSize = try container.decodeIfPresent(Int64.self, forKey: .voiceFileSize)
        self.voiceFileSHA256 = try container.decodeIfPresent(String.self, forKey: .voiceFileSHA256)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.createdOn = try container.decode(DeviceRole.self, forKey: .createdOn)
        self.isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
    }
}

public struct TrackManifestEntry: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int64
    public var isSoftDeleted: Bool
    public var versions: [VersionManifestEntry]
    public var workingTitle: String?
    public var versionNumber: Int?
    public var isReleased: Bool
    public var isSet: Bool
    public var recordingDateString: String?
    /// Cheap cover-art change signal. Clients fetch bytes via `GET /artwork/{id}`
    /// only when this differs from the local revision. Nil = no artwork.
    public var artworkRevision: Int64?

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        revision: Int64,
        isSoftDeleted: Bool = false,
        versions: [VersionManifestEntry],
        workingTitle: String? = nil,
        versionNumber: Int? = nil,
        isReleased: Bool = false,
        isSet: Bool = false,
        recordingDateString: String? = nil,
        artworkRevision: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.isSoftDeleted = isSoftDeleted
        self.versions = versions
        self.workingTitle = workingTitle
        self.versionNumber = versionNumber
        self.isReleased = isReleased
        self.isSet = isSet
        self.recordingDateString = RecordingDate.validate(recordingDateString)
        self.artworkRevision = artworkRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case revision
        case isSoftDeleted = "isDeleted"
        case versions
        case workingTitle
        case versionNumber
        case isReleased
        case isSet
        case recordingDateString
        case artworkRevision
        /// Legacy key — decoded only to derive a revision if peers still embed blobs.
        case artwork
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
        self.updatedAt = updatedAt
        self.revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
            ?? Int64(updatedAt.timeIntervalSince1970 * 1_000)
        self.isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
        self.versions = try container.decode([VersionManifestEntry].self, forKey: .versions)
        self.workingTitle = try container.decodeIfPresent(String.self, forKey: .workingTitle)
        self.versionNumber = try container.decodeIfPresent(Int.self, forKey: .versionNumber)
        self.isReleased = try container.decodeIfPresent(Bool.self, forKey: .isReleased) ?? false
        self.isSet = try container.decodeIfPresent(Bool.self, forKey: .isSet) ?? false
        self.recordingDateString = RecordingDate.validate(try container.decodeIfPresent(String.self, forKey: .recordingDateString))
        if let revision = try container.decodeIfPresent(Int64.self, forKey: .artworkRevision) {
            self.artworkRevision = revision
        } else if let legacy = try container.decodeIfPresent(Data.self, forKey: .artwork) {
            self.artworkRevision = LibraryManifest.artworkRevision(for: legacy)
        } else {
            self.artworkRevision = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(revision, forKey: .revision)
        try container.encode(isSoftDeleted, forKey: .isSoftDeleted)
        try container.encode(versions, forKey: .versions)
        try container.encodeIfPresent(workingTitle, forKey: .workingTitle)
        try container.encodeIfPresent(versionNumber, forKey: .versionNumber)
        try container.encode(isReleased, forKey: .isReleased)
        try container.encode(isSet, forKey: .isSet)
        try container.encodeIfPresent(recordingDateString, forKey: .recordingDateString)
        try container.encodeIfPresent(artworkRevision, forKey: .artworkRevision)
        // Never encode legacy `artwork` blobs.
    }
}

public struct VersionManifestEntry: Codable, Sendable {
    public var id: UUID
    public var trackID: UUID
    public var label: String
    public var fileSize: Int64
    public var fileFormat: String
    public var originalFilename: String
    public var duration: TimeInterval
    public var addedAt: Date
    public var modifiedAt: Date
    public var revision: Int64
    public var contentHash: String
    public var sourceContentHash: String?
    public var isSoftDeleted: Bool

    public init(
        id: UUID,
        trackID: UUID,
        label: String,
        fileSize: Int64,
        fileFormat: String,
        originalFilename: String,
        duration: TimeInterval,
        addedAt: Date,
        modifiedAt: Date,
        revision: Int64,
        contentHash: String,
        sourceContentHash: String? = nil,
        isSoftDeleted: Bool = false
    ) {
        self.id = id
        self.trackID = trackID
        self.label = label
        self.fileSize = fileSize
        self.fileFormat = fileFormat
        self.originalFilename = originalFilename
        self.duration = duration
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.contentHash = contentHash
        self.sourceContentHash = sourceContentHash
        self.isSoftDeleted = isSoftDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case trackID
        case label
        case fileSize
        case fileFormat
        case originalFilename
        case duration
        case addedAt
        case modifiedAt
        case revision
        case contentHash
        case sourceContentHash
        case isSoftDeleted = "isDeleted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let addedAt = try container.decode(Date.self, forKey: .addedAt)
        let modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? addedAt
        self.id = try container.decode(UUID.self, forKey: .id)
        self.trackID = try container.decode(UUID.self, forKey: .trackID)
        self.label = try container.decode(String.self, forKey: .label)
        self.fileSize = try container.decode(Int64.self, forKey: .fileSize)
        self.fileFormat = try container.decode(String.self, forKey: .fileFormat)
        self.originalFilename = try container.decode(String.self, forKey: .originalFilename)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
            ?? Int64(modifiedAt.timeIntervalSince1970 * 1_000)
        self.contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        self.sourceContentHash = try container.decodeIfPresent(String.self, forKey: .sourceContentHash)
        self.isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
    }
}
