import SwiftUI
import BounceKit

struct VoiceMemoNoteRow: View {
    let note: Note
    let isCurrentMemo: Bool
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isAvailable: Bool
    let onTogglePlayback: () -> Void
    let onPrepareSeek: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onSeekToTrackTime: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            playButton

            VStack(alignment: .leading, spacing: 6) {
                InlineNoteWaveform(
                    seed: note.id,
                    progress: progress,
                    isActive: isCurrentMemo && isAvailable,
                    tint: .white.opacity(isAvailable ? 1.0 : 0.4),
                    inactiveTint: .white.opacity(0.18),
                    onScrub: { fraction in
                        if isCurrentMemo {
                            onSeek(fraction * displayDuration)
                        } else {
                            onPrepareSeek()
                        }
                    }
                )

                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var playButton: some View {
        Button(action: onTogglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.headline)
                .foregroundStyle(.white.opacity(isAvailable ? 1.0 : 0.4))
                .frame(width: 40, height: 40)
                .background(.white.opacity(isAvailable ? 0.16 : 0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
                .monospacedDigit()

            if let timestamp = note.timestamp {
                Button(action: onSeekToTrackTime) {
                    Text(formatTime(timestamp))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if !isAvailable {
                Text("Unavailable")
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
    }

    private var timeLabel: String {
        if isCurrentMemo && isPlaying {
            let remaining = max(0, displayDuration - currentTime)
            return "-\(formatTime(remaining))"
        }
        return formatTime(displayDuration)
    }

    private var displayDuration: TimeInterval {
        max(max(duration, note.voiceDuration ?? 0), 0.1)
    }

    private var progress: Double {
        guard isCurrentMemo, displayDuration > 0 else { return 0 }
        return currentTime / displayDuration
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
