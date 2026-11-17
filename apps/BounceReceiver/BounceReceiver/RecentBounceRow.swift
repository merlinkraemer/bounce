import SwiftUI
import BounceKit

struct RecentBounceRow: View {
    @Environment(DownloadManager.self) private var downloadManager
    let track: Track
    let version: Version
    var isCurrentTrack: Bool = false
    var isPlaying: Bool = false
    let onTap: () -> Void
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var showDownloadPrompt = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                artwork
                if !version.hasBeenPlayed {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: -3, y: -3)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if isCurrentTrack {
                        PlayingIndicator(isPlaying: isPlaying, maxHeight: 10)
                    }
                    Text(displayTitle)
                        .font(.body)
                        .foregroundStyle(isCurrentTrack ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(subtitle)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if showsStandaloneDownloadControl {
                DownloadAvailabilityButton(version: version)
            } else {
                Menu {
                    if let onAddToQueue {
                        Button { onAddToQueue() } label: { Label("Add to Queue", systemImage: "text.append") }
                    }
                    switch downloadManager.downloadState(for: version) {
                    case .ready:
                        EmptyView()
                    case .pending, .downloading:
                        Button { downloadManager.cancelDownload(for: version) } label: {
                            Label("Cancel Download", systemImage: "xmark.circle")
                        }
                    case .notDownloaded, .failed:
                        Button { _ = downloadManager.requestDownload(for: version) } label: {
                            Label("Download", systemImage: "icloud.and.arrow.down")
                        }
                    }
                    if let onAddToPlaylist {
                        Button { onAddToPlaylist() } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                    }
                    if let onShare {
                        Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    if let onEdit {
                        Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
                    }
                    if let onDelete, let removal = downloadManager.removal(for: track) {
                        Button(role: .destructive) { onDelete() } label: {
                            Label(TrackRemovalCopy.actionTitle(removal), systemImage: TrackRemovalCopy.systemImage(removal))
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onTapGesture {}
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .ready = downloadManager.downloadState(for: version) {
                onTap()
            } else {
                showDownloadPrompt = true
            }
        }
        .alert("Audio is not downloaded", isPresented: $showDownloadPrompt) {
            Button("Download") { _ = requestDownloadIfAvailable() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Connect to the paired Mac to download this mix for offline playback.")
        }
    }

    private var displayTitle: String {
        if let workingTitle = track.workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingTitle.isEmpty {
            return workingTitle
        }
        return track.name
    }

    private var subtitle: String {
        let label = version.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = version.addedAt.formatted(.dateTime.month(.abbreviated).day())
        if label.isEmpty {
            return date
        }
        return "\(label) \u{00b7} \(date)"
    }

    private var showsStandaloneDownloadControl: Bool {
        switch downloadManager.downloadState(for: version) {
        case .notDownloaded, .pending, .downloading, .failed:
            return true
        case .ready:
            return false
        }
    }

    @discardableResult
    private func requestDownloadIfAvailable() -> Bool {
        guard case .connected = downloadManager.connectionState else { return false }
        return downloadManager.requestDownload(for: version)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = ArtworkImageCache.shared.image(
            for: track.id,
            data: track.artwork,
            pointSize: 44
        ) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
        }
    }
}
