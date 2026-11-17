import SwiftUI
import BounceKit
import UIKit

// MARK: - Display Link Updater

/// Drives SwiftUI redraws at screen refresh rate, even during UIScrollView
/// tracking. `TimelineView(.animation)` pauses in `UITrackingRunLoopMode`,
/// but a CADisplayLink registered in `.common` keeps firing.
struct DisplayLinkUpdater: UIViewRepresentable {
    /// Binds to a @State var that increments each frame — any view reading
    /// it will be re-evaluated.
    @Binding var frameTick: Int
    /// When false, the display link is paused so we don't force 60fps redraws
    /// while nothing is moving (paused + not scrubbing). This is the main
    /// idle-CPU/heat guard for the player.
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        let link = CADisplayLink(target: context.coordinator, selector: #selector(Coordinator.tick))
        link.add(to: .main, forMode: .common)
        link.isPaused = !isActive
        context.coordinator.link = link
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.binding = $frameTick
        context.coordinator.link?.isPaused = !isActive
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.link?.invalidate()
        coordinator.link = nil
    }

    final class Coordinator {
        weak var link: CADisplayLink?
        var binding: Binding<Int>?

        @objc func tick() {
            binding?.wrappedValue += 1
        }
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let waveformData: Data?
    let duration: TimeInterval
    let versionID: UUID
    let audioPlayer: AudioPlayer
    let onSeek: (TimeInterval) -> Void
    var notes: [Note] = []

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 1

    @State private var dragOffset: CGFloat = 0
    @State private var scrubBaseTime: TimeInterval = 0
    @State private var scrubStarted: Bool = false
    @State private var dragDirectionLocked: Bool = false
    @State private var isHorizontalDrag: Bool = false
    /// Incremented every frame by DisplayLinkUpdater — forces redraw even
    /// while the enclosing UIScrollView is tracking a touch.
    @State private var frameTick: Int = 0

    @State private var cachedSamples: [Float] = []
    @State private var unplayedBars: CGImage?
    @State private var playedBars: CGImage?
    /// Main rasters use a bounded pixel scale: short mixes get native retina
    /// sharpness, while long sets avoid allocating a full 3x timeline texture.
    @State private var rasterScale: CGFloat = 1
    @State private var rasterGeneration: Int = 0
    /// Note markers + time labels stay out of the per-frame Canvas path.
    @State private var markerTimes: [TimeInterval] = []
    @State private var labelTimes: [TimeInterval] = []
    // Playhead time to draw while the player is collapsed off-screen.
    @State private var frozenTime: TimeInterval = 0
    private var totalWidth: CGFloat { CGFloat(cachedSamples.count) * (barWidth + barSpacing) }

    private func timeToX(_ time: TimeInterval, totalW: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * totalW
    }

