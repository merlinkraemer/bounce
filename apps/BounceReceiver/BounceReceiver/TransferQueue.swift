import Foundation
import BounceKit

/// Bounded-concurrency download queue with SHA-256 verification.
///
/// Manages a pool of concurrent downloads, verifying file size and hash
/// on completion. Returns results for the caller to apply.
struct TransferQueue {

    /// Shared cancellation state lets a row action invalidate a queued or
    /// in-flight request without cancelling unrelated sync work. The transfer
    /// still gets a chance to unwind, but its temporary file is never applied.
    actor CancellationRegistry {
        private var cancelledIDs: Set<UUID> = []

        func reset(for ids: Set<UUID>) {
            cancelledIDs.subtract(ids)
        }

        func cancel(_ id: UUID) {
            cancelledIDs.insert(id)
        }

        func isCancelled(_ id: UUID) -> Bool {
            cancelledIDs.contains(id)
        }
    }

    struct TransferResult {
        let versionID: UUID
        let kind: SyncDiffKind
        let status: TransferStatus
        let tempFileURL: URL?
        let errorDescription: String?
    }

    enum TransferStatus {
        case verifying
        case failed
        case cancelled
    }

    let maxConcurrent: Int

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = maxConcurrent
    }

    func execute(
        _ jobs: [DownloadJob],
        cancellation: CancellationRegistry? = nil,
        downloader: @escaping @Sendable @MainActor (DownloadJob) async throws -> URL
    ) async -> [TransferResult] {
        guard !jobs.isEmpty else { return [] }

        let results = await withTaskGroup(of: TransferResult.self) { group in
            var results: [TransferResult] = []
            var iterator = jobs.makeIterator()

            // Seed initial batch
            for _ in 0..<min(maxConcurrent, jobs.count) {
                guard let job = iterator.next() else { break }
                group.addTask {
                    await Self.downloadAndVerify(job: job, cancellation: cancellation, downloader: downloader)
                }
            }

            // Fill slots as tasks complete
            while let result = await group.next() {
                results.append(result)
                if let nextJob = iterator.next() {
                    group.addTask {
                        await Self.downloadAndVerify(job: nextJob, cancellation: cancellation, downloader: downloader)
                    }
                }
            }

            return results
        }

        return results
    }

    // MARK: - Single download + verify

    private static func downloadAndVerify(
        job: DownloadJob,
        cancellation: CancellationRegistry?,
        downloader: @escaping @Sendable @MainActor (DownloadJob) async throws -> URL
    ) async -> TransferResult {
        if let cancellation, await cancellation.isCancelled(job.version.id) {
            return TransferResult(
                versionID: job.version.id,
                kind: job.kind,
                status: .cancelled,
                tempFileURL: nil,
                errorDescription: nil
            )
        }

        do {
            let tempURL = try await downloader(job)

            if let cancellation, await cancellation.isCancelled(job.version.id) {
                try? FileManager.default.removeItem(at: tempURL)
                return TransferResult(
                    versionID: job.version.id,
                    kind: job.kind,
                    status: .cancelled,
                    tempFileURL: nil,
                    errorDescription: nil
                )
            }

            let actualSize = try FileIntegrity.fileSize(for: tempURL)
            guard actualSize == job.version.fileSize else {
                try? FileManager.default.removeItem(at: tempURL)
                return TransferResult(
                    versionID: job.version.id,
                    kind: job.kind,
                    status: .failed,
                    tempFileURL: nil,
                    errorDescription: "size mismatch for \(job.version.originalFilename)"
                )
            }

            let actualHash = try FileIntegrity.sha256Hex(for: tempURL)
            guard actualHash == job.version.contentHash else {
                try? FileManager.default.removeItem(at: tempURL)
                return TransferResult(
                    versionID: job.version.id,
                    kind: job.kind,
                    status: .failed,
                    tempFileURL: nil,
                    errorDescription: "hash mismatch for \(job.version.originalFilename)"
                )
            }

            return TransferResult(
                versionID: job.version.id,
                kind: job.kind,
                status: .verifying,
                tempFileURL: tempURL,
                errorDescription: nil
            )
        } catch {
            let syncWasCancelled = Task.isCancelled || error is CancellationError
            if syncWasCancelled {
                return TransferResult(
                    versionID: job.version.id,
                    kind: job.kind,
                    status: .cancelled,
                    tempFileURL: nil,
                    errorDescription: nil
                )
            }
            if let cancellation, await cancellation.isCancelled(job.version.id) {
                return TransferResult(
                    versionID: job.version.id,
                    kind: job.kind,
                    status: .cancelled,
                    tempFileURL: nil,
                    errorDescription: nil
                )
            }
            return TransferResult(
                versionID: job.version.id,
                kind: job.kind,
                status: .failed,
                tempFileURL: nil,
                errorDescription: error.localizedDescription
            )
        }
    }
}

/// A single download job produced by the diff engine, enriched with a download URL.
struct DownloadJob: Sendable {
    let track: TrackManifestEntry
    let version: VersionManifestEntry
    let kind: SyncDiffKind
    let downloadURL: URL
    let requestToken: Int
}
