import UIKit
import CoreGraphics
import BounceKit

/// Decodes + downsamples waveform blobs once, and optionally rasterizes bar
/// images so the fullscreen player doesn't pay decode/draw cost on first open
/// or on every display frame.
final class WaveformSampleCache {
    static let shared = WaveformSampleCache()

    static let mainTargetCount = WaveformMetrics.minPeakCount
    /// Fallback when width/duration are unknown (prewarm).
    static let miniTargetCount = 48

    /// Match main scrubber packing: 3pt bars + 1pt gaps.
    private static let overviewPitch: CGFloat = 4
    private static let overviewBarWidth: CGFloat = 3

    struct OverviewMetrics: Equatable {
        let pitch: CGFloat
        let barWidth: CGFloat

        var barCount: (CGFloat) -> Int {
            { width in max(4, Int(width / pitch)) }
        }
    }

    /// Mini overview packing matches the main scrubber (3+1). Height texture for
    /// long sets comes from mean+contrast downsample, not fatter bars.
    static func overviewMetrics(forDuration duration: TimeInterval) -> OverviewMetrics {
        _ = duration
        return OverviewMetrics(pitch: overviewPitch, barWidth: overviewBarWidth)
    }

    static func fittedBarCount(forWidth width: CGFloat, duration: TimeInterval) -> Int {
        overviewMetrics(forDuration: duration).barCount(width)
    }

    static func fittedBarCount(forWidth width: CGFloat) -> Int {
        fittedBarCount(forWidth: width, duration: 0)
    }

    static let fittedBarPitch: CGFloat = overviewPitch
    static let fittedBarWidth: CGFloat = overviewBarWidth

    /// Main scrubber uses the stored peak count (duration-scaled), not a fixed 300.
    static func mainBarCount(for data: Data?) -> Int {
        let raw = WaveformMetrics.floatCount(in: data)
        guard raw > 0 else { return mainTargetCount }
        return min(WaveformMetrics.maxPeakCount, raw)
    }

    private struct SampleKey: Hashable {
        let versionID: UUID
        let byteCount: Int
        let targetCount: Int
        /// 0 = peak/mean (scrubber), 1 = envelope (mini overview).
        let mode: Int
    }

    private struct ImageKey: Hashable {
        let versionID: UUID
        let byteCount: Int
        let targetCount: Int
        let width: Int
        let height: Int
        let played: Bool
        let opacityBits: Int
        /// Distinguishes main vs fitted rasters that share dimensions.
        let style: Int
        let barWidthBits: Int
        /// Pixel scale used for the raster; main and mini rasters may use
        /// different bounded scales.
        let scaleBits: Int
    }

    private var samples: [SampleKey: [Float]] = [:]
    private var images: [ImageKey: CGImage] = [:]
    private let lock = NSLock()
    private let maxSampleEntries = 24
    /// Keep this small — each main waveform raster is ~width×height RGBA.
    private let maxImageEntries = 16

    func samples(
        for versionID: UUID,
        data: Data?,
        targetCount: Int
    ) -> [Float] {
        samples(for: versionID, data: data, targetCount: targetCount, mode: .peakMean)
    }

    /// Mini overview decode: mean level per bucket. The fitted renderer's
    /// contrast stretch then maps the narrow loudness range of a continuous
    /// DJ set (~0.4–0.9 of the stored RMS peaks) onto full bar height, so the
    /// strip reads as the set's energy arc — drops tall, breakdowns short.
    func overviewSamples(
        for versionID: UUID,
        data: Data?,
        targetCount: Int
    ) -> [Float] {
        samples(for: versionID, data: data, targetCount: targetCount, mode: .overviewMean)
    }

    private enum DownsampleMode: Int {
        case peakMean = 0
        case overviewMean = 1
    }

