import Foundation
import SwiftData

/// Represents an iOS-originated track version queued for upload to the Mac.
/// Persisted to survive app restarts and backgrounding.
@Model
public final class PendingUpload {
    public var id: UUID
    public var versionID: UUID
    public var trackID: UUID
    public var trackName: String
    public var filePath: String
    public var fileSize: Int64
    public var fileFormat: String
    public var originalFilename: String
    public var duration: TimeInterval
    public var versionLabel: String
    public var targetTrackID: UUID?
    public var sourceContentHash: String?

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
        versionID: UUID,
        trackID: UUID,
        trackName: String,
        filePath: String,
        fileSize: Int64,
        fileFormat: String,
        originalFilename: String,
        duration: TimeInterval,
        versionLabel: String,
        targetTrackID: UUID? = nil,
        sourceContentHash: String? = nil,
        status: PendingUploadStatus = .pending,
        createdAt: Date = .now,
        retryCount: Int = 0
    ) {
        self.id = id
        self.versionID = versionID
        self.trackID = trackID
        self.trackName = trackName
        self.filePath = filePath
        self.fileSize = fileSize
        self.fileFormat = fileFormat
        self.originalFilename = originalFilename
        self.duration = duration
        self.versionLabel = versionLabel
        self.targetTrackID = targetTrackID
        self.sourceContentHash = sourceContentHash
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.retryCount = retryCount
    }
}

public enum PendingUploadStatus: String, Codable {
    case pending
    case uploading
    case failed
    case uploaded
}
