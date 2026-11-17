import Foundation
import SwiftData

public enum SyncItemStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case pending
    case downloading
    case verifying
    case applied
    case failed
    case deleted
}

public enum SyncDiffKind: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case redownloadMissingFile
    case delete
}

@Model
public final class SyncCheckpoint {
    public var senderID: UUID
    public var senderName: String
    public var lastManifestGeneration: Int64
    public var lastManifestFetchedAt: Date?
    public var lastSyncAt: Date?
    public var lastSyncError: String?

    public init(
        senderID: UUID,
        senderName: String,
        lastManifestGeneration: Int64 = 0,
        lastManifestFetchedAt: Date? = nil,
        lastSyncAt: Date? = nil,
        lastSyncError: String? = nil
    ) {
        self.senderID = senderID
        self.senderName = senderName
        self.lastManifestGeneration = lastManifestGeneration
        self.lastManifestFetchedAt = lastManifestFetchedAt
        self.lastSyncAt = lastSyncAt
        self.lastSyncError = lastSyncError
    }
}

@Model
public final class RemoteTrackSnapshot {
    #Index<RemoteTrackSnapshot>([\.senderID])

    public var senderID: UUID
    public var trackID: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int64
    public var lastSeenGeneration: Int64

    public init(
        senderID: UUID,
        trackID: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        revision: Int64,
        lastSeenGeneration: Int64
    ) {
        self.senderID = senderID
        self.trackID = trackID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.lastSeenGeneration = lastSeenGeneration
    }
}

@Model
public final class RemoteVersionSnapshot {
    #Index<RemoteVersionSnapshot>([\.senderID])

    public var senderID: UUID
    public var trackID: UUID
    public var versionID: UUID
    public var label: String
    public var fileSize: Int64
    public var fileFormat: String
    public var originalFilename: String
    public var duration: TimeInterval
    public var addedAt: Date
    public var modifiedAt: Date
    public var revision: Int64
    public var contentHash: String
    public var lastSeenGeneration: Int64
    public var syncStatusRawValue: String
    public var retryCount: Int
    public var nextRetryAt: Date?
    public var lastError: String?
    /// Local-only intent on this receiver. It is never sent in a manifest and
    /// survives catalog-only syncs and unchanged remote generations.
    public var downloadRequested: Bool = false

    public var syncStatus: SyncItemStatus {
        get { SyncItemStatus(rawValue: syncStatusRawValue) ?? .idle }
        set { syncStatusRawValue = newValue.rawValue }
    }

    public init(
        senderID: UUID,
        trackID: UUID,
        versionID: UUID,
        label: String,
        fileSize: Int64,
        fileFormat: String,
        originalFilename: String,
        duration: TimeInterval,
        addedAt: Date,
        modifiedAt: Date,
        revision: Int64,
        contentHash: String,
        lastSeenGeneration: Int64,
        syncStatus: SyncItemStatus = .idle,
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastError: String? = nil,
        downloadRequested: Bool = false
    ) {
        self.senderID = senderID
        self.trackID = trackID
        self.versionID = versionID
        self.label = label
        self.fileSize = fileSize
        self.fileFormat = fileFormat
        self.originalFilename = originalFilename
        self.duration = duration
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.contentHash = contentHash
        self.lastSeenGeneration = lastSeenGeneration
        self.syncStatusRawValue = syncStatus.rawValue
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.downloadRequested = downloadRequested
    }
}
