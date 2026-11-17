import Foundation
import SwiftData
import BounceKit

/// Manages uploading phone-originated tracks to the Mac.
/// Reads PendingUpload queue, sends via BonjourTransport, tracks status.
@Observable
@MainActor
final class UploadQueue {

    // MARK: - Public State

    private(set) var pendingCount: Int = 0
    private(set) var uploadingCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var isUploading: Bool = false

    private let transport: BonjourTransport
    private let modelContext: ModelContext
    private var activeTask: Task<Void, Never>? = nil
    private var drainRequestedWhileActive = false

    /// Called after queue drains successfully — triggers iOS manifest push.
    var onQueueDrained: (() -> Void)?

    // MARK: - Init

    init(transport: BonjourTransport, modelContext: ModelContext) {
        self.transport = transport
        self.modelContext = modelContext
    }

    /// Call after transport.start() — observes connection state for auto-drain.
    func startObserving() {
        recoverInterruptedUploads()

        // Check immediately
        drainQueue()

        // Poll for connection state changes (simple, reliable)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self else { return }
                if case .connected = self.transport.connectionState {
                    self.drainQueue()
                }
            }
        }
    }

    // MARK: - Queue Management

    /// Enqueue a newly imported track/version for upload.
    func enqueue(track: Track, version: Version, targetTrackID: UUID? = nil) {
        if let existing = existingTrackUpload(for: version.id) {
            if existing.status == .failed {
                existing.status = .pending
                existing.lastError = nil
                try? modelContext.save()
            }
            refreshCounts()
            if case .connected = transport.connectionState {
                drainQueue()
            } else {
                transport.triggerReconnect()
            }
            return
        }

        let pending = PendingUpload(
            versionID: version.id,
            trackID: track.id,
            trackName: track.name,
            filePath: version.filePath,
            fileSize: version.fileSize,
            fileFormat: version.fileFormat,
            originalFilename: version.originalFilename,
            duration: version.duration,
            versionLabel: version.label,
            targetTrackID: targetTrackID,
            sourceContentHash: version.sourceContentHash
        )
        modelContext.insert(pending)
        try? modelContext.save()
        refreshCounts()

        // Auto-start upload if connected, otherwise trigger reconnect
        if case .connected = transport.connectionState {
            drainQueue()
        } else {
            transport.triggerReconnect()
        }
    }

    /// Enqueue a locally-recorded voice note .m4a for upload.
    func enqueueVoiceNote(noteID: UUID, fileURL: URL, sha256: String, fileSize: Int64) {
        if let existing = existingVoiceUpload(for: noteID) {
            if existing.status == .failed {
                existing.status = .pending
                existing.lastError = nil
                try? modelContext.save()
            }
            refreshCounts()
            if case .connected = transport.connectionState {
                drainQueue()
            } else {
                transport.triggerReconnect()
            }
            return
        }

        let pending = PendingVoiceUpload(
            noteID: noteID,
            filePath: fileURL.path,
            fileSize: fileSize,
            sha256: sha256
        )
        modelContext.insert(pending)
        try? modelContext.save()
        refreshCounts()

        if case .connected = transport.connectionState {
            drainQueue()
        } else {
            transport.triggerReconnect()
        }
    }

    /// Start uploading all pending items. Safe to call repeatedly.
    func drainQueue() {
        guard activeTask == nil else {
            drainRequestedWhileActive = true
            return
        }
        guard case .connected = transport.connectionState else {
            print("[UploadQueue] drainQueue: not connected (\(transport.connectionState)), skipping")
            return
        }

        recoverInterruptedUploads()

        print("[UploadQueue] drainQueue: starting")
        activeTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.drainRequestedWhileActive = false
                await self.processQueue()
            } while self.drainRequestedWhileActive && !Task.isCancelled && self.transport.connectionState == .connected
            self.activeTask = nil
        }
    }

    // MARK: - Private

    private func processQueue() async {
        isUploading = true
        var transportHealthy = true
        defer {
            if Task.isCancelled {
                recoverInterruptedUploads()
            }
            isUploading = false
        }

        for pending in fetchPendingTrackUploads() {
            guard !Task.isCancelled else { break }

            print("[UploadQueue] uploading \(pending.originalFilename) (\(pending.filePath))")
            pending.status = .uploading
            pending.lastAttemptAt = .now
            try? modelContext.save()
            refreshCounts()

            let fileURL = URL(fileURLWithPath: pending.filePath)
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                pending.status = .failed
                pending.lastError = "Could not read local file: \(fileURL.lastPathComponent)"
                pending.retryCount += 1
                try? modelContext.save()
                refreshCounts()
                print("[UploadQueue] upload FAILED locally: \(pending.originalFilename) — file not readable")
                continue
            }

            do {
                _ = try await transport.uploadFile(
                    trackName: pending.trackName,
                    versionLabel: pending.versionLabel,
                    originalFilename: pending.originalFilename,
                    fileFormat: pending.fileFormat,
                    versionID: pending.versionID,
                    trackID: pending.trackID,
                    targetTrackID: pending.targetTrackID,
                    sourceContentHash: pending.sourceContentHash,
                    fileURL: fileURL
                )

                pending.status = .uploaded
                pending.lastError = nil
                try? modelContext.save()
                print("[UploadQueue] upload succeeded: \(pending.originalFilename)")
            } catch {
                pending.status = .failed
                pending.lastError = error.localizedDescription
                pending.retryCount += 1
                try? modelContext.save()
                refreshCounts()
                transportHealthy = false

                print("[UploadQueue] upload FAILED: \(pending.originalFilename) — \(error.localizedDescription)")

                transport.handleNetworkFailure()
                transport.triggerReconnect()
                break
            }

            refreshCounts()
        }

        // Voice note uploads piggy-back on the same drain loop so we never have
        // two concurrent multipart POSTs racing on a single Bonjour connection.
        if transportHealthy && !Task.isCancelled {
            transportHealthy = await processVoiceQueue()
        }

        if transportHealthy {
            onQueueDrained?()
        }
    }

    private func processVoiceQueue() async -> Bool {
        for pending in fetchPendingVoiceUploads() {
            guard !Task.isCancelled else { break }
            print("[UploadQueue] uploading voice note \(pending.noteID) (\(pending.filePath))")
            pending.status = .uploading
            pending.lastAttemptAt = .now
            try? modelContext.save()
            refreshCounts()

            let fileURL = URL(fileURLWithPath: pending.filePath)
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                pending.status = .failed
                pending.lastError = "Could not read local voice note: \(fileURL.lastPathComponent)"
                pending.retryCount += 1
                try? modelContext.save()
                refreshCounts()
                print("[UploadQueue] voice note upload FAILED locally: \(pending.noteID) — file not readable")
                continue
            }

            do {
                _ = try await transport.uploadVoiceNote(noteID: pending.noteID, fileURL: fileURL)
                pending.status = .uploaded
                pending.lastError = nil
                try? modelContext.save()
                print("[UploadQueue] voice note upload succeeded: \(pending.noteID)")
            } catch {
                pending.status = .failed
                pending.lastError = error.localizedDescription
                pending.retryCount += 1
                try? modelContext.save()
                print("[UploadQueue] voice note upload FAILED: \(pending.noteID) — \(error.localizedDescription)")
                transport.handleNetworkFailure()
                transport.triggerReconnect()
                return false
            }

            refreshCounts()
        }
        return true
    }

    private func fetchPendingTrackUploads() -> [PendingUpload] {
        let pendingRaw = PendingUploadStatus.pending.rawValue
        let failedRaw = PendingUploadStatus.failed.rawValue
        var descriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate { $0.statusRaw == pendingRaw || $0.statusRaw == failedRaw }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchPendingVoiceUploads() -> [PendingVoiceUpload] {
        let pendingRaw = PendingUploadStatus.pending.rawValue
        let failedRaw = PendingUploadStatus.failed.rawValue
        var descriptor = FetchDescriptor<PendingVoiceUpload>(
            predicate: #Predicate { $0.statusRaw == pendingRaw || $0.statusRaw == failedRaw }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func existingTrackUpload(for versionID: UUID) -> PendingUpload? {
        let uploads = (try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? []
        return uploads.first { $0.versionID == versionID }
    }

    private func existingVoiceUpload(for noteID: UUID) -> PendingVoiceUpload? {
        let uploads = (try? modelContext.fetch(FetchDescriptor<PendingVoiceUpload>())) ?? []
        return uploads.first { $0.noteID == noteID }
    }

    /// A process can disappear after persisting .uploading but before the
    /// request completes. Those rows are no longer owned by a live task and
    /// must become retryable on the next connection or launch.
    private func recoverInterruptedUploads() {
        let uploading = PendingUploadStatus.uploading.rawValue
        let trackUploads = (try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? []
        let voiceUploads = (try? modelContext.fetch(FetchDescriptor<PendingVoiceUpload>())) ?? []
        var recovered = false

        for upload in trackUploads where upload.statusRaw == uploading {
            upload.status = .pending
            upload.lastError = nil
            recovered = true
        }
        for upload in voiceUploads where upload.statusRaw == uploading {
            upload.status = .pending
            upload.lastError = nil
            recovered = true
        }

        if recovered {
            try? modelContext.save()
        }
        refreshCounts()
    }

    private func refreshCounts() {
        let allTracks = (try? modelContext.fetch(FetchDescriptor<PendingUpload>())) ?? []
        let allVoice = (try? modelContext.fetch(FetchDescriptor<PendingVoiceUpload>())) ?? []
        let pendingRaw = PendingUploadStatus.pending.rawValue
        let uploadingRaw = PendingUploadStatus.uploading.rawValue
        let failedRaw = PendingUploadStatus.failed.rawValue
        pendingCount = allTracks.filter { $0.statusRaw == pendingRaw }.count
            + allVoice.filter { $0.statusRaw == pendingRaw }.count
        uploadingCount = allTracks.filter { $0.statusRaw == uploadingRaw }.count
            + allVoice.filter { $0.statusRaw == uploadingRaw }.count
        failedCount = allTracks.filter { $0.statusRaw == failedRaw }.count
            + allVoice.filter { $0.statusRaw == failedRaw }.count
    }
}
