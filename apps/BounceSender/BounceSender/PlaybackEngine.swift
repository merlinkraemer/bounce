import Foundation
import AVFoundation
import SwiftData
import BounceKit

/// Single source of truth for audio playback across all tabs.
/// Owns AVAudioPlayer and exposes state that the TransportBar footer, Col 1, Col 2, and Col 3 all read.
@Observable
@MainActor
final class PlaybackEngine: NSObject {
    // MARK: - Public state (read by views)

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var volume: Float = 1.0

    /// The version currently loaded into the player (may be paused).
    private(set) var loadedVersionID: UUID?

    /// Called when a track finishes playing through to the end (not paused).
    var onPlaybackEnded: (() -> Void)?

    // MARK: - Persistence

    @ObservationIgnored
    private let lastVersionIDKey = BouncePreferenceKey.lastPlayedVersionID

    // MARK: - Private

    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    override init() {
        super.init()
    }

    // MARK: - Public API

    func load(version: Version, play: Bool = true) {
        let url = URL(fileURLWithPath: version.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            SyncLog.player.warning("file not found: \(url.path, privacy: .public)")
            return
        }

        do {
            stop()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.volume = self.volume
            audioPlayer = player
            loadedVersionID = version.id
            currentTime = 0
            duration = player.duration

            // Persist last played version
            UserDefaults.standard.set(version.id.uuidString, forKey: lastVersionIDKey)

            if play {
                player.play()
                isPlaying = true
                startTimer()
            }
        } catch {
            SyncLog.player.error("load error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restore the last played version from UserDefaults without auto-playing.
    /// Call once on launch with access to the model context.
    func restoreLastPlayed(context: ModelContext) {
        guard let uuidString = UserDefaults.standard.string(forKey: lastVersionIDKey),
              let uuid = UUID(uuidString: uuidString) else { return }

        let version = try? context.fetch(FetchDescriptor<Version>()).first(where: { $0.id == uuid })
        guard let version else {
            // Version no longer exists — clear stale reference
            UserDefaults.standard.removeObject(forKey: lastVersionIDKey)
            return
        }

        let url = URL(fileURLWithPath: version.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.volume = self.volume
            audioPlayer = player
            loadedVersionID = version.id
            duration = player.duration
            currentTime = 0
        } catch {
            SyncLog.player.error("restore error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(0, value), 1)
        volume = clamped
        audioPlayer?.volume = clamped
    }

    func togglePlayback(version: Version) {
        if loadedVersionID == version.id {
            isPlaying ? pause() : resume()
        } else {
            load(version: version, play: true)
        }
    }

    /// Always (re)starts the version from the beginning. If it's already loaded, seeks to 0 and plays.
    func playFromStart(version: Version) {
        if loadedVersionID == version.id, let player = audioPlayer {
            player.currentTime = 0
            currentTime = 0
            player.play()
            isPlaying = true
            startTimer()
        } else {
            load(version: version, play: true)
        }
    }

    func pause() {
        stopTimer()
        audioPlayer?.pause()
        isPlaying = false
    }

    func resume() {
        guard let player = audioPlayer else { return }
        if player.currentTime >= player.duration {
            player.currentTime = 0
            currentTime = 0
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    func stop() {
        stopTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        loadedVersionID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), duration)
        audioPlayer?.currentTime = clamped
        currentTime = clamped
    }

    func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    // MARK: - Private

    private func startTimer() {
        stopTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}

extension PlaybackEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.stopTimer()
            self.isPlaying = false
            self.currentTime = player.duration
            self.onPlaybackEnded?()
        }
    }
}
