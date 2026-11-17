import AppKit
import Foundation
import Network
import SwiftData
import BounceKit

struct SyncHistoryItem: Identifiable, Equatable {
    let versionID: UUID
    let trackName: String
    let versionLabel: String
    let originalFilename: String
    let fileSize: Int64
    let deliveredAt: Date

    var id: String {
        "\(versionID.uuidString)-\(deliveredAt.timeIntervalSince1970)"
    }
}

/// A pending /pair request awaiting the user's allow/deny choice on the Mac.
/// The transport's `pairApprovalHandler` is async, so we stash the
/// continuation here while the SwiftUI alert is up.
struct PendingPairRequest: Identifiable {
    let id = UUID()
    let request: PairRequest
    let continuation: CheckedContinuation<PairOutcome, Never>
}

@Observable
@MainActor
final class TransferManager {

    // MARK: - Public State

    var undeliveredVersionIDs: Set<UUID> = []
    private(set) var connectionState: SyncConnectionState = .disconnected
    private(set) var connectedDeviceName: String? = nil
    private(set) var connectedDeviceID: UUID? = nil
    private(set) var connectedAppVersion: String? = nil
    private(set) var recentHistory: [SyncHistoryItem] = []
    let bondedPeerStore = BondedPeerStore(role: .sender)

    /// Read-only identity of this Mac, surfaced by the Settings window.
    var deviceID: UUID { transport.deviceID }
    var deviceName: String { transport.deviceName }

    /// When a /pair request comes in for a not-yet-bonded receiver, this
    /// gets populated and the UI presents an approval alert. nil otherwise.
    var pendingPairRequest: PendingPairRequest? = nil

    /// URL behind the Mac's pairing QR. Rotates when used or expired.
    var pairingURL: URL? { transport.pairingLink?.url }

    /// Counts pair requests approved through the QR token, so the setup
    /// sheet can advance to "You're all set" without a pending request.
    private(set) var tokenPairCount = 0

    /// True while the first-launch setup sheet is on screen. It then
    /// presents the pair approval inline (same approve/deny calls and 120 s
    /// timeout) instead of the system NSAlert.
    var isSetupSheetOpen = false

    var lastClientRequestAt: Date? {
        transport.lastClientRequestAt
    }

    var clientRequestCount: Int {
        transport.clientRequestCount
    }

    var lastRequestPath: String {
        transport.lastRequestPath
    }

    var totalBytesServed: Int64 {
        transport.totalBytesServed
    }

    var lastServedResponseBytes: Int64 {
        transport.lastServedResponseBytes
    }

    private(set) var lastPublishedManifestGeneration: Int64? = nil
    private(set) var lastPublishedTrackCount: Int = 0
    /// Scalar-only fingerprint of the last built manifest. Gate for the 400ms
    /// save-republish path: when unchanged, the full build (per-version stat +
    /// SHA cache lookups) is skipped entirely.
    private var lastManifestPreFingerprint: Int64? = nil

    // MARK: - Private

    private let transport: BonjourTransport
    private var modelContext: ModelContext?
    private var pathMonitor: NWPathMonitor?

    // MARK: - Init

    init() {
        self.transport = BonjourTransport(role: .sender)
    }

    // MARK: - Lifecycle

