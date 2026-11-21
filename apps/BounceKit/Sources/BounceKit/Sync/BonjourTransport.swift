import Foundation
import Network
#if os(iOS)
import UIKit
#endif

// MARK: - KeychainHelper

struct KeychainHelper {
    /// Outcome of a keychain read.
    ///
    /// `notFound` means the item genuinely does not exist and callers may treat
    /// it as "no value yet". `failure` covers every other status (access denied,
    /// user cancelled the access prompt, interaction required, ...) where the
    /// item may well exist and must not be treated as absent.
    enum LoadResult {
        case success(Data)
        case notFound
        case failure(OSStatus)
    }

    /// Writes `data`, updating the existing item in place and adding it only
    /// when absent. The old value is never deleted first, so a failed write
    /// leaves the previous value intact. Returns the failing status, or nil.
    @discardableResult
    static func save(_ data: Data, service: String, account: String) -> OSStatus? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return nil }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        return addStatus == errSecSuccess ? nil : addStatus
    }

    static func load(service: String, account: String) -> LoadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .notFound }
            return .success(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failure(status)
        }
    }

    static func delete(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - SyncBodyLimit

/// Per-route caps (bytes) for request bodies. `/upload` and
/// `/voice-notes/upload` stream to disk, so their caps only bound disk use.
enum SyncBodyLimit {
    /// `/pair` runs before authorisation; the real payload is a few hundred bytes.
    static let pair = 64 * 1024
    static let requestHeaders = 64 * 1024
    static let playlistArtwork = 32 * 1024 * 1024
    static let iosManifest = 64 * 1024 * 1024
    static let upload = 16 * 1024 * 1024 * 1024
    static let voiceNoteUpload = 1024 * 1024 * 1024
}

// MARK: - DiscoveredPeer

/// A sender (Mac) seen by the receiver's Bonjour browser. Surfaced through
/// `BonjourTransport.discoveredPeers` so the iOS UI can offer a manual
/// pairing list.
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let firstSeenAt: Date
    public var lastSeenAt: Date

    public init(id: UUID, name: String, firstSeenAt: Date = .now, lastSeenAt: Date = .now) {
        self.id = id
        self.name = name
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

// MARK: - UploadPayload

/// Payload delivered to the Mac-side upload handler when iOS pushes a track.
/// `fileURL` points at a temp file written on the connection queue — handlers
/// should move/copy it and must not expect the bytes to live as `Data` on MainActor.
public struct UploadPayload: Sendable {
    public let trackName: String
    public let versionLabel: String
    public let originalFilename: String
    public let fileFormat: String
    public let versionID: UUID?
    public let trackID: UUID?
    public let targetTrackID: UUID?
    public let fileURL: URL
    public let sourceDeviceName: String?
    public let sourceDeviceID: UUID?
    public let sourceContentHash: String?
}

/// Payload delivered to the upload handler when the peer pushes a voice note .m4a.
/// `fileURL` is a temp file; hash via streaming `FileIntegrity` on that URL.
public struct VoiceNoteUploadPayload: Sendable {
    public let noteID: UUID
    public let fileURL: URL
    public let sourceDeviceName: String?
    public let sourceDeviceID: UUID?
}

// MARK: - Data Multipart Helper

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data(value.utf8))
        append(Data("\r\n".utf8))
    }
}

// MARK: - Request idle watchdogs

private final class RequestIdleWatchdogs: @unchecked Sendable {
    static let idleTimeout: TimeInterval = 60

    private let lock = NSLock()
    private var armed: [ObjectIdentifier: (watchdog: IdleWatchdog, task: Task<Void, Never>)] = [:]

    func arm(_ connection: NWConnection, onExpire: @escaping @Sendable () -> Void) {
        let key = ObjectIdentifier(connection)
        let watchdog = IdleWatchdog(idleTimeout: Self.idleTimeout)
        let task = watchdog.start { [weak self] in
            self?.disarm(key)
            onExpire()
        }
        lock.lock()
        let previous = armed.updateValue((watchdog, task), forKey: key)
        lock.unlock()
        previous?.task.cancel()
    }

    func touch(_ connection: NWConnection) {
        lock.lock()
        let watchdog = armed[ObjectIdentifier(connection)]?.watchdog
        lock.unlock()
        watchdog?.touch()
    }

    func disarm(_ connection: NWConnection) {
        disarm(ObjectIdentifier(connection))
    }

    private func disarm(_ key: ObjectIdentifier) {
        lock.lock()
        let removed = armed.removeValue(forKey: key)
        lock.unlock()
        removed?.task.cancel()
    }
}

// MARK: - BonjourTransport

/// Concrete SyncTransport implementation using Bonjour + HTTP over NWListener / NWBrowser.
///
/// **Mac (sender):** advertises the configured Bounce service, runs HTTP server, serves
/// `GET /manifest`, `GET /files/<versionID>`, and `GET /artwork/<trackID>`.
///
/// **iOS (receiver):** browses for the configured Bounce service, connects, fetches manifest
/// and downloads files via NWConnection HTTP client.
@Observable
@MainActor
public final class BonjourTransport: SyncTransport {

    // MARK: Public state

    public var stateChangeHandler: ((SyncConnectionState, String?, UUID?) -> Void)? = nil
    public var requestMetadataHandler: ((SyncRequestMetadata) -> Void)? = nil

    /// Sender-side: invoked when a receiver hits POST /pair. The app should
    /// present an approval modal showing the request's `verificationCode`
    /// and return the user's choice. Existing bonds are auto-approved only
    /// when the request also proves possession of the current shared key.
    /// The UI is responsible for enforcing its own modal timeout shorter
    /// than the iOS pair request timeout (currently 90s) so that an
    /// abandoned modal degrades to a clean denial before the receiver
    /// gives up and we end up with a one-sided bond.
    public var pairApprovalHandler: ((PairRequest) async -> PairOutcome)? = nil

    /// Sender-side: invoked instead of `pairApprovalHandler` when a pair
    /// request presents the current, unused pairing token from the Mac's QR.
    /// Return `.approved` to bond without a code check.
    public var tokenPairHandler: ((PairRequest) -> PairOutcome)? = nil

    /// Sender-side: the live QR payload. Rotates when used or expired.
    public private(set) var pairingLink: PairingLink? = nil

    /// Receiver-side: peers seen by the Bonjour browser, in last-seen order.
    /// UI binds to this for the “Available Devices” list.
    public private(set) var discoveredPeers: [DiscoveredPeer] = []

    /// Set by the app on both sides at startup. The transport reads it on
    /// every request to authorise inbound traffic and to decide whether the
    /// receiver should auto-connect to a discovered peer.
    public weak var bondedPeerStore: BondedPeerStore? = nil

    public private(set) var connectionState: SyncConnectionState = .disconnected {
        didSet { stateChangeHandler?(connectionState, connectedDeviceName, connectedDeviceID) }
    }
    public private(set) var connectedDeviceName: String? = nil
    public private(set) var connectedDeviceID: UUID? = nil
    public private(set) var connectedAppVersion: String? = nil

    /// Receiver-side: resolved HTTP base URL for the connected Mac (debug/UI).
    public var connectedSenderURL: URL? { senderBaseURL ?? lastSenderBaseURL }

    /// Receiver-side: human-readable network path label (Wi-Fi, USB, Hotspot, etc.).
    public private(set) var connectionPathLabel: String? = nil

    /// Sender-side: timestamp of the last HTTP request from any client.
    public private(set) var lastClientRequestAt: Date? = nil
    /// Sender-side: count of HTTP requests received.
    public private(set) var clientRequestCount: Int = 0
    /// Sender-side: last path requested.
    public private(set) var lastRequestPath: String = ""
    public private(set) var totalBytesServed: Int64 = 0
    public private(set) var lastServedResponseBytes: Int64 = 0
    public private(set) var publishedManifestGeneration: Int64? = nil

    /// Receiver-side: timestamp of the last successful manifest fetch.
    public private(set) var lastManifestFetchAt: Date? = nil
    public private(set) var authFailureThresholdExceeded: Bool = false

    // MARK: Configuration

    public let role: SyncRole

    /// Mac sets this to resolve a local file URL for a version ID.
    public var fileProvider: ((UUID) -> URL?)? = nil

    /// Called after a version file was streamed completely to the peer.
    public var fileServedHandler: ((UUID) -> Void)? = nil

    /// Mac sets this to resolve in-memory cover-art bytes for a track ID.
    /// Served via `GET /artwork/<trackID>` — keyed by `artworkRevision` in the manifest.
    public var artworkProvider: ((UUID) -> Data?)? = nil

    /// Mac sets this to resolve playlist cover bytes for a playlist ID.
    /// Served via `GET /playlist-artwork/<playlistID>` — keyed by `coverRevision`
    /// in the manifest.
    public var playlistArtworkProvider: ((UUID) -> Data?)? = nil

    /// Mac sets this to accept playlist cover bytes pushed by iOS via
    /// `POST /playlist-artwork/<playlistID>` (raw octet-stream body).
    public var playlistArtworkUploadHandler: ((UUID, Data) async -> Bool)? = nil

    /// Mac sets this to handle incoming uploads from iOS.
    /// Receives the multipart form data and source device info.
    public var uploadHandler: ((UploadPayload) async -> Bool)? = nil

    /// Resolves the local voice note .m4a file URL for a given note ID.
    /// Both sides set this so the peer can fetch voice files via GET /voice-notes/<id>.
    public var voiceNoteProvider: ((UUID) -> URL?)? = nil

    /// Handles incoming voice note .m4a uploads pushed by the peer.
    /// Both sides may set this; iOS pushes phone-recorded voice notes to the Mac via this route.
    public var voiceNoteUploadHandler: ((VoiceNoteUploadPayload) async -> Bool)? = nil

    /// Mac sets this to receive iOS manifests of .phone-originated tracks.
    public var iosManifestHandler: ((LibraryManifest) -> Void)? = nil

    /// Receiver-side: when set to true, the browser stays alive but no
    /// auto-connect is attempted. Lets the user pause sync without losing
    /// the bond.
    public var autoConnectPaused: Bool = false {
        didSet {
            guard role == .receiver, oldValue != autoConnectPaused else { return }
            if autoConnectPaused {
                stopReceiverConnections(reason: "auto-connect paused")
            } else {
                if isPaired {
                    triggerReconnect()
                } else {
                    retryFromCurrentResults()
                }
            }
        }
    }

    /// iOS sets this as the base directory for downloaded files.
    public var downloadDirectory: URL? = nil

    // MARK: Private state

    /// All Network.framework callbacks (listener/browser/connection) run on this
    /// background queue instead of `.main` so the receive loop, send-completion,
    /// and per-connection byte pumping during uploads don't compete with SwiftUI
    /// rendering. Every handler that touches `@MainActor` state already hops via
    /// `Task { @MainActor in … }`, so nothing here assumes it runs on main.
    nonisolated private let requestWatchdogs = RequestIdleWatchdogs()
    nonisolated private let networkQueue = DispatchQueue(
        label: "com.bounce.transport.network", qos: .userInitiated
    )

    private var listener: NWListener? = nil
    private var listenerRestartTask: Task<Void, Never>?
    private var listenerRestartAttempt = 0
    private var browser: NWBrowser? = nil
    private var activeConnections: [NWConnection] = []
    private var resolvedBootstrapConnectionIDs: Set<ObjectIdentifier> = []
    private var isConnecting: Bool = false
    private var connectTimeoutTask: Task<Void, Never>? = nil
    // Sender intentionally stays in .connected after first authed request.
    // Without a peer-presence channel (sender doesn't browse) any timer-based
    // demotion races the receiver's still-Connected UI. State now flips off
    // .connected only on real events: DELETE /pair, unpair, or stop().
    private var browserTimeoutTask: Task<Void, Never>? = nil

    private var isPaired: Bool { bondedPeerStore?.peers.isEmpty == false }

    /// Sender-side: timestamps of recent failed pair attempts per deviceID.
    /// Used to throttle a misbehaving client without ever surfacing a modal
    /// — relevant only on a shared LAN where multiple users could spam
    /// /pair to phish the host. After 5 failures inside the window we
    /// reject silently for the same window length.
    private var pairFailureHistory: [UUID: [Date]] = [:]
    private var pairingTokenIssuer = PairingTokenIssuer()
    private var pairingLinkRotationTask: Task<Void, Never>? = nil
    private var senderPathMonitor: NWPathMonitor? = nil
    private var directFallbackTask: Task<Void, Never>? = nil
    private static let pairFailureLimit = 5
    private static let pairFailureWindow: TimeInterval = 60

