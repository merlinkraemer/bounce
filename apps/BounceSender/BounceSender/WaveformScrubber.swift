import SwiftUI
import BounceKit

/// Compact fixed-height waveform bar chart. Handles click and drag to seek.
/// Note markers appear as small dots above the bars.
/// Reads `currentTime` here so parent chrome is not invalidated 5×/s.
struct WaveformScrubber: View {
    let samples: [Float]?
    let duration: TimeInterval
    let noteTimestamps: [TimeInterval]
    var ghostNoteTimestamps: [TimeInterval] = []
    let onSeek: ((TimeInterval) -> Void)?
    var onPositionSelected: ((TimeInterval) -> Void)? = nil
    var playheadTime: TimeInterval? = nil
    var selectedPosition: TimeInterval? = nil

    private let fallbackAmplitude: Float = 0.25
    private let fallbackCount = 60

    var body: some View {
        let currentTime = playheadTime ?? 0

        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            Canvas { context, size in
                if samples == nil {
                    var unavailable = Path()
                    unavailable.move(to: CGPoint(x: 0, y: size.height / 2))
                    unavailable.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(unavailable, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                    return
                }
                let resolvedSamples = resampledSamples(to: barCount(for: width))
                let count = resolvedSamples.count
                guard count > 0 else { return }

                let progress = playheadTime != nil && duration > 0 ? currentTime / duration : 0
                let barW: CGFloat = 2
                let step = (width - barW) / CGFloat(max(count - 1, 1))
                let centerY = size.height / 2

                for (i, sample) in resolvedSamples.enumerated() {
                    let x = CGFloat(i) * step
                    let barH = max(2, CGFloat(sample) * height)
                    let rect = CGRect(x: x, y: centerY - barH / 2, width: barW, height: barH)
                    let barProgress = Double(i) / Double(max(count - 1, 1))
                    let color: Color = barProgress <= progress
                        ? .primary
                        : .secondary.opacity(0.3)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }

                let dotRadius: CGFloat = 1.5
                let dotY: CGFloat = dotRadius + 0.5
                for ts in ghostNoteTimestamps {
                    guard duration > 0 else { continue }
                    let x = CGFloat(ts / duration) * (width - barW) + barW / 2
                    let dotRect = CGRect(x: x - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.orange.opacity(0.25)))
                }
                for ts in noteTimestamps {
                    guard duration > 0 else { continue }
                    let x = CGFloat(ts / duration) * (width - barW) + barW / 2
                    let dotRect = CGRect(x: x - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.orange))
                }

                if let selectedPosition, duration > 0 {
                    let x = CGFloat(selectedPosition / duration) * (width - barW) + barW / 2
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(marker, with: .color(.orange), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = seekTime(for: value.location.x, width: width)
                        if let onPositionSelected {
                            onPositionSelected(time)
                        } else {
                            onSeek?(time)
                        }
                    }
                    .onEnded { value in
                        let time = seekTime(for: value.location.x, width: width)
                        if let onPositionSelected {
                            onPositionSelected(time)
                        } else {
                            onSeek?(time)
                        }
                    }
            )
        }
    }

    private func barCount(for width: CGFloat) -> Int {
        max(4, Int(width / 3))
    }

    private func resampledSamples(to targetCount: Int) -> [Float] {
        let source: [Float] = {
            guard let s = samples, !s.isEmpty else {
                return Array(repeating: fallbackAmplitude, count: fallbackCount)
            }
            return s
        }()
        guard source.count != targetCount else { return source }
        return (0..<targetCount).map { index in
            let start = Int((Double(index) / Double(targetCount)) * Double(source.count))
            let end   = Int((Double(index + 1) / Double(targetCount)) * Double(source.count))
            let lo = min(start, source.count - 1)
            let hi = min(max(start + 1, end), source.count)
            return source[lo..<hi].max() ?? source[lo]
        }
    }

    private func seekTime(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard duration > 0, width > 0 else { return 0 }
        return max(0, min(duration, (x / width) * duration))
    }
}
