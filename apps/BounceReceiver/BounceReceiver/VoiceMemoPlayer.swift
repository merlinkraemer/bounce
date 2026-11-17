import AVFoundation
import Foundation

@Observable
@MainActor
final class VoiceMemoPlayer: NSObject, AVAudioPlayerDelegate {
    var playingNoteID: UUID?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let session = AVAudioSession.sharedInstance()

    func toggle(noteID: UUID, filePath: String) {
        if playingNoteID == noteID {
            if isPlaying {
                pause()
            } else {
                resume()
            }
            return
        }

        play(noteID: noteID, filePath: filePath)
    }

    func pause() {
        player?.pause()
        setIsPlaying(false)
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(player.duration, time))
        player.currentTime = clamped
        setCurrentTime(clamped)
    }

    func stop() {
        player?.stop()
        player = nil
        if playingNoteID != nil { playingNoteID = nil }
        setCurrentTime(0)
        setDuration(0)
        setIsPlaying(false)
        stopTimer()
    }

    private func play(noteID: UUID, filePath: String) {
        stop()

        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()

            self.player = player
            playingNoteID = noteID
            setDuration(player.duration)
            setCurrentTime(0)
            setIsPlaying(true)
            startTimer()
        } catch {
            stop()
        }
    }

    private func resume() {
        guard let player else { return }
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            player.play()
            setIsPlaying(true)
            startTimer()
        } catch {
            stop()
        }
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                // Only publish when values actually change so idle ticks
                // (unchanged duration / isPlaying) don't invalidate observers.
                self.setCurrentTime(player.currentTime)
                self.setDuration(player.duration)
                self.setIsPlaying(player.isPlaying)
            }
        }
        // Use .common mode so the timer fires during UIScrollView tracking
        // (the full-screen player sheet uses a UIKit scroll view).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func setCurrentTime(_ value: TimeInterval) {
        if currentTime != value { currentTime = value }
    }

    private func setDuration(_ value: TimeInterval) {
        if duration != value { duration = value }
    }

    private func setIsPlaying(_ value: Bool) {
        if isPlaying != value { isPlaying = value }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stop()
        }
    }
}