    private func samples(
        for versionID: UUID,
        data: Data?,
        targetCount: Int,
        mode: DownsampleMode
    ) -> [Float] {
        let key = SampleKey(
            versionID: versionID,
            byteCount: data?.count ?? 0,
            targetCount: targetCount,
            mode: mode.rawValue
        )

        lock.lock()
        if let cached = samples[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let decoded = Self.decodeSamples(data: data, targetCount: targetCount, mode: mode)

        lock.lock()
        if samples.count >= maxSampleEntries { samples.removeAll(keepingCapacity: true) }
        samples[key] = decoded
        lock.unlock()

        return decoded
    }

    /// Pre-decode common sizes (and rasterize main waveform) off the expand path.
    func prewarm(versionID: UUID, data: Data?) {
        let dataCopy = data
        let mainCount = Self.mainBarCount(for: dataCopy)
        _ = samples(for: versionID, data: dataCopy, targetCount: mainCount)
        _ = overviewSamples(for: versionID, data: dataCopy, targetCount: Self.miniTargetCount)
        // Typical fullscreen waveform height (PlayerWaveformStack frame).
        // Render at 1x pixel scale to keep prewarm memory bounded.
        // Skip huge rasters during prewarm — WaveformView builds them on demand.
        guard mainCount <= 900 else { return }
        _ = barImage(
            versionID: versionID,
            data: dataCopy,
            targetCount: mainCount,
            height: 240,
            played: false
        )
        _ = barImage(
            versionID: versionID,
            data: dataCopy,
            targetCount: mainCount,
            height: 240,
            played: true
        )
    }

    func barImage(
        versionID: UUID,
        data: Data?,
        targetCount: Int,
        height: CGFloat,
        played: Bool,
        scale: CGFloat = 1
    ) -> CGImage? {
        let decoded = samples(for: versionID, data: data, targetCount: targetCount)
        return barImage(
            versionID: versionID,
            data: data,
            samples: decoded,
            height: height,
            played: played,
            scale: scale
        )
    }

    func barImage(
        versionID: UUID,
        data: Data?,
        samples: [Float],
        height: CGFloat,
        played: Bool,
        scale: CGFloat = 1
    ) -> CGImage? {
        let width = CGFloat(samples.count) * (Self.barWidth + Self.barSpacing)
        return rasterImage(
            versionID: versionID,
            data: data,
            samples: samples,
            width: width,
            height: height,
            played: played,
            opacity: played ? 1.0 : 0.15,
            style: .main,
            barWidth: Self.barWidth,
            scale: max(1, scale)
        )
    }

    /// Mini overview: leading-aligned fixed-pitch bars across the view width.
    /// Renders at `scale` (screen scale) so Canvas doesn't upscale a soft 1x bitmap.
    func fittedBarImage(
        versionID: UUID,
        data: Data?,
        samples: [Float],
        width: CGFloat,
        height: CGFloat,
        played: Bool,
        playedOpacity: CGFloat,
        metrics: OverviewMetrics,
        scale: CGFloat
    ) -> CGImage? {
        rasterImage(
            versionID: versionID,
            data: data,
            samples: samples,
            width: width,
            height: height,
            played: played,
            opacity: playedOpacity,
            style: .fitted(metrics),
            barWidth: metrics.barWidth,
            scale: max(1, scale)
        )
    }

    private enum BarStyle {
        case main
        case fitted(OverviewMetrics)

        var cacheTag: Int {
            switch self {
            case .main: return 0
            case .fitted: return 1
            }
        }
    }

    private func rasterImage(
        versionID: UUID,
        data: Data?,
        samples: [Float],
        width: CGFloat,
        height: CGFloat,
        played: Bool,
        opacity: CGFloat,
        style: BarStyle,
        barWidth: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let widthPx = max(1, Int(width.rounded()))
        let heightPx = max(1, Int(height.rounded()))
        let scaleBits = Int((scale * 100).rounded())
        let key = ImageKey(
            versionID: versionID,
            byteCount: data?.count ?? 0,
            targetCount: samples.count,
            width: widthPx,
            height: heightPx,
            played: played,
            opacityBits: Int((opacity * 1000).rounded()),
            style: style.cacheTag,
            barWidthBits: Int((barWidth * 100).rounded()),
            scaleBits: scaleBits
        )

        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let image = Self.renderBars(
            samples: samples,
            width: CGFloat(widthPx),
            height: CGFloat(heightPx),
            opacity: opacity,
            style: style,
            scale: scale
        ) else {
            return nil
        }

        lock.lock()
        if images.count >= maxImageEntries {
            // Drop half so we don't thrash every insert after the cap.
            let keys = Array(images.keys.prefix(images.count / 2))
            for k in keys { images.removeValue(forKey: k) }
        }
        images[key] = image
        lock.unlock()
        return image
    }

    private static func decodeSamples(
        data: Data?,
        targetCount: Int,
        mode: DownsampleMode
    ) -> [Float] {
        guard let data,
              data.count >= MemoryLayout<Float>.size else {
            return Array(repeating: 0.3, count: targetCount)
        }
        let raw = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !raw.isEmpty else { return Array(repeating: 0.3, count: targetCount) }
        if raw.count == targetCount { return raw }
        // Downsample for overview / collapse.
        if targetCount < raw.count {
            let reduction = Double(raw.count) / Double(targetCount)
            return (0..<targetCount).map { index in
                let start = Int((Double(index) / Double(targetCount)) * Double(raw.count))
                let end = Int((Double(index + 1) / Double(targetCount)) * Double(raw.count))
                let lo = min(start, raw.count - 1)
                let hi = min(max(start + 1, end), raw.count)
                let slice = raw[lo..<hi]
                guard !slice.isEmpty else { return raw[lo] }

                switch mode {
                case .overviewMean:
                    // Mean level per bucket, stretched at render time. A max−min
                    // "envelope" was tried here and reads as noise on continuous
                    // sets: uniformly loud buckets score near zero while buckets
                    // spanning a transition spike — the structure inverts.
                    return slice.reduce(0, +) / Float(slice.count)
                case .peakMean:
                    // Prefer mean once each destination bar covers multiple source
                    // peaks — stops legacy 300-peak long sets from painting a wall
                    // while dense regen is still running.
                    if reduction >= 2.5 {
                        return slice.reduce(0, +) / Float(slice.count)
                    }
                    return slice.max() ?? raw[lo]
                }
            }
        }
        // Upsample: linear interpolation between neighboring source samples.
        if targetCount == 1 {
            return [raw.max() ?? raw[0]]
        }
        return (0..<targetCount).map { i in
            let srcIdx = Double(i) * Double(raw.count - 1) / Double(targetCount - 1)
            let lo = Int(srcIdx)
            let hi = min(lo + 1, raw.count - 1)
            let frac = Float(srcIdx - Double(lo))
            return raw[lo] * (1 - frac) + raw[hi] * frac
        }
    }

    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 1

    /// Map overview samples into a fuller 0…1 range while preserving relative shape.
    /// Quiet floors stay above ~0.08 so silence doesn't disappear.
    private static func contrastStretched(_ samples: [Float]) -> [Float] {
        guard samples.count > 1,
              let lo = samples.min(),
              let hi = samples.max(),
              hi > lo + 0.02 else {
            return samples
        }
        let range = hi - lo
        return samples.map { sample in
            let normalized = (sample - lo) / range
            return 0.08 + normalized * 0.92
        }
    }

    private static func renderBars(
        samples: [Float],
        width: CGFloat,
        height: CGFloat,
        opacity: CGFloat,
        style: BarStyle,
        scale: CGFloat
    ) -> CGImage? {
        let count = samples.count
        guard count > 0, height > 0, width > 0 else { return nil }

        // Main and mini rasters choose their scale at the call site. The main
        // waveform bounds scale for long sets to avoid a full retina timeline
        // allocation, while the small mini overview can remain screen-sharp.
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let uiImage = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.withAlphaComponent(opacity).cgColor)

            switch style {
            case .main:
                let availableHeight = height - 20
                let halfH = availableHeight / 2
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * (barWidth + barSpacing)
                    let displaySample = sqrt(max(0.02, sample))
                    let barHeight = max(2, CGFloat(displaySample) * availableHeight)
                    let rect = CGRect(
                        x: x,
                        y: halfH - barHeight / 2,
                        width: barWidth,
                        height: barHeight
                    )
                    cg.fill(rect)
                }
            case .fitted(let metrics):
                // Leading-aligned fixed pitch — leftover space stays on the right
                // so bar gaps stay constant and seek still maps full duration.
                let barW = metrics.barWidth
                let pitch = metrics.pitch
                let halfH = height / 2
                let display = contrastStretched(samples)
                for (i, sample) in display.enumerated() {
                    let x = CGFloat(i) * pitch
                    // Soft floor only — sqrt re-compresses the stretched range
                    // (0.4–0.9 means all land above 0.63) back into a brick wall.
                    let displaySample = max(0.08, min(1, sample))
                    let barHeight = max(2, CGFloat(displaySample) * height * 0.9)
                    let rect = CGRect(
                        x: x,
                        y: halfH - barHeight / 2,
                        width: barW,
                        height: barHeight
                    )
                    // Pill caps match memo / “rounded” waveform look.
                    let radius = min(barW, barHeight) / 2
                    let path = CGPath(
                        roundedRect: rect,
                        cornerWidth: radius,
                        cornerHeight: radius,
                        transform: nil
                    )
                    cg.addPath(path)
                    cg.fillPath()
                }
            }
        }
        return uiImage.cgImage
    }
}
