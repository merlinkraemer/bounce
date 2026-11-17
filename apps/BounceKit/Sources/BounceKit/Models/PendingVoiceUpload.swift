import Foundation
import SwiftData

/// A locally-recorded voice note .m4a queued for upload to the peer.
/// Persisted so an interrupted sync resumes after restart.
@Model
public final class PendingVoiceUpload {
    public var id: UUID
    public var noteID: UUID
    public var filePath: String
    public var fileSize: Int64
    public var sha256: String

    public var status: PendingUploadStatus {
        get { PendingUploadStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
    public var statusRaw: String
    public var createdAt: Date
    public var lastAttemptAt: Date?
    public var retryCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        noteID: UUID,
        filePath: String,
        fileSize: Int64,
        sha256: String,
        status: PendingUploadStatus = .pending,
        createdAt: Date = .now,
        retryCount: Int = 0
    ) {
        self.id = id
        self.noteID = noteID
        self.filePath = filePath
        self.fileSize = fileSize
        self.sha256 = sha256
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.retryCount = retryCount
    }
}
