import Foundation
import SwiftData

@Model
public final class Version {
    public var id: UUID
    public var trackID: UUID
    public var label: String
    public var filePath: String
    public var fileSize: Int64
    public var fileFormat: String
    public var originalFilename: String
    public var duration: TimeInterval
    public var addedAt: Date
    /// External storage keeps large waveform blobs out of the row page so
    /// listing tracks / computing playlist durations doesn't fault every
    /// sample buffer through SQLite on the main thread.
    @Attribute(.externalStorage) public var waveformData: Data?
    public var contentHash: String = ""

    /// Content hash of the original source file (before AAC re-encoding).
    public var sourceContentHash: String?

    /// Mix number parsed from filename (e.g. "3.01", "3.02"). Stored as String to preserve
    /// leading zeros and avoid lossy float precision. Nil for legacy rows; backfilled lazily
    /// by the parser when the Version is touched by import or rename.
    public var mixNumber: String?

    /// Whether this bounce has been played at least once. Drives the unread indicator
    /// on the Recents tab. Set true the first time the user plays it.
    public var hasBeenPlayed: Bool = false

    /// Last local playback position in seconds. This is intentionally not part
    /// of the sync manifest: resume is natural to the device where listening
    /// happened.
    public var resumePosition: TimeInterval = 0

    /// Import processing lifecycle for this specific version. A `Version`
    /// row is `pending` while its source file is being copied/encoded and
    /// its waveform/metadata generated. Defaults to `.complete` so any
    /// pre-existing rows from before this property existed read as ready.
    public var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .complete }
        set { processingStateRaw = newValue.rawValue }
    }
    public var processingStateRaw: String = "complete"

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        label: String,
        filePath: String,
        fileSize: Int64,
        fileFormat: String,
        originalFilename: String,
        duration: TimeInterval,
        addedAt: Date = .now,
        waveformData: Data? = nil,
        contentHash: String = "",
        sourceContentHash: String? = nil,
        mixNumber: String? = nil,
        hasBeenPlayed: Bool = false,
        resumePosition: TimeInterval = 0,
        processingState: ProcessingState = .complete
    ) {
        self.id = id
        self.trackID = trackID
        self.label = label
        self.filePath = filePath
        self.fileSize = fileSize
        self.fileFormat = fileFormat
        self.originalFilename = originalFilename
        self.duration = duration
        self.addedAt = addedAt
        self.waveformData = waveformData
        self.contentHash = contentHash
        self.sourceContentHash = sourceContentHash
        self.mixNumber = mixNumber
        self.hasBeenPlayed = hasBeenPlayed
        self.resumePosition = resumePosition
        self.processingStateRaw = processingState.rawValue
    }

    /// Compute SHA-256 hash of the file at filePath and store it (streaming; no whole-file load).
    public func computeContentHash() {
        guard !filePath.isEmpty else { return }
        let url = URL(fileURLWithPath: filePath)
        contentHash = (try? FileIntegrity.sha256Hex(for: url)) ?? ""
    }
}
