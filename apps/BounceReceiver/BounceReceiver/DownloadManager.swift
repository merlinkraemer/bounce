import Foundation
import Network
import SwiftData
import BounceKit

@Observable
@MainActor
final class DownloadManager {
    let transport: BonjourTransport
    let bondedPeerStore = BondedPeerStore(role: .receiver)
    private let modelContext: ModelContext
    private let coordinator = ReceiverSyncCoordinator()
    private let waveformProcessor = WaveformProcessor()
    private let transferQueue = TransferQueue(maxConcurrent: 3)
    private let transferCancellation = TransferQueue.CancellationRegistry()
    private let periodicSyncInterval: UInt64 = 10_000_000_000
    /// Pair liveness check; kept well above the 10 s manifest poll so Mac
    /// `/pair/status` is not woken every couple of seconds. Auth failures
    /// (403) still clear the bond via `verifyPairingStatus`.
    private let pairStatusInterval: UInt64 = 45_000_000_000

    private var periodicSyncTask: Task<Void, Never>? = nil
    private var pairStatusTask: Task<Void, Never>? = nil
    private var activeSyncTask: Task<Void, Never>? = nil
    private var manualSyncRequestedDuringActiveSync = false
    private var activeSyncLeaseID: Int? = nil
    private var notePushTask: Task<Void, Never>? = nil
    private var refreshStatusTask: Task<Void, Never>? = nil
    private var downloadRequestTokens: [UUID: Int] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastLoggedConnectionState: SyncConnectionState?
    /// Protocol version of the last Mac manifest we processed. Pre-6 Macs still
    /// expect playlist covers embedded in the iOS manifest and have no
    /// /playlist-artwork endpoint — the manifest builder and cover reconcile
    /// paths use this to stay compatible for one upgrade cycle.
    @ObservationIgnored private var lastSenderProtocolVersion: Int? = nil
    /// Scalar fingerprint of the last iOS manifest actually pushed to the Mac.
    /// Debounced mutation notifications that produce an identical manifest
    /// (e.g. a re-save with no content change) skip the network push and the
    /// Mac-side merge entirely. Reset on (re)connect so a fresh peer always
    /// receives the current state.
    @ObservationIgnored private var lastPushedIOSManifestFingerprint: Int64? = nil
    @ObservationIgnored var onWillRemoveAudio: ((_ trackIDs: Set<UUID>, _ versionIDs: Set<UUID>) -> Void)?

    var connectionState: SyncConnectionState { transport.connectionState }
    var connectedDeviceName: String? { transport.connectedDeviceName }
    var connectionPathLabel: String? { transport.connectionPathLabel }
    var discoveredPeers: [DiscoveredPeer] { transport.discoveredPeers }
    var authFailureThresholdExceeded: Bool { transport.authFailureThresholdExceeded }

    /// Persisted toggle: when true, the receiver browser stays alive but
    /// no auto-connect is attempted. Mirrors `transport.autoConnectPaused`
    /// and survives app launches via UserDefaults.
    var autoConnectPaused: Bool {
        get { transport.autoConnectPaused }
        set {
            transport.autoConnectPaused = newValue
            UserDefaults.standard.set(newValue, forKey: "com.bounce.autoConnectPaused")
            refreshSyncStatusPresentation()
        }
    }

    private(set) var isSyncing: Bool = false
    private(set) var lastSyncAt: Date? = nil
    private(set) var lastSyncError: String? = nil
    private(set) var syncedTrackCount: Int = 0
    private(set) var pendingTransferCount: Int = 0
    private(set) var retryingTransferCount: Int = 0
    private(set) var failedTransferCount: Int = 0
    private(set) var activeTransferCount: Int = 0
    private(set) var lastSuccessfulGeneration: Int64 = 0

    enum DownloadState: Equatable {
        case ready
        case notDownloaded
        case pending
        case downloading
        case failed(String)
    }

    /// Coalesced badge state for header/footer sync UI. Updated only when the
    /// mapped presentation actually changes so status flicker doesn't fan out
    /// broad SwiftUI invalidation.
    private(set) var syncStatusPresentation: SyncStatusPresentation = SyncStatusPresentation(
        label: "Searching",
        color: .gray
    )

    // MARK: - Sync Event Log
    private(set) var syncLog: [SyncEvent] = []

    struct SyncEvent: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let level: SyncEventLevel

