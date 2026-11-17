import SwiftUI
import BounceKit

struct MiniPlayerBar: View {
    @Environment(AudioPlayer.self) private var audioPlayer

    let onTap: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var dragAxisIsHorizontal: Bool?
    @State private var isCommitting = false

    private static let commitFraction: CGFloat = 0.35
    private static let flickVelocity: CGFloat = 600
    private static let rubberBandFactor: CGFloat = 0.2
    private static let axisLockDistance: CGFloat = 8
    private static let edgeFadeWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                artworkView(for: audioPlayer.currentTrack)
                textCarousel
            }
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture)

            Button {
                audioPlayer.togglePlayPause()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace.offUp.byLayer))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .background(
            Capsule()
                .fill(.clear)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var textCarousel: some View {
        ZStack(alignment: .leading) {
            if let peek = peekTrack {
                trackText(track: peek, secondary: "")
                    .offset(x: dragOffset + (dragOffset < 0 ? contentWidth : -contentWidth))
            }
            trackText(track: audioPlayer.currentTrack, secondary: secondaryLabel)
                .offset(x: dragOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .mask(EdgeFadeMask(fadeWidth: Self.edgeFadeWidth))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }

    private var peekTrack: Track? {
        if dragOffset < 0 { return audioPlayer.peekNextTrack }
        if dragOffset > 0 { return audioPlayer.peekPreviousTrack }
        return nil
    }

    private func trackText(track: Track?, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track?.displayTitle ?? "")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.edgeFadeWidth)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isCommitting else { return }
                if dragAxisIsHorizontal == nil,
                   max(abs(value.translation.width), abs(value.translation.height)) > Self.axisLockDistance {
                    dragAxisIsHorizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                guard dragAxisIsHorizontal == true else { return }
                dragOffset = resistedOffset(for: value.translation.width)
            }
            .onEnded { value in
                defer { dragAxisIsHorizontal = nil }
                guard dragAxisIsHorizontal == true, !isCommitting else { return }
                let width = value.translation.width
                let velocity = value.velocity.width
                let isFlick = abs(velocity) > Self.flickVelocity && velocity.sign == width.sign
                let pastThreshold = abs(width) > contentWidth * Self.commitFraction
                let goesNext = width < 0
                let hasTarget = goesNext ? audioPlayer.peekNextTrack != nil : audioPlayer.peekPreviousTrack != nil
                if hasTarget && (isFlick || pastThreshold) {
                    commit(goesNext: goesNext)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
    }

    private func resistedOffset(for translation: CGFloat) -> CGFloat {
        let hasTarget = translation < 0 ? audioPlayer.peekNextTrack != nil : audioPlayer.peekPreviousTrack != nil
        return hasTarget ? translation : translation * Self.rubberBandFactor
    }

    private func commit(goesNext: Bool) {
        isCommitting = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = goesNext ? -contentWidth : contentWidth
        } completion: {
            if goesNext {
                audioPlayer.next()
            } else {
                audioPlayer.skipToPreviousTrack()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dragOffset = 0 }
            isCommitting = false
        }
    }

    private func artworkView(for track: Track?) -> some View {
        Group {
            if let track,
               let image = ArtworkImageCache.shared.image(
                   for: track.id,
                   data: track.artwork,
                   pointSize: 40
               ) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var secondaryLabel: String {
        guard let version = audioPlayer.currentVersion else { return "" }
        var parts = [version.label]
        if version.duration > 0 {
            parts.append(formatDuration(version.duration))
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct EdgeFadeMask: View {
    let fadeWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
        }
    }
}
