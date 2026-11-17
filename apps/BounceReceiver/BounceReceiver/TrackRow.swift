import SwiftUI
import BounceKit

struct TrackRow: View {
    @Environment(\.editMode) private var editMode
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager

    let track: Track
    let isSelecting: Bool
    let isSelected: Bool
    let onTapRow: () -> Void
    let onLongPress: () -> Void
    /// Optional version selected by a version-scoped playlist entry. Ordinary
    /// library/set rows use the track's normal latest-version resolver.
    var preferredVersion: Version? = nil
    var showCover: Bool = true
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onRemoveFromSets: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var showsRecordingDate: Bool = false
    @State private var showDownloadPrompt = false

    // Derived here (not passed from list parents) so play/pause only invalidates
    // the current row. Short-circuit keeps non-current rows from registering an
    // isPlaying dependency.
    private var isCurrentTrack: Bool {
        audioPlayer.currentTrack?.id == track.id
    }

    private var isPlaying: Bool {
        guard isCurrentTrack else { return false }
        return audioPlayer.isPlaying
    }

    private var playbackVersion: Version? { preferredVersion ?? track.latestVersion ?? track.versions.first }

    private var downloadState: DownloadManager.DownloadState? {
        playbackVersion.map(downloadManager.downloadState(for:))
    }

    private var displayTitle: String {
        if let workingTitle = track.workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingTitle.isEmpty {
            if showsRecordingDate {
                return workingTitle
            }
            if let v = track.versionNumber {
                return "\(workingTitle) v\(v)"
            }
            return workingTitle
        }
        return track.name
    }

    private var subtitle: String {
        let versionLabel = track.latestVersionLabel
        let addedDate = (track.latestVersionDate ?? track.createdAt)
            .formatted(.dateTime.month(.abbreviated).day())

        if showsRecordingDate {
            return "Recorded: \(track.recordingDateString ?? "—")"
        }

        if versionLabel.isEmpty {
            return addedDate
        }
        return "\(versionLabel) \u{00b7} \(addedDate)"
    }

    private var showsStandaloneDownloadControl: Bool {
        guard !isSelecting, let downloadState else { return false }
        switch downloadState {
        case .notDownloaded, .pending, .downloading, .failed:
            return true
        case .ready:
            return false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }

            if showCover {
                coverView
            }

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

            let showMenu = !isSelecting && (editMode?.wrappedValue.isEditing != true)
            if showMenu {
                if let version = playbackVersion, showsStandaloneDownloadControl {
                    DownloadAvailabilityButton(version: version)
                } else {
                    Menu {
                        if let onAddToQueue {
                            Button {
                                onAddToQueue()
                            } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                        }
                        if let version = playbackVersion {
                            switch downloadState {
                            case .pending, .downloading:
                                Button { downloadManager.cancelDownload(for: version) } label: {
                                    Label("Cancel Download", systemImage: "xmark.circle")
                                }
                            case .notDownloaded, .failed:
                                Button { requestDownload(version) } label: {
                                    Label("Download", systemImage: "icloud.and.arrow.down")
                                }
                            default:
                                EmptyView()
                            }
                        }
                        if let onAddToPlaylist {
                            Button {
                                onAddToPlaylist()
                            } label: {
                                Label("Add to Playlist", systemImage: "text.badge.plus")
                            }
                        }
                        if let onShare {
                            Button {
                                onShare()
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        if let onEdit {
                            Button {
                                onEdit()
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                        if let onRemoveFromSets {
                            Button {
                                onRemoveFromSets()
                            } label: {
                                Label(RecordingsCopy.removeFrom, systemImage: "sdcard")
                            }
                        }
                        if let onDelete, let removal = downloadManager.removal(for: track) {
                            Button(role: .destructive) {
                                onDelete()
                            } label: {
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
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .ready = downloadState {
                onTapRow()
            } else if playbackVersion != nil {
                showDownloadPrompt = true
            } else {
                onTapRow()
            }
        }
        // Long-press enters multi-select. The contextMenu modifier was
        // stealing the long-press gesture; the row's ellipsis menu already
        // exposes Edit / Delete, so the contextMenu was redundant.
        .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
        .alert("Audio is not downloaded", isPresented: $showDownloadPrompt) {
            if let version = playbackVersion {
                Button("Download") { requestDownload(version) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The catalog entry is available, but its audio is not stored on this iPhone. Connect to the paired Mac to download it.")
        }
    }

    private func requestDownload(_ version: Version) {
        guard case .connected = downloadManager.connectionState else {
            showDownloadPrompt = true
            return
        }
        _ = downloadManager.requestDownload(for: version)
    }

    private var coverView: some View {
        Group {
            if let image = ArtworkImageCache.shared.image(
                for: track.id,
                data: track.artwork,
                pointSize: 44
            ) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    Image(systemName: track.isSet ? "sdcard" : "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DownloadAvailabilityButton: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let version: Version
    @State private var errorMessage: String?

    var body: some View {
        Group {
            switch downloadManager.downloadState(for: version) {
            case .notDownloaded:
                downloadButton(
                    systemName: "icloud.and.arrow.down",
                    label: "Download"
                )
            case .failed:
                downloadButton(
                    systemName: "icloud.and.arrow.down",
                    label: "Retry download",
                    color: .orange
                )
            case .pending:
                cancelButton(isWaiting: true)
            case .downloading:
                cancelButton(isWaiting: false)
            case .ready:
                EmptyView()
            }
        }
        .alert("Download unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Connect to the paired Mac to download this audio.")
        }
    }

    private func cancelButton(isWaiting: Bool) -> some View {
        Button {
            downloadManager.cancelDownload(for: version)
        } label: {
            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 2)
                TimelineView(.animation(paused: isWaiting || reduceMotion)) { context in
                    Circle()
                        .trim(from: 0, to: isWaiting ? 0.08 : 0.28)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(isWaiting || reduceMotion ? -90 :
                            context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5 * 360 - 90))
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 28, height: 28)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel download")
        .accessibilityValue(isWaiting ? "Waiting" : "Downloading")
    }

    private func downloadButton(systemName: String, label: String, color: Color = .secondary) -> some View {
        Button {
            guard case .connected = downloadManager.connectionState else {
                errorMessage = "Connect to the paired Mac to download this audio."
                return
            }
            guard downloadManager.requestDownload(for: version) else {
                errorMessage = "Sync the catalog with the paired Mac before downloading this audio."
                return
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
