import Foundation
import SwiftData
import BounceKit

/// Shared insert/append logic for adding library track versions to a playlist.
/// Used by the sidebar's drop-onto-playlist-row gesture (append at end) and the
/// playlist detail table's drop-to-insert gesture (insert at a specific row).
/// Fetches entries fresh from `context`, so it works whether or not the target
/// playlist's detail view is mounted.
///
/// Dedupes by trackID: a track that already has an entry in the playlist is
/// silently skipped.
@MainActor
func insertPlaylistEntries(
    versionIDs: [UUID],
    into playlist: Playlist,
    at destinationIndex: Int? = nil,
    context: ModelContext
) {
    guard !versionIDs.isEmpty else { return }

    let playlistID = playlist.id
    var entries = (try? context.fetch(FetchDescriptor<PlaylistEntry>(
        predicate: #Predicate { $0.playlistID == playlistID },
        sortBy: [SortDescriptor(\.position)]
    ))) ?? []

    var seenTrackIDs = Set(entries.map(\.trackID))
    var newEntries: [PlaylistEntry] = []

    for versionID in versionIDs {
        guard let version = context.fetchByID(Version.self, id: versionID) else { continue }
        guard seenTrackIDs.insert(version.trackID).inserted else { continue }

        let entry = PlaylistEntry(
            playlistID: playlistID,
            trackID: version.trackID,
            versionID: versionID,
            position: 0
        )
        context.insert(entry)
        newEntries.append(entry)
    }

    guard !newEntries.isEmpty else { return }

    let insertIndex = destinationIndex.map { max(0, min($0, entries.count)) } ?? entries.count
    entries.insert(contentsOf: newEntries, at: insertIndex)
    for (index, entry) in entries.enumerated() {
        entry.position = index
    }

    playlist.entries.append(contentsOf: newEntries)
    playlist.updatedAt = .now
    try? context.save()
}
