import SwiftUI
import SwiftData
import BounceKit

/// Snappy press feedback for the queue-sheet mode pills.
private struct PillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// "Up Next" — the queue view accessible from the full-screen player's queue
/// button. Mirrors `MixSwitcherSheet`'s dark/plain presentation. Swipe a row
/// to remove it, long-press for more; shuffle + repeat live here (not on the player transport).
struct UpNextSheet: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.dismiss) private var dismiss
    @Query private var allTracks: [Track]

    @State private var trackToAddToPlaylist: Track?
    @State private var navigateToNewPlaylist: Playlist?

    var body: some View {
        NavigationStack {
            List {
                playbackModeRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if let current = audioPlayer.currentTrack {
                    Section {
                        UpNextRow(track: current, isCurrent: true)
                    } header: {
                        Text("Now Playing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .textCase(nil)
                    }
                }

                if !audioPlayer.upNextTracks.isEmpty {
                    Section {
                        ForEach(Array(audioPlayer.upNextTracks.enumerated()), id: \.element.id) { index, track in
                            UpNextRow(track: track, isCurrent: false)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    audioPlayer.playUpNext(at: index)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        audioPlayer.removeFromUpNext(at: index)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        trackToAddToPlaylist = track
                                    } label: {
                                        Label("Add to Playlist", systemImage: "text.badge.plus")
                                    }
                                    Button(role: .destructive) {
                                        audioPlayer.removeFromUpNext(at: index)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Up Next")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.5))
                                .textCase(nil)
                            Spacer()
                            Text("\(audioPlayer.upNextCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.5))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !audioPlayer.upNextTracks.isEmpty {
                        Button(role: .destructive) {
                            audioPlayer.clearUpNext()
                        } label: {
                            Text("Clear")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(
                playlist: nil,
                tracks: allTracks,
                preselectedTrackIDs: [track.id],
                createdPlaylist: $navigateToNewPlaylist
            )
        }
    }

    private var playbackModeRow: some View {
        HStack(spacing: 10) {
            modePill(
                systemName: "shuffle",
                isOn: audioPlayer.shuffleEnabled,
                accessibilityLabel: audioPlayer.shuffleEnabled ? "Shuffle on" : "Shuffle off"
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    audioPlayer.toggleShuffle()
                }
            }

            modePill(
                systemName: repeatGlyph,
                isOn: audioPlayer.repeatMode != .off,
                accessibilityLabel: repeatLabel,
                animatesSymbol: true
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    audioPlayer.cycleRepeatMode()
                }
            }

            modePill(
                systemName: "infinity",
                isOn: audioPlayer.autoplayEnabled,
                accessibilityLabel: audioPlayer.autoplayEnabled ? "Autoplay on" : "Autoplay off"
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    audioPlayer.toggleAutoplay()
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modePill(
        systemName: String,
        isOn: Bool,
        accessibilityLabel: String,
        animatesSymbol: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : .white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background {
                    Capsule().fill(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)))
                }
                .contentTransition(animatesSymbol
                    ? .symbolEffect(.replace.offUp.byLayer)
                    : .identity)
        }
        .buttonStyle(PillPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .sensoryFeedback(.selection, trigger: isOn)
    }

    private var repeatGlyph: String {
        switch audioPlayer.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var repeatLabel: String {
        switch audioPlayer.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }
}

private struct UpNextRow: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                if let image = ArtworkImageCache.shared.image(
                    for: track.id,
                    data: track.artwork,
                    pointSize: 36
                ) {
                    image
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                    .lineLimit(1)
                Text(isCurrent ? (audioPlayer.currentVersion?.label ?? track.latestVersionLabel) : track.latestVersionLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent {
                PlayingIndicator(isPlaying: audioPlayer.isPlaying, maxHeight: 12)
            }
        }
        .listRowBackground(Color.clear)
    }
}