    /// Latest manifest held in memory (sender side).
    private var currentManifest: LibraryManifest? = nil
    /// Pre-encoded `GET /manifest` body. Idle polls must return this without
    /// re-running `JSONEncoder` on the main actor.
    private var currentManifestData: Data? = nil

    /// Base URL for the currently discovered/connected sender (receiver side).
    private var senderBaseURL: URL? = nil
    /// Resolved NWEndpoint for the connected sender — used for all receiver HTTP.
    private var senderEndpoint: NWEndpoint? = nil
    /// Fallback URL used for `notifyRemoteForget` even after the current
    /// session has been reset (e.g. by a transient 404 during first sync).
    private var lastSenderBaseURL: URL? = nil
    /// Fallback endpoint for best-effort forget after session reset.
    private var lastSenderEndpoint: NWEndpoint? = nil

    private let _deviceID: UUID
    private let _deviceName: String

    /// Persistent device identifier for this role.
    public var deviceID: UUID { _deviceID }

    /// Device display name used in Bonjour advertising and sent to the peer.
    /// On iOS a name the user set in Bounce settings wins over
    /// `UIDevice.current.name` (the generic model name since iOS 16).
    public var deviceName: String {
        #if !os(macOS)
        if let custom = UserDefaults.standard.string(forKey: BouncePreferenceKey.receiverDeviceName)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        #endif
        return _deviceName
    }

    private static let keychainService = BounceConstants.keychainService
    private static let keychainAccount = "localPairingKey"
    private static let senderDeviceIDKey = BouncePreferenceKey.senderDeviceID
    private static let receiverDeviceIDKey = BouncePreferenceKey.receiverDeviceID
    private static let legacySenderDeviceIDKey = BouncePreferenceKey.legacySenderDeviceID
    private static let autoConnectPausedKey = BouncePreferenceKey.autoConnectPaused

    // MARK: Init

    public init(role: SyncRole, deviceID: UUID? = nil, deviceName: String? = nil) {
        self.role = role
        self._deviceID = deviceID ?? Self.persistentDeviceID(for: role)
        #if os(macOS)
        self._deviceName = deviceName ?? Host.current().localizedName ?? "Bounce Device"
        #else
        self._deviceName = deviceName ?? DeviceModelName.current(systemName: UIDevice.current.name)
        #endif
    }

