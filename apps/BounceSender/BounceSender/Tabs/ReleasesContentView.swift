import SwiftUI
import SwiftData
import BounceKit
import AppKit

/// Big cover grid of released playlists and released tracks (singles).
struct ReleasesContentView: View {
    let tracks: [Track]
    let playlists: [Playlist]
    /// Shared with the toolbar sort menu (`AllTracksSortMode` raw value).
    let sortModeRaw: String
    @Binding var selectedVersionID: UUID?
    let onSelectVersion: (UUID) -> Void
    let onSelectPlaylist: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext

    private enum ReleaseItem: Identifiable {
        case playlist(Playlist)
        case track(Track)

        var id: String {
            switch self {
            case .playlist(let playlist): return "playlist-\(playlist.id.uuidString)"
            case .track(let track): return "track-\(track.id.uuidString)"
            }
        }

        var sortName: String {
            switch self {
            case .playlist(let playlist): return playlist.name
            case .track(let track): return track.name
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
        let playlistItems = playlists
            .filter { $0.isReleased && !$0.isSoftDeleted }
            .map { ReleaseItem.playlist($0) }
        let trackItems = tracks
            .filter(\.isReleased)
            .map { ReleaseItem.track($0) }
        let all = playlistItems + trackItems
        if AllTracksSortMode(rawValue: sortModeRaw) == .name {
            return all.sorted { $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending }
        }
        return all.sorted { $0.sortDate > $1.sortDate }
    }

    // Fixed tile size (min == max) so inspector/sidebar width animations don't
    // continuously grow cells between adaptive bounds — that reads as a scale-up.
    private let tileSide: CGFloat = 160
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSide, maximum: tileSide), spacing: 24, alignment: .leading)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                sectionHeaderClearance
                sectionHeader
                ContentUnavailableView(
                    "No Releases",
                    systemImage: "checkmark.seal",
                    description: Text("Mark a track or playlist as released to see it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // The clearance spacer and header live inside the scroll
                    // content so they scroll away with the grid, matching the
                    // catalogue surface where the header is row 0.
                    VStack(spacing: 0) {
                        sectionHeaderClearance
                        sectionHeader
                        grid
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .columnBackground(.content)
    }

    /// The same constant resting clearance as the catalogue's scroll inset,
    /// so the two surfaces cannot drift.
    private var sectionHeaderClearance: some View {
        Color.clear
            .frame(height: BounceConstants.columnTopFadeHeight)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(items) { item in
                releaseTile(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private var sectionHeader: some View {
        let count = items.count
        return HStack {
            Text("Releases")
                .font(.system(size: 15, weight: .semibold))
            Text("\(count) \(count == 1 ? "release" : "releases")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func releaseTile(_ item: ReleaseItem) -> some View {
        switch item {
        case .playlist(let playlist):
            Button {
                onSelectPlaylist(playlist.id)
            } label: {
                ReleaseCoverTile(
                    title: playlist.name,
                    subtitle: playlist.artist?.nilIfEmpty ?? "Playlist",
                    coverImageData: playlist.coverImageData,
                    coverID: playlist.id,
                    coverRevision: playlist.coverRevision
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    togglePlaylistRelease(playlist)
                } label: {
                    Label("Unmark as Released", systemImage: "checkmark.seal.fill")
                }
            }

        case .track(let track):
            Button {
                selectTrack(track)
            } label: {
                ReleaseCoverTile(
                    title: track.name,
                    subtitle: track.artist.nilIfEmpty ?? "Single",
                    coverImageData: track.artwork,
                    coverID: track.id,
                    coverRevision: track.artworkRevision
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    toggleTrackRelease(track)
                } label: {
                    Label("Unmark as Released", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private func selectTrack(_ track: Track) {
        guard let version = track.latestVersion else { return }
        selectedVersionID = version.id
        onSelectVersion(version.id)
    }

    private func togglePlaylistRelease(_ playlist: Playlist) {
        playlist.isReleased = false
        playlist.updatedAt = .now
        try? modelContext.save()
    }

    private func toggleTrackRelease(_ track: Track) {
        track.isReleased = false
        track.updatedAt = .now
        track.lastTouchedAt = .now
        try? modelContext.save()
    }
}

private struct ReleaseCoverTile: View {
    let title: String
    let subtitle: String
    let coverImageData: Data?
    let coverID: UUID
    let coverRevision: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let data = coverImageData,
           let nsImage = ArtworkThumbnailCache.thumbnail(
            data,
            id: coverID,
            side: 200,
            revision: coverRevision
           ) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