    var body: some View {
        GeometryReader { geo in
            let viewWidth = geo.size.width
            let viewHeight = geo.size.height
            let totalW = totalWidth
            let barHeight = max(1, viewHeight)

            // Read frameTick so this view re-evaluates every display frame
            let _ = frameTick

            // Poll the non-observable clock — never read audioPlayer.displayTime
            // here (that used to register a 60 fps @Observable dependency).
            let now: TimeInterval = scrubStarted
                ? max(0, min(duration, scrubBaseTime - Double(dragOffset) * duration / Double(max(totalW, 1))))
                : (audioPlayer.showFullScreenPlayer ? audioPlayer.playbackClock.time : frozenTime)

            ZStack {
                Canvas { context, size in
                    let availableHeight = size.height - 20
                    let tx = viewWidth / 2 - timeToX(now, totalW: totalW)
                    let playedX = timeToX(now, totalW: totalW)

                    // Bars in their own layer so the played-region clip doesn't
                    // swallow note markers / time labels below.
                    context.drawLayer { bars in
                        bars.translateBy(x: tx, y: 0)
                        if let unplayed = unplayedBars, let played = playedBars {
                            let barSize = CGSize(width: totalW, height: size.height)
                            let unplayedImg = Image(decorative: unplayed, scale: rasterScale)
                            let playedImg = Image(decorative: played, scale: rasterScale)
                            bars.draw(unplayedImg, in: CGRect(origin: .zero, size: barSize))
                            bars.clip(to: Path(CGRect(x: 0, y: 0, width: max(0, playedX), height: size.height)))
                            bars.draw(playedImg, in: CGRect(origin: .zero, size: barSize))
                        } else {
                            // Long timelines stay vector-backed. A single wide
                            // bitmap is filtered by Canvas as it moves under the
                            // playhead, especially when its pixel scale is
                            // bounded below the device scale. Draw only the
                            // bars that can be visible in this frame instead.
                            let halfH = availableHeight / 2
                            let pitch = barWidth + barSpacing
                            let firstBar = max(0, Int(floor(-tx / pitch)) - 1)
                            let lastBar = min(
                                cachedSamples.count,
                                Int(ceil((viewWidth - tx) / pitch)) + 1
                            )
                            guard firstBar < lastBar else { return }
                            for i in firstBar..<lastBar {
                                let sample = cachedSamples[i]
                                let x = CGFloat(i) * (barWidth + barSpacing)
                                let displaySample = sqrt(max(0.02, sample))
                                let h = max(2, CGFloat(displaySample) * availableHeight)
                                let rect = CGRect(x: x, y: halfH - h / 2, width: barWidth, height: h)
                                bars.fill(
                                    Path(rect),
                                    with: .color(x < playedX ? .white : .white.opacity(0.15))
                                )
                            }
                        }
                    }

                    context.translateBy(x: tx, y: 0)

                    for ts in markerTimes {
                        let nx = timeToX(ts, totalW: totalW)
                        let markerY: CGFloat = 6
                        let markerSize: CGFloat = 5
                        let diamond = Path { p in
                            p.move(to: CGPoint(x: nx, y: markerY - markerSize))
                            p.addLine(to: CGPoint(x: nx + markerSize, y: markerY))
                            p.addLine(to: CGPoint(x: nx, y: markerY + markerSize))
                            p.addLine(to: CGPoint(x: nx - markerSize, y: markerY))
                            p.closeSubpath()
                        }
                        context.fill(diamond, with: .color(.yellow))
                    }

                    for t in labelTimes {
                        var textAttrs = AttributedString(formatTime(t))
                        textAttrs.font = .system(size: 9, design: .monospaced)
                        textAttrs.foregroundColor = .white.opacity(0.3)
                        context.draw(Text(textAttrs), at: CGPoint(x: timeToX(t, totalW: totalW), y: availableHeight + 10))
                    }
                }
                .frame(width: viewWidth, height: viewHeight)
                .contentShape(Rectangle())
                // simultaneousGesture (not gesture) so a vertical drag on the
                // waveform still scrolls/dismisses the sheet — the seek gesture
                // only acts on horizontal motion and ignores vertical, while the
                // enclosing ScrollView ignores horizontal. Plain .gesture would
                // win arbitration and swallow vertical drags (scroll dead-zone).
                .simultaneousGesture(
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
                            guard isHorizontalDrag else { return }

                            if !scrubStarted {
                                scrubBaseTime = audioPlayer.playbackClock.time
                                audioPlayer.isScrubbing = true
                                scrubStarted = true
                            }

                            dragOffset = value.translation.width
                            let offset = Double(dragOffset) * duration / Double(max(totalW, 1))
                            let scrubTime = max(0, min(duration, scrubBaseTime - offset))
                            audioPlayer.playbackClock.time = scrubTime
                            audioPlayer.displayTime = scrubTime
                        }
                        .onEnded { _ in
                            let wasHorizontal = isHorizontalDrag
                            dragDirectionLocked = false
                            isHorizontalDrag = false

                            guard wasHorizontal else {
                                scrubStarted = false
                                dragOffset = 0
                                audioPlayer.isScrubbing = false
                                return
                            }
                            guard abs(dragOffset) > 2 else {
                                scrubStarted = false
                                dragOffset = 0
                                audioPlayer.isScrubbing = false
                                return
                            }
                            let offset = Double(dragOffset) * duration / Double(max(totalW, 1))
                            let seekTo = max(0, min(duration, scrubBaseTime - offset))
                            scrubStarted = false
                            dragOffset = 0
                            onSeek(seekTo)
                            audioPlayer.isScrubbing = false
                        }
                )

                // Playhead line
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1.5, height: viewHeight - 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            .background(DisplayLinkUpdater(
                frameTick: $frameTick,
                isActive: audioPlayer.showFullScreenPlayer
                    && (audioPlayer.isPlaying || audioPlayer.isScrubbing)
            ))
            .onChange(of: waveformData, initial: true) { _, _ in
                refreshWaveform(height: barHeight)
            }
            .onChange(of: versionID) { _, _ in
                refreshWaveform(height: barHeight)
            }
            .onChange(of: viewHeight) { _, newHeight in
                refreshWaveform(height: max(1, newHeight))
            }
            .onChange(of: notes.count) { _, _ in
                refreshMarkers()
            }
            .onChange(of: duration) { _, _ in
                refreshLabels()
            }
            .onChange(of: audioPlayer.showFullScreenPlayer) { _, expanded in
                if !expanded { frozenTime = audioPlayer.playbackClock.time }
            }
        }
    }