        enum SyncEventLevel {
            case info, error
        }
    }

    func logSync(_ message: String, level: SyncEvent.SyncEventLevel = .info) {
        let event = SyncEvent(date: .now, message: message, level: level)
        syncLog.append(event)
        // Keep last 100
        if syncLog.count > 100 { syncLog.removeFirst(syncLog.count - 100) }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.transport = BonjourTransport(role: .receiver)
    }

    // MARK: - Lifecycle

    func start() async {
        transport.bondedPeerStore = bondedPeerStore
        transport.autoConnectPaused = UserDefaults.standard.bool(forKey: "com.bounce.autoConnectPaused")
        transport.stateChangeHandler = { [weak self] state, _, senderID in
            guard let self else { return }
            Task { @MainActor in
                await self.handleTransportStateChange(state, senderID: senderID)
            }
        }
        // Resolve voice-note audio through the note record first so legacy files
        // and stale container paths can still be served to the Mac.
        transport.voiceNoteProvider = { [weak self] noteID in
            self?.resolveLocalVoiceNoteURL(for: noteID)
        }
        await transport.start()
        startPathMonitoring()
        // Run path/metadata migrations off the launch-critical path. The voice-note
        // migration hashes every candidate file (SHA-256), which blocked the main
        // thread for 150–500 ms at launch. It now hashes off the main actor.
        Task(priority: .utility) { [weak self] in
            await self?.migrateVoiceMemoPaths()
            self?.migrateFilePaths()
        }
        refreshPersistedStatus(senderID: transport.connectedDeviceID)
        await handleTransportStateChange(transport.connectionState, senderID: transport.connectedDeviceID)
        refreshSyncStatusPresentation()
    }

    // MARK: - Manual Sync Controls

    /// User-tapped Sync now. If we're connected, run a sync round; if not,
    /// trigger a reconnect attempt. This makes the button do *something*
    /// visible regardless of state.
    func userRequestedSyncNow() async {
        if case .connected = transport.connectionState {
            await syncNow()
        } else {
            triggerReconnect()
        }
    }

    /// User-tapped Disconnect. Drops the active session but leaves the
    /// browser running so the user can pick a peer to reconnect to.
    func userDisconnect() {
        transport.resetReceiverState()
    }

    func downloadState(for version: Version) -> DownloadState {
        if FileManager.default.fileExists(atPath: version.filePath) { return .ready }
        guard let senderID = transport.connectedDeviceID ?? bondedPeerStore.peers.first?.id,
              let snapshot = fetchVersionSnapshots(senderID: senderID).first(where: { $0.versionID == version.id }) else {
            return .notDownloaded
        }
        switch snapshot.syncStatus {
        case .pending: return .pending
        case .downloading, .verifying: return .downloading
        case .failed: return .failed(snapshot.lastError ?? "Download failed")
        default: return snapshot.downloadRequested ? .pending : .notDownloaded
        }
    }

    @discardableResult
    func requestDownload(for version: Version) -> Bool {
        guard !FileManager.default.fileExists(atPath: version.filePath) else { return true }
        guard let senderID = transport.connectedDeviceID ?? bondedPeerStore.peers.first?.id,
              let snapshot = fetchVersionSnapshots(senderID: senderID).first(where: { $0.versionID == version.id }) else {
            logSync("Download unavailable until the paired Mac catalog has synced", level: .error)
            return false
        }
        snapshot.downloadRequested = true
        snapshot.syncStatus = .pending
        snapshot.nextRetryAt = nil
        snapshot.lastError = nil
        downloadRequestTokens[version.id, default: 0] += 1
        declinedAutoDownloadVersionIDs.remove(version.id)
        try? modelContext.save()
        refreshPersistedStatus(senderID: senderID)
        Task { await requestSync(trigger: .manual, waitForCompletion: false) }
        return true
    }

    /// Cancel a selected download without changing the catalog row. This is
    /// intentionally separate from ordinary Delete and Remove Download: the
    /// version remains visible and can be requested again later.
    func cancelDownload(for version: Version) {
        downloadRequestTokens[version.id, default: 0] += 1
        declinedAutoDownloadVersionIDs.insert(version.id)
        Task { await transferCancellation.cancel(version.id) }
        if let senderID = transport.connectedDeviceID ?? bondedPeerStore.peers.first?.id,
           let snapshot = fetchVersionSnapshots(senderID: senderID).first(where: { $0.versionID == version.id }) {
            snapshot.downloadRequested = false
            snapshot.syncStatus = .idle
            snapshot.nextRetryAt = nil
            snapshot.lastError = nil
            try? modelContext.save()
            refreshPersistedStatus(senderID: senderID)
        }
    }

    @discardableResult
    func removeDownload(for version: Version) -> Bool {
        let hasFile = FileManager.default.fileExists(atPath: version.filePath)
        if hasFile {
            guard let track = (try? modelContext.fetch(FetchDescriptor<Track>()))?.first(where: { $0.id == version.trackID }) else { return false }
            guard track.origin == .mac || uploadedToMac(versionID: version.id) else { return false }
        }

        cancelDownload(for: version)
        if hasFile {
            onWillRemoveAudio?([], [version.id])
            try? FileManager.default.removeItem(atPath: version.filePath)
            version.waveformData = nil
        }
        if let senderID = transport.connectedDeviceID ?? bondedPeerStore.peers.first?.id,
           let snapshot = fetchVersionSnapshots(senderID: senderID).first(where: { $0.versionID == version.id }) {
            snapshot.downloadRequested = false
            snapshot.syncStatus = .idle
            snapshot.nextRetryAt = nil
            snapshot.lastError = nil
        }
        try? modelContext.save()
        refreshPersistedStatus(senderID: transport.connectedDeviceID)
        return true
    }

    func canRemoveDownload(for version: Version) -> Bool {
        guard FileManager.default.fileExists(atPath: version.filePath),
              let track = (try? modelContext.fetch(FetchDescriptor<Track>()))?.first(where: { $0.id == version.trackID }) else { return false }
        return track.origin == .mac || uploadedToMac(versionID: version.id)
    }

    private func uploadedToMac(versionID: UUID) -> Bool {
        let uploads = (try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? []
        return uploads.first(where: { $0.versionID == versionID })?.status == .uploaded
    }

    enum TrackRemoval {
        case removeDownload
        case delete
    }

    func removal(for track: Track) -> TrackRemoval? {
        let uploadedVersionIDs: Set<UUID> = track.origin == .mac ? [] : Set(
            ((try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? [])
                .filter { $0.status == .uploaded }
                .map(\.versionID)
        )
        let isOnMac = track.origin == .mac || track.versions.contains { uploadedVersionIDs.contains($0.id) }
        guard isOnMac else { return .delete }
        let hasRemovableAudio = track.versions.contains { version in
            (track.origin == .mac || uploadedVersionIDs.contains(version.id))
                && FileManager.default.fileExists(atPath: version.filePath)
        }
        return hasRemovableAudio ? .removeDownload : nil
    }

    func removal(for version: Version, of track: Track) -> TrackRemoval? {
        guard track.origin == .mac || uploadedToMac(versionID: version.id) else { return .delete }
        return FileManager.default.fileExists(atPath: version.filePath) ? .removeDownload : nil
    }

    func removeDownloads(for track: Track) {
        for version in track.versions where FileManager.default.fileExists(atPath: version.filePath) {
            removeDownload(for: version)
        }
    }

    func deleteLocalTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let trackIDs = Set(tracks.map(\.id))
        onWillRemoveAudio?(trackIDs, [])
        let fileManager = FileManager.default

        for upload in (try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? [] where trackIDs.contains(upload.trackID) {
            modelContext.delete(upload)
        }

        let entries = ((try? modelContext.fetch(FetchDescriptor<PlaylistEntry>())) ?? []).filter { trackIDs.contains($0.trackID) }
        if !entries.isEmpty {
            let entryIDs = Set(entries.map(\.id))
            let playlistIDs = Set(entries.map(\.playlistID))
            for playlist in (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? [] where playlistIDs.contains(playlist.id) {
                playlist.entries.removeAll { entryIDs.contains($0.id) }
                for (index, entry) in playlist.entries.sorted(by: { $0.position < $1.position }).enumerated() {
                    entry.position = index
                }
                playlist.updatedAt = .now
            }
            for entry in entries {
                modelContext.delete(entry)
            }
        }

        for track in tracks {
            let trackID = track.id
            let versions = (try? modelContext.fetch(FetchDescriptor<Version>(predicate: #Predicate { $0.trackID == trackID }))) ?? []
            for version in versions {
                try? fileManager.removeItem(atPath: version.filePath)
                modelContext.delete(version)
            }
            let notes = (try? modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.trackID == trackID }))) ?? []
            for note in notes {
                if let voiceURL = VoiceMemoRecorder.existingVoiceMemoURL(noteID: note.id, storedPath: note.voiceFilePath) {
                    try? fileManager.removeItem(at: voiceURL)
                }
                modelContext.delete(note)
            }
            modelContext.delete(track)
        }

        do {
            try modelContext.save()
        } catch {
            logSync("Failed to delete tracks: \(error.localizedDescription)", level: .error)
        }
        notifyLocalManifestMutated()
    }

    func deleteLocalVersion(_ version: Version, of track: Track) {
        let versionID = version.id
        onWillRemoveAudio?([], [versionID])

        for upload in (try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? [] where upload.versionID == versionID {
            modelContext.delete(upload)
        }
        for entry in (try? modelContext.fetch(FetchDescriptor<PlaylistEntry>())) ?? [] where entry.versionID == versionID {
            entry.versionID = nil
        }

        try? FileManager.default.removeItem(atPath: version.filePath)
        modelContext.delete(version)
        track.updatedAt = .now
        track.lastTouchedAt = .now
        do {
            try modelContext.save()
        } catch {
            logSync("Failed to delete mix: \(error.localizedDescription)", level: .error)
        }
        notifyLocalManifestMutated()
    }

    private static let declinedAutoDownloadsKey = "declinedAutoDownloadVersionIDs"

    private var declinedAutoDownloadVersionIDs: Set<UUID> {
        get {
            Set((UserDefaults.standard.stringArray(forKey: Self.declinedAutoDownloadsKey) ?? []).compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.declinedAutoDownloadsKey)
        }
    }

    /// Idempotent trigger for paired-mode reconnect.
    func triggerReconnect() {
        transport.triggerReconnect()
    }

    /// Reset auth-failure counters and attempt to reconnect after a
    /// threshold-exceeded soft failure.
    func retryAfterAuthFailure() {
        if let peerID = transport.connectedDeviceID ?? bondedPeerStore.peers.first?.id {
            bondedPeerStore.resetAuthFailures(id: peerID)
        }
        transport.clearAuthFailureThreshold()
        triggerReconnect()
    }

    private func startPathMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self.triggerReconnect()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    /// User-initiated pair with a discovered (not-yet-bonded) peer. The
    /// `nonce` must match the one whose verification code was shown in
    /// the confirmation sheet.
    func pair(with peer: DiscoveredPeer, nonce: Data, pairingToken: String? = nil) async throws {
        _ = try await transport.pair(with: peer, nonce: nonce, pairingToken: pairingToken)
        await didPair()
    }

    func pair(with link: PairingLink, nonce: Data, onReachable: () -> Void) async throws -> Bool {
        guard try await transport.pair(with: link, nonce: nonce, onReachable: onReachable) != nil else { return false }
        await didPair()
        return true
    }

    private func didPair() async {
        UserDefaults.standard.set(true, forKey: ReceiverAppStorageKeys.hasEverPairedReceiverDevice)
        await handleTransportStateChange(transport.connectionState, senderID: transport.connectedDeviceID)
        await requestSync(trigger: .connected, waitForCompletion: false)
    }

    /// Drop a bond. Tells the remote to forget us first (so it doesn't
    /// keep auto-accepting requests from this device after re-pair) then
    /// clears the local bond and tears down the connection.
    func forgetPeer(_ id: UUID) {
        Task {
            // Always attempt to notify the remote — in a 1:1 model the
            // receiver may have been reset (e.g. by a transient 404) and
            // still needs to tell the Mac to drop its side of the bond.
            await transport.notifyRemoteForget()
            await MainActor.run {
                bondedPeerStore.forget(id: id)
                transport.resetReceiverState()
            }
        }
    }

    /// Fix stale absolute file paths after app reinstall (container UUID changes).
    /// SwiftData preserves records but iOS changes the sandbox path, breaking audio playback.
    private func migrateFilePaths() {
        let currentAudioDir = audioDirectory().path
        let fileManager = FileManager.default

        do {
            let descriptor = FetchDescriptor<Version>()
            let versions = try modelContext.fetch(descriptor)

            var migrated = 0
            for version in versions {
                guard !version.filePath.isEmpty else { continue }

                // Already in the correct directory — skip
                if version.filePath.hasPrefix(currentAudioDir) {
                    // Also verify the file actually exists
                    continue
                }

                // Extract just the filename from the old path
                let filename = URL(fileURLWithPath: version.filePath).lastPathComponent
                let newPath = currentAudioDir + "/" + filename

                // Check if the file exists at the new location already
                // (may have been synced or already migrated)
                if fileManager.fileExists(atPath: newPath) {
                    version.filePath = newPath
                    migrated += 1
                } else if fileManager.fileExists(atPath: version.filePath) {
                    // Old path still valid — file exists at old location
                    // Move it to the new location
                    try? fileManager.moveItem(atPath: version.filePath, toPath: newPath)
                    version.filePath = newPath
                    migrated += 1
                } else {
                    // File is gone — update path anyway so sync can re-download
                    version.filePath = newPath
                    migrated += 1
                }
            }

            if migrated > 0 {
                try? modelContext.save()
                logSync("Migrated \(migrated) file paths to current container")
            }
        } catch {
            logSync("Failed to migrate file paths: \(error.localizedDescription)")
        }
    }

    /// Recover voice-note files after app reinstalls / path changes and backfill
    /// the sync metadata needed to advertise them to the Mac.
    private func migrateVoiceMemoPaths() async {
        let fileManager = FileManager.default
        let canonicalDirectory = VoiceMemoRecorder.voiceMemoDirectory()

        do {
            let descriptor = FetchDescriptor<Note>()
            let notes = try modelContext.fetch(descriptor)
            let voiceNotes = notes.filter { $0.type == .voice && !$0.isSoftDeleted }

            // Steady-state fast path: a note already at the canonical `<noteID>.m4a`
            // path with size/hash backfilled needs no filesystem work at all — mirrors
            // migrateFilePaths' prefix early-out, trusting the recorded path instead
            // of probing it. Pre-fix notes (stale path, or missing size/hash) still
            // fall through to the recovery pass below.
            let notesNeedingRecovery = voiceNotes.filter { note in
                let canonicalPath = VoiceMemoRecorder.voiceMemoURL(for: note.id).path
                return note.voiceFilePath != canonicalPath
                    || note.voiceFileSize == nil
                    || note.voiceFileSHA256 == nil
            }
            guard !notesNeedingRecovery.isEmpty else { return }

            let directoryFiles = ((try? fileManager.contentsOfDirectory(
                at: canonicalDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension.lowercased() == "m4a" }

            // Hashing + sizing every candidate file is the expensive part. Do it off the
            // main actor so the model-mutating loop below only ever hits the warm cache.
            let prewarmed = await Task.detached(priority: .utility) { () -> ([URL: String], [URL: Int64]) in
                var sha: [URL: String] = [:]
                var size: [URL: Int64] = [:]
                for url in directoryFiles {
                    if let value = try? FileIntegrity.sha256Hex(for: url) { sha[url] = value }
                    if let value = try? FileIntegrity.fileSize(for: url) { size[url] = value }
                }
                return (sha, size)
            }.value

            var sizeCache: [URL: Int64] = prewarmed.1
            var shaCache: [URL: String] = prewarmed.0
            var migratedCount = 0

            func cachedFileSize(for url: URL) -> Int64? {
                if let cached = sizeCache[url] { return cached }
                guard let size = try? FileIntegrity.fileSize(for: url) else { return nil }
                sizeCache[url] = size
                return size
            }

            func cachedSHA(for url: URL) -> String? {
                if let cached = shaCache[url] { return cached }
                guard let sha = try? FileIntegrity.sha256Hex(for: url) else { return nil }
                shaCache[url] = sha
                return sha
            }

            for note in notesNeedingRecovery {
                let canonicalURL = VoiceMemoRecorder.voiceMemoURL(for: note.id)
                let resolvedURL = recoverVoiceMemoURL(
                    for: note,
                    directoryFiles: directoryFiles,
                    cachedFileSize: cachedFileSize,
                    cachedSHA: cachedSHA
                )

                guard let resolvedURL else { continue }

                let finalURL: URL
                if resolvedURL.path != canonicalURL.path {
                    do {
                        if fileManager.fileExists(atPath: canonicalURL.path) {
                            finalURL = canonicalURL
                        } else {
                            try fileManager.moveItem(at: resolvedURL, to: canonicalURL)
                            finalURL = canonicalURL
                            migratedCount += 1
                        }
                    } catch {
                        logSync("Failed to move voice note \(note.id) to canonical path: \(error.localizedDescription)", level: .error)
                        finalURL = resolvedURL
                    }
                } else {
                    finalURL = canonicalURL
                }

                if note.voiceFilePath != finalURL.path {
                    note.voiceFilePath = finalURL.path
                    migratedCount += 1
                }
                if note.voiceFileSize == nil, let size = cachedFileSize(for: finalURL) {
                    note.voiceFileSize = size
                    migratedCount += 1
                }
                if note.voiceFileSHA256 == nil, let sha = cachedSHA(for: finalURL) {
                    note.voiceFileSHA256 = sha
                    migratedCount += 1
                }
            }

            if migratedCount > 0 {
                try modelContext.save()
                logSync("Recovered \(migratedCount) voice-note path/metadata fields")
            }
        } catch {
            logSync("Failed to migrate voice-note paths: \(error.localizedDescription)", level: .error)
        }
    }

    private func handleTransportStateChange(_ state: SyncConnectionState, senderID: UUID?) async {
        SyncLog.receiver.info("transport state changed to \(String(describing: state), privacy: .public)")
        if state != lastLoggedConnectionState {
            lastLoggedConnectionState = state
            if case .connected = state, let url = transport.connectedSenderURL {
                logSync("Connection: connected (\(url.host ?? url.absoluteString))")
            } else {
                logSync("Connection: \(String(describing: state))")
            }
        }
        let directive = await coordinator.handleConnectionStateChange(state, senderID: senderID)

        if directive.shouldCancelRunningSync {
            activeSyncTask?.cancel()
            activeSyncTask = nil
            activeSyncLeaseID = nil
            isSyncing = false
            manualSyncRequestedDuringActiveSync = false
        }

        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        pairStatusTask?.cancel()
        pairStatusTask = nil

        if directive.scheduleToken != nil {
            periodicSyncTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: self.periodicSyncInterval)
                    guard !Task.isCancelled else { return }
                    await self.requestSync(trigger: .periodic, waitForCompletion: false)
                }
            }
            pairStatusTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: self.pairStatusInterval)
                    guard !Task.isCancelled else { return }
                    guard case .connected = self.transport.connectionState else { return }
                    switch await self.transport.verifyPairingStatus() {
                    case .valid:
                        break
                    case .rejected:
                        // verifyPairingStatus already cleared the bond or recorded auth failure.
                        self.logSync("Mac rejected pairing — re-pair in Sync settings", level: .error)
                    case .unreachable:
                        // Transient hotspot/Wi‑Fi glitch — keep the session alive.
                        SyncLog.receiver.debug("pair status unreachable; keeping session")
                    }
                }
            }
        }

        if directive.shouldStartImmediateSync {
            // Fresh/changed sender session — never suppress the first push to it.
            lastPushedIOSManifestFingerprint = nil
            await requestSync(trigger: .connected, waitForCompletion: false)
        }

        refreshSyncStatusPresentation()
        scheduleRefreshPersistedStatus(senderID: senderID)
    }

    // MARK: - Sync

    func syncNow() async {
        await requestSync(trigger: .manual, waitForCompletion: true)
    }

    func notifyNoteMutated() {
        notifyLocalManifestMutated()
    }

    func notifyLocalManifestMutated() {
        notePushTask?.cancel()
        notePushTask = Task { [weak self] in
            // Debounce (matches the Mac's 400ms) so bursts of edits — adding
            // several tracks to a playlist, reorders — build and push the
            // full manifest once instead of per mutation.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }

            let state = self.transport.connectionState
            guard state == .connected || state == .idle else {
                // Not connected — trigger a reconnect so the note can sync.
                self.triggerReconnect()
                return
            }

            let manifest = self.buildiOSManifest()
            // Scalar fingerprint dedupe: identical content since the last
            // successful push → skip the network round-trip and Mac merge.
            let fingerprint = LibraryManifest.generationFingerprint(
                tracks: manifest.tracks,
                notes: manifest.notes,
                playlistFolders: manifest.playlistFolders,
                playlists: manifest.playlists
            )
            if fingerprint == self.lastPushedIOSManifestFingerprint {
                SyncLog.notes.debug("skipping iOS manifest push — fingerprint unchanged")
                return
            }
            do {
                try await self.transport.pushiOSManifest(manifest)
                self.lastPushedIOSManifestFingerprint = fingerprint
            } catch {
                SyncLog.notes.error("failed to push iOS note update: \(error.localizedDescription, privacy: .public)")
                let desc = error.localizedDescription
                if desc.contains("(403)") {
                    self.logSync("Note push rejected — Mac doesn't recognize this device. Re-pair.", level: .error)
                } else if desc.contains("notConnected") ||
                    desc.localizedCaseInsensitiveContains("could not connect to the server") ||
                    desc.localizedCaseInsensitiveContains("network connection was lost") {
                    self.triggerReconnect()
                }
            }
        }
    }

    private func requestSync(trigger: ReceiverSyncCoordinator.Trigger, waitForCompletion: Bool) async {
        guard case .connected = transport.connectionState else {
            SyncLog.receiver.debug("sync request skipped because transport is \(String(describing: self.transport.connectionState), privacy: .public)")
            return
        }

        if let activeSyncTask {
            if trigger == .manual {
                manualSyncRequestedDuringActiveSync = true
            }
            if waitForCompletion {
                await activeSyncTask.value
            }
            return
        }

        guard let lease = await coordinator.beginSync(trigger: trigger, senderID: transport.connectedDeviceID) else {
            SyncLog.receiver.debug("sync request skipped because a session is already active")
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSync(lease: lease)
        }
        activeSyncTask = task
        activeSyncLeaseID = lease.id

        if waitForCompletion {
            await task.value
        }
    }

    private func runSync(lease: ReceiverSyncCoordinator.SyncLease) async {
        isSyncing = true
        lastSyncError = nil
        refreshSyncStatusPresentation()
        defer {
            let runFollowUpManualSync = activeSyncLeaseID == lease.id && manualSyncRequestedDuringActiveSync
            if activeSyncLeaseID == lease.id {
                isSyncing = false
                activeSyncTask = nil
                activeSyncLeaseID = nil
                manualSyncRequestedDuringActiveSync = false
            }
            refreshSyncStatusPresentation()
            Task {
                await coordinator.finishSync(lease)
                if runFollowUpManualSync {
                    await requestSync(trigger: .manual, waitForCompletion: false)
                }
            }
        }

        // Steady-state 10s polls hit the tiny GET /generation first and skip
        // the multi-KB manifest download + JSON decode entirely when nothing
        // changed. Manual/connect syncs always do the full fetch, and any
        // pre-check failure (old Mac without the endpoint, transient error)
        // falls through to the full-manifest path.
        if lease.trigger == .periodic, await generationPrecheckSaysUnchanged() {
            SyncLog.receiver.debug("sync early-out: generation pre-check unchanged")
            return
        }

        logSync("Starting sync…")

        do {
            let manifest = try await transport.requestManifest()
            logSync("Received manifest gen \(manifest.generation) with \(manifest.tracks.count) tracks")
            if let leaseSenderID = lease.senderID, leaseSenderID != manifest.senderID {
                SyncLog.receiver.error("discarding stale sync result for replaced sender session")
                logSync("Discarded stale sync result", level: .error)
                return
            }
            let summary = try await processManifest(manifest)
            syncedTrackCount = manifest.tracks.count

            if summary.skippedUnchanged {
                SyncLog.receiver.debug(
                    "sync early-out: generation \(manifest.generation) unchanged, no pending/failed snapshots"
                )
                logSync("Sync idle — manifest unchanged")
            } else if summary.failedCount == 0 {
                lastSyncAt = Date()
                lastSyncError = nil
                logSync("Sync complete: \(summary.downloadedCount) downloaded, \(summary.deletedCount) deleted")
                SyncLog.receiver.info(
                    "sync complete: downloaded \(summary.downloadedCount), deleted \(summary.deletedCount), generation \(manifest.generation)"
                )
                // Only push phone→Mac when this round mutated local state.
                // Steady-state no-ops must not rebuild/push the full iOS manifest.
                // Local note/playlist edits still push via notifyNoteMutated / notifyLocalManifestMutated.
                if summary.didMutate {
                    notifyLocalManifestMutated()
                }
            } else {
                lastSyncError = "\(summary.failedCount) transfer(s) failed"
                logSync("Sync partial failure: \(summary.failedCount) failed", level: .error)
                SyncLog.receiver.error(
                    "sync partial failure: downloaded \(summary.downloadedCount), failed \(summary.failedCount), generation \(manifest.generation)"
                )
            }
            if !summary.skippedUnchanged {
                refreshPersistedStatus(senderID: manifest.senderID)
            }
        } catch {
            guard !Task.isCancelled else {
                SyncLog.receiver.debug("sync task cancelled")
                return
            }
            lastSyncError = error.localizedDescription
            let desc = error.localizedDescription
            if desc.contains("(403)") {
                logSync("Sync rejected by Mac — open Sync and re-pair", level: .error)
            } else {
                logSync("Sync failed: \(desc)", level: .error)
            }
            SyncLog.receiver.error("sync failed: \(desc, privacy: .public)")
            // Only tear down the transport for auth failures or not-connected.
            // Transient HTTP errors (404 manifest not ready, 500, decode issues)
            // should keep the session alive so the next periodic sync retries.
            if desc.contains("notConnected") ||
                desc.contains("(403)") ||
                desc.localizedCaseInsensitiveContains("could not connect to the server") ||
                desc.localizedCaseInsensitiveContains("network connection was lost") {
                if desc.contains("(403)") {
                    // Auth handler inside transport already reset state / cleared bond.
                } else {
                    transport.handleNetworkFailure()
                    triggerReconnect()
                }
            }
            refreshPersistedStatus(senderID: transport.connectedDeviceID)
        }
    }

    /// True when the connected Mac's published generation matches the last one
    /// this device fully applied and no snapshots are awaiting retry — the same
    /// condition as `processManifest`'s early-out, checked without downloading
    /// the manifest. Any doubt (no checkpoint yet, endpoint unsupported,
    /// transient error, outstanding work) returns false → full poll.
    private func generationPrecheckSaysUnchanged() async -> Bool {
        guard let senderID = transport.connectedDeviceID,
              let checkpoint = fetchCheckpoint(senderID: senderID) else { return false }
        guard !hasOutstandingVersionSnapshots(senderID: senderID) else { return false }
        do {
            guard let remoteGeneration = try await transport.requestGeneration() else {
                return false
            }
            return remoteGeneration == checkpoint.lastManifestGeneration
        } catch {
            SyncLog.receiver.debug(
                "generation pre-check failed, falling back to full manifest: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Manifest Processing

    private struct SyncSummary {
        let downloadedCount: Int
        let deletedCount: Int
        let failedCount: Int
        /// True when SwiftData or downloads changed something this round.
        let didMutate: Bool
        /// True when generation matched and there was no pending/failed work — no model I/O.
        let skippedUnchanged: Bool

        static let idleUnchanged = SyncSummary(
            downloadedCount: 0,
            deletedCount: 0,
            failedCount: 0,
            didMutate: false,
            skippedUnchanged: true
        )
    }

    private func processManifest(_ manifest: LibraryManifest) async throws -> SyncSummary {
        await Task.yield()

        lastSenderProtocolVersion = manifest.protocolVersion

        // Steady-state early-out: identical Mac generation and nothing to retry
        // → skip all SwiftData fetches/writes and do not push an iOS manifest.
        if let existingCheckpoint = fetchCheckpoint(senderID: manifest.senderID),
           existingCheckpoint.lastManifestGeneration == manifest.generation,
           !hasOutstandingVersionSnapshots(senderID: manifest.senderID),
           !hasUndownloadedRemoteAudio(in: manifest) {
            return .idleUnchanged
        }

        let checkpoint = fetchOrCreateCheckpoint(senderID: manifest.senderID, senderName: manifest.senderName)

        let localTracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        let localVersions = (try? modelContext.fetch(FetchDescriptor<Version>())) ?? []
        let trackSnapshots = fetchTrackSnapshots(senderID: manifest.senderID)
        let versionSnapshots = fetchVersionSnapshots(senderID: manifest.senderID)

        // Update snapshots to reflect latest manifest data
        var trackSnapshotsByID = Dictionary(trackSnapshots.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        var versionSnapshotsByID = Dictionary(versionSnapshots.map { ($0.versionID, $0) }, uniquingKeysWith: { first, _ in first })

        var localTracksByEntryID = Dictionary(localTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var localVersionsByEntryID = Dictionary(localVersions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Reconcile the catalog before deciding which audio bytes to fetch.
        // A missing local file is a valid metadata-only state, not a remote
        // deletion and not an automatic download request.
        materializeCatalogEntries(
            manifest: manifest,
            tracksByID: &localTracksByEntryID,
            versionsByID: &localVersionsByEntryID
        )

        /// trackID → remote artworkRevision (nil = clear local cover).
        var pendingArtworkRevisions: [UUID: Int64?] = [:]
        let declinedVersionIDs = declinedAutoDownloadVersionIDs

        for trackEntry in manifest.tracks where !trackEntry.isSoftDeleted {
            upsertTrackSnapshot(trackEntry, senderID: manifest.senderID, generation: manifest.generation, snapshotsByID: &trackSnapshotsByID)

            // Cover art is revision-keyed — never byte-compare blobs on idle polls.
            // Queue a fetch when the remote revision differs from the local signal.
            if let track = localTracksByEntryID[trackEntry.id] {
                let localRevision = track.resolvedArtworkRevision()
                if localRevision != trackEntry.artworkRevision {
                    pendingArtworkRevisions[trackEntry.id] = trackEntry.artworkRevision
                }
            } else if trackEntry.artworkRevision != nil {
                // Track may be created during a version download this round.
                pendingArtworkRevisions[trackEntry.id] = trackEntry.artworkRevision
            }

            for versionEntry in trackEntry.versions where !versionEntry.isSoftDeleted {
                let snapshot = upsertVersionSnapshot(versionEntry, senderID: manifest.senderID, generation: manifest.generation, snapshotsByID: &versionSnapshotsByID)

                // Catalog sync is metadata-only by default. When the receiver
                // preference is enabled, turn missing remote audio into local
                // download intent while leaving failed snapshots' retry
                // backoff intact.
                if autoDownloadSyncedTracks,
                   !declinedVersionIDs.contains(versionEntry.id),
                   localVersionsByEntryID[versionEntry.id].map({ !FileManager.default.fileExists(atPath: $0.filePath) }) ?? true {
                    snapshot.downloadRequested = true
                }

                // Preserve existing local audio on upgrade and migrate legacy
                // receivers into explicit intent without downloading anything.
                if let localVersion = localVersionsByEntryID[versionEntry.id],
                   FileManager.default.fileExists(atPath: localVersion.filePath) {
                    snapshot.downloadRequested = true
                }

                // Mark already-matched versions as applied (skip download)
                if let localVersion = localVersionsByEntryID[versionEntry.id],
                   FileManager.default.fileExists(atPath: localVersion.filePath),
                   localVersionMatchesRemote(localVersion, remote: versionEntry, snapshot: snapshot) {
                    let track = localTracksByEntryID[trackEntry.id]
                    updateLocalVersion(localVersion, from: versionEntry, destinationURL: URL(fileURLWithPath: localVersion.filePath))
                    if let track { ensureVersionAttached(localVersion, to: track) }
                    if snapshot.syncStatus != .applied {
                        snapshot.syncStatus = .applied
                    }
                    if snapshot.retryCount != 0 {
                        snapshot.retryCount = 0
                    }
                    if snapshot.nextRetryAt != nil {
                        snapshot.nextRetryAt = nil
                    }
                    if snapshot.lastError != nil {
                        snapshot.lastError = nil
                    }
                }
            }
        }

        // Compute diff using the engine
        let diff = ManifestDiffEngine.compute(
            manifest: manifest,
            localTracks: Array(localTracksByEntryID.values),
            localVersions: Array(localVersionsByEntryID.values),
            trackSnapshots: trackSnapshots,
            versionSnapshots: versionSnapshots,
            now: Date(),
            requestedVersionIDs: Set(versionSnapshotsByID.values.filter(\.downloadRequested).map(\.versionID))
        )

        // Resolve download URLs for jobs
        var downloadJobsWithURLs: [DownloadJob] = []
        for job in diff.downloadJobs {
            guard let downloadURL = try? transport.fileDownloadURL(versionID: job.version.id) else {
                if let snapshot = versionSnapshotsByID[job.version.id] {
                    markSnapshotFailure(snapshot, error: "missing sender base URL")
                }
                continue
            }
            let snapshot = versionSnapshotsByID[job.version.id]
            if snapshot?.syncStatus != .pending {
                snapshot?.syncStatus = .pending
            }
            if snapshot?.lastError != nil {
                snapshot?.lastError = nil
            }
            if snapshot?.nextRetryAt != nil {
                snapshot?.nextRetryAt = nil
            }
            downloadJobsWithURLs.append(DownloadJob(
                track: job.track,
                version: job.version,
                kind: job.kind,
                downloadURL: downloadURL,
                requestToken: downloadRequestTokens[job.version.id, default: 0]
            ))
        }

        // Persist the transition out of the queued state before the bounded
        // transfer pool starts. A relaunch during the transfer should expose
        // selected work as in progress rather than silently reverting to idle.
        for job in downloadJobsWithURLs {
            versionSnapshotsByID[job.version.id]?.syncStatus = .downloading
        }

        onWillRemoveAudio?(diff.deletedTrackIDs, diff.deletedVersionIDs)
        var localTracksByID = Dictionary(localTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var localVersionsByID = Dictionary(localVersions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var deletedCount = 0

        for versionID in diff.deletedVersionIDs {
            guard let snapshot = versionSnapshotsByID[versionID] else { continue }
            deletedCount += deleteRemoteVersion(
                snapshot: snapshot,
                localTracksByID: &localTracksByID,
                localVersionsByID: &localVersionsByID
            )
            modelContext.delete(snapshot)
        }

        for trackID in diff.deletedTrackIDs {
            guard let snapshot = trackSnapshotsByID[trackID] else { continue }
            if let track = localTracksByID[trackID], track.versions.isEmpty {
                modelContext.delete(track)
            }
            modelContext.delete(snapshot)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        refreshPersistedStatus(senderID: manifest.senderID)
        await Task.yield()

        // Execute downloads via transfer queue. Save the explicit downloading
        // state once before the work begins; later verification/apply changes
        // are committed with the final sync save below.
        if modelContext.hasChanges {
            try modelContext.save()
        }
        activeTransferCount = downloadJobsWithURLs.count
        refreshSyncStatusPresentation()

        await transferCancellation.reset(for: Set(downloadJobsWithURLs.map { $0.version.id }))
        let transferResults = await transferQueue.execute(
            downloadJobsWithURLs,
            cancellation: transferCancellation
        ) { [transport] job in
            try await transport.downloadFile(versionID: job.version.id)
        }
        activeTransferCount = 0
        refreshSyncStatusPresentation()

        let jobsByVersionID = Dictionary(downloadJobsWithURLs.map { ($0.version.id, $0) }, uniquingKeysWith: { first, _ in first })
        var downloadedCount = 0
        var failedCount = 0

        for (index, result) in transferResults.enumerated() {
            if index.isMultiple(of: 4) {
                await Task.yield()
            }
            guard let job = jobsByVersionID[result.versionID],
                  let snapshot = versionSnapshotsByID[job.version.id] else {
                if let temp = result.tempFileURL { try? FileManager.default.removeItem(at: temp) }
                continue
            }

            // A user can remove/cancel while the bounded transfer is in flight.
            // Drop the late temp file and do not reinstall an unwanted copy.
            guard snapshot.downloadRequested,
                  downloadRequestTokens[job.version.id, default: 0] == job.requestToken else {
                if let temp = result.tempFileURL { try? FileManager.default.removeItem(at: temp) }
                continue
            }

            switch result.status {
            case .verifying:
                guard let tempFileURL = result.tempFileURL else { continue }
                snapshot.syncStatus = .verifying
                do {
                    let destinationURL = try await installDownloadedVersion(
                        job, tempFileURL: tempFileURL,
                        localTracksByID: &localTracksByID,
                        localVersionsByID: &localVersionsByID
                    )
                    updateSnapshot(snapshot, from: job.version, generation: manifest.generation)
                    snapshot.syncStatus = .applied
                    snapshot.retryCount = 0
                    snapshot.nextRetryAt = nil
                    snapshot.lastError = nil
                    downloadedCount += 1
                    SyncLog.apply.info("applied \(destinationURL.lastPathComponent, privacy: .public)")
                } catch {
                    try? FileManager.default.removeItem(at: tempFileURL)
                    failedCount += 1
                    markSnapshotFailure(snapshot, error: error.localizedDescription)
                    SyncLog.apply.error(
                        "apply failed for \(job.version.originalFilename, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            case .failed:
                failedCount += 1
                markSnapshotFailure(snapshot, error: result.errorDescription ?? "unknown transfer failure")
                SyncLog.receiver.error(
                    "download failed for \(job.version.originalFilename, privacy: .public): \((result.errorDescription ?? "unknown error"), privacy: .public)"
                )
            case .cancelled:
                // Cancellation is user intent, not a transfer failure. The
                // request token/downloadRequested guard above normally drops
                // this result before reaching the switch; keep the case
                // explicit so a racing cancellation cannot create a retry.
                if let temp = result.tempFileURL {
                    try? FileManager.default.removeItem(at: temp)
                }
            }
        }

        var localNotesByID = Dictionary(((try? modelContext.fetch(FetchDescriptor<Note>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for noteEntry in manifest.notes {
            mergeNoteEntry(noteEntry, into: &localNotesByID, tracksByID: &localTracksByID, versionsByID: localVersionsByID)
        }
        await fetchMissingVoiceNoteFiles(in: localNotesByID)
        await applyArtworkUpdates(pendingArtworkRevisions, localTracksByID: &localTracksByID)
        // Cover transfer decisions compare pre-merge timestamps (merge copies the
        // remote updatedAt onto winners, erasing who was newer), so compute them
        // before mergePlaylistEntries and execute after it (new playlists exist then).
        let coverActions = pendingPlaylistCoverActions(for: manifest)
        mergePlaylistEntries(from: manifest)
        await applyPlaylistCoverUpdates(coverActions)

        // Measure content mutation before checkpoint bookkeeping so a no-op
        // retry pass (failed snapshot waiting on nextRetryAt) does not look
        // like a real change and trigger an iOS manifest push.
        let didMutate = downloadedCount > 0 || deletedCount > 0 || modelContext.hasChanges

        if checkpoint.senderName != manifest.senderName {
            checkpoint.senderName = manifest.senderName
        }
        if checkpoint.lastManifestFetchedAt != manifest.generatedAt {
            checkpoint.lastManifestFetchedAt = manifest.generatedAt
        }

        if failedCount == 0 {
            if checkpoint.lastManifestGeneration != manifest.generation {
                checkpoint.lastManifestGeneration = manifest.generation
            }
            checkpoint.lastSyncAt = .now
            if checkpoint.lastSyncError != nil {
                checkpoint.lastSyncError = nil
            }
        } else {
            checkpoint.lastSyncError = "\(failedCount) transfer(s) failed"
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        refreshPersistedStatus(senderID: manifest.senderID)

        return SyncSummary(
            downloadedCount: downloadedCount,
            deletedCount: deletedCount,
            failedCount: failedCount,
            didMutate: didMutate,
            skippedUnchanged: false
        )
    }

    // MARK: - Local Apply

    private func installDownloadedVersion(
        _ job: DownloadJob,
        tempFileURL: URL,
        localTracksByID: inout [UUID: Track],
        localVersionsByID: inout [UUID: Version]
    ) async throws -> URL {
        let destinationURL = audioDirectory().appendingPathComponent(
            FileIntegrity.preferredFilename(for: job.version.id, fileFormat: job.version.fileFormat)
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempFileURL, to: destinationURL)

        let track = fetchOrCreateTrack(entry: job.track, localTracksByID: &localTracksByID)
        let version = fetchOrCreateVersion(entry: job.version, destinationURL: destinationURL, localVersionsByID: &localVersionsByID)

        updateLocalVersion(version, from: job.version, destinationURL: destinationURL)
        ensureVersionAttached(version, to: track)

        if let waveformData = try? await waveformProcessor.process(fileURL: destinationURL) {
            version.waveformData = waveformData
        }

        return destinationURL
    }

    private func materializeCatalogEntries(
        manifest: LibraryManifest,
        tracksByID: inout [UUID: Track],
        versionsByID: inout [UUID: Version]
    ) {
        for entry in manifest.tracks where !entry.isSoftDeleted {
            let track = fetchOrCreateTrackMetadata(entry: entry, localTracksByID: &tracksByID)
            for versionEntry in entry.versions where !versionEntry.isSoftDeleted {
                let destination = audioDirectory().appendingPathComponent(
                    FileIntegrity.preferredFilename(for: versionEntry.id, fileFormat: versionEntry.fileFormat)
                )
                let version: Version
                if let existing = versionsByID[versionEntry.id] {
                    version = existing
                    if version.filePath.isEmpty { version.filePath = destination.path }
                } else {
                    version = Version(
                        id: versionEntry.id,
                        trackID: versionEntry.trackID,
                        label: versionEntry.label,
                        filePath: destination.path,
                        fileSize: versionEntry.fileSize,
                        fileFormat: versionEntry.fileFormat,
                        originalFilename: versionEntry.originalFilename,
                        duration: versionEntry.duration,
                        contentHash: versionEntry.contentHash,
                        sourceContentHash: versionEntry.sourceContentHash
                    )
                    modelContext.insert(version)
                    versionsByID[version.id] = version
                }
                updateLocalVersion(version, from: versionEntry, destinationURL: URL(fileURLWithPath: version.filePath))
                ensureVersionAttached(version, to: track)
            }
        }
    }

    private func fetchOrCreateTrackMetadata(
        entry: TrackManifestEntry,
        localTracksByID: inout [UUID: Track]
    ) -> Track {
        if let existing = localTracksByID[entry.id] {
            // Track metadata is last-write-wins. A phone-side date clear or
            // override must not be erased by a stale Mac manifest while the
            // next phone→Mac push is still in flight. Equal timestamps resolve
            // in favour of the remote entry, matching the Mac merge rule.
            guard entry.updatedAt >= existing.updatedAt else { return existing }
            existing.name = entry.name
            existing.createdAt = entry.createdAt
            existing.updatedAt = entry.updatedAt
            existing.workingTitle = entry.workingTitle
            existing.versionNumber = entry.versionNumber
            existing.isReleased = entry.isReleased
            existing.isSet = entry.isSet
            existing.recordingDateString = entry.recordingDateString
            return existing
        }
        let track = Track(
            id: entry.id,
            name: entry.name,
            origin: .mac,
            workingTitle: entry.workingTitle,
            versionNumber: entry.versionNumber,
            isReleased: entry.isReleased,
            isSet: entry.isSet,
            recordingDateString: entry.recordingDateString,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt
        )
        modelContext.insert(track)
        localTracksByID[track.id] = track
        return track
    }

    private func fetchOrCreateTrack(entry: TrackManifestEntry, localTracksByID: inout [UUID: Track]) -> Track {
        if let existing = localTracksByID[entry.id] {
            guard entry.updatedAt >= existing.updatedAt else { return existing }
            existing.name = entry.name
            existing.createdAt = entry.createdAt
            existing.updatedAt = entry.updatedAt
            existing.workingTitle = entry.workingTitle
            existing.versionNumber = entry.versionNumber
            existing.isReleased = entry.isReleased
            existing.isSet = entry.isSet
            existing.recordingDateString = entry.recordingDateString
            // Artwork applied separately via revision-keyed `/artwork/{id}` fetch.
            return existing
        }
        let track = Track(
            id: entry.id,
            name: entry.name,
            artwork: nil,
            origin: .mac,
            workingTitle: entry.workingTitle,
            versionNumber: entry.versionNumber,
            isReleased: entry.isReleased,
            isSet: entry.isSet,
            recordingDateString: entry.recordingDateString,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt
        )
        modelContext.insert(track)
        localTracksByID[track.id] = track
        return track
    }

    private func fetchOrCreateVersion(entry: VersionManifestEntry, destinationURL: URL, localVersionsByID: inout [UUID: Version]) -> Version {
        if let existing = localVersionsByID[entry.id] { return existing }
        let version = Version(
            id: entry.id, trackID: entry.trackID, label: entry.label,
            filePath: destinationURL.path, fileSize: entry.fileSize,
            fileFormat: entry.fileFormat, originalFilename: entry.originalFilename,
            duration: entry.duration, addedAt: entry.addedAt
        )
        modelContext.insert(version)
        localVersionsByID[version.id] = version
        return version
    }

    private func updateLocalVersion(_ version: Version, from entry: VersionManifestEntry, destinationURL: URL) {
        version.trackID = entry.trackID
        version.label = entry.label
        version.filePath = destinationURL.path
        version.fileSize = entry.fileSize
        version.fileFormat = entry.fileFormat
        version.originalFilename = entry.originalFilename
        version.duration = entry.duration
        version.addedAt = entry.addedAt
    }

    private func ensureVersionAttached(_ version: Version, to track: Track) {
        if track.versions.contains(where: { $0.id == version.id }) { return }
        track.versions.append(version)
    }

    private func deleteRemoteVersion(
        snapshot: RemoteVersionSnapshot,
        localTracksByID: inout [UUID: Track],
        localVersionsByID: inout [UUID: Version]
    ) -> Int {
        guard let version = localVersionsByID.removeValue(forKey: snapshot.versionID) else { return 0 }
        let fileURL = URL(fileURLWithPath: version.filePath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let track = localTracksByID[snapshot.trackID] {
            track.versions.removeAll { $0.id == version.id }
            if track.versions.isEmpty {
                modelContext.delete(track)
                localTracksByID.removeValue(forKey: track.id)
            }
        }
        modelContext.delete(version)
        return 1
    }

    private func localVersionMatchesRemote(_ localVersion: Version, remote: VersionManifestEntry, snapshot: RemoteVersionSnapshot?) -> Bool {
        guard localVersion.trackID == remote.trackID else { return false }
        guard localVersion.fileSize == remote.fileSize else { return false }
        guard localVersion.fileFormat == remote.fileFormat else { return false }
        guard localVersion.originalFilename == remote.originalFilename else { return false }
        guard localVersion.duration == remote.duration else { return false }
        if let snapshot {
            guard snapshot.revision == remote.revision else { return false }
            guard snapshot.contentHash == remote.contentHash else { return false }
        }
        return true
    }

    // MARK: - Snapshot CRUD

    private func fetchCheckpoint(senderID: UUID) -> SyncCheckpoint? {
        var descriptor = FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.senderID == senderID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchOrCreateCheckpoint(senderID: UUID, senderName: String) -> SyncCheckpoint {
        if let existing = fetchCheckpoint(senderID: senderID) { return existing }
        let checkpoint = SyncCheckpoint(senderID: senderID, senderName: senderName)
        modelContext.insert(checkpoint)
        return checkpoint
    }

    /// Pending/failed/in-flight version snapshots that must still be retried even
    /// when Mac `manifest.generation` is unchanged.
    private func hasOutstandingVersionSnapshots(senderID: UUID) -> Bool {
        let pending = SyncItemStatus.pending.rawValue
        let downloading = SyncItemStatus.downloading.rawValue
        let verifying = SyncItemStatus.verifying.rawValue
        let failed = SyncItemStatus.failed.rawValue
        var descriptor = FetchDescriptor<RemoteVersionSnapshot>(
            predicate: #Predicate { snapshot in
                snapshot.senderID == senderID && (
                    snapshot.syncStatusRawValue == pending
                    || snapshot.syncStatusRawValue == downloading
                    || snapshot.syncStatusRawValue == verifying
                    || snapshot.syncStatusRawValue == failed
                )
            }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first) != nil
    }

    private var autoDownloadSyncedTracks: Bool {
        UserDefaults.standard.bool(forKey: "autoDownloadSyncedTracks")
    }

    private func hasUndownloadedRemoteAudio(in manifest: LibraryManifest) -> Bool {
        guard autoDownloadSyncedTracks else { return false }
        let declinedVersionIDs = declinedAutoDownloadVersionIDs

        let localVersions = (try? modelContext.fetch(FetchDescriptor<Version>())) ?? []
        let localVersionsByID = Dictionary(localVersions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return manifest.tracks.contains { track in
            track.versions.contains { version in
                guard !version.isSoftDeleted, !declinedVersionIDs.contains(version.id) else { return false }
                guard let localVersion = localVersionsByID[version.id] else { return true }
                return !FileManager.default.fileExists(atPath: localVersion.filePath)
            }
        }
    }

    private func fetchTrackSnapshots(senderID: UUID) -> [RemoteTrackSnapshot] {
        (try? modelContext.fetch(FetchDescriptor<RemoteTrackSnapshot>(predicate: #Predicate { $0.senderID == senderID }))) ?? []
    }

    private func fetchVersionSnapshots(senderID: UUID) -> [RemoteVersionSnapshot] {
        (try? modelContext.fetch(FetchDescriptor<RemoteVersionSnapshot>(predicate: #Predicate { $0.senderID == senderID }))) ?? []
    }

    private func upsertTrackSnapshot(_ entry: TrackManifestEntry, senderID: UUID, generation: Int64, snapshotsByID: inout [UUID: RemoteTrackSnapshot]) {
        if let existing = snapshotsByID[entry.id] {
            // SwiftData dirties on any setter — only write when revision actually changed.
            guard existing.revision != entry.revision else { return }
            existing.name = entry.name
            existing.createdAt = entry.createdAt
            existing.updatedAt = entry.updatedAt
            existing.revision = entry.revision
            existing.lastSeenGeneration = generation
            return
        }
        let snapshot = RemoteTrackSnapshot(senderID: senderID, trackID: entry.id, name: entry.name, createdAt: entry.createdAt, updatedAt: entry.updatedAt, revision: entry.revision, lastSeenGeneration: generation)
        modelContext.insert(snapshot)
        snapshotsByID[entry.id] = snapshot
    }

    private func upsertVersionSnapshot(_ entry: VersionManifestEntry, senderID: UUID, generation: Int64, snapshotsByID: inout [UUID: RemoteVersionSnapshot]) -> RemoteVersionSnapshot {
        if let existing = snapshotsByID[entry.id] {
            if existing.revision != entry.revision {
                updateSnapshot(existing, from: entry, generation: generation)
            }
            return existing
        }
        let snapshot = RemoteVersionSnapshot(
            senderID: senderID, trackID: entry.trackID, versionID: entry.id,
            label: entry.label, fileSize: entry.fileSize, fileFormat: entry.fileFormat,
            originalFilename: entry.originalFilename, duration: entry.duration,
            addedAt: entry.addedAt, modifiedAt: entry.modifiedAt, revision: entry.revision,
            contentHash: entry.contentHash, lastSeenGeneration: generation
        )
        modelContext.insert(snapshot)
        snapshotsByID[entry.id] = snapshot
        return snapshot
    }

    private func updateSnapshot(_ snapshot: RemoteVersionSnapshot, from entry: VersionManifestEntry, generation: Int64) {
        snapshot.trackID = entry.trackID
        snapshot.label = entry.label
        snapshot.fileSize = entry.fileSize
        snapshot.fileFormat = entry.fileFormat
        snapshot.originalFilename = entry.originalFilename
        snapshot.duration = entry.duration
        snapshot.addedAt = entry.addedAt
        snapshot.modifiedAt = entry.modifiedAt
        snapshot.revision = entry.revision
        snapshot.contentHash = entry.contentHash
        snapshot.lastSeenGeneration = generation
    }

    private func markSnapshotFailure(_ snapshot: RemoteVersionSnapshot, error: String) {
        snapshot.syncStatus = .failed
        snapshot.retryCount += 1
        snapshot.nextRetryAt = Date().addingTimeInterval(retryDelay(for: snapshot.retryCount))
        snapshot.lastError = error
    }

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        let base = pow(2.0, Double(max(retryCount - 1, 0)))
        return min(base * 5, 300)
    }

    // MARK: - Status

    private func refreshSyncStatusPresentation() {
        let presentation = SyncStatusMapper.presentation(
            state: transport.connectionState,
            isUnpaired: bondedPeerStore.peers.isEmpty,
            isSyncing: isSyncing,
            autoConnectPaused: autoConnectPaused,
            failedTransferCount: failedTransferCount,
            authFailureThresholdExceeded: authFailureThresholdExceeded,
            connectionPath: transport.connectionPathLabel
        )
        guard presentation != syncStatusPresentation else { return }
        syncStatusPresentation = presentation
    }

    /// Debounced so rapid connection-state churn doesn't refetch every snapshot
    /// on the main actor between Searching → Found → Connected.
    private func scheduleRefreshPersistedStatus(senderID: UUID?) {
        refreshStatusTask?.cancel()
        refreshStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.applyPersistedStatus(senderID: senderID)
        }
    }

    private func refreshPersistedStatus(senderID: UUID?) {
        refreshStatusTask?.cancel()
        applyPersistedStatus(senderID: senderID)
    }

    private func applyPersistedStatus(senderID: UUID?) {
        guard let senderID else {
            pendingTransferCount = 0
            retryingTransferCount = 0
            failedTransferCount = 0
            refreshSyncStatusPresentation()
            return
        }
        let snapshots = fetchVersionSnapshots(senderID: senderID)
        pendingTransferCount = snapshots.filter {
            $0.syncStatus == .pending || $0.syncStatus == .downloading || $0.syncStatus == .verifying
        }.count
        retryingTransferCount = snapshots.filter { $0.nextRetryAt != nil }.count
        failedTransferCount = snapshots.filter { $0.syncStatus == .failed }.count

        var descriptor = FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.senderID == senderID })
        descriptor.fetchLimit = 1
        if let checkpoint = try? modelContext.fetch(descriptor).first {
            lastSuccessfulGeneration = checkpoint.lastManifestGeneration
        }
        refreshSyncStatusPresentation()
    }

    // MARK: - iOS Manifest Generation

    /// Build a manifest of all .phone-originated tracks plus locally edited
    /// Mac-originated metadata and every locally-known note. The extra Mac
    /// tracks are metadata-only: the Mac already owns their audio and its
    /// merge path updates the existing row by ID without importing a duplicate.
    func buildiOSManifest() -> LibraryManifest {
        // Fetch all tracks and filter in memory. SwiftData #Predicate with captured
        // local variables can silently fail at runtime, so avoid it.
        let allTracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        var phoneTracks = allTracks.filter { $0.origin == .phone }

        let senderID = transport.connectedDeviceID ?? bondedPeerStore.peers.first?.id
        let remoteUpdatedAtByTrackID: [UUID: Date] = {
            guard let senderID else { return [:] }
            let snapshots = fetchTrackSnapshots(senderID: senderID)
            return Dictionary(snapshots.map { ($0.trackID, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        }()
        let locallyEditedMacTracks = allTracks.filter { track in
            guard track.origin != .phone,
                  let remoteUpdatedAt = remoteUpdatedAtByTrackID[track.id] else { return false }
            return track.updatedAt > remoteUpdatedAt
        }

        let noteEntries = manifestNoteEntries()

        // Include any track (regardless of origin) that has at least one non-deleted note,
        // so the Mac can create stub tracks and attach the notes properly.
        let phoneTrackIDs = Set(phoneTracks.map(\.id))
        let noteTrackIDs = Set(noteEntries.filter { !$0.isSoftDeleted }.map(\.trackID))
        let missingTrackIDs = noteTrackIDs.subtracting(phoneTrackIDs)

        for track in allTracks where missingTrackIDs.contains(track.id) {
            phoneTracks.append(track)
        }

        let existingIDs = Set(phoneTracks.map(\.id))
        phoneTracks.append(contentsOf: locallyEditedMacTracks.filter { !existingIDs.contains($0.id) })

        let tracks = phoneTracks
        let deviceID = transport.deviceID
        let deviceName = transport.deviceName

        let playlistFolderEntries = manifestPlaylistFolderEntries()
        let playlistEntries = manifestPlaylistEntries()

        let trackEntries = tracks.map { track -> TrackManifestEntry in
            let versionEntries = track.versions.map { version -> VersionManifestEntry in
                VersionManifestEntry(
                    id: version.id,
                    trackID: version.trackID,
                    label: version.label,
                    fileSize: version.fileSize,
                    fileFormat: version.fileFormat,
                    originalFilename: version.originalFilename,
                    duration: version.duration,
                    addedAt: version.addedAt,
                    modifiedAt: version.addedAt,
                    revision: Int64(version.addedAt.timeIntervalSince1970 * 1_000),
                    contentHash: version.contentHash,
                    sourceContentHash: version.sourceContentHash
                )
            }
            return TrackManifestEntry(
                id: track.id,
                name: track.name,
                createdAt: track.createdAt,
                updatedAt: track.updatedAt,
                revision: Int64(track.updatedAt.timeIntervalSince1970 * 1_000),
                versions: versionEntries,
                workingTitle: track.workingTitle,
                versionNumber: track.versionNumber,
                isReleased: track.isReleased,
                isSet: track.isSet,
                recordingDateString: track.recordingDateString,
                artworkRevision: track.resolvedArtworkRevision()
            )
        }

        return LibraryManifest(
            senderID: deviceID,
            senderName: deviceName,
            generation: Int64(Date().timeIntervalSince1970 * 1_000),
            generatedAt: .now,
            originatingDevice: .phone,
            tracks: trackEntries,
            notes: noteEntries,
            playlistFolders: playlistFolderEntries,
            playlists: playlistEntries
        )
    }

    private func manifestNoteEntries() -> [NoteManifestEntry] {
        let notes = ((try? modelContext.fetch(FetchDescriptor<Note>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }

        return notes.map { note in
            NoteManifestEntry(
                id: note.id,
                trackID: note.trackID,
                versionID: note.versionID,
                timestamp: note.timestamp,
                type: note.type,
                content: note.content,
                voiceFilePath: nil,
                voiceDuration: note.voiceDuration,
                voiceFileSize: note.voiceFileSize,
                voiceFileSHA256: note.voiceFileSHA256,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                createdOn: note.createdOn,
                isSoftDeleted: note.isSoftDeleted
            )
        }
    }

    private func manifestPlaylistFolderEntries() -> [PlaylistFolderManifestEntry] {
        let folders = ((try? modelContext.fetch(FetchDescriptor<PlaylistFolder>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }

        return folders.map { folder in
            PlaylistFolderManifestEntry(
                id: folder.id,
                name: folder.name,
                createdAt: folder.createdAt,
                updatedAt: folder.updatedAt,
                isSoftDeleted: folder.isSoftDeleted
            )
        }
    }

    private func manifestPlaylistEntries() -> [PlaylistManifestEntry] {
        let playlists = ((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let allEntries = (try? modelContext.fetch(FetchDescriptor<PlaylistEntry>())) ?? []
        let entriesByPlaylistID = Dictionary(grouping: allEntries, by: \.playlistID)

        // A pre-6 Mac has no /playlist-artwork endpoint and clears any cover it
        // can't find embedded — keep embedding for those peers for one upgrade
        // cycle. Unknown peer (never fetched a manifest) is assumed modern.
        let embedLegacyCovers = (lastSenderProtocolVersion ?? LibraryManifest.currentProtocolVersion) < 6

        return playlists.map { playlist in
            PlaylistManifestEntry(
                id: playlist.id,
                name: playlist.name,
                sortIndex: playlist.sortIndex,
                coverImagePath: playlist.coverImagePath,
                coverImageData: embedLegacyCovers ? playlist.coverImageData : nil,
                coverRevision: playlist.resolvedCoverRevision(),
                artist: playlist.artist,
                playlistDescription: playlist.playlistDescription,
                notes: playlist.notes,
                folderID: playlist.folder?.id,
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt,
                isSoftDeleted: playlist.isSoftDeleted,
                isReleased: playlist.isReleased,
                entries: (entriesByPlaylistID[playlist.id] ?? [])
                    .sorted { $0.position < $1.position }
                    .map { entry in
                        PlaylistEntryManifestEntry(
                            id: entry.id,
                            playlistID: entry.playlistID,
                            trackID: entry.trackID,
                            versionID: entry.versionID,
                            position: entry.position
                        )
                    }
            )
        }
    }

    private func mergePlaylistEntries(from manifest: LibraryManifest) {
        var foldersByID = Dictionary(((try? modelContext.fetch(FetchDescriptor<PlaylistFolder>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var playlistsByID = Dictionary(((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in manifest.playlistFolders {
            if let folder = foldersByID[entry.id] {
                guard entry.updatedAt > folder.updatedAt else { continue }
                folder.name = entry.name
                folder.updatedAt = entry.updatedAt
                if entry.isSoftDeleted && !folder.isSoftDeleted {
                    for playlist in Array(folder.playlists) { playlist.folder = nil }
                }
                folder.isSoftDeleted = entry.isSoftDeleted
            } else if !entry.isSoftDeleted {
                let folder = PlaylistFolder(id: entry.id, name: entry.name, createdAt: entry.createdAt, updatedAt: entry.updatedAt)
                modelContext.insert(folder)
                foldersByID[folder.id] = folder
            }
        }

        for entry in manifest.playlists {
            let playlist: Playlist
            // Whether the incoming snapshot may overwrite our local entries.
            // Entries carry no timestamp of their own, so we use the parent
            // playlist's updatedAt as the recency signal — captured BEFORE
            // apply() advances it. `>=` (not `>`) keeps the earlier
            // stranded-entries fix working (equal timestamps still apply, e.g.
            // an entry change that didn't bump updatedAt) while blocking a
            // *strictly older* peer snapshot from clobbering newer local
            // entries — the playlist-edit-reversal race.
            let applyEntries: Bool
            if let existing = playlistsByID[entry.id] {
                playlist = existing
                applyEntries = entry.updatedAt >= existing.updatedAt
                // Metadata (name/cover/folder) stays timestamp-gated.
                if entry.updatedAt > existing.updatedAt {
                    apply(entry, to: existing, foldersByID: foldersByID)
                }
            } else {
                // Never resurrect a playlist from a tombstone we don't have.
                guard !entry.isSoftDeleted else { continue }
                playlist = Playlist(
                    id: entry.id,
                    name: entry.name,
                    sortIndex: entry.sortIndex,
                    coverImagePath: entry.coverImagePath,
                    coverImageData: entry.coverImageData,
                    artist: entry.artist,
                    playlistDescription: entry.playlistDescription,
                    notes: entry.notes,
                    isReleased: entry.isReleased,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt
                )
                playlist.folder = entry.folderID.flatMap { foldersByID[$0] }
                modelContext.insert(playlist)
                playlistsByID[playlist.id] = playlist
                applyEntries = true // brand new — nothing local to protect
            }
            // Only rewrite entries when they actually differ — reconciling
            // identical entries every 10s sync would dirty the models and
            // trigger a @Query invalidation storm across the list views.
            let desiredEntries = entry.isSoftDeleted ? [] : entry.entries
            if applyEntries && playlistEntriesDiffer(playlist.entries, desiredEntries) {
                replacePlaylistEntries(for: playlist, with: desiredEntries)
            }
        }
    }

    /// Cheap scalar comparison (no version/waveform faulting) to decide whether
    /// the Mac's entry set differs from what's stored locally.
    private func playlistEntriesDiffer(
        _ local: [PlaylistEntry],
        _ incoming: [PlaylistEntryManifestEntry]
    ) -> Bool {
        guard local.count == incoming.count else { return true }
        let localSorted = local.sorted { $0.position < $1.position }
        let incomingSorted = incoming.sorted { $0.position < $1.position }
        for (l, r) in zip(localSorted, incomingSorted) {
            if l.id != r.id
                || l.trackID != r.trackID
                || l.versionID != r.versionID
                || l.position != r.position {
                return true
            }
        }
        return false
    }

    private func apply(_ entry: PlaylistManifestEntry, to playlist: Playlist, foldersByID: [UUID: PlaylistFolder]) {
        playlist.name = entry.name
        playlist.sortIndex = entry.sortIndex
        playlist.coverImagePath = entry.coverImagePath
        if let legacyCover = entry.coverImageData {
            // Pre-6 Mac still embeds cover bytes — apply them directly.
            playlist.setCoverImage(legacyCover)
        } else if entry.coverRevision == nil {
            // Mac cleared the cover (or never had one) and its edit won.
            if playlist.coverImageData != nil || playlist.coverRevision != nil {
                playlist.setCoverImage(nil)
            }
        }
        // else: revision-only signal — bytes are fetched separately via
        // GET /playlist-artwork/{id} (see applyPlaylistCoverUpdates).
        playlist.artist = entry.artist
        playlist.playlistDescription = entry.playlistDescription
        playlist.notes = entry.notes
        playlist.createdAt = entry.createdAt
        playlist.updatedAt = entry.updatedAt
        playlist.isSoftDeleted = entry.isSoftDeleted
        playlist.isReleased = entry.isReleased
        playlist.folder = entry.folderID.flatMap { foldersByID[$0] }
    }

    private func replacePlaylistEntries(for playlist: Playlist, with entries: [PlaylistEntryManifestEntry]) {
        // Dedup incoming by id (a malformed manifest could repeat one) so a
        // duplicate id can never spawn a second PlaylistEntry.
        var incomingByID: [UUID: PlaylistEntryManifestEntry] = [:]
        for entry in entries { incomingByID[entry.id] = entry }

        // Keep the first existing object per id that's still in the manifest;
        // delete the rest — both stale entries and any duplicate copies sharing
        // an id (dirty data from the earlier merge bug). Self-heals the store.
        var keptByID: [UUID: PlaylistEntry] = [:]
        for localEntry in playlist.entries {
            if incomingByID[localEntry.id] != nil, keptByID[localEntry.id] == nil {
                keptByID[localEntry.id] = localEntry
            } else {
                modelContext.delete(localEntry)
            }
        }

        // Rebuild the ordered relationship fresh from the deduped incoming set.
        var rebuilt: [PlaylistEntry] = []
        for entry in incomingByID.values.sorted(by: { $0.position < $1.position }) {
            let localEntry: PlaylistEntry
            if let existing = keptByID[entry.id] {
                localEntry = existing
                localEntry.playlistID = entry.playlistID
                localEntry.trackID = entry.trackID
                localEntry.versionID = entry.versionID
                localEntry.position = entry.position
            } else {
                localEntry = PlaylistEntry(
                    id: entry.id,
                    playlistID: entry.playlistID,
                    trackID: entry.trackID,
                    versionID: entry.versionID,
                    position: entry.position
                )
                modelContext.insert(localEntry)
            }
            rebuilt.append(localEntry)
        }
        playlist.entries = rebuilt
    }

    private func mergeNoteEntry(
        _ entry: NoteManifestEntry,
        into localNotesByID: inout [UUID: Note],
        tracksByID: inout [UUID: Track],
        versionsByID: [UUID: Version]
    ) {
        let resolvedTrackID = resolveTrackID(for: entry, tracksByID: tracksByID, versionsByID: versionsByID)

        if let localNote = localNotesByID[entry.id] {
            if entry.updatedAt > localNote.updatedAt {
                localNote.trackID = resolvedTrackID
                localNote.versionID = entry.versionID
                localNote.timestamp = entry.timestamp
                localNote.type = entry.type
                localNote.content = entry.content
                // voiceFilePath is per-device local state — never overwrite from the wire.
                localNote.voiceDuration = entry.voiceDuration
                if let sha = entry.voiceFileSHA256 { localNote.voiceFileSHA256 = sha }
                if let size = entry.voiceFileSize { localNote.voiceFileSize = size }
                localNote.updatedAt = entry.updatedAt
                localNote.isSoftDeleted = entry.isSoftDeleted
            }

            if tracksByID[localNote.trackID] == nil, resolvedTrackID != localNote.trackID {
                localNote.trackID = resolvedTrackID
            }
            if let track = tracksByID[localNote.trackID] {
                attach(note: localNote, to: track, updatedAt: localNote.updatedAt)
            }
            return
        }

        let note = Note(
            id: entry.id,
            trackID: resolvedTrackID,
            versionID: entry.versionID,
            timestamp: entry.timestamp,
            type: entry.type,
            content: entry.content,
            voiceFilePath: nil,
            voiceDuration: entry.voiceDuration,
            voiceFileSHA256: entry.voiceFileSHA256,
            voiceFileSize: entry.voiceFileSize,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            createdOn: entry.createdOn,
            isSoftDeleted: entry.isSoftDeleted
        )
        modelContext.insert(note)
        localNotesByID[note.id] = note

        if let track = tracksByID[note.trackID] {
            attach(note: note, to: track, updatedAt: note.updatedAt)
        }
    }

    private func attach(note: Note, to track: Track, updatedAt: Date) {
        if !track.notes.contains(where: { $0.id == note.id }) {
            track.notes.append(note)
        }
        if updatedAt > track.updatedAt {
            track.updatedAt = updatedAt
        }
    }

    private func resolveTrackID(
        for entry: NoteManifestEntry,
        tracksByID: [UUID: Track],
        versionsByID: [UUID: Version]
    ) -> UUID {
        if tracksByID[entry.trackID] != nil {
            return entry.trackID
        }
        if let versionID = entry.versionID,
           let version = versionsByID[versionID],
           tracksByID[version.trackID] != nil {
            return version.trackID
        }
        return entry.trackID
    }

    /// Pull voice .m4a files for any notes the peer advertises a hash for that
    /// don't yet exist locally. Voice files are tiny so we serialize the fetches.
    private func fetchMissingVoiceNoteFiles(in notesByID: [UUID: Note]) async {
        let candidates = notesByID.values.filter {
            $0.type == .voice
                && !$0.isSoftDeleted
                && $0.voiceFileSHA256 != nil
                && ($0.voiceFilePath == nil
                    || !FileManager.default.fileExists(atPath: $0.voiceFilePath!))
        }
        guard !candidates.isEmpty else { return }

        for note in candidates {
            let destination = VoiceMemoRecorder.voiceMemoURL(for: note.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                note.voiceFilePath = destination.path
                continue
            }
            do {
                let tempURL = try await transport.downloadVoiceNote(noteID: note.id)
                do {
                    try verifyVoiceNoteDownload(tempURL, against: note)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw error
                }
                note.voiceFilePath = destination.path
                if note.voiceFileSize == nil {
                    note.voiceFileSize = try? FileIntegrity.fileSize(for: destination)
                }
                SyncLog.receiver.info("downloaded voice note \(note.id, privacy: .public)")
            } catch {
                SyncLog.receiver.error("voice note fetch failed for \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        try? modelContext.save()
    }

    private func verifyVoiceNoteDownload(_ fileURL: URL, against note: Note) throws {
        if let expectedSize = note.voiceFileSize {
            let actualSize = try FileIntegrity.fileSize(for: fileURL)
            guard actualSize == expectedSize else {
                throw SyncError.transferFailed("voice note size mismatch (\(actualSize) of \(expectedSize) bytes)")
            }
        }
        if let expectedHash = note.voiceFileSHA256 {
            guard try FileIntegrity.sha256Hex(for: fileURL) == expectedHash else {
                throw SyncError.transferFailed("voice note hash mismatch")
            }
        }
    }

    /// Fetch cover bytes via `GET /artwork/{id}` only when the revision signal changed.
    private func applyArtworkUpdates(
        _ pending: [UUID: Int64?],
        localTracksByID: inout [UUID: Track]
    ) async {
        guard !pending.isEmpty else { return }

        // Cheap pass first: resolve removals inline and collect the track IDs that
        // actually need a network fetch.
        var fetchTrackIDs: [UUID] = []
        for (trackID, remoteRevision) in pending {
            guard let track = localTracksByID[trackID] else { continue }
            let localRevision = track.resolvedArtworkRevision()
            if localRevision == remoteRevision { continue }

            guard remoteRevision != nil else {
                if localRevision != nil {
                    track.setArtwork(nil)
                }
                continue
            }

            fetchTrackIDs.append(trackID)
        }
        guard !fetchTrackIDs.isEmpty else { return }

        // Same bounded 3-wide concurrency as the audio transfer queue: seed an
        // initial batch, then refill a slot each time a fetch completes.
        struct ArtworkFetchResult {
            let trackID: UUID
            let data: Data?
            let errorDescription: String?
        }

        let maxConcurrent = transferQueue.maxConcurrent
        let results = await withTaskGroup(of: ArtworkFetchResult.self) { group -> [ArtworkFetchResult] in
            var collected: [ArtworkFetchResult] = []
            var iterator = fetchTrackIDs.makeIterator()

            func addNext() {
                guard let trackID = iterator.next() else { return }
                group.addTask { @MainActor [transport] in
                    do {
                        let data = try await transport.downloadArtwork(trackID: trackID)
                        return ArtworkFetchResult(trackID: trackID, data: data, errorDescription: nil)
                    } catch {
                        return ArtworkFetchResult(trackID: trackID, data: nil, errorDescription: error.localizedDescription)
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, fetchTrackIDs.count) { addNext() }
            while let result = await group.next() {
                collected.append(result)
                addNext()
            }
            return collected
        }

        for result in results {
            guard let track = localTracksByID[result.trackID] else { continue }
            if let data = result.data {
                guard !data.isEmpty else { continue }
                track.setArtwork(data)
                SyncLog.receiver.info("downloaded artwork for track \(result.trackID, privacy: .public)")
            } else {
                SyncLog.receiver.error(
                    "artwork fetch failed for \(result.trackID, privacy: .public): \(result.errorDescription ?? "unknown error", privacy: .public)"
                )
            }
        }
    }

    // MARK: - Playlist Cover Sync (protocol 6)

    private struct PlaylistCoverActions {
        /// Playlists whose cover bytes should be fetched from the Mac.
        var fetchIDs: [UUID] = []
        /// Playlists whose local cover bytes should be pushed to the Mac.
        var pushIDs: [UUID] = []
        var isEmpty: Bool { fetchIDs.isEmpty && pushIDs.isEmpty }
    }

    /// Decides, per playlist, whether cover bytes need to move and in which
    /// direction. Must run BEFORE `mergePlaylistEntries` — the merge copies the
    /// remote `updatedAt` onto winners, which erases the newer-side signal.
    ///
    /// Rules (localRev vs entry.coverRevision, ties broken conservatively):
    /// - revisions equal → nothing.
    /// - remote strictly newer → adopt remote (fetch; clears are applied by
    ///   `apply(_:to:foldersByID:)` during the merge itself).
    /// - local strictly newer → push local bytes (a local clear propagates via
    ///   the nil revision in the next iOS manifest instead).
    /// - equal timestamps: only act when exactly one side has a cover
    ///   (remote-only → fetch, local-only → push). Both-sided mismatch at the
    ///   same timestamp is ambiguous — never clobber, just log.
    private func pendingPlaylistCoverActions(for manifest: LibraryManifest) -> PlaylistCoverActions {
        var actions = PlaylistCoverActions()
        // Pre-6 manifests embed cover bytes and the Mac has no fetch/push endpoints.
        guard manifest.protocolVersion >= 6 else { return actions }

        let localPlaylistsByID = Dictionary(
            ((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for entry in manifest.playlists where !entry.isSoftDeleted {
            // Legacy safety: if bytes somehow rode along, the merge applies them.
            guard entry.coverImageData == nil else { continue }
            let remoteRevision = entry.coverRevision

            guard let playlist = localPlaylistsByID[entry.id] else {
                // Created by this merge round — fetch its cover once it exists.
                if remoteRevision != nil {
                    actions.fetchIDs.append(entry.id)
                }
                continue
            }
            if playlist.isSoftDeleted { continue }

            let localRevision = playlist.resolvedCoverRevision()
            guard localRevision != remoteRevision else { continue }

            if entry.updatedAt > playlist.updatedAt {
                if remoteRevision != nil {
                    actions.fetchIDs.append(entry.id)
                }
                // remote nil → cleared during merge apply.
            } else if playlist.updatedAt > entry.updatedAt {
                if localRevision != nil {
                    actions.pushIDs.append(entry.id)
                }
                // local nil → clear propagates via the iOS manifest revision.
            } else if remoteRevision != nil && localRevision == nil {
                actions.fetchIDs.append(entry.id)
            } else if localRevision != nil && remoteRevision == nil {
                actions.pushIDs.append(entry.id)
            } else {
                SyncLog.receiver.error(
                    "playlist \(entry.id, privacy: .public) cover revisions diverge at equal updatedAt — leaving both sides untouched"
                )
            }
        }
        return actions
    }

    /// Moves playlist cover bytes decided by `pendingPlaylistCoverActions`.
    /// Covers are small (≤ ~500 KB post-backfill) and rare, so transfers run
    /// sequentially. Failures are logged and retried naturally on the next
    /// generation change (revisions still mismatch).
    private func applyPlaylistCoverUpdates(_ actions: PlaylistCoverActions) async {
        guard !actions.isEmpty else { return }

        for playlistID in actions.fetchIDs {
            do {
                let data = try await transport.downloadPlaylistArtwork(playlistID: playlistID)
                guard !data.isEmpty else { continue }
                var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
                descriptor.fetchLimit = 1
                guard let playlist = try? modelContext.fetch(descriptor).first, !playlist.isSoftDeleted else { continue }
                playlist.setCoverImage(data)
                SyncLog.receiver.info("downloaded cover (\(data.count) bytes) for playlist \(playlistID, privacy: .public)")
            } catch {
                SyncLog.receiver.error(
                    "playlist cover fetch failed for \(playlistID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        for playlistID in actions.pushIDs {
            var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
            descriptor.fetchLimit = 1
            guard let playlist = try? modelContext.fetch(descriptor).first,
                  let data = playlist.coverImageData, !data.isEmpty else { continue }
            do {
                _ = try await transport.uploadPlaylistArtwork(playlistID: playlistID, data: data)
                SyncLog.receiver.info("pushed cover (\(data.count) bytes) for playlist \(playlistID, privacy: .public)")
            } catch {
                SyncLog.receiver.error(
                    "playlist cover push failed for \(playlistID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// UI hook for local cover edits: eagerly push the new bytes to the Mac
    /// (the manifest only carries the revision scalar), then schedule the
    /// normal debounced manifest push. If the eager push fails, the reconcile
    /// pass retries while this side's `updatedAt` is still newer.
    func notifyPlaylistCoverChanged(_ playlistID: UUID) {
        let state = transport.connectionState
        if state == .connected || state == .idle,
           (lastSenderProtocolVersion ?? LibraryManifest.currentProtocolVersion) >= 6 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
                descriptor.fetchLimit = 1
                guard let playlist = try? self.modelContext.fetch(descriptor).first,
                      let data = playlist.coverImageData, !data.isEmpty else { return }
                do {
                    _ = try await self.transport.uploadPlaylistArtwork(playlistID: playlistID, data: data)
                    SyncLog.receiver.info("pushed edited cover for playlist \(playlistID, privacy: .public)")
                } catch {
                    SyncLog.receiver.error(
                        "eager cover push failed for \(playlistID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        notifyLocalManifestMutated()
    }

    // MARK: - Directories

    private func audioDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Bounce/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func resolveLocalVoiceNoteURL(for noteID: UUID) -> URL? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
        descriptor.fetchLimit = 1
        guard let note = try? modelContext.fetch(descriptor).first else {
            return VoiceMemoRecorder.existingVoiceMemoURL(noteID: noteID, storedPath: nil)
        }
        return VoiceMemoRecorder.existingVoiceMemoURL(noteID: noteID, storedPath: note.voiceFilePath)
    }

    private func recoverVoiceMemoURL(
        for note: Note,
        directoryFiles: [URL],
        cachedFileSize: (URL) -> Int64?,
        cachedSHA: (URL) -> String?
    ) -> URL? {
        if let resolved = VoiceMemoRecorder.existingVoiceMemoURL(noteID: note.id, storedPath: note.voiceFilePath) {
            return resolved
        }

        guard note.voiceFileSHA256 != nil || note.voiceFileSize != nil else { return nil }

        let candidates = directoryFiles.filter { url in
            if let expectedSize = note.voiceFileSize, let size = cachedFileSize(url), size != expectedSize {
                return false
            }
            return true
        }

        guard let expectedSHA = note.voiceFileSHA256 else {
            return candidates.count == 1 ? candidates.first : nil
        }

        return candidates.first { cachedSHA($0) == expectedSHA }
    }
}
