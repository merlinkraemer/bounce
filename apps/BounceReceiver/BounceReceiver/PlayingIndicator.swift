import SwiftUI

/// Three-bar equalizer indicator. Bars animate to random heights while
/// `isPlaying` is true and settle to a flat baseline when not.
///
/// TimelineView only runs while playing — a permanent 0.18s timer on every
/// current-track row was a steady heat source while browsing with playback.
struct PlayingIndicator: View {
    let isPlaying: Bool
    var barCount: Int = 3
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 12
    var minHeight: CGFloat = 2

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.periodic(from: .now, by: 0.18)) { context in
                    bars(at: context.date)
                }
            } else {
                bars(at: .distantPast)
            }
        }
        .frame(
            width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing,
            height: maxHeight,
            alignment: .bottom
        )
    }

    private func bars(at date: Date) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(.tint)
                    .frame(width: barWidth, height: targetHeight(for: i, at: date))
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
    }

    private func targetHeight(for index: Int, at date: Date) -> CGFloat {
        guard isPlaying else { return minHeight }
        var hasher = Hasher()
        hasher.combine(Int(date.timeIntervalSinceReferenceDate * 10))
        hasher.combine(index)
        let h = abs(hasher.finalize()) % 100
        return minHeight + CGFloat(h) / 100.0 * (maxHeight - minHeight)
    }
}
