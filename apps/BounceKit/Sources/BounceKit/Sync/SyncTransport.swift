import Foundation

public enum SyncConnectionState: Equatable, Sendable {
    case searching
    case found(deviceName: String)
    case pairing
    case connected
    case syncing
    case idle
    case disconnected
}

public enum SyncError: LocalizedError, Sendable {
    case connectionFailed(String)
    case transferFailed(String)
    case pairingFailed(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .transferFailed(let msg): return "Transfer failed: \(msg)"
        case .pairingFailed(let msg): return "Pairing failed: \(msg)"
        case .notConnected: return "Not connected"
        }
    }
}

/// Role of this device in the sync session.
public enum SyncRole: Sendable {
    case sender   // Mac
    case receiver // iOS
}

/// Result of GET /pair/status on the receiver — distinguishes auth rejection
/// from transient network failures so we don't tear down a good session.
public enum PairingVerification: Sendable {
    case valid
    case rejected
    case unreachable
}

public struct SyncRequestMetadata: Sendable {
    public let path: String
    public let deviceName: String?
    public let deviceID: UUID?
    public let appVersion: String?
    public let requestedAt: Date

    public init(
        path: String,
        deviceName: String?,
        deviceID: UUID?,
        appVersion: String?,
        requestedAt: Date
    ) {
        self.path = path
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.requestedAt = requestedAt
    }
}

@MainActor
public protocol SyncTransport: AnyObject {
    var connectionState: SyncConnectionState { get }
    var connectedDeviceName: String? { get }
    var connectedDeviceID: UUID? { get }

    func start() async
    func stop()

    // MARK: Sender (Mac)

    /// Push the current library manifest so the receiver can request it via HTTP.
    func sendManifest(_ manifest: LibraryManifest) async throws

    /// Mac-side handler for incoming uploads from iOS.
    var uploadHandler: ((UploadPayload) async -> Bool)? { get set }

    /// Mac resolves cover-art bytes for `GET /artwork/<trackID>`.
    var artworkProvider: ((UUID) -> Data?)? { get set }

    /// Resolves the local voice note .m4a file URL for a given note ID. Both sides set this
    /// so the peer can fetch voice files via GET /voice-notes/<id>.
    var voiceNoteProvider: ((UUID) -> URL?)? { get set }

    /// Handles incoming voice note uploads from the peer.
    var voiceNoteUploadHandler: ((VoiceNoteUploadPayload) async -> Bool)? { get set }

    // MARK: Receiver (iOS)

    /// Fetch the manifest from the connected sender.
    func requestManifest() async throws -> LibraryManifest

    /// Cheap poll pre-check (`GET /generation`). Returns nil when the sender
    /// doesn't serve the endpoint (older peer, or no manifest published yet) —
    /// callers must fall back to the full manifest fetch in that case.
    func requestGeneration() async throws -> Int64?

    /// Download a specific audio file to a temporary file URL.
    func downloadFile(versionID: UUID) async throws -> URL

    /// Download cover art bytes for a track (`GET /artwork/<trackID>`).
    func downloadArtwork(trackID: UUID) async throws -> Data

    /// Download a specific voice note .m4a to a temporary file URL.
    func downloadVoiceNote(noteID: UUID) async throws -> URL

    /// Upload a file to the connected sender. Returns true on success.
    func uploadFile(trackName: String, versionLabel: String, originalFilename: String, fileFormat: String, versionID: UUID?, trackID: UUID?, targetTrackID: UUID?, sourceContentHash: String?, fileURL: URL) async throws -> Bool

    /// Upload a voice note .m4a to the connected sender. Returns true on success.
    func uploadVoiceNote(noteID: UUID, fileURL: URL) async throws -> Bool
}
