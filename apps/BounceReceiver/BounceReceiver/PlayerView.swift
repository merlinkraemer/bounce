import SwiftUI
import BounceKit

struct PlayerView: View {
    @Environment(AudioPlayer.self) private var audioPlayer

    let voiceNoteController: VoiceNoteInteractionController
    let onDismiss: () -> Void
    let onShare: () -> Void
    let onAddToPlaylist: () -> Void
    let onQueue: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onEditTrack: () -> Void
    let onVersionTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let track = audioPlayer.currentTrack, let version = audioPlayer.currentVersion {
                let waveformData = version.waveformData
                let _ = audioPlayer.waveformRefreshToken

                PlayerHeaderBar(
                    track: track,
                    versionLabel: version.label,
                    onDismiss: onDismiss,
                    onAddToPlaylist: onAddToPlaylist,
                    onEditTrack: onEditTrack,
                    onShare: onShare
                )

                Spacer()

                PlayerWaveformStack(
                    waveformData: waveformData,
                    // AVPlayerItem duration arrives async; fall back to the
                    // model's known length so waveform metrics and time labels
                    // never render a long set as duration 0 during load.
                    duration: audioPlayer.duration > 0 ? audioPlayer.duration : version.duration,
                    versionID: version.id,
                    track: track,
                    audioPlayer: audioPlayer,
                    waveformRefreshToken: audioPlayer.waveformRefreshToken
                )

                PlayerTimeDisplay(audioPlayer: audioPlayer)

                Color.clear.frame(height: 28)

                PlayerTransportPrimary(
                    audioPlayer: audioPlayer,
                    voiceNoteController: voiceNoteController,
                    onPrevious: onPrevious,
                    onNext: onNext
                )

                PlayerTransportSecondary(
                    audioPlayer: audioPlayer,
                    onVersionTap: onVersionTap,
                    onQueue: onQueue,
                    onShare: onShare
                )
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct PlayerHeaderBar: View {
    let track: Track
    let versionLabel: String
    let onDismiss: () -> Void
    let onAddToPlaylist: () -> Void
    let onEditTrack: () -> Void
    let onShare: () -> Void

    private var subtitle: String? {
        let parts = [track.artist, versionLabel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }

            Group {
                if let image = ArtworkImageCache.shared.image(
                    for: track.id,
                    data: track.artwork,
                    pointSize: 40
                ) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                MarqueeTitle(text: track.displayTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    onAddToPlaylist()
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }

                Button {
                    onShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button {
                    onEditTrack()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .padding(.top, 4)
    }
}

private struct PlayerWaveformStack: View {
    let waveformData: Data?
    let duration: TimeInterval
    let versionID: UUID
    let track: Track
    let audioPlayer: AudioPlayer
    let waveformRefreshToken: Int

    @State private var notesForVersion: [Note] = []

    var body: some View {
        let _ = waveformRefreshToken
        VStack(spacing: 0) {
            WaveformView(
                waveformData: waveformData,
                duration: duration,
                versionID: versionID,
                audioPlayer: audioPlayer,
                onSeek: { time in audioPlayer.seek(to: time) },
                notes: notesForVersion
            )
            .frame(height: 240)

            MiniWaveformView(
                waveformData: waveformData,
                duration: duration,
                versionID: versionID,
                audioPlayer: audioPlayer,
                onSeek: { time in audioPlayer.seek(to: time) }
            )
            .frame(height: 40)
            .padding(.horizontal, 20)
            .padding(.top, 32)
        }
        .onAppear { refreshNotes() }
        .onChange(of: versionID) { _, _ in refreshNotes() }
        .onChange(of: track.visibleNotes.count) { _, _ in refreshNotes() }
    }

    private func refreshNotes() {
        notesForVersion = track.visibleNotes(forVersion: versionID)
    }
}

private struct PlayerTimeDisplay: View {
    let audioPlayer: AudioPlayer

    var body: some View {
        let elapsed = audioPlayer.showFullScreenPlayer ? audioPlayer.currentTime : 0
        return HStack {
            Text(formatDuration(elapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))

            Spacer()

            if audioPlayer.duration > 0 {
                Text(formatDuration(audioPlayer.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct PlayerTransportPrimary: View {
    let audioPlayer: AudioPlayer
    let voiceNoteController: VoiceNoteInteractionController
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrevious) {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }

            Button { audioPlayer.togglePlayPause() } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.symbolEffect(.replace.offUp.byLayer))
            }

            Button(action: onNext) {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .overlay(alignment: .top) {
            errorToast
                .offset(y: -44)
                .padding(.horizontal, 24)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: voiceNoteController.errorMessage)
        }
    }

    @ViewBuilder
    private var errorToast: some View {
        if let errorMessage = voiceNoteController.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(errorMessage)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.85))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct PlayerTransportSecondary: View {
    let audioPlayer: AudioPlayer
    let onVersionTap: () -> Void
    let onQueue: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack {
            Button(action: onVersionTap) {
                HStack(spacing: 6) {
                    Text(audioPlayer.currentVersion?.label ?? "Version")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(LiquidGlassCapsule())
            }

            Spacer()

            Button(action: onQueue) {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }

            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .disabled(audioPlayer.currentFileURL == nil)
        }
        .padding(.horizontal, 24)
    }
}

private struct MarqueeTitle: View {
    let text: String

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationToken: Int = 0

    var body: some View {
        GeometryReader { proxy in
            let overflow = max(0, textWidth - proxy.size.width)
            let needsScroll = overflow > 1
            ZStack(alignment: .leading) {
                Text(text)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: needsScroll ? offset : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .onAppear { restartIfNeeded(overflow: overflow) }
            .onChange(of: proxy.size.width) { _, _ in restartIfNeeded(overflow: overflow) }
            .onChange(of: needsScroll) { _, scroll in
                if scroll {
                    restartIfNeeded(overflow: overflow)
                } else {
                    animationToken &+= 1
                    offset = 0
                }
            }
        }
        .background {
            Text(text)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in textWidth = width }
                })
                .hidden()
        }
        .frame(height: 22)
        .onChange(of: text) { _, _ in
            animationToken &+= 1
            offset = 0
        }
    }

    private func restartIfNeeded(overflow: CGFloat) {
        animationToken &+= 1
        offset = 0
        guard overflow > 1 else { return }
        let token = animationToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard token == animationToken else { return }
            withAnimation(.linear(duration: max(3, Double(overflow) / 28)).repeatForever(autoreverses: true)) {
                offset = -overflow
            }
        }
    }
}
