import SwiftUI
import SwiftData
import BounceKit

// MARK: - Sync data types

struct SyncDeviceSummary {
    let id: UUID
    let name: String
    let connectionState: SyncConnectionState
    let appVersion: String?
    let lastSeenAt: Date?
    let queueCount: Int
    let queueBytes: Int64
    let historyCount: Int
}

struct SyncQueueItem: Identifiable {
    let versionID: UUID
    let trackName: String
    let versionLabel: String
    let originalFilename: String
    let fileSize: Int64
    let fileFormat: String
    let addedAt: Date

    var id: UUID { versionID }
}

enum SyncListItemStatus {
    case queued
    case delivered
}

struct SyncListItem: Identifiable {
    let id: String
    let status: SyncListItemStatus
    let trackName: String
    let detail: String
    let sizeText: String
    let trailingText: String
}

/// Library-wide totals derived from the sheet's `@Query`ed tracks.
///
/// Computed once per library/queue change (see `libraryStatsToken`) and held
/// in `@State`, so rendering the sheet never rescans the library. These values
/// are backed by SwiftData and survive a relaunch.
struct SyncLibraryStats: Equatable {
    var trackCount = 0
    var versionCount = 0
    var totalBytes: Int64 = 0
    var totalDuration: TimeInterval = 0
    var releasedCount = 0
    var undeliveredVersionCount = 0

    static func make(tracks: [Track], undeliveredVersionIDs: Set<UUID>) -> SyncLibraryStats {
        var stats = SyncLibraryStats()
        stats.trackCount = tracks.count
        for track in tracks {
            if track.isReleased {
                stats.releasedCount += 1
            }
            for version in track.versions {
                stats.versionCount += 1
                stats.totalBytes += version.fileSize
                stats.totalDuration += version.duration
                if undeliveredVersionIDs.contains(version.id) {
                    stats.undeliveredVersionCount += 1
                }
            }
        }
        return stats
    }
}

/// Transport and delivery counters that live only for this process launch.
/// Nothing here is persisted, so it is presented as an addition to the
/// persisted library and pairing data, never as the foundation of the panel.
struct SyncSessionStats: Equatable {
    var clientRequestCount = 0
    var totalBytesServed: Int64 = 0
    var lastServedResponseBytes: Int64 = 0
    var lastClientRequestAt: Date?
    var deliveredThisSession = 0
    var appVersion: String?

    var hasActivity: Bool {
        clientRequestCount > 0
            || totalBytesServed > 0
            || lastServedResponseBytes > 0
            || lastClientRequestAt != nil
            || deliveredThisSession > 0
    }
}

