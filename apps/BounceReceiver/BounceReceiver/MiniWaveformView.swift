import SwiftUI
import BounceKit
import UIKit

struct MiniWaveformView: View {
    let waveformData: Data?
    let duration: TimeInterval
    let versionID: UUID
    let audioPlayer: AudioPlayer
    let onSeek: (TimeInterval) -> Void

    @State private var dragDirectionLocked: Bool = false
    @State private var isHorizontalDrag: Bool = false
    @State private var frameTick: Int = 0
    @State private var unplayedBars: CGImage?
    @State private var playedBars: CGImage?
    /// Matches the pixel scale used when rasterizing fitted bars (retina).
    @State private var rasterScale: CGFloat = 1
    // Bumped on every refresh; a stale background raster (older generation)
    // that finishes after a newer one is discarded instead of overwriting.
    @State private var rasterGeneration: Int = 0
    // Frozen playhead while the fullscreen player is collapsed.
    @State private var frozenTime: TimeInterval = 0

    var body: some View {
        GeometryReader { geo in
            let viewWidth = geo.size.width
            let viewHeight = geo.size.height
            let _ = frameTick

            let now = audioPlayer.showFullScreenPlayer
                ? audioPlayer.playbackClock.time
                : frozenTime
            let playedX = duration > 0
                ? CGFloat(now / duration) * viewWidth
                : 0

            ZStack(alignment: .leading) {
                if waveformData?.isEmpty ?? true {
                    WaveformLoadingPlaceholder(barWidth: 2, barSpacing: 1)
                        .frame(width: viewWidth, height: viewHeight)
                }
                Canvas { context, size in
                    if let unplayed = unplayedBars, let played = playedBars {
                        let barSize = CGSize(width: size.width, height: size.height)
                        let unplayedImg = Image(decorative: unplayed, scale: rasterScale)
                        let playedImg = Image(decorative: played, scale: rasterScale)
                        context.draw(unplayedImg, in: CGRect(origin: .zero, size: barSize))
                        context.drawLayer { layer in
                            layer.clip(to: Path(CGRect(x: 0, y: 0, width: max(0, playedX), height: size.height)))
                            layer.draw(playedImg, in: CGRect(origin: .zero, size: barSize))
                        }
                    }
                }
                .frame(width: viewWidth, height: viewHeight)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1.5, height: viewHeight)
                    .offset(x: max(0, playedX - 0.75))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // simultaneousGesture so vertical drags scroll/dismiss the sheet
            // instead of being swallowed; seek only acts on horizontal motion.
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
                        guard duration > 0 else { return }
                        let fraction = max(0, min(1, Double(value.location.x / viewWidth)))
                        let scrubTime = fraction * duration
                        audioPlayer.isScrubbing = true
                        audioPlayer.playbackClock.time = scrubTime
                        audioPlayer.displayTime = scrubTime
                    }
                    .onEnded { value in
                        let wasHorizontal = isHorizontalDrag
                        dragDirectionLocked = false
                        isHorizontalDrag = false
                        guard wasHorizontal, duration > 0 else {
                            audioPlayer.isScrubbing = false
                            return
                        }
                        let fraction = max(0, min(1, Double(value.location.x / viewWidth)))
                        onSeek(fraction * duration)
                        audioPlayer.isScrubbing = false
                    }
            )
            .background(DisplayLinkUpdater(
                frameTick: $frameTick,
                isActive: audioPlayer.showFullScreenPlayer
                    && (audioPlayer.isPlaying || audioPlayer.isScrubbing)
            ))
            .onChange(of: waveformData, initial: true) { _, _ in
                refreshRaster(width: viewWidth, height: viewHeight)
            }
            .onChange(of: versionID) { _, _ in
                refreshRaster(width: viewWidth, height: viewHeight)
            }
            .onChange(of: viewWidth) { _, w in
                refreshRaster(width: w, height: viewHeight)
            }
            .onChange(of: viewHeight) { _, h in
                refreshRaster(width: viewWidth, height: h)
            }
            // Bar pitch + count are duration-dependent. PlayerView seeds the
            // model's duration as a fallback, but re-raster when the live
            // AVPlayerItem duration replaces it (or a legacy row reports 0).
            .onChange(of: duration) { _, _ in
                refreshRaster(width: viewWidth, height: viewHeight)
            }
            .onChange(of: audioPlayer.showFullScreenPlayer) { _, expanded in
                if !expanded { frozenTime = audioPlayer.playbackClock.time }
            }
        }
    }

    // Decode + rasterize off the main thread. Doing this synchronously on
    // `.onChange(of: versionID)` was the start-of-track stutter: fitted mini
    // bars depend on runtime view width/height so they always missed the
    // prewarm cache and paid full decode+draw cost on the main actor right as
    // a new track loaded. The cache is lock-protected and safe to hit from a
    // background task; results are assigned back on the main actor.
    private func refreshRaster(width: CGFloat, height: CGFloat) {
        guard width > 1, height > 1 else { return }
        rasterGeneration &+= 1
        let generation = rasterGeneration
        let versionID = versionID
        let data = waveformData
        let duration = duration
        // Capture on the main actor — UIScreen from a detached task is unsafe.
        let scale = UIScreen.main.scale
        Task.detached(priority: .userInitiated) {
            // Main-style packing (3+1) + mean+contrast height texture. Retina
            // scale keeps rounded caps crisp; 1x bitmaps looked soft/blurry.
            let metrics = WaveformSampleCache.overviewMetrics(forDuration: duration)
            let targetCount = metrics.barCount(width)
            let samples = WaveformSampleCache.shared.overviewSamples(
                for: versionID,
                data: data,
                targetCount: targetCount
            )
            let unplayed = WaveformSampleCache.shared.fittedBarImage(
                versionID: versionID,
                data: data,
                samples: samples,
                width: width,
                height: height,
                played: false,
                playedOpacity: 0.15,
                metrics: metrics,
                scale: scale
            )
            let played = WaveformSampleCache.shared.fittedBarImage(
                versionID: versionID,
                data: data,
                samples: samples,
                width: width,
                height: height,
                played: true,
                playedOpacity: 0.85,
                metrics: metrics,
                scale: scale
            )
            await MainActor.run {
                // Ignore results superseded by a newer refresh.
                guard generation == rasterGeneration else { return }
                unplayedBars = unplayed
                playedBars = played
                rasterScale = scale
            }
        }
    }
}
