import SwiftUI

struct InlineNoteWaveform: View {
    let seed: UUID
    let progress: Double
    let isActive: Bool
    let tint: Color
    let inactiveTint: Color
    let onScrub: (Double) -> Void

    var height: CGFloat = 28
    var barWidth: CGFloat = 2.5
    var barSpacing: CGFloat = 2

    @State private var dragDirectionLocked = false
    @State private var isHorizontalDrag = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let bars = generateBars(count: barCount(for: width))
            let playedX = CGFloat(progress.clamped01) * width
            let playheadDiameter: CGFloat = isActive ? 9 : 0

            Canvas { context, size in
                let halfH = size.height / 2
                let unit = size.width / CGFloat(bars.count)

                for (i, sample) in bars.enumerated() {
                    let x = CGFloat(i) * unit
                    let h = max(2, CGFloat(sample) * size.height)
                    let rect = CGRect(
                        x: x,
                        y: halfH - h / 2,
                        width: barWidth,
                        height: h
                    )
                    let color = x < playedX ? tint : inactiveTint
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
            .overlay(alignment: .leading) {
                if isActive {
                    Circle()
                        .fill(tint)
                        .frame(width: playheadDiameter, height: playheadDiameter)
                        .offset(x: playedX - playheadDiameter / 2)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            // Only attach a gesture while the memo is loaded; otherwise the
            // waveform must let touches fall through to the enclosing scroll
            // view so vertical scrolling works through the row.
            .gesture(isActive ? scrubGesture(width: width) : nil)
        }
        .frame(height: height)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !dragDirectionLocked {
                    let absX = abs(value.translation.width)
                    let absY = abs(value.translation.height)
                    if absX > 8 || absY > 8 {
                        dragDirectionLocked = true
                        isHorizontalDrag = absX > absY
                    }
                    if !isHorizontalDrag { return }
                }
                guard isHorizontalDrag, width > 0 else { return }
                let fraction = max(0, min(1, Double(value.location.x / width)))
                onScrub(fraction)
            }
            .onEnded { _ in
                dragDirectionLocked = false
                isHorizontalDrag = false
            }
    }

    private func barCount(for width: CGFloat) -> Int {
        let unit = barWidth + barSpacing
        return max(8, Int(width / unit))
    }

    private func generateBars(count: Int) -> [Float] {
        var generator = SeededGenerator(seed: seed.uuidString.hashValue)
        return (0..<count).map { i in
            let envelope = sin(Double(i) / Double(count) * .pi)
            let jitter = Double.random(in: 0.25...1.0, using: &generator)
            let value = 0.18 + envelope * jitter * 0.78
            return Float(max(0.12, min(1.0, value)))
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        self.state = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
        if state == 0 { state = 0xDEADBEEFCAFEBABE }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private extension Double {
    var clamped01: Double { max(0, min(1, self)) }
}