    private func refreshWaveform(height: CGFloat) {
        let targetCount = WaveformSampleCache.mainBarCount(for: waveformData)
        let versionID = versionID
        let data = waveformData
        let usesVectorBars = Self.usesVectorBars(for: targetCount)
        let scale = Self.mainRasterScale(for: targetCount)
        rasterGeneration &+= 1
        let generation = rasterGeneration
        unplayedBars = nil
        playedBars = nil

        // Decode and rasterize off the main actor. A 90-minute set can carry
        // thousands of bars; doing this synchronously during sheet expansion
        // was visible as a first-open hitch.
        Task.detached(priority: .userInitiated) {
            let samples = WaveformSampleCache.shared.samples(
                for: versionID,
                data: data,
                targetCount: targetCount
            )
            let unplayed = usesVectorBars ? nil : WaveformSampleCache.shared.barImage(
                versionID: versionID,
                data: data,
                targetCount: targetCount,
                height: height,
                played: false,
                scale: scale
            )
            let played = usesVectorBars ? nil : WaveformSampleCache.shared.barImage(
                versionID: versionID,
                data: data,
                targetCount: targetCount,
                height: height,
                played: true,
                scale: scale
            )

            await MainActor.run {
                guard generation == rasterGeneration else { return }
                cachedSamples = samples
                unplayedBars = unplayed
                playedBars = played
                rasterScale = scale
                refreshMarkers()
                refreshLabels()
            }
        }
    }

    private static func usesVectorBars(for targetCount: Int) -> Bool {
        // A 1,200-bar timeline is already near the practical width limit for
        // a retina bitmap. Keeping longer timelines vector-backed avoids a
        // filtered 1.5x texture without changing the bar density.
        targetCount > 1_200
    }

    private static func mainRasterScale(for targetCount: Int) -> CGFloat {
        let screenScale = UIScreen.main.scale
        switch targetCount {
        case ...600:
            return screenScale
        case ...1_200:
            return min(screenScale, 2)
        default:
            // Kept for the cache API; long-form timelines use vector bars.
            return 1
        }
    }

    private func refreshMarkers() {
        markerTimes = notes.compactMap(\.timestamp).sorted()
    }

    private func refreshLabels() {
        guard duration > 0, totalWidth > 0 else {
            labelTimes = []
            return
        }
        // Scale the interval with duration AND canvas width. A fixed 30s
        // interval on a 90-min set is ~180 labels; with a sparse legacy blob
        // (small totalWidth) they land a few points apart — the "pile of
        // overlapping duration markers" bug. Spacing is measured in canvas
        // points because totalWidth tracks blob density, not view width.
        let minLabelSpacing: CGFloat = 64
        let pointsPerSecond = totalWidth / CGFloat(duration)
        let intervals: [TimeInterval] = [10, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let minInterval: TimeInterval = duration > 60 ? 30 : 10
        let interval = intervals.first {
            $0 >= minInterval && CGFloat($0) * pointsPerSecond >= minLabelSpacing
        } ?? 3600
        let labelCount = Int(duration / interval)
        labelTimes = (0...labelCount).map { TimeInterval($0) * interval }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
