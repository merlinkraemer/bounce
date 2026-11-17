import Foundation
import SwiftData
import BounceKit

/// Produces the set of sync actions needed to bring local state in line with a remote manifest.
///
/// Pure function — no side effects, no network calls. Takes local state + remote manifest,
/// returns create/update/delete/redownload actions.
struct ManifestDiffEngine {

    // MARK: - Diff result

    struct DiffResult {
        var downloadJobs: [DownloadJob]
        var deletedVersionIDs: Set<UUID>
        var deletedTrackIDs: Set<UUID>
    }

    struct DownloadJob: Sendable {
        let track: TrackManifestEntry
        let version: VersionManifestEntry
        let kind: SyncDiffKind
    }

    // MARK: - Compute diff

    static func compute(
        manifest: LibraryManifest,
        localTracks: [Track],
        localVersions: [Version],
        trackSnapshots: [RemoteTrackSnapshot],
        versionSnapshots: [RemoteVersionSnapshot],
        now: Date,
        requestedVersionIDs: Set<UUID> = []
    ) -> DiffResult {
        let localVersionsByID = Dictionary(localVersions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let versionSnapshotsByID = Dictionary(versionSnapshots.map { ($0.versionID, $0) }, uniquingKeysWith: { first, _ in first })

        var remoteTrackIDs = Set<UUID>()
        var remoteVersionIDs = Set<UUID>()
        var downloadJobs: [DownloadJob] = []

        for trackEntry in manifest.tracks where !trackEntry.isSoftDeleted {
            remoteTrackIDs.insert(trackEntry.id)

            for versionEntry in trackEntry.versions where !versionEntry.isSoftDeleted {
                remoteVersionIDs.insert(versionEntry.id)

                let snapshot = versionSnapshotsByID[versionEntry.id]

                // Skip if local version exists, file is present, and data matches
                if let existingVersion = localVersionsByID[versionEntry.id],
                   fileExists(for: existingVersion),
                   versionMatchesRemote(existingVersion, remote: versionEntry, snapshot: snapshot) {
                    continue
                }

                // Determine action kind
                let fileMissing = localVersionsByID[versionEntry.id].map { !fileExists(for: $0) } ?? false
                let hasLocalFile = !fileMissing && localVersionsByID[versionEntry.id] != nil
                let explicitlyRequested = requestedVersionIDs.contains(versionEntry.id)
                    || versionSnapshotsByID[versionEntry.id]?.downloadRequested == true
                // Catalog reconciliation is metadata-only by default. Existing
                // local files remain eligible, while new audio requires an
                // explicit local request.
                guard hasLocalFile || explicitlyRequested else { continue }
                let kind: SyncDiffKind = {
                    if fileMissing {
                        return .redownloadMissingFile
                    }
                    return localVersionsByID[versionEntry.id] == nil ? .create : .update
                }()

                // Check retry eligibility
                if let snapshot, !shouldAttemptDownload(snapshot: snapshot, now: now) {
                    continue
                }

                downloadJobs.append(DownloadJob(
                    track: trackEntry,
                    version: versionEntry,
                    kind: kind
                ))
            }
        }

        // Identify deletions: versions in snapshots but not in remote manifest
        let deletedVersionIDs = Set(versionSnapshots.filter { !remoteVersionIDs.contains($0.versionID) }.map(\.versionID))
        let deletedTrackIDs = Set(trackSnapshots.filter { !remoteTrackIDs.contains($0.trackID) }.map(\.trackID))

        return DiffResult(
            downloadJobs: downloadJobs,
            deletedVersionIDs: deletedVersionIDs,
            deletedTrackIDs: deletedTrackIDs
        )
    }

    // MARK: - Helpers

    private static func versionMatchesRemote(
        _ localVersion: Version,
        remote: VersionManifestEntry,
        snapshot: RemoteVersionSnapshot?
    ) -> Bool {
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

    private static func shouldAttemptDownload(snapshot: RemoteVersionSnapshot, now: Date) -> Bool {
        guard let nextRetryAt = snapshot.nextRetryAt else { return true }
        return nextRetryAt <= now
    }

    private static func fileExists(for version: Version) -> Bool {
        FileManager.default.fileExists(atPath: version.filePath)
    }
}
