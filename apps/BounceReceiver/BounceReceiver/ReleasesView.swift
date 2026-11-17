import SwiftUI
import SwiftData
import BounceKit

struct ReleasesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager

    @Query(
        filter: #Predicate<Track> { $0.isReleased },
        sort: \Track.lastTouchedAt,
        order: .reverse
    ) private var releases: [Track]
    @Query private var allTracks: [Track]
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var allPlaylists: [Playlist]

    @State private var trackToAddToPlaylist: Track?
    @State private var trackToEdit: Track?
    @State private var navigateToNewPlaylist: Playlist?
    @State private var shareItem: ShareItem?

    @State private var navigateToPlaylist: Playlist?
    /// Blocks tile taps for 500 ms after onAppear so a rapid pop→push
    /// never overlaps the Liquid Glass nav bar morph.
    @State private var navigationReadyAt: Date = .now

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var releasedPlaylists: [Playlist] {
        allPlaylists.filter { $0.isReleased && !$0.isSoftDeleted }
    }

    private enum ReleaseItem: Identifiable {
        case playlist(Playlist)
        case track(Track)

        var id: String {
            switch self {
            case .playlist(let playlist): return "playlist-\(playlist.id.uuidString)"
            case .track(let track): return "track-\(track.id.uuidString)"
            }
        }

        var sortDate: Date {
            switch self {
            case .playlist(let playlist): return playlist.updatedAt
            case .track(let track): return track.lastTouchedAt
            }
        }
    }

    private var items: [ReleaseItem] {
        let playlistItems = releasedPlaylists.map { ReleaseItem.playlist($0) }
        let trackItems = releases.map { ReleaseItem.track($0) }
        return (playlistItems + trackItems).sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyStateBlock(
                    symbolName: "checkmark.seal",
                    symbolSize: 48,
                    title: "No Releases",
                    description: "Mark a track or playlist as released to surface it in this grid."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(items) { item in
                            tile(for: item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.currentTrack != nil {
                Color.clear.frame(height: 76)
            }
        }
        .navigationTitle("Releases")
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(item: $navigateToPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(
                playlist: nil,
                tracks: allTracks,
                preselectedTrackIDs: [track.id],
                createdPlaylist: $navigateToNewPlaylist
            )
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .navigationDestination(item: $navigateToNewPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .onAppear {
            DebugLog.log("ReleasesView onAppear")
            navigationReadyAt = Date().addingTimeInterval(0.5)
        }
        .onDisappear { DebugLog.log("ReleasesView onDisappear") }
    }

    @ViewBuilder
    private func tile(for item: ReleaseItem) -> some View {
        switch item {
        case .playlist(let playlist):
            playlistTile(playlist)
        case .track(let track):
            trackTile(track)
        }
    }

    private func playlistTile(_ playlist: Playlist) -> some View {
        Button {
            guard Date() >= navigationReadyAt else { return }
            navigateToPlaylist = playlist
        } label: {
            tileLabel(
                id: playlist.id,
                artwork: playlist.coverImageData,
                isPlaylist: true,
                title: playlist.name,
                subtitle: playlistSubtitle(playlist)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                unmarkAsReleased(playlist)
            } label: {
                Label("Unmark as Released", systemImage: "xmark.seal")
            }
        }
    }

    private func trackTile(_ track: Track) -> some View {
        Button {
            play(track)
        } label: {
            tileLabel(
                id: track.id,
                artwork: track.artwork,
                isPlaylist: false,
                title: track.displayTitle,
                subtitle: trackSubtitle(track)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                audioPlayer.addToQueue(track)
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            Button {
                trackToAddToPlaylist = track
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            if let url = TrackShareURL.resolve(for: track) {
                Button {
                    shareItem = ShareItem(url: url)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                trackToEdit = track
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    private func tileLabel(
        id: UUID,
        artwork: Data?,
        isPlaylist: Bool,
        title: String,
        subtitle: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(id: id, data: artwork, isPlaylist: isPlaylist)

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func cover(id: UUID, data: Data?, isPlaylist: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = ArtworkImageCache.shared.image(
                    for: id,
                    data: data,
                    pointSize: 240
                ) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: isPlaylist ? "music.note.list" : "music.note")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String? {
        playlist.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trackSubtitle(_ track: Track) -> String? {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? nil : artist
    }

    private func play(_ track: Track) {
        if audioPlayer.currentTrack?.id == track.id && audioPlayer.isPlaying {
            audioPlayer.openFullScreenPlayer()
            return
        }
        audioPlayer.load(track: track, queue: releases, context: .releases)
        audioPlayer.openFullScreenPlayer()
    }

    private func unmarkAsReleased(_ playlist: Playlist) {
        playlist.isReleased = false
        playlist.updatedAt = .now
        do {
            try modelContext.save()
            downloadManager.notifyLocalManifestMutated()
        } catch {
            print("[ReleasesView] ERROR: Failed to unmark as released: \(error)")
        }
    }
}

struct SetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager

    @Query(
        filter: #Predicate<Track> { $0.isSet },
        sort: \Track.lastTouchedAt,
        order: .reverse
    ) private var sets: [Track]
    @Query private var allTracks: [Track]

    @State private var trackToAddToPlaylist: Track?
    @State private var trackToEdit: Track?
    @State private var shareItem: ShareItem?

    var body: some View {
        Group {
            if sets.isEmpty {
                EmptyStateBlock(
                    symbolName: "sdcard",
                    symbolSize: 48,
                    title: RecordingsCopy.emptyTitle,
                    description: RecordingsCopy.emptyDescription
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sets) { track in
                        TrackRow(
                            track: track,
                            isSelecting: false,
                            isSelected: false,
                            onTapRow: { play(track) },
                            onLongPress: {},
                            onAddToQueue: { audioPlayer.addToQueue(track) },
                            onAddToPlaylist: { trackToAddToPlaylist = track },
                            onShare: {
                                if let url = TrackShareURL.resolve(for: track) {
                                    shareItem = ShareItem(url: url)
                                }
                            },
                            onEdit: { trackToEdit = track },
                            onRemoveFromSets: { removeFromSets(track) },
                            showsRecordingDate: true
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                }
                .listStyle(.plain)
                .listSectionSpacing(.compact)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.currentTrack != nil {
                Color.clear.frame(height: 76)
            }
        }
        .navigationTitle(RecordingsCopy.plural)
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(
                playlist: nil,
                tracks: allTracks,
                preselectedTrackIDs: [track.id],
                createdPlaylist: .constant(nil)
            )
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private func removeFromSets(_ track: Track) {
        track.isSet = false
        track.updatedAt = .now
        track.lastTouchedAt = .now
        try? modelContext.save()
        downloadManager.notifyLocalManifestMutated()
    }

    private func play(_ track: Track) {
        if audioPlayer.currentTrack?.id == track.id && audioPlayer.isPlaying {
            audioPlayer.openFullScreenPlayer()
            return
        }
        audioPlayer.load(track: track, queue: sets, context: .sets)
        audioPlayer.openFullScreenPlayer()
    }
}