/// Sync sheet — replaces the old Sync tab. Opened from the sidebar's
/// SyncStatusFooter. Single-column detail view for the paired device.
struct SyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TransferManager.self) private var transferManager
    @Query(
        sort: [
            SortDescriptor(\Track.updatedAt, order: .reverse),
            SortDescriptor(\Track.createdAt, order: .reverse)
        ]
    )
    private var tracks: [Track]

    /// Aggregates are recomputed only when the track set or queue size changes
    /// (plus the sheet's first appearance), not on every render — a sync that
    /// ticks transport state must not trigger a full library rescan.
    @State private var libraryStats = SyncLibraryStats()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)

            Divider()

            if showOnboarding {
                PairingOnboardingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SyncDetailColumnView(
                    device: selectedSummary,
                    items: combinedListItems,
                    stats: libraryStats,
                    peer: selectedPeer,
                    session: sessionStats,
                    onForget: forget,
                    isBonded: transferManager.bondedPeerStore.contains(id: selectedSummary.id)
                )
                .frame(minWidth: 360)
            }
        }
        .frame(width: 660, height: 560)
        .task(id: libraryStatsToken) {
            libraryStats = SyncLibraryStats.make(
                tracks: tracks,
                undeliveredVersionIDs: transferManager.undeliveredVersionIDs
            )
        }
    }

    private var libraryStatsToken: Int {
        var hasher = Hasher()
        hasher.combine(tracks.count)
        hasher.combine(tracks.reduce(0) { $0 + $1.versions.count })
        hasher.combine(transferManager.undeliveredVersionIDs)
        return hasher.finalize()
    }

    private var selectedPeer: BondedPeer? {
        transferManager.bondedPeerStore.peers.first { $0.id == selectedSummary.id }
    }

    private var sessionStats: SyncSessionStats {
        SyncSessionStats(
            clientRequestCount: transferManager.clientRequestCount,
            totalBytesServed: transferManager.totalBytesServed,
            lastServedResponseBytes: transferManager.lastServedResponseBytes,
            lastClientRequestAt: transferManager.lastClientRequestAt,
            deliveredThisSession: transferManager.recentHistory.count,
            appVersion: transferManager.connectedAppVersion
        )
    }

    /// True when the Mac has nothing to show: no bonded peers AND no live
    /// receiver hitting our endpoints.
    private var showOnboarding: Bool {
        OnboardingShot.step == .syncSheet ||
            (transferManager.bondedPeerStore.peers.isEmpty &&
                transferManager.connectedDeviceID == nil)
    }

    private var selectedSummary: SyncDeviceSummary {
        let queueItems = pendingQueueItems
        let historyItems = transferManager.recentHistory
        let bondedFallback = transferManager.bondedPeerStore.peers
            .max(by: { $0.lastSeenAt < $1.lastSeenAt })
        let deviceID = transferManager.connectedDeviceID
            ?? bondedFallback?.id
            ?? UUID()
        let deviceName = transferManager.connectedDeviceName
            ?? bondedFallback?.name
            ?? "Bounce Receiver"

        return SyncDeviceSummary(
            id: deviceID,
            name: deviceName,
            connectionState: transferManager.connectionState,
            appVersion: transferManager.connectedAppVersion,
            lastSeenAt: transferManager.lastClientRequestAt,
            queueCount: queueItems.count,
            queueBytes: queueItems.reduce(into: Int64(0)) { $0 += $1.fileSize },
            historyCount: historyItems.count
        )
    }

    private var pendingQueueItems: [SyncQueueItem] {
        tracks
            .flatMap { track in
                track.versions.compactMap { version in
                    guard transferManager.undeliveredVersionIDs.contains(version.id) else { return nil }
                    return SyncQueueItem(
                        versionID: version.id,
                        trackName: track.name,
                        versionLabel: version.label,
                        originalFilename: version.originalFilename,
                        fileSize: version.fileSize,
                        fileFormat: version.fileFormat,
                        addedAt: version.addedAt
                    )
                }
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private var combinedListItems: [SyncListItem] {
        let queue = pendingQueueItems.map { item in
            SyncListItem(
                id: "queue-\(item.versionID.uuidString)",
                status: .queued,
                trackName: item.trackName,
                detail: "\(item.versionLabel) • \(item.originalFilename)",
                sizeText: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
                trailingText: queuedTrailing(addedAt: item.addedAt, format: item.fileFormat)
            )
        }

        let history = transferManager.recentHistory.map { item in
            SyncListItem(
                id: "history-\(item.versionID.uuidString)-\(item.deliveredAt.timeIntervalSince1970)",
                status: .delivered,
                trackName: item.trackName,
                detail: "\(item.versionLabel) • \(item.originalFilename)",
                sizeText: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
                trailingText: item.deliveredAt.formatted(date: .omitted, time: .shortened)
            )
        }

        return queue + history
    }

    private static func queuedTrailing(addedAt: Date, format: String) -> String {
        // `addedAt` is the underlying file's creation date, not when the
        // version landed in the queue — it can read "3 days ago" even
        // for a fresh import. So just label the format; the queued state
        // is already conveyed by the row's status icon.
        format.uppercased()
    }

    private func queuedTrailing(addedAt: Date, format: String) -> String {
        Self.queuedTrailing(addedAt: addedAt, format: format)
    }

    private func forget() {
        let id = selectedSummary.id
        Task { await transferManager.forgetPeer(id) }
    }
}

/// Empty-state shown when no iPhone is paired and none is currently
/// connecting. Pairing is always initiated from iPhone — Mac just approves.
private struct PairingOnboardingView: View {
    var body: some View {
        VStack(spacing: 20) {
            GetIPhoneAppView()

            Divider().frame(maxWidth: 240)

            Text("Waiting to pair")
                .font(.title3.weight(.semibold))

            Text("Already installed? Open Bounce on your iPhone and choose this Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