    func start() async {
        // BonjourTransport calls fileProvider on the main queue (NWListener/NWBrowser use .main),
        // so accessing @MainActor state here is safe.
        transport.bondedPeerStore = bondedPeerStore
        transport.pairApprovalHandler = { [weak self] request in
            await self?.requestUserApproval(for: request) ?? .denied(reason: "transfer manager gone")
        }
        transport.tokenPairHandler = { [weak self] _ in
            self?.approveViaPairingToken() ?? .denied(reason: "transfer manager gone")
        }
        transport.fileProvider = { [weak self] versionID in
            guard let self else { return nil }
            return self.resolveFilePath(for: versionID)
        }
        transport.fileServedHandler = { [weak self] versionID in
            guard let self else { return }
            self.markDelivered(versionID)
            self.appendHistoryItem(for: versionID, deliveredAt: .now)
        }
        transport.artworkProvider = { [weak self] trackID in
            guard let self else { return nil }
            return self.resolveArtwork(for: trackID)
        }
        transport.playlistArtworkProvider = { [weak self] playlistID in
            guard let self else { return nil }
            return self.resolvePlaylistCover(for: playlistID)
        }
        transport.playlistArtworkUploadHandler = { [weak self] playlistID, data in
            guard let self else { return false }
            return self.handleIncomingPlaylistCover(playlistID: playlistID, data: data)
        }
        transport.stateChangeHandler = { [weak self] state, deviceName, deviceID in
            guard let self else { return }
            self.connectionState = state
            if let deviceName {
                self.connectedDeviceName = deviceName
            }
            if let deviceID {
                self.connectedDeviceID = deviceID
            }
            if state == .disconnected {
                self.connectedDeviceName = nil
                self.connectedDeviceID = nil
                self.connectedAppVersion = nil
            }
            self.handleTransportStateChange(state)
        }
        transport.requestMetadataHandler = { [weak self] metadata in
            guard let self else { return }
            self.recordRequestMetadata(metadata)
        }

        transport.uploadHandler = { [weak self] payload in
            guard let self else { return false }
            return await self.handleIncomingUpload(payload)
        }

        transport.voiceNoteProvider = { [weak self] noteID in
            guard let self else { return nil }
            return self.resolveVoiceNotePath(for: noteID)
        }

        transport.voiceNoteUploadHandler = { [weak self] payload in
            guard let self else { return false }
            return await self.handleIncomingVoiceNote(payload)
        }

        transport.iosManifestHandler = { [weak self] manifest in
            guard let self else { return }
            self.handleIOSManifest(manifest)
        }

        await transport.start()
        startPathMonitoring()
        connectionState = transport.connectionState
        connectedDeviceName = transport.connectedDeviceName
        connectedDeviceID = transport.connectedDeviceID
        connectedAppVersion = transport.connectedAppVersion
        handleTransportStateChange(transport.connectionState)
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        // Re-publish the served manifest after every local save. GET /manifest
        // serves the last pushed snapshot, so without this, playlist/track edits
        // sit stale until some unrelated push happens — which is how deleted
        // playlists used to bounce back from the phone.
        NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleManifestRepublish()
            }
        }
        // Push manifest immediately now that we have a context
        pushManifestIfConnected()
    }

    private var manifestRepublishTask: Task<Void, Never>?

    /// Debounced push so bursts of saves (imports, reorders) produce one publish.
    private func scheduleManifestRepublish() {
        manifestRepublishTask?.cancel()
        manifestRepublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.pushManifestIfConnected()
        }
    }

    func deleteNote(_ note: Note, for track: Track) {
        guard let context = modelContext else { return }
        track.removeNote(note, in: context)
        pushManifestIfConnected()
    }

    /// Drop a peer from the bond store and bounce the transport so the
    /// receiver immediately notices and clears its side of the bond.
    /// We always restart (not just when `connectedDeviceID == id`)
    /// because that field only flips after an authenticated request —
    /// an idle but-still-connected receiver wouldn't trigger the
    /// disconnect path otherwise, and would happily sit with a stale
    /// bond until its next request.
    func forgetPeer(_ id: UUID) async {
        bondedPeerStore.forget(id: id)
        await disconnectCurrentReceiver()
    }

    /// Bridge between the transport's pair handler and the user's
    /// approval. Uses a native NSAlert with a dedicated pairing-code
    /// accessory so the UX matches macOS pairing prompts and still works
    /// when the app is backgrounded.
    ///
    /// A 120s timeout dismisses the modal before the iOS pair request's
    /// 150s URLSession timeout, so the user-takes-too-long path always
    /// resolves on the Mac side first — preventing a late "Pair" tap
    /// from committing a bond against a connection the receiver has
    /// already given up on.
    private func requestUserApproval(for request: PairRequest) async -> PairOutcome {
        if pendingPairRequest != nil {
            return .denied(reason: "another pairing request is already pending")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<PairOutcome, Never>) in
            let pending = PendingPairRequest(request: request, continuation: cont)
            self.pendingPairRequest = pending
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "Bounce" {
                window.makeKeyAndOrderFront(nil)
            }
            if self.isSetupSheetOpen {
                // The setup sheet shows the request inline (no alert). Same
                // 120 s limit as the alert path; only acts if this very
                // request is still pending.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    if self?.pendingPairRequest?.id == pending.id {
                        self?.denyPendingPairRequest()
                    }
                }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Pair with \(request.deviceName)?"
            alert.informativeText = "Confirm the code below matches the one shown on your iPhone."
            alert.alertStyle = .informational
            alert.icon = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: nil)
            alert.accessoryView = makePairingCodeAccessory(for: OnboardingShot.fakeCode ?? request.verificationCode)
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Don't Pair")

            // Timer.scheduledTimer attaches to the current run loop in default
            // mode only — that mode is not pumped while NSAlert.runModal is
            // up, so the timer would never fire. Add it explicitly to
            // `.modalPanel` so the timeout still triggers during the prompt.
            // `.cancel` (not `.alertFirstButtonReturn`) routes runModal's
            // return into the deny branch below.
            let timeoutTimer = Timer(timeInterval: 120, repeats: false) { _ in
                NSApp.stopModal(withCode: .cancel)
            }
            RunLoop.current.add(timeoutTimer, forMode: .modalPanel)

            let response = alert.runModal()
            timeoutTimer.invalidate()

            if response == .alertFirstButtonReturn {
                self.approvePendingPairRequest()
            } else {
                self.denyPendingPairRequest()
            }
        }
    }

    /// Called from the approval UI when the user taps Allow.
    func approvePendingPairRequest() {
        guard let pending = pendingPairRequest else { return }
        pendingPairRequest = nil
        UserDefaults.standard.set(true, forKey: SetupPrefs.everPairedKey)
        pending.continuation.resume(returning: .approved(sharedKey: makeSharedPairingKey()))
    }

    private func approveViaPairingToken() -> PairOutcome {
        UserDefaults.standard.set(true, forKey: SetupPrefs.everPairedKey)
        tokenPairCount += 1
        return .approved(sharedKey: makeSharedPairingKey())
    }

    /// Called from the approval UI when the user taps Deny.
    func denyPendingPairRequest() {
        guard let pending = pendingPairRequest else { return }
        pendingPairRequest = nil
        pending.continuation.resume(returning: .denied(reason: "User denied pairing"))
    }

    private func makePairingCodeAccessory(for rawCode: String) -> NSView {
        // NSAlert sizes its accessoryView from the view's `frame`, not from
        // Auto Layout — so a stack view that only has intrinsic sizes can
        // overflow the alert horizontally. Build the accessory with an
        // explicit fixed-width frame and lay subviews out manually.
        let width: CGFloat = 280
        let codeBoxHeight: CGFloat = 56
        let subtitleHeight: CGFloat = 18
        let spacing: CGFloat = 10
        let totalHeight = codeBoxHeight + spacing + subtitleHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))

        let codeBox = NSView(frame: NSRect(x: 0, y: subtitleHeight + spacing, width: width, height: codeBoxHeight))
        codeBox.wantsLayer = true
        codeBox.layer?.cornerRadius = 10
        codeBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let codeField = NSTextField(labelWithString: rawCode)
        codeField.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        codeField.alignment = .center
        codeField.lineBreakMode = .byClipping
        codeField.maximumNumberOfLines = 1
        codeField.drawsBackground = false
        codeField.isBezeled = false
        // Center the single line vertically inside the rounded box.
        let textHeight = codeField.intrinsicContentSize.height
        let textY = (codeBoxHeight - textHeight) / 2
        codeField.frame = NSRect(x: 0, y: textY, width: width, height: textHeight)
        codeBox.addSubview(codeField)

        let subtitle = NSTextField(labelWithString: "If the code doesn't match, choose Don't Pair.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.drawsBackground = false
        subtitle.isBezeled = false
        subtitle.frame = NSRect(x: 0, y: 0, width: width, height: subtitleHeight)

        container.addSubview(codeBox)
        container.addSubview(subtitle)
        return container
    }

    func disconnectCurrentReceiver() async {
        transport.stop()
        connectionState = .disconnected
        connectedDeviceName = nil
        connectedDeviceID = nil
        connectedAppVersion = nil
        // Drop the published-generation memo so the next pairing receives a
        // fresh manifest even if its hash hasn't changed.
        lastPublishedManifestGeneration = nil
        await transport.start()
        handleTransportStateChange(transport.connectionState)
    }

    private func startPathMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            Task { @MainActor in
                guard self.transport.connectionState == .disconnected else { return }
                SyncLog.sender.info("network path satisfied; restarting sender listener")
                await self.restartSender()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func restartSender() async {
        transport.stop()
        connectionState = .disconnected
        connectedDeviceName = nil
        connectedDeviceID = nil
        connectedAppVersion = nil
        await transport.start()
        connectionState = transport.connectionState
        connectedDeviceName = transport.connectedDeviceName
        connectedDeviceID = transport.connectedDeviceID
        connectedAppVersion = transport.connectedAppVersion
        handleTransportStateChange(transport.connectionState)
    }

    // MARK: - Version Queuing

    func queueVersion(_ version: Version) {
        let inserted = undeliveredVersionIDs.insert(version.id).inserted
        if inserted {
            SyncLog.sender.debug(
                "queued version \(version.id, privacy: .public) (\(self.undeliveredVersionIDs.count) pending)"
            )
        }
        pushManifestIfConnected()
    }

    func markDelivered(_ versionID: UUID) {
        let removed = undeliveredVersionIDs.remove(versionID) != nil
        if removed {
            SyncLog.sender.debug(
                "delivered version \(versionID, privacy: .public) (\(self.undeliveredVersionIDs.count) pending)"
            )
        }
    }

    // MARK: - Manifest Building

    /// Content hashes keyed by file path, invalidated by mtime/size. The
    /// manifest is rebuilt after every save (debounced), and hashing the
    /// whole audio library on the main actor each time froze the UI.
    private var fileHashCache: [String: (mtime: Date, size: Int64, hash: String)] = [:]
    private var lastBuiltVersionHashes: [UUID: String] = [:]

    private func cachedContentHash(forPath path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let cached = fileHashCache[path],
              cached.mtime == (attrs[.modificationDate] as? Date ?? .distantPast),
              cached.size == ((attrs[.size] as? NSNumber)?.int64Value ?? -1) else { return nil }
        return cached.hash
    }

    /// Ensures `fileHashCache` holds a current SHA-256 for every on-disk version
    /// file, hashing cache-misses **off the main actor**. `buildManifest` only
    /// reads this cache, so hashing never blocks the UI; a file that cannot be
    /// hashed keeps its last built hash, or is left out if it never had one.
    private func prefetchContentHashes(tracks: [Track]) async {
        // On the main actor: stat each included version file (cheap, no hashing)
        // and collect the ones whose cached hash is missing or stale.
        var missMeta: [String: (mtime: Date, size: Int64)] = [:]
        for track in tracks {
            for version in track.versions where !version.filePath.isEmpty {
                let path = version.filePath
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                let mtime = attrs[.modificationDate] as? Date ?? .distantPast
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                if let cached = fileHashCache[path], cached.mtime == mtime, cached.size == size {
                    continue
                }
                missMeta[path] = (mtime, size)
            }
        }
        guard !missMeta.isEmpty else { return }

        // Off the main actor: hash the missing files.
        let paths = Array(missMeta.keys)
        let hashes: [String: String] = await Task.detached(priority: .utility) {
            var out: [String: String] = [:]
            for path in paths {
                if let hash = try? FileIntegrity.sha256Hex(for: URL(fileURLWithPath: path)) {
                    out[path] = hash
                }
            }
            return out
        }.value

        // Back on the main actor: populate the cache with the fresh hashes.
        for (path, hash) in hashes {
            if let meta = missMeta[path] {
                fileHashCache[path] = (meta.mtime, meta.size, hash)
            }
        }
    }

    /// Maps tracks → manifest entries. `contentHash` abstracts the expensive
    /// part: the real build hashes files (per-version stat + SHA cache), while
    /// the pre-fingerprint gate passes the stored scalar so unchanged saves
    /// never touch the filesystem.
    private func manifestTrackEntries(
        tracks: [Track],
        requireFileOnDisk: Bool,
        contentHash: (Version) -> String?
    ) -> [TrackManifestEntry] {
        tracks
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { track in
            let versionEntries: [VersionManifestEntry] = track.versions
                .filter { !$0.filePath.isEmpty && (!requireFileOnDisk || FileManager.default.fileExists(atPath: $0.filePath)) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .compactMap { version -> VersionManifestEntry? in
                guard let hash = contentHash(version) else { return nil }
                return VersionManifestEntry(
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
                    contentHash: hash
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
    }

    /// Scalar-only fingerprint used to gate manifest builds: computed purely
    /// from model fields and stored revisions — no file stats, no SHA hashing,
    /// no image blobs. Distinct from the published `generation` (which hashes
    /// real file contentHashes); it only needs to be self-consistent between
    /// pushes so an unchanged library skips the expensive build entirely.
    private func manifestPreFingerprint(tracks: [Track]) -> Int64 {
        let trackEntries = manifestTrackEntries(tracks: tracks, requireFileOnDisk: false) { $0.contentHash }
        return LibraryManifest.generationFingerprint(
            tracks: trackEntries,
            notes: manifestNoteEntries(),
            playlistFolders: manifestPlaylistFolderEntries(),
            playlists: manifestPlaylistEntries(validTrackIDs: Set(tracks.map(\.id)))
        )
    }

    func buildManifest(tracks: [Track]) -> LibraryManifest {
        let senderID = transport.deviceID
        let senderName = Host.current().localizedName ?? "Bounce Mac"
        let noteEntries = manifestNoteEntries()
        let playlistFolderEntries = manifestPlaylistFolderEntries()
        let playlistEntries = manifestPlaylistEntries(validTrackIDs: Set(tracks.map(\.id)))

        let trackEntries: [TrackManifestEntry] = manifestTrackEntries(tracks: tracks, requireFileOnDisk: true) { version in
            if let hash = cachedContentHash(forPath: version.filePath) {
                return hash
            }
            if let previousHash = lastBuiltVersionHashes[version.id] {
                SyncLog.sender.error("keeping last known hash for \(version.filePath, privacy: .public): no current content hash")
                return previousHash
            }
            SyncLog.sender.error("leaving \(version.filePath, privacy: .public) out of the manifest: no content hash")
            return nil
        }
        lastBuiltVersionHashes = Dictionary(
            trackEntries.flatMap { $0.versions }.map { ($0.id, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )

        let generation = LibraryManifest.generationFingerprint(
            tracks: trackEntries,
            notes: noteEntries,
            playlistFolders: playlistFolderEntries,
            playlists: playlistEntries
        )

        return LibraryManifest(
            senderID: senderID,
            senderName: senderName,
            generation: generation,
            generatedAt: .now,
            originatingDevice: .mac,
            tracks: trackEntries,
            notes: noteEntries,
            playlistFolders: playlistFolderEntries,
            playlists: playlistEntries
        )
    }

    /// Pushes the current library manifest to the connected receiver. With
    /// `force: false` (the default) skips the send when the generation fingerprint
    /// matches what we last published — used for incidental pushes (manifest
    /// auto-republish on `queueVersion`, on `setModelContext`, etc.). With
    /// `force: true` (the Sync Now button) sends every time so the user
    /// always sees something happen.
    private var manifestPublishTask: Task<Void, Never>?

    func pushManifest(tracks: [Track], force: Bool = false) {
        // Fingerprint-first: hash model scalars (no file IO, no blobs) and skip
        // the expensive entry build when nothing changed since the last publish.
        let preFingerprint = manifestPreFingerprint(tracks: tracks)
        if !force, lastPublishedManifestGeneration != nil, preFingerprint == lastManifestPreFingerprint {
            SyncLog.sender.debug("skipping manifest build — scalar fingerprint unchanged")
            return
        }
        // Serialize builds through a single chain so overlapping calls never
        // interleave and publishes stay in submission order. The SHA-256 hashing
        // hops off the main actor (see prefetchContentHashes), keeping this a
        // fire-and-forget call that never freezes the UI during import/builds.
        let previous = manifestPublishTask
        manifestPublishTask = Task { @MainActor in
            _ = await previous?.value
            await self.buildAndPublishManifest(preFingerprint: preFingerprint, force: force)
        }
    }

    private func buildAndPublishManifest(preFingerprint: Int64, force: Bool) async {
        guard let context = modelContext else { return }
        do {
            let tracksBeforeHashing = try context.fetch(FetchDescriptor<Track>())
            await prefetchContentHashes(tracks: tracksBeforeHashing)
            let manifest = buildManifest(tracks: try context.fetch(FetchDescriptor<Track>()))
            lastManifestPreFingerprint = preFingerprint
            lastPublishedTrackCount = manifest.tracks.count
            if !force, lastPublishedManifestGeneration == manifest.generation {
                SyncLog.sender.debug(
                    "skipping manifest push — generation \(manifest.generation) already published"
                )
                return
            }
            lastPublishedManifestGeneration = manifest.generation
            do {
                try await transport.sendManifest(manifest)
                SyncLog.sender.info(
                    "published manifest generation \(manifest.generation) with \(manifest.tracks.count) tracks"
                )
            } catch {
                SyncLog.sender.error(
                    "manifest send failed for generation \(manifest.generation): \(error.localizedDescription, privacy: .public)"
                )
            }
        } catch {
            SyncLog.sender.error("failed to build manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Incoming Upload (from iOS)

    private func handleIncomingUpload(_ payload: UploadPayload) async -> Bool {
        SyncLog.sender.info("handleIncomingUpload: \(payload.originalFilename, privacy: .public) from \(payload.sourceDeviceName ?? "Unknown", privacy: .public)")
        guard let context = modelContext else {
            SyncLog.sender.error("upload failed: no model context")
            return false
        }

        let audioDir = ImportCoordinator.audioDirectory()
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            SyncLog.sender.error("upload failed: cannot create audio directory: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Uploads are at-least-once: the Mac may have committed the file and
        // then lost the response before iOS marked its queue item uploaded.
        // Reusing the stable version ID makes that retry idempotent instead of
        // inserting a second SwiftData Version with the same identity.
        let existingVersion: Version? = {
            if let versionID = payload.versionID,
               let version = context.fetchByID(Version.self, id: versionID) {
                return version
            }
            guard let sourceContentHash = payload.sourceContentHash else { return nil }
            let versions = (try? context.fetch(FetchDescriptor<Version>())) ?? []
            return versions.first { $0.sourceContentHash == sourceContentHash }
        }()

        // Move uploaded temp file into the library — preserve iOS version/track IDs for dedup
        let outputID = existingVersion?.id ?? payload.versionID ?? UUID()
        let fileFormat = payload.fileFormat.isEmpty ? "m4a" : payload.fileFormat
        let outputURL = audioDir.appendingPathComponent("\(outputID.uuidString).\(fileFormat)")

        if let existingVersion,
           let incomingHash = payload.sourceContentHash,
           let existingHash = existingVersion.sourceContentHash,
           incomingHash != existingHash {
            SyncLog.sender.error(
                "upload rejected: version ID \(existingVersion.id, privacy: .public) conflicts with an existing source hash"
            )
            return false
        }

        if let existingVersion,
           FileManager.default.fileExists(atPath: existingVersion.filePath) {
            if existingVersion.sourceContentHash == nil, let incomingHash = payload.sourceContentHash {
                existingVersion.sourceContentHash = incomingHash
                try? context.save()
            }
            SyncLog.sender.info(
                "upload retry already applied: \(existingVersion.id, privacy: .public)"
            )
            return true
        }

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: payload.fileURL, to: outputURL)
        } catch {
            SyncLog.sender.error("upload failed: cannot move file: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let fileSize: Int64
        do {
            fileSize = try FileIntegrity.fileSize(for: outputURL)
        } catch {
            SyncLog.sender.error("upload failed: cannot read file size: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let duration = await ImportCoordinator.audioDuration(url: outputURL)
        SyncLog.sender.info(
            "received upload from \(payload.sourceDeviceName ?? "Unknown", privacy: .public): \(payload.originalFilename, privacy: .public), \(fileSize) bytes"
        )
        SyncLog.sender.debug("uploaded file duration: \(duration)s, size: \(fileSize), format: \(fileFormat, privacy: .public)")

        // Find or create track with phone origin (match by explicit target, then by ID)
        let trackName = payload.trackName
        let trackID = payload.trackID ?? UUID()

        let track: Track
        if let existingVersion,
           let existingTrack = context.fetchByID(Track.self, id: existingVersion.trackID) {
            // A retry must stay attached to the track chosen by the first
            // attempt, even if a later request carries stale routing fields.
            track = existingTrack
        } else if let targetID = payload.targetTrackID,
           let existing = try? context.fetch(FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.id == targetID })).first {
            track = existing
        } else if let id = payload.trackID,
                  let existing = try? context.fetch(FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.id == id })).first {
            track = existing
        } else {
            track = Track(id: trackID, name: trackName, origin: .phone)
            context.insert(track)
        }

        // Use the uploaded version label; only auto-generate if empty
        let versionLabel: String
        if payload.versionLabel.isEmpty {
            let nextNum = track.versions.count + 1
            versionLabel = "v\(nextNum)"
        } else {
            versionLabel = payload.versionLabel
        }

        let version: Version
        if let existingVersion {
            version = existingVersion
            version.trackID = track.id
            version.label = versionLabel
            version.filePath = outputURL.path
            version.fileSize = fileSize
            version.fileFormat = fileFormat
            version.originalFilename = payload.originalFilename
            version.duration = duration
            if let sourceContentHash = payload.sourceContentHash {
                version.sourceContentHash = sourceContentHash
            }
        } else {
            version = Version(
                id: outputID,
                trackID: track.id,
                label: versionLabel,
                filePath: outputURL.path,
                fileSize: fileSize,
                fileFormat: fileFormat,
                originalFilename: payload.originalFilename,
                duration: duration,
                sourceContentHash: payload.sourceContentHash
            )
        }

        if !track.versions.contains(where: { $0.id == version.id }) {
            track.versions.append(version)
        }
        track.updatedAt = .now
        if existingVersion == nil {
            context.insert(version)
        }

        do {
            try context.save()
        } catch {
            SyncLog.sender.error("upload failed: save error: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Queue for sync to other receivers
        queueVersion(version)

        // Generate waveform before final save
        let processor = WaveformProcessor()
        if let waveformData = try? await processor.process(fileURL: outputURL) {
            version.waveformData = waveformData
            try? context.save()
        } else {
            SyncLog.sender.warning("waveform generation failed for \(outputURL.lastPathComponent, privacy: .public)")
        }

        SyncLog.sender.info(
            "upload complete: \(payload.originalFilename, privacy: .public) → \(track.name, privacy: .public) [\(versionLabel)]"
        )
        return true
    }

    // MARK: - Bidirectional Sync: iOS Manifest Merge

    private func handleIOSManifest(_ iosManifest: LibraryManifest) {
        SyncLog.sender.info(
            "received iOS manifest: \(iosManifest.tracks.count) .phone tracks, \(iosManifest.notes.count) notes from \(iosManifest.senderName, privacy: .public)"
        )

        guard let context = modelContext else {
            SyncLog.sender.error("iOS manifest merge failed: no model context")
            return
        }

        // Get existing Mac tracks (both .mac and .phone origin)
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let allTrackIDs = Set(allTracks.map(\.id))

        // Build a name → track map for .phone tracks (uploaded tracks may have different UUIDs)
        let phoneTracksByName = Dictionary(grouping: allTracks.filter { $0.origin == .phone }, by: \.name)

        // Hoist hash lookup once — was rebuilt O(tracks) inside the loop.
        var existingHashes = Set(allTracks.flatMap(\.versions).compactMap(\.sourceContentHash))
        var tracksByID = Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for trackEntry in iosManifest.tracks where !trackEntry.isSoftDeleted {
            // Skip merge if Mac already has this track by ID (came from upload with matching ID),
            // but still propagate the working-title / release / sibling-number metadata
            // when the iOS revision is newer.
            if allTrackIDs.contains(trackEntry.id) {
                if let existing = tracksByID[trackEntry.id],
                   trackEntry.updatedAt >= existing.updatedAt {
                    existing.workingTitle = trackEntry.workingTitle
                    existing.versionNumber = trackEntry.versionNumber
                    existing.isReleased = trackEntry.isReleased
                    existing.isSet = trackEntry.isSet
                    existing.recordingDateString = trackEntry.recordingDateString
                    existing.updatedAt = trackEntry.updatedAt
                }
                continue
            }

            // Skip if Mac already has a .phone track with this name (came from upload with different ID)
            if phoneTracksByName[trackEntry.name]?.first != nil {
                // Already have this track from upload — just update the ID if needed
                SyncLog.sender.debug("track \(trackEntry.name, privacy: .public) already exists on Mac (from upload), skipping merge")
                continue
            }

            // Check for SHA-256 dedup: if any version's sourceContentHash matches an existing version, skip
            let incomingHashes = Set(trackEntry.versions.compactMap(\.sourceContentHash))
            let duplicateHashes = incomingHashes.intersection(existingHashes)

            // If all incoming versions are duplicates, skip entirely
            if !incomingHashes.isEmpty && incomingHashes == duplicateHashes {
                SyncLog.sender.debug("skipping track \(trackEntry.name, privacy: .public) — all versions are duplicates by hash")
                continue
            }

            // Create new track for versions Mac doesn't have
            SyncLog.sender.info("merging track \(trackEntry.name, privacy: .public) from iOS manifest")
            let track = Track(
                id: trackEntry.id,
                name: trackEntry.name,
                origin: .phone,
                workingTitle: trackEntry.workingTitle,
                versionNumber: trackEntry.versionNumber,
                isReleased: trackEntry.isReleased,
                isSet: trackEntry.isSet,
                recordingDateString: trackEntry.recordingDateString
            )
            track.createdAt = trackEntry.createdAt
            track.updatedAt = trackEntry.updatedAt
            context.insert(track)
            tracksByID[track.id] = track

            for versionEntry in trackEntry.versions where !versionEntry.isSoftDeleted {
                // Skip if source content hash matches an existing version
                if let hash = versionEntry.sourceContentHash, duplicateHashes.contains(hash) {
                    SyncLog.sender.debug("skipping version \(versionEntry.label, privacy: .public) — duplicate by hash")
                    continue
                }

                let version = Version(
                    id: versionEntry.id,
                    trackID: track.id,
                    label: versionEntry.label,
                    filePath: "", // Placeholder — file isn't on Mac yet
                    fileSize: versionEntry.fileSize,
                    fileFormat: versionEntry.fileFormat,
                    originalFilename: versionEntry.originalFilename,
                    duration: versionEntry.duration,
                    contentHash: versionEntry.contentHash,
                    sourceContentHash: versionEntry.sourceContentHash
                )
                track.versions.append(version)
                context.insert(version)
                if let hash = versionEntry.sourceContentHash {
                    existingHashes.insert(hash)
                }
            }
        }

        // Handle deletions: .phone tracks on Mac whose ID isn't in the iOS manifest.
        // Keying by ID (not name) so a rename on iOS does not delete-and-recreate
        // the Mac row (and drop local version file paths / notes). Never delete a
        // track that carries phone-origin notes — those notes must always win.
        let iosTrackIDs = Set(iosManifest.tracks.map(\.id))
        var deletedFilePaths: [String] = []
        for track in allTracks where track.origin == .phone {
            if !iosTrackIDs.contains(track.id) {
                let hasPhoneNotes = track.notes.contains { $0.createdOn == .phone }
                if hasPhoneNotes {
                    SyncLog.sender.info("preserving phone-originated track \(track.name, privacy: .public) — has phone-origin notes")
                    continue
                }
                SyncLog.sender.info("deleting phone-originated track \(track.name, privacy: .public) — not in iOS manifest")
                tracksByID.removeValue(forKey: track.id)
                deletedFilePaths += context.deleteTrack(track)
            }
        }

        let versionsByID = tracksByID.values.flatMap(\.versions).reduce(into: [UUID: Version]()) { partialResult, version in
            if partialResult[version.id] == nil {
                partialResult[version.id] = version
            }
        }

        // Create stub tracks for any note that references a track not yet in the Mac database.
        // The iOS manifest includes track metadata for these (see buildiOSManifest), but if
        // for any reason the track wasn't merged above (e.g. empty versions list filtered out),
        // we still need a track row so the notes are visible.
        let iosTracksByID = Dictionary(iosManifest.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let noteTrackIDs = Set(iosManifest.notes.map(\.trackID))
        for trackID in noteTrackIDs where tracksByID[trackID] == nil {
            if let entry = iosTracksByID[trackID] {
                let stub = Track(
                    id: entry.id,
                    name: entry.name,
                    origin: iosManifest.originatingDevice,
                    workingTitle: entry.workingTitle,
                    versionNumber: entry.versionNumber,
                    isReleased: entry.isReleased,
                    isSet: entry.isSet,
                    recordingDateString: entry.recordingDateString
                )
                stub.createdAt = entry.createdAt
                stub.updatedAt = entry.updatedAt
                context.insert(stub)
                tracksByID[stub.id] = stub
                SyncLog.sender.info("created stub track \(entry.name, privacy: .public) for orphaned notes")
            }
        }

        var notesByID = Dictionary(((try? context.fetch(FetchDescriptor<Note>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for noteEntry in iosManifest.notes {
            mergeNoteEntry(noteEntry, into: &notesByID, tracksByID: &tracksByID, versionsByID: versionsByID, context: context)
        }
        mergePlaylistEntries(from: iosManifest, context: context)

        // Single save after the full merge — avoids mid-loop SwiftData invalidation storms.
        do {
            try context.save()
        } catch {
            SyncLog.sender.error(
                "iOS manifest merge save failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        context.removeUnreferencedFiles(atPaths: deletedFilePaths)

        // Re-publish manifest to include merged tracks + notes.
        pushManifestIfConnected()
    }

    private func findTrack(named name: String, context: ModelContext) -> Track? {
        let lower = name.lowercased()
        var descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.name == name }
        )
        descriptor.fetchLimit = 1
        if let exact = try? context.fetch(descriptor).first {
            return exact
        }
        // Case-insensitive fallback
        let all = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        return all.first { $0.name.lowercased() == lower }
    }

    // MARK: - Private Helpers

    func pushManifestIfConnected(force: Bool = false) {
        guard let context = modelContext else { return }
        let state = transport.connectionState
        guard state == .connected || state == .idle else { return }

        do {
            let tracks = try context.fetch(FetchDescriptor<Track>())
            pushManifest(tracks: tracks, force: force)
        } catch {
            SyncLog.sender.error("failed to fetch tracks for manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTransportStateChange(_ state: SyncConnectionState) {
        switch state {
        case .connected, .idle:
            pushManifestIfConnected()
        default:
            break
        }
    }

    private func recordRequestMetadata(_ metadata: SyncRequestMetadata) {
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

    private func appendHistoryItem(for versionID: UUID, deliveredAt: Date) {
        guard let version = fetchVersion(id: versionID),
              let track = fetchTrack(id: version.trackID) else { return }

        recentHistory.removeAll { $0.versionID == versionID }
        recentHistory.insert(
            SyncHistoryItem(
                versionID: versionID,
                trackName: track.name,
                versionLabel: version.label,
                originalFilename: version.originalFilename,
                fileSize: version.fileSize,
                deliveredAt: deliveredAt
            ),
            at: 0
        )
        if recentHistory.count > 24 {
            recentHistory = Array(recentHistory.prefix(24))
        }
    }

    private func resolveFilePath(for versionID: UUID) -> URL? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<Version>(
            predicate: #Predicate { $0.id == versionID }
        )
        descriptor.fetchLimit = 1
        guard let version = try? context.fetch(descriptor).first, !version.filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: version.filePath)
    }

    private func resolveArtwork(for trackID: UUID) -> Data? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackID }
        )
        descriptor.fetchLimit = 1
        guard let track = try? context.fetch(descriptor).first else { return nil }
        guard let artwork = track.artwork, !artwork.isEmpty else { return nil }
        return artwork
    }

    private func resolvePlaylistCover(for playlistID: UUID) -> Data? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == playlistID }
        )
        descriptor.fetchLimit = 1
        guard let playlist = try? context.fetch(descriptor).first else { return nil }
        guard let cover = playlist.coverImageData, !cover.isEmpty else { return nil }
        return cover
    }

    /// iOS pushed cover bytes for a playlist whose revision the phone owns.
    /// Applies bytes + revision only — never `updatedAt`, so the accepted push
    /// can't masquerade as a newer local edit and ping-pong back.
    private func handleIncomingPlaylistCover(playlistID: UUID, data: Data) -> Bool {
        guard let context = modelContext else { return false }
        var descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == playlistID }
        )
        descriptor.fetchLimit = 1
        guard let playlist = try? context.fetch(descriptor).first, !playlist.isSoftDeleted else {
            SyncLog.sender.error("playlist cover push for unknown/deleted playlist \(playlistID, privacy: .public)")
            return false
        }
        playlist.setCoverImage(data)
        do {
            try context.save()
        } catch {
            SyncLog.sender.error("failed to save pushed playlist cover: \(error.localizedDescription, privacy: .public)")
            return false
        }
        SyncLog.sender.info("applied pushed cover (\(data.count) bytes) for playlist \(playlistID, privacy: .public)")
        return true
    }

    /// Canonical Mac-side directory for voice note .m4a files.
    /// Lives next to the SwiftData store so backups treat them as a unit.
    static func voiceMemoDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("\(BounceConstants.applicationSupportDirectoryName)/voice-memos", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func voiceMemoURL(for noteID: UUID) -> URL {
        voiceMemoDirectory().appendingPathComponent("\(noteID.uuidString).m4a")
    }

    private func resolveVoiceNotePath(for noteID: UUID) -> URL? {
        let url = Self.voiceMemoURL(for: noteID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func handleIncomingVoiceNote(_ payload: VoiceNoteUploadPayload) async -> Bool {
        guard let context = modelContext else {
            SyncLog.sender.error("voice note upload failed: no model context")
            return false
        }

        let outputURL = Self.voiceMemoURL(for: payload.noteID)
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: payload.fileURL, to: outputURL)
        } catch {
            SyncLog.sender.error("voice note upload failed: cannot move file: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let fileSize: Int64
        do {
            fileSize = try FileIntegrity.fileSize(for: outputURL)
        } catch {
            SyncLog.sender.error("voice note upload: cannot read file size: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Stream-hash the file URL — do not load the whole file into Data on main.
        let sha256: String
        do {
            sha256 = try FileIntegrity.sha256Hex(for: outputURL)
        } catch {
            SyncLog.sender.error("voice note upload: cannot hash written file: \(error.localizedDescription, privacy: .public)")
            sha256 = ""
        }

        // Update the matching Note if the manifest entry already arrived; otherwise
        // the file is staged on disk and the next manifest merge will hook it up.
        let noteID = payload.noteID
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
        descriptor.fetchLimit = 1
        if let note = try? context.fetch(descriptor).first {
            note.voiceFilePath = outputURL.path
            note.voiceFileSize = fileSize
            if !sha256.isEmpty {
                note.voiceFileSHA256 = sha256
            }
            do {
                try context.save()
            } catch {
                SyncLog.sender.error("voice note save failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        SyncLog.sender.info("voice note received: \(payload.noteID, privacy: .public) — \(fileSize) bytes")
        return true
    }

    private func fetchVersion(id: UUID) -> Version? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<Version>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchTrack(id: UUID) -> Track? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func manifestNoteEntries() -> [NoteManifestEntry] {
        guard let context = modelContext else { return [] }
        let notes = ((try? context.fetch(FetchDescriptor<Note>())) ?? [])
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
        guard let context = modelContext else { return [] }
        let folders = ((try? context.fetch(FetchDescriptor<PlaylistFolder>())) ?? [])
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

    /// Builds the outgoing playlist-membership manifest, dropping any entry whose
    /// `trackID` no longer resolves to a live track. This mirrors the Mac UI, which
    /// `compactMap`s such orphans out of view — without it, an orphan (e.g. from a
    /// track deleted before cascade-cleanup existed) would sync to iOS and render
    /// forever as a "Missing track" row. Pure/read-only: safe in the fingerprint gate.
    private func manifestPlaylistEntries(validTrackIDs: Set<UUID>) -> [PlaylistManifestEntry] {
        guard let context = modelContext else { return [] }
        let playlists = ((try? context.fetch(FetchDescriptor<Playlist>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let allEntries = ((try? context.fetch(FetchDescriptor<PlaylistEntry>())) ?? [])
            .filter { validTrackIDs.contains($0.trackID) }
        let entriesByPlaylistID = Dictionary(grouping: allEntries, by: \.playlistID)

        return playlists.map { playlist in
            PlaylistManifestEntry(
                id: playlist.id,
                name: playlist.name,
                sortIndex: playlist.sortIndex,
                coverImagePath: playlist.coverImagePath,
                // Covers never ride in the manifest (protocol 6): the phone
                // fetches bytes via GET /playlist-artwork/{id} on revision mismatch.
                coverImageData: nil,
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

    private func mergePlaylistEntries(from manifest: LibraryManifest, context: ModelContext) {
        var foldersByID = Dictionary(((try? context.fetch(FetchDescriptor<PlaylistFolder>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var playlistsByID = Dictionary(((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in manifest.playlistFolders {
            if let folder = foldersByID[entry.id] {
                guard entry.updatedAt > folder.updatedAt else { continue }
                folder.name = entry.name
                folder.updatedAt = entry.updatedAt
                if entry.isSoftDeleted && !folder.isSoftDeleted {
                    // Detach playlists so the cascade relationship can't take
                    // them down later; their own tombstones arrive separately.
                    for playlist in Array(folder.playlists) { playlist.folder = nil }
                }
                folder.isSoftDeleted = entry.isSoftDeleted
            } else if !entry.isSoftDeleted {
                let folder = PlaylistFolder(id: entry.id, name: entry.name, createdAt: entry.createdAt, updatedAt: entry.updatedAt)
                context.insert(folder)
                foldersByID[folder.id] = folder
            }
        }

        for entry in manifest.playlists {
            let playlist: Playlist
            // Entries carry no timestamp; use the parent playlist's updatedAt as
            // the recency signal, captured BEFORE apply() advances it. `>=` keeps
            // the stranded-entries fix (equal timestamps still apply) while
            // blocking a *strictly older* peer snapshot from reversing newer
            // local entries — the iOS-stale-push-clobbers-Mac-edit race.
            let applyEntries: Bool
            if let existing = playlistsByID[entry.id] {
                playlist = existing
                applyEntries = entry.updatedAt >= existing.updatedAt
                // Metadata stays timestamp-gated.
                if entry.updatedAt > existing.updatedAt {
                    apply(entry, to: existing, foldersByID: foldersByID)
                }
            } else {
                // Never resurrect from a tombstone we don't even have locally.
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
                context.insert(playlist)
                playlistsByID[playlist.id] = playlist
                applyEntries = true // brand new — nothing local to protect
            }
            let desiredEntries = entry.isSoftDeleted ? [] : entry.entries
            if applyEntries && playlistEntriesDiffer(playlist.entries, desiredEntries) {
                replacePlaylistEntries(for: playlist, with: desiredEntries, context: context)
            }
        }
    }

    /// Cheap scalar comparison so identical entry sets don't dirty models every sync.
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
            // Pre-6 iOS still embeds cover bytes — apply them directly.
            playlist.setCoverImage(legacyCover)
        } else if entry.coverRevision == nil {
            // Phone cleared the cover (or never had one).
            if playlist.coverImageData != nil || playlist.coverRevision != nil {
                playlist.setCoverImage(nil)
            }
        }
        // else: revision-only signal — keep current bytes; the phone pushes
        // changed bytes via POST /playlist-artwork/{id}.
        playlist.artist = entry.artist
        playlist.playlistDescription = entry.playlistDescription
        playlist.notes = entry.notes
        playlist.createdAt = entry.createdAt
        playlist.updatedAt = entry.updatedAt
        playlist.isSoftDeleted = entry.isSoftDeleted
        playlist.isReleased = entry.isReleased
        playlist.folder = entry.folderID.flatMap { foldersByID[$0] }
    }

    private func replacePlaylistEntries(for playlist: Playlist, with entries: [PlaylistEntryManifestEntry], context: ModelContext) {
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
                context.delete(localEntry)
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
                context.insert(localEntry)
            }
            rebuilt.append(localEntry)
        }
        playlist.entries = rebuilt
    }

    private func mergeNoteEntry(
        _ entry: NoteManifestEntry,
        into notesByID: inout [UUID: Note],
        tracksByID: inout [UUID: Track],
        versionsByID: [UUID: Version],
        context: ModelContext
    ) {
        let resolvedTrackID = resolveTrackID(for: entry, tracksByID: tracksByID, versionsByID: versionsByID)

        if let localNote = notesByID[entry.id] {
            // Phone-origin notes retain their intentional precedence while the
            // deletion state remains last-write-wins. Without this boundary, a
            // stale live phone manifest can resurrect a note just tombstoned on
            // the Mac during an in-flight/reconnect race.
            let deletionStateConflicts = entry.isSoftDeleted != localNote.isSoftDeleted
            let shouldOverwrite = deletionStateConflicts
                ? entry.updatedAt > localNote.updatedAt
                : entry.createdOn == .phone || entry.updatedAt > localNote.updatedAt
            if shouldOverwrite {
                localNote.trackID = resolvedTrackID
                localNote.versionID = entry.versionID
                localNote.timestamp = entry.timestamp
                localNote.type = entry.type
                localNote.content = entry.content
                // voiceFilePath is per-device local state; never overwrite from the wire.
                localNote.voiceDuration = entry.voiceDuration
                if let sha = entry.voiceFileSHA256 { localNote.voiceFileSHA256 = sha }
                if let size = entry.voiceFileSize { localNote.voiceFileSize = size }
                // Phone precedence may accept older live content, but never
                // move the recency marker backwards: that would reopen the
                // tombstone race on the next stale manifest.
                localNote.updatedAt = max(localNote.updatedAt, entry.updatedAt)
                localNote.isSoftDeleted = entry.isSoftDeleted
                localNote.createdOn = entry.createdOn
            }

            // If a voice file landed via /voice-notes/upload before this entry arrived,
            // wire up the local path now.
            if localNote.type == .voice, localNote.voiceFilePath == nil {
                let staged = Self.voiceMemoURL(for: localNote.id)
                if FileManager.default.fileExists(atPath: staged.path) {
                    localNote.voiceFilePath = staged.path
                }
            }

            if tracksByID[localNote.trackID] == nil, resolvedTrackID != localNote.trackID {
                localNote.trackID = resolvedTrackID
            }
            if let track = tracksByID[localNote.trackID] {
                attach(note: localNote, to: track, updatedAt: localNote.updatedAt)
            }
            return
        }

        // New note from the manifest. Pick up a pre-staged voice file if it landed first.
        var initialVoicePath: String? = nil
        if entry.type == .voice {
            let staged = Self.voiceMemoURL(for: entry.id)
            if FileManager.default.fileExists(atPath: staged.path) {
                initialVoicePath = staged.path
            }
        }

        let note = Note(
            id: entry.id,
            trackID: resolvedTrackID,
            versionID: entry.versionID,
            timestamp: entry.timestamp,
            type: entry.type,
            content: entry.content,
            voiceFilePath: initialVoicePath,
            voiceDuration: entry.voiceDuration,
            voiceFileSHA256: entry.voiceFileSHA256,
            voiceFileSize: entry.voiceFileSize,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            createdOn: entry.createdOn,
            isSoftDeleted: entry.isSoftDeleted
        )
        context.insert(note)
        notesByID[note.id] = note

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

}

#if DEBUG
extension TransferManager {
    /// `-onboardingShot pair-alert`: shows the pairing alert with a fixed device name and code.
    func debugPresentPairAlert() {
        let request = PairRequest(deviceID: UUID(), deviceName: OnboardingShot.fakeDeviceName, appVersion: nil, nonce: Data())
        Task { _ = await requestUserApproval(for: request) }
    }
}
#endif
