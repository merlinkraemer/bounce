import Foundation
import SwiftData

public extension ModelContext {
    /// Deletes `version` from `track`, unpins playlist slots that pointed at it,
    /// and deletes the track too when this was its last version. Returns the
    /// files the deleted rows owned; pass them to `removeUnreferencedFiles(atPaths:)`
    /// after the deletion has been saved.
    func deleteVersion(_ version: Version, of track: Track) -> [String] {
        var paths = [version.filePath]
        let versionID: UUID? = version.id
        track.versions.removeAll { $0.id == version.id }
        delete(version)
        unpinPlaylistEntries(pinnedTo: versionID)
        if track.versions.isEmpty {
            paths += deleteTrack(track)
        }
        return paths
    }

    /// Deletes `track` with its versions and notes and removes the playlist
    /// slots that reference it. Returns the audio and voice-note files the
    /// deleted rows owned.
    func deleteTrack(_ track: Track) -> [String] {
        let paths = track.versions.map(\.filePath) + track.notes.compactMap(\.voiceFilePath)
        removePlaylistEntries(forTrackID: track.id)
        delete(track)
        return paths
    }

    /// Tombstones `playlist` so the deletion wins against stale manifests
    /// pushed back from the phone. Entries and cover data are stripped to keep
    /// the tombstone tiny.
    func softDeletePlaylist(_ playlist: Playlist) {
        for entry in playlist.entries {
            delete(entry)
        }
        playlist.entries.removeAll()
        playlist.setCoverImage(nil)
        playlist.coverImagePath = nil
        playlist.folder = nil
        playlist.isSoftDeleted = true
        playlist.updatedAt = .now
    }

    /// Tombstones `folder` and every playlist in it.
    func softDeleteFolder(_ folder: PlaylistFolder) {
        for playlist in Array(folder.playlists) {
            softDeletePlaylist(playlist)
        }
        folder.isSoftDeleted = true
        folder.updatedAt = .now
    }

    /// Removes files at the given absolute paths unless a remaining version or
    /// note still points at them. Call after the deleting save succeeded.
    func removeUnreferencedFiles(atPaths paths: [String]) {
        let fileManager = FileManager.default
        for path in Set(paths) where path.hasPrefix("/") {
            guard !isFileReferenced(path) else { continue }
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                SyncLog.sender.error("Could not remove deleted file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func unpinPlaylistEntries(pinnedTo versionID: UUID?) {
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate { $0.versionID == versionID }
        )
        guard let entries = try? fetch(descriptor), !entries.isEmpty else { return }
        for entry in entries {
            entry.versionID = nil
            if let playlist = fetchByID(Playlist.self, id: entry.playlistID) {
                playlist.updatedAt = .now
            }
        }
    }

    private func isFileReferenced(_ path: String) -> Bool {
        let voicePath: String? = path
        let versionCount = (try? fetchCount(FetchDescriptor<Version>(predicate: #Predicate { $0.filePath == path }))) ?? 1
        let noteCount = (try? fetchCount(FetchDescriptor<Note>(predicate: #Predicate { $0.voiceFilePath == voicePath }))) ?? 1
        return versionCount + noteCount > 0
    }
}