    /// Clears all local sync-pairing state for the current app container:
    /// transport pairing key, bonded peers, and persisted per-role device IDs.
    public static func resetLocalPairingState() {
        KeychainHelper.delete(service: keychainService, account: keychainAccount)
        KeychainHelper.delete(service: Self.keychainService, account: "bondedPeers.sender")
        KeychainHelper.delete(service: Self.keychainService, account: "bondedPeers.receiver")

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: senderDeviceIDKey)
        defaults.removeObject(forKey: receiverDeviceIDKey)
        defaults.removeObject(forKey: legacySenderDeviceIDKey)
    }

    // MARK: SyncTransport

    public func start() async {
        switch role {
        case .sender:
            startHTTPServer()
            publishPairingLink()
            startSenderPathMonitor()
        case .receiver:
            if isPaired {
                connectionState = .disconnected
                SyncLog.receiver.info("receiver start: paired, standby mode (no continuous browse)")
            } else {
                // Unpaired: do not browse yet. Browsing triggers the iOS Local Network
                // permission prompt, so wait until the user opens pairing (`beginDiscovery`).
                connectionState = .disconnected
                SyncLog.receiver.info("receiver start: unpaired, discovery deferred until pairing is requested")
            }
        }
    }

    public func stop() {
        pairingLinkRotationTask?.cancel()
        pairingLinkRotationTask = nil
        pairingLink = nil
        senderPathMonitor?.cancel()
        senderPathMonitor = nil
        directFallbackTask?.cancel()
        directFallbackTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        browserTimeoutTask?.cancel()
        browserTimeoutTask = nil
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        listenerRestartAttempt = 0
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for conn in activeConnections { conn.cancel() }
        activeConnections.removeAll()
        connectionState = .disconnected
        connectedDeviceName = nil
        connectedDeviceID = nil
        connectedAppVersion = nil
        senderBaseURL = nil
        senderEndpoint = nil
        connectionPathLabel = nil
        isConnecting = false
    }

    // MARK: - Trigger-based Reconnect

    /// Cancels the browser and its timeout without touching TCP connections
    /// or published state.
    private func stopBrowsing() {
        browserTimeoutTask?.cancel()
        browserTimeoutTask = nil
        browser?.cancel()
        browser = nil
    }

    /// Receiver-side: start a time-boxed browse when paired and not
    /// currently connected. Idempotent — safe to call multiple times.
    public func triggerReconnect() {
        guard role == .receiver else { return }
        guard !autoConnectPaused else {
            SyncLog.receiver.debug("triggerReconnect ignored — auto-connect paused")
            return
        }
        guard connectionState != .connected, !isConnecting else { return }
        guard browser == nil else {
            SyncLog.receiver.debug("triggerReconnect ignored — browser already running")
            return
        }
        guard isPaired else {
            // Unpaired mode already browses continuously; nothing to do.
            return
        }
        SyncLog.receiver.info("triggerReconnect: starting time-boxed browse")
        startBrowsing(triggered: true)
        scheduleDirectFallback()
    }

    private static let directFallbackDelay: UInt64 = 3_000_000_000

    @discardableResult
    private func scheduleDirectFallback(after delay: UInt64 = BonjourTransport.directFallbackDelay) -> Bool {
        guard let peer = bondedPeerStore?.peers.first,
              let route = DirectSenderRoute.load(), route.macDeviceID == peer.id else { return false }
        directFallbackTask?.cancel()
        directFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled,
                  self.senderEndpoint == nil, !self.isConnecting, !self.autoConnectPaused else { return }
            self.isConnecting = true
            let connected = await self.connectDirectly(route, deviceName: peer.name)
            guard !Task.isCancelled, !connected else { return }
            self.isConnecting = false
            self.retryFromCurrentResults()
        }
        return true
    }

    private func retryAfterBonjourConnectFailure() {
        if !scheduleDirectFallback(after: 0) {
            retryFromCurrentResults()
        }
    }

    private func connectDirectly(_ route: DirectSenderRoute, deviceName: String?) async -> Bool {
        SyncLog.discovery.info("trying direct route \(route.hosts.joined(separator: ","), privacy: .public) port \(route.port)")
        guard let endpoint = await Self.firstVerifiedEndpoint(in: route) else {
            SyncLog.discovery.info("direct route unreachable or not the paired Mac")
            return false
        }
        guard !Task.isCancelled else { return false }
        adoptSenderEndpoint(endpoint, path: nil, deviceName: deviceName, deviceID: route.macDeviceID)
        return senderEndpoint != nil
    }

    nonisolated private static func firstVerifiedEndpoint(in route: DirectSenderRoute) async -> NWEndpoint? {
        let expectedID = route.macDeviceID
        return await withTaskGroup(of: NWEndpoint?.self) { group in
            for endpoint in route.endpoints {
                group.addTask {
                    guard let response = try? await NWHTTPClient.request(
                        endpoint: endpoint, method: "GET", path: "/identity", timeout: 3
                    ), response.statusCode == 200,
                          let identity = try? JSONDecoder().decode(SenderIdentity.self, from: response.body),
                          identity.deviceID == expectedID else { return nil }
                    return endpoint
                }
            }
            for await endpoint in group {
                if let endpoint {
                    group.cancelAll()
                    return endpoint
                }
            }
            return nil
        }
    }

    /// Receiver-side: start discovery on explicit user request (opening the pairing UI).
    /// Unpaired receivers do not browse at launch so the Local Network prompt appears
    /// only when the user asks to pair. Idempotent.
    public func beginDiscovery() {
        guard role == .receiver else { return }
        if isPaired {
            triggerReconnect()
        } else if browser == nil {
            startBrowsing()
        }
    }

    // MARK: Sender

    public func sendManifest(_ manifest: LibraryManifest) async throws {
        // Encode off the main actor — SwiftData ownership stays in TransferManager's
        // build path; this is only the JSON bytes served to idle `/manifest` polls.
        let encoded = try await Task.detached(priority: .userInitiated) {
            try JSONEncoder().encode(manifest)
        }.value
        currentManifest = manifest
        currentManifestData = encoded
        publishedManifestGeneration = manifest.generation
    }

    // MARK: Receiver

    public func requestManifest() async throws -> LibraryManifest {
        guard senderEndpoint != nil else {
            SyncLog.transport.error("manifest request attempted without a connected sender endpoint")
            throw SyncError.notConnected
        }
        SyncLog.transport.debug("GET /manifest via \(self.endpointLogDescription(), privacy: .public)")
        let response = try await performReceiverHTTP(method: "GET", path: "/manifest")
        guard response.statusCode == 200 else {
            SyncLog.transport.error("manifest fetch returned HTTP \(response.statusCode) via \(self.endpointLogDescription(), privacy: .public)")
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("manifest fetch returned non-200 (\(response.statusCode))")
        }
        let data = response.body
        // Decode off the main actor — a large manifest is still multi-MB of JSON
        // and blocks the UI for tens of ms if decoded inline on every periodic sync.
        let manifest = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(LibraryManifest.self, from: data)
        }.value
        lastManifestFetchAt = Date()
        clearAuthFailuresForCurrentPeer()
        SyncLog.receiver.info("received manifest generation \(manifest.generation) with \(manifest.tracks.count) tracks")
        return manifest
    }

    private struct GenerationResponse: Decodable {
        let generation: Int64
    }

    /// Cheap poll pre-check (`GET /generation`). Returns nil when the sender
    /// doesn't serve the endpoint (pre-6 Mac, or no manifest published yet) —
    /// callers must fall back to the full manifest fetch in that case.
    public func requestGeneration() async throws -> Int64? {
        guard senderEndpoint != nil else { throw SyncError.notConnected }
        let response = try await performReceiverHTTP(method: "GET", path: "/generation", timeout: 15)
        if response.statusCode == 404 {
            // Older peer without the endpoint (or manifest not ready) — full poll.
            return nil
        }
        guard response.statusCode == 200 else {
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("generation check returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        guard let decoded = try? JSONDecoder().decode(GenerationResponse.self, from: response.body) else {
            throw SyncError.transferFailed("generation check returned malformed body")
        }
        return decoded.generation
    }

    public func downloadFile(versionID: UUID) async throws -> URL {
        let path = "/files/\(versionID.uuidString)"
        return try await performReceiverDownload(path: path, failureContext: "file download for \(versionID)")
    }

    public func fileDownloadURL(versionID: UUID) throws -> URL {
        guard let base = senderBaseURL else { throw SyncError.notConnected }
        return base.appendingPathComponent("files/\(versionID.uuidString)")
    }

    public func downloadArtwork(trackID: UUID) async throws -> Data {
        let path = "/artwork/\(trackID.uuidString)"
        let response = try await performReceiverHTTP(method: "GET", path: path, timeout: 60)
        guard response.statusCode == 200 else {
            SyncLog.transport.error(
                "artwork download for \(trackID) returned HTTP \(response.statusCode) via \(self.endpointLogDescription(), privacy: .public)"
            )
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("artwork download returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        return response.body
    }

    public func downloadPlaylistArtwork(playlistID: UUID) async throws -> Data {
        let path = "/playlist-artwork/\(playlistID.uuidString)"
        let response = try await performReceiverHTTP(method: "GET", path: path, timeout: 60)
        guard response.statusCode == 200 else {
            SyncLog.transport.error(
                "playlist artwork download for \(playlistID) returned HTTP \(response.statusCode) via \(self.endpointLogDescription(), privacy: .public)"
            )
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("playlist artwork download returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        return response.body
    }

    /// Push playlist cover bytes to the Mac (raw octet-stream). Used by iOS when
    /// its local cover revision is newer than the one in the Mac's manifest.
    public func uploadPlaylistArtwork(playlistID: UUID, data: Data) async throws -> Bool {
        guard senderEndpoint != nil else { throw SyncError.notConnected }
        let response = try await performReceiverHTTP(
            method: "POST",
            path: "/playlist-artwork/\(playlistID.uuidString)",
            extraHeaders: ["Content-Type": "application/octet-stream"],
            body: data,
            timeout: 60
        )
        guard response.statusCode == 200 else {
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("playlist artwork upload returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        return true
    }

    public func downloadVoiceNote(noteID: UUID) async throws -> URL {
        let path = "/voice-notes/\(noteID.uuidString)"
        return try await performReceiverDownload(path: path, failureContext: "voice note download for \(noteID)")
    }

    // MARK: - HTTP Server (Sender / Mac)

    private func startHTTPServer() {
        guard listener == nil else {
            SyncLog.sender.debug("startHTTPServer skipped — listener already active")
            return
        }
        connectionState = .idle
        SyncLog.sender.info("starting HTTP server")

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let stickyPort = UInt16(exactly: UserDefaults.standard.integer(forKey: BouncePreferenceKey.senderListenerPort))
            .flatMap { $0 == 0 ? nil : $0 }
        let requestedPort = stickyPort ?? BounceConstants.defaultHTTPPort
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: requestedPort)!) else {
            connectionState = .disconnected
            SyncLog.sender.error("failed to create NWListener on port \(requestedPort)")
            UserDefaults.standard.removeObject(forKey: BouncePreferenceKey.senderListenerPort)
            scheduleListenerRestart()
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.listenerRestartAttempt = 0
                    if let port = listener.port {
                        SyncLog.sender.info("listener ready on port \(port.rawValue)")
                        UserDefaults.standard.set(Int(port.rawValue), forKey: BouncePreferenceKey.senderListenerPort)
                        self.advertiseBonjour(port: port.rawValue)
                        self.publishPairingLink()
                    }
                case .failed(let error):
                    SyncLog.sender.error("listener failed: \(error.localizedDescription, privacy: .public)")
                    guard self.listener === listener else { return }
                    UserDefaults.standard.removeObject(forKey: BouncePreferenceKey.senderListenerPort)
                    listener.cancel()
                    self.listener = nil
                    self.connectionState = .disconnected
                    self.scheduleListenerRestart()
                default:
                    SyncLog.sender.debug("listener state: \(String(describing: state), privacy: .public)")
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in
                self.activeConnections.append(connection)
                self.handleHTTPConnection(connection)
            }
        }

        listener.start(queue: networkQueue)
    }

    private func advertiseBonjour(port: UInt16) {
        SyncLog.discovery.info("advertising Bonjour as \(self._deviceName, privacy: .public) on port \(port)")
        let txtRecord = NWTXTRecord([
            "deviceName": _deviceName,
            "deviceID": deviceID.uuidString
        ])
        listener?.service = NWListener.Service(
            name: _deviceName,
            type: BounceConstants.bonjourServiceType,
            domain: nil,
            txtRecord: txtRecord
        )
    }

    private func scheduleListenerRestart() {
        listenerRestartTask?.cancel()
        listenerRestartAttempt += 1
        let delay = min(pow(2, Double(listenerRestartAttempt)), 60)
        SyncLog.sender.info("restarting listener in \(delay, privacy: .public) s (attempt \(self.listenerRestartAttempt, privacy: .public))")
        listenerRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.listener == nil else { return }
            self.startHTTPServer()
        }
    }

    // MARK: HTTP Connection Handling

    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        requestWatchdogs.arm(connection) { [weak self] in
            SyncLog.transport.error("closing connection: request idle for \(RequestIdleWatchdogs.idleTimeout, privacy: .public) s")
            Task { @MainActor in self?.closeConnection(connection) }
        }
        receiveHTTPRequest(connection)
    }

    private func receiveHTTPRequest(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                SyncLog.transport.error("receive error: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    self.closeConnection(connection)
                }
                return
            }
            var accumulated = buffered
            if let data, !data.isEmpty {
                accumulated.append(data)
                self.requestWatchdogs.touch(connection)
            }
            let request = accumulated
            let hasCompleteHeaders = request.range(of: Data("\r\n\r\n".utf8)) != nil
            Task { @MainActor in
                if hasCompleteHeaders {
                    self.processHTTPRequest(data: request, connection: connection)
                } else if request.isEmpty && isComplete {
                    self.closeConnection(connection)
                } else if isComplete || request.count > SyncBodyLimit.requestHeaders {
                    self.send400(connection)
                } else {
                    self.receiveHTTPRequest(connection, buffered: request)
                }
            }
        }
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) {
        // Split headers from body at \r\n\r\n — works on raw Data, no String conversion
        let headerEndMarker = Data("\r\n\r\n".utf8)
        guard let headerEndRange = data.range(of: headerEndMarker) else {
            send400(connection)
            return
        }

        let headerData = data[data.startIndex..<headerEndRange.lowerBound]
        let bodyData = data[headerEndRange.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            send400(connection)
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { send400(connection); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { send400(connection); return }
        let method = parts[0]
        let path = parts[1]
        let headers = requestHeaders(from: lines)
        if (Int(headers["content-length"] ?? "0") ?? 0) <= bodyData.count {
            requestWatchdogs.disarm(connection)
        }

        // Track request metadata
        lastClientRequestAt = Date()
        clientRequestCount += 1
        lastRequestPath = path

        let metadata = SyncRequestMetadata(
            path: path,
            deviceName: headers["x-bounce-device-name"],
            deviceID: headers["x-bounce-device-id"].flatMap(UUID.init(uuidString:)),
            appVersion: headers["x-bounce-app-version"],
            requestedAt: lastClientRequestAt ?? Date()
        )

        SyncLog.transport.debug("incoming request \(path, privacy: .public); total requests \(self.clientRequestCount)")

        // Pairing handshake bypasses authorisation — it's how new bonds get
        // established in the first place. Don't promote any UI state from
        // this either: the device isn't really "connected" until the bond
        // is approved.
        if path == "/pair" && method == "POST" {
            let declaredLength = Int(headers["content-length"] ?? "0") ?? 0
            receiveRequestBody(
                connection: connection,
                initialBody: Data(bodyData),
                declaredLength: declaredLength,
                maxLength: SyncBodyLimit.pair
            ) { [weak self] completeBody in
                guard let self else { return }
                guard let completeBody else {
                    self.send400(connection)
                    return
                }
                self.handlePairRequest(bodyData: completeBody, connection: connection, headers: headers)
            }
            return
        }

        if path == "/identity" && method == "GET" {
            sendJSON(connection, status: 200, statusText: "OK", payload: SenderIdentity(deviceID: deviceID, deviceName: deviceName))
            return
        }

        // Authorise every non-/pair request against the bonded peer
        // store BEFORE promoting any sender-side UI state. Pairing is
        // explicit — there is no legacy bypass: a request without a
        // matching bond gets 403, period.
        if let store = bondedPeerStore {
            guard let peer = authoriseRequest(headers: headers, store: store) else {
                guard !store.storedBondsUnreadable() else {
                    SyncLog.sender.error("bond store unreadable; answering \(path, privacy: .public) with 503")
                    send503(connection)
                    return
                }
                SyncLog.sender.error("rejecting unauthorised request to \(path, privacy: .public)")
                // Any request presenting a pair key we don't recognise is
                // working off a stale bond — explicit forget, silent keychain
                // wipe (e.g. ad-hoc resigning), or never-bonded device. Tell
                // the receiver to drop its side so both ends converge to
                // unpaired instead of leaving the receiver stuck with a
                // useless bond and "Auto-sync paused".
                send403(connection, forgotten: true)
                return
            }
            store.touch(id: peer.id, name: metadata.deviceName)
        }

        // Auth passed (or legacy mode) — now safe to publish "we're talking
        // to this device" state.
        if role == .sender {
            if let deviceName = metadata.deviceName {
                connectedDeviceName = deviceName
            }
            if let deviceID = metadata.deviceID {
                connectedDeviceID = deviceID
            }
            if let appVersion = metadata.appVersion {
                connectedAppVersion = appVersion
            }
        }
        requestMetadataHandler?(metadata)

        // Sender: transition to .connected on first authorised request.
        if role == .sender, connectionState == .idle {
            connectionState = .connected
        }

        if path == "/pair" && method == "DELETE" {
            // Authenticated device asked us to drop the bond on this side.
            // Use the deviceID resolved by `authoriseRequest` above (already
            // touched the peer); just forget it now.
            if let idString = headers["x-bounce-device-id"],
               let deviceID = UUID(uuidString: idString) {
                bondedPeerStore?.forget(id: deviceID)
                SyncLog.sender.info("forgot peer \(deviceID, privacy: .public) per remote DELETE /pair")
            }
            sendHTTPResponse(connection, statusCode: 200, statusText: "OK", contentType: "text/plain", body: Data())
            // Notify the UI: drop any active connection state for this peer.
            if connectedDeviceID != nil {
                connectionState = .disconnected
                connectedDeviceID = nil
                connectedDeviceName = nil
                connectedAppVersion = nil
            }
            return
        }

        if path == "/pair/status" && method == "GET" {
            sendHTTPResponse(connection, statusCode: 200, statusText: "OK", contentType: "text/plain", body: Data("OK".utf8))
        } else if path == "/manifest" && method == "GET" {
            serveManifest(connection)
        } else if path == "/generation" && method == "GET" {
            serveGeneration(connection)
        } else if path.hasPrefix("/files/") && method == "GET" {
            let idString = String(path.dropFirst("/files/".count))
            if let versionID = UUID(uuidString: idString) {
                serveFile(versionID: versionID, connection: connection)
            } else {
                send404(connection)
            }
        } else if path.hasPrefix("/artwork/") && method == "GET" {
            let idString = String(path.dropFirst("/artwork/".count))
            if let trackID = UUID(uuidString: idString) {
                serveArtwork(trackID: trackID, connection: connection)
            } else {
                send404(connection)
            }
        } else if path.hasPrefix("/playlist-artwork/") && method == "GET" {
            let idString = String(path.dropFirst("/playlist-artwork/".count))
            if let playlistID = UUID(uuidString: idString) {
                servePlaylistArtwork(playlistID: playlistID, connection: connection)
            } else {
                send404(connection)
            }
        } else if path.hasPrefix("/playlist-artwork/") && method == "POST" {
            let idString = String(path.dropFirst("/playlist-artwork/".count))
            guard let playlistID = UUID(uuidString: idString) else {
                send404(connection)
                return
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            receiveRequestBody(
                connection: connection,
                initialBody: Data(bodyData),
                declaredLength: contentLength,
                maxLength: SyncBodyLimit.playlistArtwork
            ) { [weak self] completeBody in
                guard let self else { return }
                guard let completeBody, !completeBody.isEmpty else {
                    self.send400(connection)
                    return
                }
                self.handlePlaylistArtworkUpload(playlistID: playlistID, body: completeBody, connection: connection)
            }
        } else if path.hasPrefix("/voice-notes/") && method == "GET" {
            let idString = String(path.dropFirst("/voice-notes/".count))
            if let noteID = UUID(uuidString: idString) {
                serveVoiceNote(noteID: noteID, connection: connection)
            } else {
                send404(connection)
            }
        } else if path == "/voice-notes/upload" && method == "POST" {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            guard contentLength <= SyncBodyLimit.voiceNoteUpload else {
                send413(connection)
                return
            }
            let initialBody = Data(bodyData)
            let remaining = contentLength - initialBody.count
            handleVoiceNoteUpload(connection: connection, headers: headers, initialBody: initialBody, remaining: remaining)
        } else if path == "/ios-manifest" && method == "POST" {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            receiveRequestBody(
                connection: connection,
                initialBody: Data(bodyData),
                declaredLength: contentLength,
                maxLength: SyncBodyLimit.iosManifest
            ) { [weak self] completeBody in
                guard let self else { return }
                guard let completeBody else {
                    self.send400(connection)
                    return
                }
                self.handleIOSManifestPush(bodyData: completeBody, connection: connection)
            }
        } else if path == "/upload" && method == "POST" {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            guard contentLength <= SyncBodyLimit.upload else {
                send413(connection)
                return
            }
            let initialBody = Data(bodyData)
            let remaining = contentLength - initialBody.count
            handleUpload(connection: connection, headers: headers, initialBody: initialBody, remaining: remaining)
        } else {
            send404(connection)
        }
    }

    /// Resolves the requesting peer against the bond store. Returns the
    /// matched peer if both `X-Bounce-Device-ID` and the base64-encoded
    /// `X-Bounce-Pair-Key` line up; nil otherwise.
    private func authoriseRequest(headers: [String: String], store: BondedPeerStore) -> BondedPeer? {
        guard let idString = headers["x-bounce-device-id"],
              let deviceID = UUID(uuidString: idString) else { return nil }
        guard let keyB64 = headers["x-bounce-pair-key"],
              let keyData = Data(base64Encoded: keyB64) else { return nil }
        return store.authorize(id: deviceID, sharedKey: keyData)
    }

    // MARK: - Pair Endpoint (Sender)

    private func handlePairRequest(bodyData: Data, connection: NWConnection, headers: [String: String]) {
        guard let request = try? JSONDecoder().decode(PairRequest.self, from: bodyData) else {
            SyncLog.sender.error("received malformed /pair body")
            send400(connection)
            return
        }

        SyncLog.sender.info("pair request from \(request.deviceName, privacy: .public) (\(request.deviceID.uuidString, privacy: .public)) code=\(request.verificationCode, privacy: .public)")

        if isPairThrottled(deviceID: request.deviceID) {
            SyncLog.sender.error("pair request from \(request.deviceID.uuidString, privacy: .public) throttled — too many recent failures")
            sendJSON(
                connection,
                status: 429,
                statusText: "Too Many Requests",
                payload: PairResponse(
                    ok: false,
                    deviceID: deviceID,
                    deviceName: deviceName,
                    sharedKeyBase64: nil,
                    error: "too many failed pair attempts; try again in a minute"
                )
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Re-evaluate state inside the Task so that two concurrent
            // /pair requests can't both decide they're "first-run" before
            // either has had a chance to bond. The store mutation in
            // `bond(_:)` happens on the same actor, so subsequent tasks
            // observe the updated state.
            let outcome: PairOutcome
            if let presentedToken = headers["x-bounce-pair-token"],
               headers["x-bounce-pair-key"] == nil,
               self.consumePairingToken(presentedToken),
               let tokenHandler = self.tokenPairHandler {
                SyncLog.sender.info("pair request carried a valid pairing token; approving without code check")
                outcome = tokenHandler(request)
            } else if let existing = self.bondedPeerStore?.peer(id: request.deviceID) {
                // Already bonded: auto-approve only when the requester proves
                // possession of the currently bonded shared key.
                if let presentedB64 = headers["x-bounce-pair-key"] {
                    guard let presented = Data(base64Encoded: presentedB64),
                          presented == existing.sharedKey else {
                        SyncLog.sender.error("pair request for existing peer failed key proof")
                        self.recordPairFailure(deviceID: request.deviceID)
                        self.sendJSON(
                            connection,
                            status: 403,
                            statusText: "Forbidden",
                            payload: PairResponse(
                                ok: false,
                                deviceID: self.deviceID,
                                deviceName: self.deviceName,
                                sharedKeyBase64: nil,
                                error: "invalid pairing proof"
                            )
                        )
                        return
                    }
                    outcome = .approved(sharedKey: existing.sharedKey)
                } else if let handler = self.pairApprovalHandler {
                    outcome = await handler(request)
                } else {
                    outcome = .denied(reason: "pairing requires user approval")
                }
            } else if let handler = self.pairApprovalHandler {
                outcome = await handler(request)
            } else {
                outcome = .denied(reason: "no pairing UI registered")
            }

            switch outcome {
            case .approved(let sharedKey):
                let peer = BondedPeer(
                    id: request.deviceID,
                    name: request.deviceName,
                    sharedKey: sharedKey
                )
                let response = PairResponse(
                    ok: true,
                    deviceID: self.deviceID,
                    deviceName: self.deviceName,
                    sharedKeyBase64: sharedKey.base64EncodedString(),
                    error: nil
                )
                // Persist the bond only after the receiver has actually
                // received the success response. This keeps both sides
                // consistent: if the response can't be delivered, we behave
                // as though pairing never happened.
                self.sendPairResponse(connection, status: 200, statusText: "OK", payload: response) { [weak self] sent in
                    guard let self, sent else {
                        SyncLog.sender.warning("pair approval response failed to deliver; not bonding")
                        return
                    }
                    // Sync is 1:1 — when a brand-new deviceID gets approved,
                    // forget every other bond so a fresh iOS install (which
                    // mints a new deviceID and can't notify us about the old
                    // one) doesn't leave ghost peers in the keychain forever.
                    if let store = self.bondedPeerStore, !store.contains(id: request.deviceID) {
                        let stale = store.peers.map(\.id)
                        for id in stale {
                            SyncLog.sender.info("forgetting stale bond \(id, privacy: .public) — replaced by new pair with \(request.deviceID, privacy: .public)")
                            store.forget(id: id)
                        }
                    }
                    self.bondedPeerStore?.bond(peer)
                    self.pairFailureHistory[request.deviceID] = nil
                    self.connectedDeviceName = request.deviceName
                    self.connectedDeviceID = request.deviceID
                    self.connectedAppVersion = request.appVersion
                    self.connectionState = .connected
                }
            case .denied(let reason):
                self.recordPairFailure(deviceID: request.deviceID)
                let response = PairResponse(
                    ok: false,
                    deviceID: self.deviceID,
                    deviceName: self.deviceName,
                    sharedKeyBase64: nil,
                    error: reason
                )
                self.sendJSON(connection, status: 403, statusText: "Forbidden", payload: response)
            }
        }
    }

    private func publishPairingLink() {
        pairingTokenIssuer.rotateIfExpired()
        let link = PairingLink(
            macDeviceID: deviceID,
            macName: deviceName,
            token: pairingTokenIssuer.token,
            expiresAt: pairingTokenIssuer.expiresAt,
            hosts: LocalNetworkAddresses.current(),
            port: listener?.port?.rawValue
        )
        if pairingLink != link {
            pairingLink = link
        }
        schedulePairingLinkRotation()
    }

    private func startSenderPathMonitor() {
        guard senderPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pairingLink != nil else { return }
                self.publishPairingLink()
            }
        }
        monitor.start(queue: networkQueue)
        senderPathMonitor = monitor
    }

    private func schedulePairingLinkRotation() {
        pairingLinkRotationTask?.cancel()
        let delay = max(pairingTokenIssuer.expiresAt.timeIntervalSinceNow, 0)
        pairingLinkRotationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pairingTokenIssuer.rotate()
            self.publishPairingLink()
        }
    }

    private func consumePairingToken(_ presented: String) -> Bool {
        guard pairingTokenIssuer.consume(presented) else { return false }
        publishPairingLink()
        return true
    }

    /// Returns true when this deviceID has accumulated enough recent
    /// failed pair attempts that we should silently reject without
    /// surfacing a modal. Successful approval clears the history.
    private func isPairThrottled(deviceID: UUID) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.pairFailureWindow)
        let recent = (pairFailureHistory[deviceID] ?? []).filter { $0 > cutoff }
        if recent.count != pairFailureHistory[deviceID]?.count {
            pairFailureHistory[deviceID] = recent.isEmpty ? nil : recent
        }
        return recent.count >= Self.pairFailureLimit
    }

    private func recordPairFailure(deviceID: UUID) {
        let cutoff = Date().addingTimeInterval(-Self.pairFailureWindow)
        var history = (pairFailureHistory[deviceID] ?? []).filter { $0 > cutoff }
        history.append(Date())
        pairFailureHistory[deviceID] = history
    }

    /// Send a JSON pair response and report delivery success. `onComplete`
    /// is invoked on the main actor with `true` when the bytes flushed to
    /// the kernel successfully, `false` on send error or encode failure.
    private func sendPairResponse<T: Encodable>(
        _ connection: NWConnection,
        status: Int,
        statusText: String,
        payload: T,
        onComplete: @escaping @MainActor (Bool) -> Void
    ) {
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            send500(connection)
            Task { @MainActor in onComplete(false) }
            return
        }
        let header =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                self?.recordServedBytes(Int64(body.count))
                self?.closeConnection(connection)
                onComplete(error == nil)
            }
        })
    }

    private func sendJSON<T: Encodable>(_ connection: NWConnection, status: Int, statusText: String, payload: T) {
        do {
            let body = try JSONEncoder().encode(payload)
            sendHTTPResponse(connection, statusCode: status, statusText: statusText, contentType: "application/json", body: body)
        } catch {
            send500(connection)
        }
    }

    /// Ensures we have a complete HTTP request body according to
    /// `Content-Length`. Some requests (including `/pair`) may arrive split
    /// across multiple TCP packets.
    private func receiveRequestBody(
        connection: NWConnection,
        initialBody: Data,
        declaredLength: Int,
        maxLength: Int,
        onComplete deliver: @escaping @MainActor (Data?) -> Void
    ) {
        let watchdogs = requestWatchdogs
        let onComplete: @MainActor (Data?) -> Void = { body in
            watchdogs.disarm(connection)
            deliver(body)
        }
        if declaredLength > maxLength || initialBody.count > maxLength {
            SyncLog.transport.error("request body too large (declared \(declaredLength, privacy: .public), cap \(maxLength, privacy: .public)); rejecting with 413")
            send413(connection)
            return
        }

        if declaredLength <= 0 || initialBody.count >= declaredLength {
            Task { @MainActor in onComplete(initialBody) }
            return
        }

        var body = initialBody

        func accumulate() {
            let needed = declaredLength - body.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(needed, 1_048_576)) { data, _, isComplete, error in
                if let error {
                    SyncLog.transport.error("request body receive error: \(error.localizedDescription, privacy: .public)")
                    Task { @MainActor in onComplete(nil) }
                    return
                }
                if let data {
                    watchdogs.touch(connection)
                    body.append(data)
                }
                if body.count >= declaredLength {
                    Task { @MainActor in onComplete(body) }
                } else if isComplete {
                    SyncLog.transport.error(
                        "request body ended early (\(body.count)/\(declaredLength), privacy: .public)"
                    )
                    Task { @MainActor in onComplete(nil) }
                } else {
                    accumulate()
                }
            }
        }

        accumulate()
    }

    private func serveManifest(_ connection: NWConnection) {
        guard let body = currentManifestData else {
            send404(connection)
            return
        }
        sendHTTPResponse(
            connection,
            statusCode: 200,
            statusText: "OK",
            contentType: "application/json",
            body: body
        )
    }

    /// Tiny poll pre-check body: the receiver compares this against its last
    /// applied generation and only downloads the full manifest on mismatch.
    private func serveGeneration(_ connection: NWConnection) {
        guard let generation = currentManifest?.generation else {
            send404(connection)
            return
        }
        sendHTTPResponse(
            connection,
            statusCode: 200,
            statusText: "OK",
            contentType: "application/json",
            body: Data("{\"generation\":\(generation)}".utf8)
        )
    }

    private func serveFile(versionID: UUID, connection: NWConnection) {
        guard let provider = fileProvider, let fileURL = provider(versionID) else {
            send404(connection)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await Self.streamFileResponse(from: fileURL, connection: connection)
                await self.recordServedBytes(bytes)
                await self.closeConnection(connection)
                await self.notifyFileServed(versionID)
            } catch {
                SyncLog.sender.error("failed to stream \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await self.failFileResponse(connection, error: error)
            }
        }
    }

    private func serveArtwork(trackID: UUID, connection: NWConnection) {
        guard let provider = artworkProvider, let data = provider(trackID), !data.isEmpty else {
            send404(connection)
            return
        }
        sendHTTPResponse(
            connection,
            statusCode: 200,
            statusText: "OK",
            contentType: "application/octet-stream",
            body: data
        )
    }

    private func servePlaylistArtwork(playlistID: UUID, connection: NWConnection) {
        guard let provider = playlistArtworkProvider, let data = provider(playlistID), !data.isEmpty else {
            send404(connection)
            return
        }
        sendHTTPResponse(
            connection,
            statusCode: 200,
            statusText: "OK",
            contentType: "application/octet-stream",
            body: data
        )
    }

    private func handlePlaylistArtworkUpload(playlistID: UUID, body: Data, connection: NWConnection) {
        guard let handler = playlistArtworkUploadHandler else {
            send404(connection)
            return
        }
        Task { @MainActor [weak self] in
            let success = await handler(playlistID, body)
            guard let self else { return }
            if success {
                self.sendHTTPResponse(
                    connection,
                    statusCode: 200,
                    statusText: "OK",
                    contentType: "application/json",
                    body: Data("{\"status\":\"ok\"}".utf8)
                )
            } else {
                SyncLog.sender.error("playlist artwork upload rejected for \(playlistID, privacy: .public)")
                self.send500(connection)
            }
        }
    }

    private func serveVoiceNote(noteID: UUID, connection: NWConnection) {
        guard let provider = voiceNoteProvider, let fileURL = provider(noteID) else {
            send404(connection)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await Self.streamFileResponse(from: fileURL, connection: connection)
                await self.recordServedBytes(bytes)
                await self.closeConnection(connection)
            } catch {
                SyncLog.sender.error("failed to stream voice note \(noteID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await self.failFileResponse(connection, error: error)
            }
        }
    }

    // MARK: - iOS Manifest Push

    private func handleIOSManifestPush(bodyData: Data, connection: NWConnection) {
        // Mirror requestManifest: decode off main before SwiftData merge on MainActor.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let manifest = try JSONDecoder().decode(LibraryManifest.self, from: bodyData)
                await MainActor.run {
                    guard let self else { return }
                    SyncLog.sender.info(
                        "received iOS manifest: \(manifest.tracks.count) tracks, \(manifest.notes.count) notes from \(manifest.senderName)"
                    )
                    self.iosManifestHandler?(manifest)
                    self.sendHTTPResponse(
                        connection,
                        statusCode: 200,
                        statusText: "OK",
                        contentType: "application/json",
                        body: Data("{\"ok\":true}".utf8)
                    )
                }
            } catch let decError as DecodingError {
                let msg = Self.describeDecodingError(decError)
                let preview = String(data: bodyData.prefix(2000), encoding: .utf8) ?? "<non-utf8>"
                await MainActor.run {
                    guard let self else { return }
                    SyncLog.sender.error("iOS manifest decode failed: \(msg)")
                    SyncLog.sender.error("iOS manifest payload prefix: \(preview)")
                    self.send400(connection)
                }
            } catch {
                let errorDescription = String(describing: error)
                await MainActor.run {
                    guard let self else { return }
                    SyncLog.sender.error("iOS manifest decode failed: \(errorDescription)")
                    self.send400(connection)
                }
            }
        }
    }

    nonisolated private static func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "keyNotFound: \(key.stringValue) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")) — \(ctx.debugDescription)"
        case .typeMismatch(let type, let ctx):
            return "typeMismatch: expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")) — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "valueNotFound: \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")) — \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            return "dataCorrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")) — \(ctx.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    // MARK: Upload Handling

    private func handleUpload(
        connection: NWConnection,
        headers: [String: String],
        initialBody: Data,
        remaining: Int
    ) {
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        SyncLog.sender.info(
            "POST /upload received: \(initialBody.count) bytes initial, \(remaining) remaining (content-length \(contentLength))"
        )
        accumulateRequestBodyToTempFile(
            connection: connection,
            initialBody: initialBody,
            remaining: remaining,
            label: "upload"
        ) { [weak self] bodyURL in
            guard let self else { return }
            guard let bodyURL else {
                Task { @MainActor in self.send500(connection) }
                return
            }
            // Brief MainActor hop only to start off-main parse/handler work.
            Task { @MainActor in
                self.processUploadBodyFile(bodyURL, headers: headers, connection: connection)
            }
        }
    }

    private func processUploadBodyFile(_ bodyURL: URL, headers: [String: String], connection: NWConnection) {
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            let contentType = headers["content-type"] ?? ""
            guard contentType.hasPrefix("multipart/form-data; boundary=") else {
                await self?.send400(connection)
                return
            }
            let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

            let body: Data
            do {
                body = try Data(contentsOf: bodyURL, options: .alwaysMapped)
            } catch {
                SyncLog.sender.error("upload body read failed: \(error.localizedDescription, privacy: .public)")
                await self?.send500(connection)
                return
            }

            let parts = Self.parseMultipartStatic(body: body, boundary: boundary)
            guard let filePart = parts.first(where: { $0.name == "file" }) else {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 400,
                    statusText: "Bad Request",
                    contentType: "text/plain",
                    body: Data("Missing file part".utf8)
                )
                return
            }

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bounce-upload-file-\(UUID().uuidString)")
            do {
                try filePart.data.write(to: fileURL, options: .atomic)
            } catch {
                SyncLog.sender.error("upload file extract failed: \(error.localizedDescription, privacy: .public)")
                await self?.send500(connection)
                return
            }

            let payload = UploadPayload(
                trackName: parts.first(where: { $0.name == "trackName" })?.value ?? "Unknown",
                versionLabel: parts.first(where: { $0.name == "versionLabel" })?.value ?? "v1",
                originalFilename: filePart.filename ?? "upload.m4a",
                fileFormat: parts.first(where: { $0.name == "fileFormat" })?.value ?? "m4a",
                versionID: parts.first(where: { $0.name == "versionID" }).flatMap { $0.value }.flatMap(UUID.init(uuidString:)),
                trackID: parts.first(where: { $0.name == "trackID" }).flatMap { $0.value }.flatMap(UUID.init(uuidString:)),
                targetTrackID: parts.first(where: { $0.name == "targetTrackID" }).flatMap { $0.value }.flatMap(UUID.init(uuidString:)),
                fileURL: fileURL,
                sourceDeviceName: headers["x-bounce-device-name"],
                sourceDeviceID: headers["x-bounce-device-id"].flatMap(UUID.init(uuidString:)),
                sourceContentHash: parts.first(where: { $0.name == "sourceContentHash" })?.value
            )

            let success = await self?.invokeUploadHandler(payload) ?? false
            // Handler owns/moves the file on success; clean up leftovers either way.
            try? FileManager.default.removeItem(at: fileURL)

            if success {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 200,
                    statusText: "OK",
                    contentType: "application/json",
                    body: Data("{\"status\":\"ok\"}".utf8)
                )
            } else {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 500,
                    statusText: "Import Failed",
                    contentType: "text/plain",
                    body: Data("Upload processing failed".utf8)
                )
            }
        }
    }

    private func invokeUploadHandler(_ payload: UploadPayload) async -> Bool {
        guard let uploadHandler else {
            return false
        }
        return await uploadHandler(payload)
    }

    // MARK: Voice Note Upload Handling

    private func handleVoiceNoteUpload(
        connection: NWConnection,
        headers: [String: String],
        initialBody: Data,
        remaining: Int
    ) {
        SyncLog.sender.info(
            "POST /voice-notes/upload received: \(initialBody.count) bytes initial, \(remaining) remaining"
        )
        accumulateRequestBodyToTempFile(
            connection: connection,
            initialBody: initialBody,
            remaining: remaining,
            label: "voice-note upload"
        ) { [weak self] bodyURL in
            guard let self else { return }
            guard let bodyURL else {
                Task { @MainActor in self.send500(connection) }
                return
            }
            Task { @MainActor in
                self.processVoiceNoteUploadBodyFile(bodyURL, headers: headers, connection: connection)
            }
        }
    }

    private func processVoiceNoteUploadBodyFile(_ bodyURL: URL, headers: [String: String], connection: NWConnection) {
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            let contentType = headers["content-type"] ?? ""
            guard contentType.hasPrefix("multipart/form-data; boundary=") else {
                await self?.send400(connection)
                return
            }
            let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

            let body: Data
            do {
                body = try Data(contentsOf: bodyURL, options: .alwaysMapped)
            } catch {
                SyncLog.sender.error("voice-note body read failed: \(error.localizedDescription, privacy: .public)")
                await self?.send500(connection)
                return
            }

            let parts = Self.parseMultipartStatic(body: body, boundary: boundary)
            guard let filePart = parts.first(where: { $0.name == "file" }) else {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 400,
                    statusText: "Bad Request",
                    contentType: "text/plain",
                    body: Data("Missing file part".utf8)
                )
                return
            }
            guard let noteIDString = parts.first(where: { $0.name == "noteID" })?.value,
                  let noteID = UUID(uuidString: noteIDString) else {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 400,
                    statusText: "Bad Request",
                    contentType: "text/plain",
                    body: Data("Missing or malformed noteID".utf8)
                )
                return
            }

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bounce-voice-\(noteID.uuidString)-\(UUID().uuidString).m4a")
            do {
                try filePart.data.write(to: fileURL, options: .atomic)
            } catch {
                SyncLog.sender.error("voice-note file extract failed: \(error.localizedDescription, privacy: .public)")
                await self?.send500(connection)
                return
            }

            let payload = VoiceNoteUploadPayload(
                noteID: noteID,
                fileURL: fileURL,
                sourceDeviceName: headers["x-bounce-device-name"],
                sourceDeviceID: headers["x-bounce-device-id"].flatMap(UUID.init(uuidString:))
            )

            let success = await self?.invokeVoiceNoteUploadHandler(payload) ?? false
            try? FileManager.default.removeItem(at: fileURL)

            if success {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 200,
                    statusText: "OK",
                    contentType: "application/json",
                    body: Data("{\"status\":\"ok\"}".utf8)
                )
            } else {
                await self?.sendHTTPResponse(
                    connection,
                    statusCode: 500,
                    statusText: "Import Failed",
                    contentType: "text/plain",
                    body: Data("Voice note upload processing failed".utf8)
                )
            }
        }
    }

    private func invokeVoiceNoteUploadHandler(_ payload: VoiceNoteUploadPayload) async -> Bool {
        guard let voiceNoteUploadHandler else {
            return false
        }
        return await voiceNoteUploadHandler(payload)
    }

    /// Writes the HTTP body to a temp file on the connection queue — no MainActor hops
    /// and no growing in-memory `Data` passed across actors.
    nonisolated private func accumulateRequestBodyToTempFile(
        connection: NWConnection,
        initialBody: Data,
        remaining: Int,
        label: String,
        onComplete deliver: @escaping @Sendable (URL?) -> Void
    ) {
        let watchdogs = requestWatchdogs
        let onComplete: @Sendable (URL?) -> Void = { url in
            watchdogs.disarm(connection)
            deliver(url)
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounce-body-\(UUID().uuidString).tmp")

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            SyncLog.sender.error("\(label, privacy: .public): cannot create temp body file")
            onComplete(nil)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            SyncLog.sender.error("\(label, privacy: .public): cannot open temp body file")
            onComplete(nil)
            return
        }

        do {
            try handle.write(contentsOf: initialBody)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            SyncLog.sender.error("\(label, privacy: .public): temp write failed: \(error.localizedDescription, privacy: .public)")
            onComplete(nil)
            return
        }

        if remaining <= 0 {
            try? handle.close()
            onComplete(tempURL)
            return
        }

        let needed = initialBody.count + remaining
        final class BodyWriteState: @unchecked Sendable {
            var written: Int
            let handle: FileHandle
            init(written: Int, handle: FileHandle) {
                self.written = written
                self.handle = handle
            }
        }
        let state = BodyWriteState(written: initialBody.count, handle: handle)

        func accumulate() {
            let toRead = max(1, min(needed - state.written, 1_048_576))
            connection.receive(minimumIncompleteLength: 1, maximumLength: toRead) { data, _, isComplete, error in
                if let error {
                    SyncLog.sender.error("\(label, privacy: .public) receive error: \(error.localizedDescription, privacy: .public)")
                    try? state.handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    onComplete(nil)
                    return
                }
                if let data, !data.isEmpty {
                    watchdogs.touch(connection)
                    do {
                        try state.handle.write(contentsOf: data)
                        state.written += data.count
                    } catch {
                        SyncLog.sender.error("\(label, privacy: .public) temp write failed: \(error.localizedDescription, privacy: .public)")
                        try? state.handle.close()
                        try? FileManager.default.removeItem(at: tempURL)
                        onComplete(nil)
                        return
                    }
                }
                if state.written >= needed {
                    try? state.handle.close()
                    onComplete(tempURL)
                } else if isComplete {
                    SyncLog.sender.error("\(label, privacy: .public) connection closed before full body (\(state.written)/\(needed))")
                    try? state.handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    onComplete(nil)
                } else {
                    accumulate()
                }
            }
        }
        accumulate()
    }

    // MARK: Multipart Parser

    nonisolated private struct MultipartPart: Sendable {
        let name: String
        let filename: String?
        let data: Data
        /// For text fields, the decoded string value.
        var value: String? {
            String(data: data, encoding: .utf8)
        }
    }

    nonisolated private static func parseMultipartStatic(body: Data, boundary: String) -> [MultipartPart] {
        let boundaryData = Data("--\(boundary)".utf8)
        let delimiterData = Data("--\(boundary)\r\n".utf8)
        let endDelimiterData = Data("--\(boundary)--".utf8)
        let headerEndMarker = Data("\r\n\r\n".utf8)

        var parts: [MultipartPart] = []
        var searchStart = body.startIndex

        // Find first boundary
        guard let firstBoundary = body.range(of: delimiterData, in: searchStart..<body.endIndex) else {
            return parts
        }
        searchStart = firstBoundary.upperBound

        while searchStart < body.endIndex {
            // Find end of part headers
            guard let headerEnd = body.range(of: headerEndMarker, in: searchStart..<body.endIndex) else {
                break
            }
            let headerData = body[searchStart..<headerEnd.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                break
            }

            // Parse Content-Disposition
            let name = extractAttributeValueStatic(from: headerString, attribute: "name")
            let filename = extractAttributeValueStatic(from: headerString, attribute: "filename")

            let contentStart = headerEnd.upperBound

            // Find next boundary
            let nextBoundary = body.range(of: boundaryData, in: contentStart..<body.endIndex)
            let contentEnd = nextBoundary?.lowerBound ?? body.endIndex

            // Content ends with \r\n before boundary
            let actualEnd = contentEnd >= 2 && body[contentEnd-2..<contentEnd] == Data("\r\n".utf8)
                ? contentEnd - 2
                : contentEnd

            let contentData = body[contentStart..<actualEnd]
            parts.append(MultipartPart(name: name ?? "", filename: filename, data: contentData))

            guard let next = nextBoundary else { break }

            // Check for end delimiter
            let afterBoundary = body[next.lowerBound..<min(next.lowerBound + endDelimiterData.count, body.endIndex)]
            if afterBoundary == endDelimiterData.prefix(afterBoundary.count) {
                break
            }

            searchStart = next.upperBound + 2 // skip \r\n after boundary
        }

        return parts
    }

    nonisolated private static func extractAttributeValueStatic(from header: String, attribute: String) -> String? {
        // Extract value from: name="value" or filename="value"
        guard let range = header.range(of: "\(attribute)=\"") else { return nil }
        let afterQuote = header[range.upperBound...]
        guard let endQuote = afterQuote.firstIndex(of: "\"") else { return nil }
        return String(afterQuote[..<endQuote])
    }

    private func sendHTTPResponse(
        _ connection: NWConnection,
        statusCode: Int,
        statusText: String,
        contentType: String,
        extraHeaders: [String: String] = [:],
        body: Data
    ) {
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: \(contentType)\r\n"
        for (key, value) in extraHeaders {
            header += "\(key): \(value)\r\n"
        }
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.recordServedBytes(Int64(body.count))
                self?.closeConnection(connection)
            }
        })
    }

    private func send400(_ connection: NWConnection) {
        sendHTTPResponse(connection, statusCode: 400, statusText: "Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8))
    }

    private func send413(_ connection: NWConnection) {
        sendHTTPResponse(connection, statusCode: 413, statusText: "Payload Too Large", contentType: "text/plain", body: Data("Payload Too Large".utf8))
    }

    private func send503(_ connection: NWConnection) {
        sendHTTPResponse(connection, statusCode: 503, statusText: "Service Unavailable", contentType: "text/plain", body: Data("Service Unavailable".utf8))
    }

    private func send404(_ connection: NWConnection) {
        sendHTTPResponse(connection, statusCode: 404, statusText: "Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
    }

    private func send500(_ connection: NWConnection) {
        sendHTTPResponse(connection, statusCode: 500, statusText: "Internal Server Error", contentType: "text/plain", body: Data("Internal Server Error".utf8))
    }

    private func send403(_ connection: NWConnection, forgotten: Bool = false) {
        var extra: [String: String] = [:]
        if forgotten { extra["X-Bounce-Auth-Reason"] = "forgotten" }
        sendHTTPResponse(connection, statusCode: 403, statusText: "Forbidden", contentType: "text/plain", extraHeaders: extra, body: Data("Forbidden".utf8))
    }

    // MARK: - Bonjour Browser (Receiver / iOS)

    private func startBrowsing(triggered: Bool = false) {
        connectionState = .searching
        SyncLog.discovery.info("starting receiver Bonjour browser for \(BounceConstants.bonjourServiceType, privacy: .public)")

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: BounceConstants.bonjourServiceType,
                domain: BounceConstants.bonjourDomain
            ),
            using: params
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    SyncLog.discovery.info("browser ready")
                case .failed(let error):
                    SyncLog.discovery.error("browser failed: \(error.localizedDescription, privacy: .public)")
                    self.connectionState = .disconnected
                case .cancelled:
                    SyncLog.discovery.debug("browser cancelled")
                default:
                    SyncLog.discovery.debug("browser state: \(String(describing: state), privacy: .public)")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshDiscoveredPeers(from: results)

                // If we were connected but the sender disappeared from results, disconnect
                if self.senderBaseURL != nil, results.isEmpty {
                    SyncLog.discovery.info("sender disappeared from browse results; resetting receiver state")
                    self.resetReceiverState()
                    return
                }

                // Check if the sender we were connected to is still in results
                if self.senderBaseURL != nil, let connectedName = self.connectedDeviceName {
                    let stillPresent = results.contains { result in
                        if case let .service(name, _, _, _) = result.endpoint {
                            return name == connectedName
                        }
                        return false
                    }
                    if !stillPresent {
                        SyncLog.discovery.info("connected sender \(connectedName, privacy: .public) disappeared from browse results")
                        self.resetReceiverState()
                        return
                    }
                }

                guard self.senderBaseURL == nil, !self.isConnecting, !self.autoConnectPaused else { return }
                guard let result = self.preferredAutoConnectResult(from: results) else { return }
                self.connectToSender(result)
            }
        }

        browser.start(queue: networkQueue)

        if triggered {
            browserTimeoutTask?.cancel()
            browserTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                guard !Task.isCancelled else { return }
                guard self.browser != nil, self.senderBaseURL == nil else { return }
                SyncLog.receiver.debug("trigger-based browse timeout; stopping browser")
                self.stopBrowsing()
                self.connectionState = .disconnected
            }
        }
    }

    private func connectToSender(_ result: NWBrowser.Result) {
        isConnecting = true

        // Extract device name from TXT record if available.
        var discoveredName: String? = nil
        var discoveredDeviceID: UUID? = nil
        if case let .service(name, _, _, _) = result.endpoint {
            discoveredName = name
        }
        if case let .bonjour(txtRecord) = result.metadata {
            discoveredName = txtRecord.dictionary["deviceName"] ?? discoveredName
            if let rawDeviceID = txtRecord.dictionary["deviceID"] {
                discoveredDeviceID = UUID(uuidString: rawDeviceID)
            }
        }

        SyncLog.discovery.info("connecting to sender \(discoveredName ?? "Unknown", privacy: .public)")
        // Manual pairing has its own state. Keep it through URL resolution so
        // the receiver does not publish `.connected` and start syncing before
        // the shared key has been stored.
        if connectionState != .pairing {
            connectionState = .found(deviceName: discoveredName ?? "Unknown")
        }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        let connectionID = ObjectIdentifier(connection)
        activeConnections.append(connection)
        let resolvedName = discoveredName
        let resolvedDeviceID = discoveredDeviceID

        // Cancel previous timeout if any
        connectTimeoutTask?.cancel()

        // Timeout: if connection doesn't become ready in 8 seconds, cancel and retry
        connectTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            guard self.isConnecting else { return }
            SyncLog.discovery.error("connection timed out; cancelling and retrying")
            connection.cancel()
            self.activeConnections.removeAll { $0 === connection }
            self.connectionState = .disconnected
            self.senderBaseURL = nil
            self.senderEndpoint = nil
            self.connectionPathLabel = nil
            self.isConnecting = false
            self.retryAfterBonjourConnectFailure()
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [resolvedName, resolvedDeviceID] in
                switch state {
                case .ready:
                    self.connectTimeoutTask?.cancel()
                    SyncLog.discovery.debug("TCP connection ready; resolving base URL")
                    self.resolvedBootstrapConnectionIDs.insert(connectionID)
                    self.resolveBaseURL(
                        for: connection,
                        deviceName: resolvedName,
                        deviceID: resolvedDeviceID
                    )
                case .failed(let error):
                    self.connectTimeoutTask?.cancel()
                    if self.resolvedBootstrapConnectionIDs.contains(connectionID) {
                        SyncLog.discovery.debug("ignoring terminal state on bootstrap connection after URL resolve")
                        self.resolvedBootstrapConnectionIDs.remove(connectionID)
                        connection.cancel()
                        self.removeActiveConnection(connection)
                        return
                    }
                    SyncLog.discovery.error("connection failed: \(error.localizedDescription, privacy: .public)")
                    self.resolvedBootstrapConnectionIDs.remove(connectionID)
                    connection.cancel()
                    self.activeConnections.removeAll { $0 === connection }
                    self.connectionState = .disconnected
                    self.senderBaseURL = nil
                    self.senderEndpoint = nil
                    self.connectionPathLabel = nil
                    self.connectedDeviceName = nil
                    self.connectedDeviceID = nil
                    self.connectedAppVersion = nil
                    self.isConnecting = false
                    self.retryAfterBonjourConnectFailure()
                case .cancelled:
                    self.connectTimeoutTask?.cancel()
                    self.resolvedBootstrapConnectionIDs.remove(connectionID)
                    self.removeActiveConnection(connection)
                case .waiting(let error):
                    SyncLog.discovery.debug("connection waiting: \(error.localizedDescription, privacy: .public)")
                default:
                    SyncLog.discovery.debug("connection state: \(String(describing: state), privacy: .public)")
                }
            }
        }

        connection.start(queue: networkQueue)
    }

    // MARK: - Receiver State Management

    /// Receiver-side: cancels any active connection but keeps the browser
    /// running so the UI still updates `discoveredPeers`. Used when the
    /// user explicitly pauses auto-sync.
    private func stopReceiverConnections(reason: String) {
        SyncLog.receiver.info("stopping receiver connections: \(reason, privacy: .public)")
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        directFallbackTask?.cancel()
        directFallbackTask = nil
        for connection in activeConnections { connection.cancel() }
        activeConnections.removeAll()
        senderBaseURL = nil
        senderEndpoint = nil
        connectionPathLabel = nil
        connectedDeviceName = nil
        connectedDeviceID = nil
        connectedAppVersion = nil
        isConnecting = false
        connectionState = .disconnected
    }

    /// Update the published `discoveredPeers` list from the latest browse
    /// results. Preserves first-seen timestamps for stable UI ordering.
    private func refreshDiscoveredPeers(from results: Set<NWBrowser.Result>) {
        var byID = Dictionary(uniqueKeysWithValues: discoveredPeers.map { ($0.id, $0) })
        var seenIDs = Set<UUID>()

        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let rawID = txt.dictionary["deviceID"],
                  let id = UUID(uuidString: rawID) else { continue }
            // Skip our own service if it ever shows up in the browser.
            if id == deviceID { continue }
            let name: String = {
                if let n = txt.dictionary["deviceName"], !n.isEmpty { return n }
                if case let .service(serviceName, _, _, _) = result.endpoint { return serviceName }
                return "Unknown"
            }()
            seenIDs.insert(id)
            if var existing = byID[id] {
                existing.lastSeenAt = .now
                byID[id] = existing
            } else {
                byID[id] = DiscoveredPeer(id: id, name: name)
            }
        }

        // Drop peers that have aged out of the browse results entirely.
        // Snapshot the keys first — mutating a dictionary while iterating
        // its `.keys` view is undefined behaviour.
        let staleIDs = byID.keys.filter { !seenIDs.contains($0) }
        for id in staleIDs {
            byID.removeValue(forKey: id)
        }

        discoveredPeers = byID.values.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    /// Pick which discovered service to auto-connect to: prefer bonded
    /// peers; fall back to first-seen when there are no bonds yet (legacy
    /// migration). Returns nil if a bond store is configured with peers but
    /// none of them are present.
    private func preferredAutoConnectResult(from results: Set<NWBrowser.Result>) -> NWBrowser.Result? {
        // Auto-connect only to a peer we've already bonded with. Strangers
        // are surfaced as Available Devices in the UI for explicit pairing.
        let bonded = bondedPeerStore?.peers ?? []
        guard !bonded.isEmpty else { return nil }
        let bondedIDs = Set(bonded.map(\.id))
        return results.first { result in
            guard case let .bonjour(txt) = result.metadata,
                  let rawID = txt.dictionary["deviceID"],
                  let id = UUID(uuidString: rawID) else { return false }
            return bondedIDs.contains(id)
        }
    }

    /// Reset receiver-side connection state so it can reconnect.
    public func resetReceiverState() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        for connection in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        senderBaseURL = nil
        senderEndpoint = nil
        connectionPathLabel = nil
        connectedDeviceName = nil
        connectedDeviceID = nil
        connectedAppVersion = nil
        isConnecting = false
        if isPaired {
            connectionState = .disconnected
            SyncLog.receiver.info("receiver state reset; paired, waiting for trigger")
        } else {
            connectionState = .searching
            SyncLog.receiver.info("receiver state reset; unpaired, restarting browse")
            // A paired-mode triggered browse may have been stopped, timed out,
            // or filtered for bonded peers. After clearing the bond, restart
            // discovery from scratch so Available Devices refills immediately.
            stopBrowsing()
            discoveredPeers.removeAll()
            startBrowsing()
        }
    }

    /// Call this when a network request (manifest/file) fails — triggers disconnect.
    /// In paired mode this resets to `.disconnected` without an automatic retry loop;
    /// the next trigger (foreground, user action, etc.) will re-browse.
    public func handleNetworkFailure() {
        guard role == .receiver else { return }
        guard connectionState == .connected || senderBaseURL != nil else { return }
        SyncLog.receiver.error("network failure detected; resetting receiver state")
        resetReceiverState()
        // In paired mode resetReceiverState leaves us in .disconnected;
        // no automatic retry until next trigger.
    }

    public func clearAuthFailureThreshold() {
        authFailureThresholdExceeded = false
    }

    private func clearAuthFailuresForCurrentPeer() {
        guard let store = bondedPeerStore else { return }
        let peerID = connectedDeviceID ?? store.peers.first?.id
        guard let peerID else { return }
        store.resetAuthFailures(id: peerID)
        authFailureThresholdExceeded = false
    }

    /// Sender returned 403 — our shared key is no longer trusted.
    /// Instead of immediately clearing the bond, we record a failure and
    /// only escalate after 3 consecutive failures.
    private func handleAuthFailure() {
        guard role == .receiver else { return }
        guard let store = bondedPeerStore else { return }
        let peerID = connectedDeviceID ?? store.peers.first?.id
        guard let peerID, let peer = store.peer(id: peerID) else {
            resetReceiverState()
            return
        }
        store.recordAuthFailure(id: peerID)
        let updatedPeer = store.peer(id: peerID)!
        if updatedPeer.consecutiveAuthFailures >= 3 {
            SyncLog.receiver.error("auth failure threshold reached for \(peerID, privacy: .public)")
            authFailureThresholdExceeded = true
        } else {
            SyncLog.receiver.warning("auth failure #\(updatedPeer.consecutiveAuthFailures) for \(peerID, privacy: .public)")
        }
        resetReceiverState()
    }

    /// Inspects a URLResponse for 403 and routes to either immediate bond
    /// clearing (explicit forget) or tolerant threshold counting (transient).
    private func handlePossibleAuthFailure(response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        handlePossibleAuthFailure(statusCode: http.statusCode, headers: headers)
    }

    private func handlePossibleAuthFailure(statusCode: Int, headers: [String: String]) {
        guard statusCode == 403 else { return }
        if headers["x-bounce-auth-reason"] == "forgotten" {
            handleExplicitForget()
        } else {
            handleAuthFailure()
        }
    }

    /// The remote explicitly forgot us (or never knew us). Clear the bond
    /// immediately, bypassing the tolerant-auth threshold, and also reset
    /// `autoConnectPaused` + `authFailureThresholdExceeded` so a previous
    /// "Auto-sync paused" state doesn't survive into the next pairing.
    private func handleExplicitForget() {
        guard role == .receiver else { return }
        guard let store = bondedPeerStore else { return }
        let peerID = connectedDeviceID ?? store.peers.first?.id
        guard let peerID else { return }
        SyncLog.receiver.info("remote explicitly forgot us (\(peerID, privacy: .public)); clearing bond")
        store.forget(id: peerID)
        clearAuthFailuresForCurrentPeer()
        if autoConnectPaused {
            autoConnectPaused = false
        }
        UserDefaults.standard.removeObject(forKey: Self.autoConnectPausedKey)
        resetReceiverState()
    }

    /// Attempt to reconnect using the browser's current results.
    private func retryFromCurrentResults() {
        guard let browser else { return }
        let results = browser.browseResults
        guard !results.isEmpty else {
            SyncLog.discovery.debug("retry requested without browse results")
            return
        }
        // Small delay before retrying to let the network settle
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
            guard !Task.isCancelled else { return }
            guard self.senderBaseURL == nil, !self.isConnecting, !self.autoConnectPaused else { return }
            guard let result = self.preferredAutoConnectResult(from: results) else { return }
            SyncLog.discovery.debug("retrying connection from current browse results")
            self.connectToSender(result)
        }
    }

    // MARK: - Pair (Receiver)

    /// User-initiated pairing with a specific discovered peer. Opens a
    /// connection just long enough to send POST /pair, persists the
    /// returned shared key in the bond store, and lets the normal
    /// auto-connect flow take it from there. Throws on denial or transport
    /// failure so the UI can show an error.
    ///
    /// `nonce` must be the exact bytes whose `verificationCode` was shown
    /// to the user in the confirmation sheet — the Mac will derive the
    /// same code from this nonce + our deviceID and display it for the
    /// user to compare visually.
    public func pair(
        with peer: DiscoveredPeer,
        nonce: Data,
        pairingToken: String? = nil,
        onReachable: () -> Void = {}
    ) async throws -> BondedPeer {
        guard role == .receiver else {
            throw SyncError.pairingFailed("pair() can only be called on a receiver")
        }
        guard let browser else {
            throw SyncError.pairingFailed("browser not running")
        }
        let result = browser.browseResults.first { res in
            guard case let .bonjour(txt) = res.metadata,
                  let raw = txt.dictionary["deviceID"],
                  let id = UUID(uuidString: raw) else { return false }
            return id == peer.id
        }
        guard let result else {
            throw SyncError.pairingFailed("\(peer.name) is no longer available")
        }

        // Tear down any existing connection so we can re-resolve a fresh
        // base URL pointing at the peer the user actually selected.
        stopReceiverConnections(reason: "manual pair initiated")

        connectionState = .pairing
        connectToSender(result)
        try await waitForConnectionReady(timeout: 8)
        onReachable()

        let bonded = try await performPairHandshake(
            expectedPeerID: peer.id,
            expectedPeerName: peer.name,
            nonce: nonce,
            pairingToken: pairingToken
        )
        return bonded
    }

    private static let linkDirectFirstAttemptDelay: TimeInterval = 1.5
    private static let linkDirectRetryInterval: TimeInterval = 4

    /// Pairs with the Mac from its QR link. Uses Bonjour when the Mac shows up
    /// there, and the link's direct addresses when it does not (iPhone
    /// hotspot). Returns nil when the Mac was not reachable before `timeout`.
    /// The Mac's identity is checked before the token is sent, and the pair
    /// response must carry the link's Mac device ID.
    public func pair(
        with link: PairingLink,
        nonce: Data,
        timeout: TimeInterval = 20,
        onReachable: () -> Void = {}
    ) async throws -> BondedPeer? {
        guard role == .receiver else {
            throw SyncError.pairingFailed("pair() can only be called on a receiver")
        }
        let start = Date()
        var nextDirectAttempt = start.addingTimeInterval(Self.linkDirectFirstAttemptDelay)
        var bonjourUnreachable = false
        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            if !bonjourUnreachable, let peer = discoveredPeers.first(where: { $0.id == link.macDeviceID }) {
                var reached = false
                do {
                    let bonded = try await pair(with: peer, nonce: nonce, pairingToken: link.token, onReachable: {
                        reached = true
                        onReachable()
                    })
                    saveDirectRoute(after: link)
                    return bonded
                } catch let error where !reached && !(error is CancellationError) && link.directRoute != nil {
                    SyncLog.discovery.info("Bonjour pair connection failed (\(error.localizedDescription, privacy: .public)); trying the link's direct route")
                    bonjourUnreachable = true
                    nextDirectAttempt = Date()
                }
            }
            if let route = link.directRoute, Date() >= nextDirectAttempt {
                stopReceiverConnections(reason: "direct pair from link")
                connectionState = .pairing
                isConnecting = true
                if await connectDirectly(route, deviceName: link.macName) {
                    onReachable()
                    let bonded = try await performPairHandshake(
                        expectedPeerID: link.macDeviceID,
                        expectedPeerName: link.macName,
                        nonce: nonce,
                        pairingToken: link.token
                    )
                    saveDirectRoute(after: link)
                    return bonded
                }
                isConnecting = false
                connectionState = browser == nil ? .disconnected : .searching
                nextDirectAttempt = Date().addingTimeInterval(Self.linkDirectRetryInterval)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func saveDirectRoute(after link: PairingLink) {
        guard let linkRoute = link.directRoute else { return }
        let current = DirectSenderRoute.load().flatMap { $0.macDeviceID == link.macDeviceID ? $0 : nil }
        DirectSenderRoute(
            macDeviceID: link.macDeviceID,
            hosts: (current?.hosts ?? []) + linkRoute.hosts,
            port: current?.port ?? linkRoute.port
        ).save()
    }

    private func refreshDirectRoute(host: NWEndpoint.Host, port: NWEndpoint.Port, deviceID: UUID?) {
        guard role == .receiver, let deviceID, bondedPeerStore?.contains(id: deviceID) == true else { return }
        var ipv4: String? = nil
        if case .ipv4 = host {
            ipv4 = "\(host)".components(separatedBy: "%").first
        }
        let existing = DirectSenderRoute.load().flatMap { $0.macDeviceID == deviceID ? $0 : nil }
        let route = (existing ?? DirectSenderRoute(macDeviceID: deviceID, hosts: [], port: port.rawValue))
            .preferring(ipv4, port: port.rawValue)
        guard !route.hosts.isEmpty, route != existing else { return }
        route.save()
    }

    /// Wait until `senderEndpoint` is set or the timeout expires.
    private func waitForConnectionReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if senderEndpoint != nil { return }
            if connectionState == .disconnected {
                throw SyncError.pairingFailed("connection failed before pairing")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SyncError.pairingFailed("timed out waiting for connection")
    }

    /// POST /pair to the currently resolved sender, decode the response,
    /// store the bond. Caller must already have a resolved `senderEndpoint`.
    /// `nonce` is the user-confirmed nonce so the Mac sees the same code.
    @discardableResult
    private func performPairHandshake(expectedPeerID: UUID, expectedPeerName: String, nonce: Data, pairingToken: String?) async throws -> BondedPeer {
        guard senderEndpoint != nil else {
            throw SyncError.pairingFailed("no sender endpoint")
        }
        let request = PairRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            appVersion: Self.appVersionString(),
            nonce: nonce
        )
        let body = try JSONEncoder().encode(request)

        var extraHeaders: [String: String] = ["Content-Type": "application/json"]
        if let existingBond = bondedPeerStore?.peer(id: expectedPeerID) {
            extraHeaders["X-Bounce-Pair-Key"] = existingBond.sharedKey.base64EncodedString()
        }
        if let pairingToken {
            extraHeaders["X-Bounce-Pair-Token"] = pairingToken
        }

        let response = try await performReceiverHTTP(
            method: "POST",
            path: "/pair",
            extraHeaders: extraHeaders,
            body: body,
            timeout: 150
        )
        guard let pairResponse = try? JSONDecoder().decode(PairResponse.self, from: response.body) else {
            let bodyPreview = String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = bodyPreview.isEmpty ? "" : ": \(bodyPreview)"
            throw SyncError.pairingFailed("invalid pair response format (HTTP \(response.statusCode))\(detail)")
        }
        guard pairResponse.ok, let keyB64 = pairResponse.sharedKeyBase64,
              let sharedKey = Data(base64Encoded: keyB64) else {
            throw SyncError.pairingFailed(pairResponse.error ?? "pair denied (HTTP \(response.statusCode))")
        }
        guard pairResponse.deviceID == expectedPeerID else {
            SyncLog.receiver.error(
                "pair response deviceID \(pairResponse.deviceID, privacy: .public) did not match expected \(expectedPeerID, privacy: .public)"
            )
            throw SyncError.pairingFailed("paired device did not match selected peer")
        }

        let bonded = BondedPeer(
            id: pairResponse.deviceID,
            name: pairResponse.deviceName.isEmpty ? expectedPeerName : pairResponse.deviceName,
            sharedKey: sharedKey
        )
        bondedPeerStore?.bond(bonded)
        if case let .hostPort(host, port) = senderEndpoint {
            refreshDirectRoute(host: host, port: port, deviceID: bonded.id)
        }
        // Ensure subsequent receiver requests always carry the bonded key,
        // even if browse metadata did not include a deviceID.
        connectedDeviceID = bonded.id
        if connectedDeviceName == nil || connectedDeviceName?.isEmpty == true {
            connectedDeviceName = bonded.name
        }
        // Pair succeeded; stop discovery churn and keep this session stable.
        stopBrowsing()
        clearAuthFailuresForCurrentPeer()
        // Now the bond is stored; safe to promote to .connected and let
        // auto-sync / state-change handlers run with a valid auth key.
        connectionState = .connected
        SyncLog.receiver.info("paired with \(bonded.name, privacy: .public)")
        // Auto-connect logic will see the new bond on next browse-result tick.
        return bonded
    }

    /// Tell the currently-connected sender to forget us. Best-effort: a
    /// network failure here is not surfaced — the local bond is the source
    /// of truth and we'll have already cleared it. Without this, an
    /// asymmetric forget leaves the Mac trusting the old shared key while
    /// the receiver no longer presents it, producing 403s on reconnect.
    public func notifyRemoteForget() async {
        guard let endpoint = senderEndpoint ?? lastSenderEndpoint else { return }
        var headers = receiverAuthHeaders()
        do {
            let response = try await NWHTTPClient.request(
                endpoint: endpoint,
                method: "DELETE",
                path: "/pair",
                headers: headers,
                timeout: 5
            )
            if response.statusCode != 200 {
                SyncLog.receiver.error("DELETE /pair returned HTTP \(response.statusCode)")
            }
            SyncLog.receiver.info("sent DELETE /pair to remote")
        } catch {
            SyncLog.receiver.error("DELETE /pair failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lightweight authenticated liveness check used by the receiver to
    /// notice when the Mac has forgotten this bond. A 403 with the
    /// `forgotten` reason clears the local bond via `handlePossibleAuthFailure`.
    @discardableResult
    public func verifyPairingStatus() async -> PairingVerification {
        guard role == .receiver else { return .valid }
        guard senderEndpoint != nil else { return .unreachable }
        do {
            let response = try await performReceiverHTTP(
                method: "GET",
                path: "/pair/status",
                timeout: 5
            )
            if response.statusCode == 200 { return .valid }
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            return .rejected
        } catch {
            SyncLog.receiver.error("pair status check failed: \(error.localizedDescription, privacy: .public)")
            return .unreachable
        }
    }

    // MARK: - Receiver Upload

    // MARK: - iOS → Mac Manifest Push

    /// Push the iOS manifest of .phone-originated tracks to the Mac.
    /// Mac uses this to discover phone-originated content for bidirectional sync.
    public func pushiOSManifest(_ manifest: LibraryManifest) async throws {
        guard senderEndpoint != nil else {
            throw SyncError.notConnected
        }

        let body = try JSONEncoder().encode(manifest)
        let response = try await performReceiverHTTP(
            method: "POST",
            path: "/ios-manifest",
            extraHeaders: ["Content-Type": "application/json"],
            body: body
        )
        guard response.statusCode == 200 else {
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("ios-manifest push returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        print("[BonjourTransport] pushed iOS manifest: \(manifest.tracks.count) tracks")
    }

    // MARK: - iOS → Mac Upload

    public func uploadFile(trackName: String, versionLabel: String, originalFilename: String, fileFormat: String = "m4a", versionID: UUID? = nil, trackID: UUID? = nil, targetTrackID: UUID? = nil, sourceContentHash: String? = nil, fileURL: URL) async throws -> Bool {
        guard senderEndpoint != nil else {
            throw SyncError.notConnected
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        // Multipart fields
        body.appendMultipartField(boundary: boundary, name: "trackName", value: trackName)
        body.appendMultipartField(boundary: boundary, name: "versionLabel", value: versionLabel)
        body.appendMultipartField(boundary: boundary, name: "fileFormat", value: fileFormat)
        if let versionID {
            body.appendMultipartField(boundary: boundary, name: "versionID", value: versionID.uuidString)
        }
        if let trackID {
            body.appendMultipartField(boundary: boundary, name: "trackID", value: trackID.uuidString)
        }
        if let targetTrackID {
            body.appendMultipartField(boundary: boundary, name: "targetTrackID", value: targetTrackID.uuidString)
        }
        if let sourceContentHash {
            body.appendMultipartField(boundary: boundary, name: "sourceContentHash", value: sourceContentHash)
        }

        // File part
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(originalFilename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

        let response = try await performReceiverUpload(
            path: "/upload",
            boundary: boundary,
            fileBody: NWHTTPFileBody(prefix: body, fileURL: fileURL, suffix: Data("\r\n--\(boundary)--\r\n".utf8)),
            timeout: 300
        )
        guard response.statusCode == 200 else {
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("upload returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        return true
    }

    public func uploadVoiceNote(noteID: UUID, fileURL: URL) async throws -> Bool {
        guard senderEndpoint != nil else { throw SyncError.notConnected }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(boundary: boundary, name: "noteID", value: noteID.uuidString)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(noteID.uuidString).m4a\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

        let response = try await performReceiverUpload(
            path: "/voice-notes/upload",
            boundary: boundary,
            fileBody: NWHTTPFileBody(prefix: body, fileURL: fileURL, suffix: Data("\r\n--\(boundary)--\r\n".utf8)),
            timeout: 120
        )
        guard response.statusCode == 200 else {
            handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
            throw SyncError.transferFailed("voice note upload returned non-200 (\(response.statusCode))")
        }
        clearAuthFailuresForCurrentPeer()
        return true
    }

    private func resolveBaseURL(for connection: NWConnection, deviceName: String?, deviceID: UUID?) {
        defer {
            // Bootstrap connection only resolves the peer endpoint; HTTP uses fresh NWConnections.
            removeActiveConnection(connection)
            connection.cancel()
        }

        guard let path = connection.currentPath, let remoteEndpoint = path.remoteEndpoint else {
            SyncLog.discovery.error("failed to resolve remote endpoint")
            connectionState = .disconnected
            isConnecting = false
            return
        }
        adoptSenderEndpoint(remoteEndpoint, path: path, deviceName: deviceName, deviceID: deviceID)
    }

    private func adoptSenderEndpoint(_ remoteEndpoint: NWEndpoint, path: NWPath?, deviceName: String?, deviceID: UUID?) {
        guard case let .hostPort(host, port) = remoteEndpoint else {
            SyncLog.discovery.error("remote endpoint is not host:port")
            connectionState = .disconnected
            isConnecting = false
            return
        }

        // Build the host portion of the URL for debug/UI.
        let hostString: String
        switch host {
        case .name(let name, _):
            hostString = name
        case .ipv4:
            hostString = "\(host)"
        case .ipv6:
            let raw = "\(host)"
            let stripped = raw.components(separatedBy: "%").first ?? raw
            hostString = "[\(stripped)]"
        @unknown default:
            hostString = "\(host)"
        }

        let urlString = "http://\(hostString):\(port.rawValue)"
        SyncLog.discovery.debug("resolved sender URL \(urlString, privacy: .public)")

        guard let url = URL(string: urlString) else {
            SyncLog.discovery.error("URL rejected sender address \(urlString, privacy: .public)")
            connectionState = .disconnected
            isConnecting = false
            return
        }

        senderEndpoint = remoteEndpoint
        lastSenderEndpoint = remoteEndpoint
        senderBaseURL = url
        lastSenderBaseURL = url
        connectionPathLabel = NWPathLabel.from(path: path)
        refreshDirectRoute(host: host, port: port, deviceID: deviceID)
        connectedDeviceName = deviceName
        connectedDeviceID = deviceID
        connectedAppVersion = nil
        if connectionState != .pairing {
            connectionState = .connected
        }
        isConnecting = false
        if isPaired {
            stopBrowsing()
            SyncLog.receiver.debug("connected while paired; stopping browser to save power")
        }
        let pathLabel = connectionPathLabel ?? "unknown"
        let interfaces = NWPathLabel.interfaceDescription(path: path)
        SyncLog.discovery.info(
            "connected to \(deviceName ?? "Unknown", privacy: .public) at \(urlString, privacy: .public) path=\(pathLabel, privacy: .public) interfaces=\(interfaces, privacy: .public)"
        )
    }

    private func removeActiveConnection(_ connection: NWConnection) {
        activeConnections.removeAll { $0 === connection }
    }

    private func recordServedBytes(_ bytes: Int64) {
        lastServedResponseBytes = bytes
        totalBytesServed += bytes
    }

    private func closeConnection(_ connection: NWConnection) {
        requestWatchdogs.disarm(connection)
        removeActiveConnection(connection)
        connection.cancel()
    }

    private func makeReceiverRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in receiverAuthHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func receiverAuthHeaders() -> [String: String] {
        var headers: [String: String] = [
            "X-Bounce-Device-Name": deviceName,
            "X-Bounce-Device-ID": deviceID.uuidString,
            "X-Bounce-App-Version": Self.appVersionString()
        ]
        let authPeerID = connectedDeviceID ?? bondedPeerStore?.peers.first?.id
        if let authPeerID,
           let bond = bondedPeerStore?.peer(id: authPeerID) {
            headers["X-Bounce-Pair-Key"] = bond.sharedKey.base64EncodedString()
        }
        return headers
    }

    private func endpointLogDescription() -> String {
        guard let endpoint = senderEndpoint,
              case let .hostPort(host, port) = endpoint else {
            return "unknown endpoint"
        }
        let path = connectionPathLabel ?? "unknown"
        return "\(host):\(port.rawValue) (\(path))"
    }

    private func performReceiverHTTP(
        method: String,
        path: String,
        extraHeaders: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> NWHTTPResponse {
        guard let endpoint = senderEndpoint else {
            throw SyncError.notConnected
        }
        var headers = receiverAuthHeaders()
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return try await mappingClientErrors(method: method, path: path) {
            try await NWHTTPClient.request(
                endpoint: endpoint,
                method: method,
                path: path,
                headers: headers,
                body: body,
                timeout: timeout
            )
        }
    }

    private func performReceiverUpload(
        path: String,
        boundary: String,
        fileBody: NWHTTPFileBody,
        timeout: TimeInterval
    ) async throws -> NWHTTPResponse {
        guard let endpoint = senderEndpoint else {
            throw SyncError.notConnected
        }
        var headers = receiverAuthHeaders()
        headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        return try await mappingClientErrors(method: "POST", path: path) {
            try await NWHTTPClient.upload(
                endpoint: endpoint,
                method: "POST",
                path: path,
                headers: headers,
                fileBody: fileBody,
                timeout: timeout
            )
        }
    }

    private func mappingClientErrors(
        method: String,
        path: String,
        _ operation: () async throws -> NWHTTPResponse
    ) async throws -> NWHTTPResponse {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SyncLog.transport.error(
                "HTTP \(method) \(path) failed via \(self.endpointLogDescription(), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if let clientError = error as? NWHTTPClientError {
                throw SyncError.transferFailed(clientError.localizedDescription ?? "request failed")
            }
            throw SyncError.transferFailed(error.localizedDescription)
        }
    }

    private func performReceiverDownload(path: String, failureContext: String, timeout: TimeInterval = 300) async throws -> URL {
        guard let endpoint = senderEndpoint else {
            throw SyncError.notConnected
        }
        let headers = receiverAuthHeaders()
        do {
            let (url, response) = try await NWHTTPClient.download(
                endpoint: endpoint,
                method: "GET",
                path: path,
                headers: headers,
                timeout: timeout
            )
            guard response.statusCode == 200 else {
                try? FileManager.default.removeItem(at: url)
                SyncLog.transport.error(
                    "\(failureContext) returned HTTP \(response.statusCode) via \(self.endpointLogDescription(), privacy: .public)"
                )
                handlePossibleAuthFailure(statusCode: response.statusCode, headers: response.headers)
                throw SyncError.transferFailed("\(failureContext) returned non-200 (\(response.statusCode))")
            }
            clearAuthFailuresForCurrentPeer()
            return url
        } catch let error as SyncError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SyncLog.transport.error(
                "\(failureContext) failed via \(self.endpointLogDescription(), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if let clientError = error as? NWHTTPClientError {
                throw SyncError.transferFailed(clientError.localizedDescription ?? "download failed")
            }
            throw SyncError.transferFailed(error.localizedDescription)
        }
    }

    private func requestHeaders(from lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildNumber = info?["CFBundleVersion"] as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where shortVersion != buildNumber:
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildNumber?):
            return buildNumber
        default:
            return "Unknown"
        }
    }

    private enum FileResponseError: Error {
        case fileMissing
        case interruptedAfterHeaders(Error)
    }

    private func notifyFileServed(_ versionID: UUID) {
        fileServedHandler?(versionID)
    }

    private func failFileResponse(_ connection: NWConnection, error: Error) {
        switch error {
        case FileResponseError.fileMissing:
            send404(connection)
        case FileResponseError.interruptedAfterHeaders(_):
            closeConnection(connection)
        default:
            send500(connection)
        }
    }

    private static func streamFileResponse(from fileURL: URL, connection: NWConnection) async throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FileResponseError.fileMissing
        }
        let fileSize = try FileIntegrity.fileSize(for: fileURL)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(fileSize)\r\nConnection: close\r\n\r\n"
        do {
            try await sendChunk(Data(header.utf8), on: connection)
            var sent: Int64 = 0
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty {
                    break
                }
                try await sendChunk(chunk, on: connection)
                sent += Int64(chunk.count)
            }
            guard sent == fileSize else {
                throw SyncError.transferFailed("\(fileURL.lastPathComponent) changed size while streaming (\(sent) of \(fileSize) bytes)")
            }
        } catch {
            throw FileResponseError.interruptedAfterHeaders(error)
        }

        return fileSize
    }

    private static func sendChunk(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func persistentDeviceID(for role: SyncRole) -> UUID {
        let key: String
        switch role {
        case .sender:
            key = senderDeviceIDKey
        case .receiver:
            key = receiverDeviceIDKey
        }

        if let stored = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }

        if role == .sender,
           let stored = UserDefaults.standard.string(forKey: legacySenderDeviceIDKey),
           let uuid = UUID(uuidString: stored) {
            UserDefaults.standard.set(uuid.uuidString, forKey: key)
            return uuid
        }

        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
    }
}
