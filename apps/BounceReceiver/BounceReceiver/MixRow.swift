import SwiftUI
import BounceKit

struct MixRow: View {
    let track: Track
    let version: Version
    let onPlay: () -> Void
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager

    private var isCurrentVersion: Bool { audioPlayer.currentVersion?.id == version.id }

    private var label: String {
        let trimmed = version.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled mix" : trimmed
    }

    private var detail: String {
        let date = version.addedAt.formatted(date: .abbreviated, time: .omitted)
        guard version.duration > 0 else { return date }
        let seconds = Int(version.duration)
        return "\(date)  \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 44, height: 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isCurrentVersion {
                        PlayingIndicator(isPlaying: audioPlayer.isPlaying, maxHeight: 9)
                    }
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(isCurrentVersion ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if downloadManager.downloadState(for: version) == .ready {
                menu
            } else {
                DownloadAvailabilityButton(version: version)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            switch downloadManager.downloadState(for: version) {
            case .ready:
                onPlay()
            case .notDownloaded, .failed:
                if case .connected = downloadManager.connectionState {
                    downloadManager.requestDownload(for: version)
                }
            case .pending, .downloading:
                break
            }
        }
    }

    private var menu: some View {
        Menu {
            Button(action: onPlay) {
                Label("Play", systemImage: "play")
            }
            if let onAddToQueue {
                Button(action: onAddToQueue) {
                    Label("Add to Queue", systemImage: "text.append")
                }
            }
            if let onAddToPlaylist {
                Button(action: onAddToPlaylist) {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            }
            if let onShare {
                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }
            if downloadManager.removal(for: version, of: track) == .removeDownload {
                Button {
                    downloadManager.removeDownload(for: version)
                } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                }
            }
            if let onDelete, let removal = downloadManager.removal(for: track) {
                Button(role: .destructive, action: onDelete) {
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
