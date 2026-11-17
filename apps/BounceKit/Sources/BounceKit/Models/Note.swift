import Foundation
import SwiftData

public enum NoteType: String, Codable, Sendable {
    case text
    case voice
}

public enum DeviceRole: String, Codable, Sendable {
    case mac
    case phone
}

@Model
public final class Note {
    public var id: UUID
    public var trackID: UUID
    public var versionID: UUID?
    public var timestamp: TimeInterval?
    public var type: NoteType
    public var content: String?
    public var voiceFilePath: String?
    public var voiceDuration: TimeInterval?
    /// SHA-256 of the local voice .m4a, set once the file has been written and hashed.
    /// Drives the manifest's "this device can serve the audio" advertisement.
    public var voiceFileSHA256: String?
    public var voiceFileSize: Int64?
    public var createdAt: Date
    public var updatedAt: Date
    public var createdOn: DeviceRole
    /// Tombstone flag. Named `isSoftDeleted` to avoid shadowing
    /// SwiftData's `PersistentModel.isDeleted` which triggers real deletion.
    @Attribute(originalName: "isDeleted")
    public var isSoftDeleted: Bool = false

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        versionID: UUID? = nil,
        timestamp: TimeInterval? = nil,
        type: NoteType,
        content: String? = nil,
        voiceFilePath: String? = nil,
        voiceDuration: TimeInterval? = nil,
        voiceFileSHA256: String? = nil,
        voiceFileSize: Int64? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
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
        self.voiceFileSHA256 = voiceFileSHA256
        self.voiceFileSize = voiceFileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdOn = createdOn
        self.isSoftDeleted = isSoftDeleted
    }
}
