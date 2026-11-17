import SwiftUI
import AppKit
import BounceKit

/// SwiftUI row rendered inside the playlist entries NSTableView (via NSHostingView).
/// Mirrors LibraryRowView's visual anatomy but is snapshot-driven, has no section dividers,
/// and does not handle row selection (NSTableView does that).
struct PlaylistEntryRow: View {
    let snapshot: PlaylistEntryRowSnapshot
    /// Loaded lazily for visible cells — not part of the entry snapshot.
    let artworkData: Data?

    /// `artworkData` can be present but non-decodable; the placeholder must
    /// cover that case too, not only `nil`.
    private var hasDecodableArtwork: Bool {
        guard let artworkData else { return false }
        return ArtworkThumbnailCache.thumbnail(
            artworkData,
            id: snapshot.trackID,
            side: LibraryRowMetrics.artworkSide,
            revision: snapshot.artworkRevision
        ) != nil
    }
    let columns: LibraryColumnVisibility
    let isSelected: Bool
    let isHovered: Bool
    let playbackEngine: PlaybackEngine
    @Bindable var renameManager: InlineRenameManager
    let onPlayToggle: () -> Void
    let onChangeVersion: (UUID) -> Void
    let onAddToQueue: () -> Void
    let onEditTrack: () -> Void
    let onRemove: () -> Void

    private var isLoaded: Bool {
        guard let versionID = snapshot.versionID else { return false }
        return playbackEngine.loadedVersionID == versionID
    }

    private var isPlaying: Bool {
        isLoaded && playbackEngine.isPlaying
    }

    private static let artworkBG       = Color(.secondarySystemFill)
    private static let artworkBGActive = Color(.tertiarySystemFill)
    private static let noteIconColor   = Color(nsColor: .tertiaryLabelColor)
    private static let labelColor      = Color(nsColor: .labelColor)
    private static let secondaryLabelColor = Color(nsColor: .secondaryLabelColor)

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: LibraryRowMetrics.artworkSide, height: LibraryRowMetrics.artworkSide)

            VStack(alignment: .leading, spacing: 2) {
                if renameManager.activeTarget?.id == snapshot.trackID && renameManager.activeTarget?.kind == .track {
                    FocusableTextField(
                        text: renameManager.editTextBinding,
                        onCommit: { renameManager.commit() },
                        onCancel: { renameManager.cancel() }
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(snapshot.trackName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Self.labelColor)
                        .lineLimit(1)
                }

                if let versionLabel = snapshot.versionLabel, !versionLabel.isEmpty {
                    Text(versionLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Self.secondaryLabelColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if columns.showsAdded {
                Text(snapshot.addedAt.map(Self.dateFormatter.string(from:)) ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.secondaryLabelColor)
                    .frame(width: LibraryRowMetrics.dateWidth, alignment: .trailing)
            }

            if columns.showsDuration {
                Text(formatDuration(snapshot.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Self.secondaryLabelColor)
                    .frame(width: LibraryRowMetrics.durationWidth, alignment: .trailing)
            }

            Menu {
                contextMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isLoaded ? Color.accentColor : Color.secondary)
                    .frame(width: LibraryRowMetrics.menuWidth, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered || isLoaded ? 1 : 0)
            .allowsHitTesting(isHovered || isLoaded)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems }
    }

    private var artwork: some View {
        ZStack {
            if let data = artworkData,
               let nsImage = ArtworkThumbnailCache.thumbnail(
                data,
                id: snapshot.trackID,
                side: LibraryRowMetrics.artworkSide,
                revision: snapshot.artworkRevision
               ) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: LibraryRowMetrics.artworkSide, height: LibraryRowMetrics.artworkSide)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if isPlaying || isHovered || isLoaded {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected || isLoaded ? Self.artworkBGActive : Self.artworkBG)
            }

            if isPlaying && !isHovered {
                Button(action: onPlayToggle) {
                    PlayingBarsIndicator()
                        .frame(width: 18, height: 18)
                        .frame(width: LibraryRowMetrics.artworkSide, height: LibraryRowMetrics.artworkSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if isHovered || isLoaded {
                Button(action: onPlayToggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: isPlaying ? 14 : 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: LibraryRowMetrics.artworkSide, height: LibraryRowMetrics.artworkSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if artworkData == nil || !hasDecodableArtwork {
                Image("MusicNoteIcon").renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Self.noteIconColor)
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if snapshot.availableVersions.count > 1 {
            Menu {
                ForEach(snapshot.availableVersions) { version in
                    Button(version.label) { onChangeVersion(version.id) }
                }
            } label: {
                Label("Change Version", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        if snapshot.versionID != nil {
            Button(action: onPlayToggle) {
                Label("Play", systemImage: "play.fill")
            }
        }

        Button(action: onAddToQueue) {
            Label("Add to Queue", systemImage: "list.bullet")
        }

        Divider()

        Button(action: onEditTrack) {
            Label("Edit Track\u{2026}", systemImage: "pencil")
        }

        if let filePath = snapshot.filePath {
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
            } label: {
                Label("Show in Finder", systemImage: "doc")
            }
        }

        Divider()

        Button(role: .destructive, action: onRemove) {
            Label("Remove from Playlist", systemImage: "trash")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
