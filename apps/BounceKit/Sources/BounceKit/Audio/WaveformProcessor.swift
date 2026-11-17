import Foundation
import AVFoundation

/// Shared sizing rules for stored waveform peaks and UI resampling.
public enum WaveformMetrics {
    /// Classic Bounce density: 300 peaks ≈ 3 minutes.
    public static let targetSecondsPerPeak: Double = 1.0
    public static let minPeakCount = 300
    /// Caps main-scrubber raster memory (~width × height RGBA × 2).
    public static let maxPeakCount = 2400

    public static func peakCount(forDuration duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return minPeakCount }
        let computed = Int((duration / targetSecondsPerPeak).rounded(.up))
        return min(maxPeakCount, max(minPeakCount, computed))
    }

    public static func floatCount(in data: Data?) -> Int {
        guard let data, !data.isEmpty else { return 0 }
        return data.count / MemoryLayout<Float>.size
    }

    /// Legacy blobs are fixed at ~300 peaks; long sets need a denser encode.
    public static func needsDenserWaveform(sampleCount: Int, duration: TimeInterval) -> Bool {
        let desired = peakCount(forDuration: duration)
        return sampleCount < max(1, desired / 2)
    }
}

public actor WaveformProcessor {
    /// Max frames per `AVAudioFile` read. Stereo float32 ≈ 8 MB vs full-file PCM (~100 MB+).
    private static let readChunkFrames: AVAudioFrameCount = 1_000_000

    public init() {}

    /// Builds a normalized RMS peak blob. When `sampleCount` is omitted, density
    /// scales with duration so 90‑minute sets stay readable in overview/scrubber.
    public func process(fileURL: URL, sampleCount: Int? = nil) async throws -> Data {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat
        let totalFrames = Int(audioFile.length)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
        let duration = Double(totalFrames) / sampleRate
        let resolvedCount = sampleCount ?? WaveformMetrics.peakCount(forDuration: duration)

        guard totalFrames > 0 else {
            let silent = Array(repeating: Float(0.1), count: resolvedCount)
            return silent.withUnsafeBytes { Data($0) }
        }

        let channelCount = Int(format.channelCount)
        let framesPerBucket = max(1, totalFrames / resolvedCount)

        var sumOfSquares = [Float](repeating: 0, count: resolvedCount)
        var sampleCounts = [Int](repeating: 0, count: resolvedCount)

        let chunkCapacity = min(Self.readChunkFrames, AVAudioFrameCount(totalFrames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            throw WaveformError.bufferAllocationFailed
        }

        var absoluteFrame = 0
        while absoluteFrame < totalFrames {
            let remaining = AVAudioFrameCount(totalFrames - absoluteFrame)
            let framesToRead = min(chunkCapacity, remaining)
            try audioFile.read(into: buffer, frameCount: framesToRead)

            guard let floatChannelData = buffer.floatChannelData else {
                throw WaveformError.noChannelData
            }

            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }

            for localFrame in 0..<framesRead {
                let frameIndex = absoluteFrame + localFrame
                let bucket = frameIndex / framesPerBucket
                if bucket >= resolvedCount { break }

                for channel in 0..<channelCount {
                    let sample = floatChannelData[channel][localFrame]
                    sumOfSquares[bucket] += sample * sample
                    sampleCounts[bucket] += 1
                }
            }

            absoluteFrame += framesRead
        }

        // Same shape as the old full-buffer path: one RMS per bucket while
        // `startFrame < totalFrames` (short files may return fewer than sampleCount).
        var amplitudes = [Float]()
        amplitudes.reserveCapacity(resolvedCount)
        for bucket in 0..<resolvedCount {
            let startFrame = bucket * framesPerBucket
            if startFrame >= totalFrames { break }

            let count = sampleCounts[bucket]
            let rms: Float = count > 0 ? sqrt(sumOfSquares[bucket] / Float(count)) : 0
            amplitudes.append(min(1.0, rms))
        }

        let maxAmp = amplitudes.max() ?? 1.0
        if maxAmp > 0 {
            amplitudes = amplitudes.map { $0 / maxAmp }
        }

        return amplitudes.withUnsafeBytes { Data($0) }
    }
}

public enum WaveformError: Error, LocalizedError {
    case bufferAllocationFailed
    case noChannelData

    public var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Failed to allocate audio buffer"
        case .noChannelData: return "No channel data in audio file"
        }
    }
}
