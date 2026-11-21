import SwiftUI

struct WaveformLoadingPlaceholder: View {
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 1
    var bottomInset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 2.4
            Canvas { context, size in
                let availableHeight = max(1, size.height - bottomInset)
                let midY = availableHeight / 2
                let pitch = barWidth + barSpacing
                let count = Int(size.width / pitch) + 1
                for i in 0..<count {
                    let wave = 0.5 + 0.5 * sin(Double(i) * 0.28 - phase)
                    let h = max(2, CGFloat(0.12 + 0.28 * wave) * availableHeight)
                    let rect = CGRect(x: CGFloat(i) * pitch, y: midY - h / 2, width: barWidth, height: h)
                    context.fill(Path(rect), with: .color(.white.opacity(0.08 + 0.1 * wave)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Loading waveform")
    }
}
