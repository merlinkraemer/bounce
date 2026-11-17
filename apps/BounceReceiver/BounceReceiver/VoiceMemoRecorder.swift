import AVFoundation
import Foundation

struct VoiceMemoRecording {
    let fileURL: URL
    let duration: TimeInterval
}

@Observable
@MainActor
final class VoiceMemoRecorder {
    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private let session = AVAudioSession.sharedInstance()

    func startRecording(noteID: UUID) async -> Bool {
        guard !isRecording else { return true }

        errorMessage = nil
        elapsedTime = 0

        guard await requestPermission() else {
            errorMessage = "Microphone access is required to record voice memos."
            return false
        }

        let url = Self.voiceMemoURL(for: noteID)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()

            guard recorder.record() else {
                errorMessage = "Could not start recording."
                return false
            }

            self.recorder = recorder
            recordingURL = url
            isRecording = true
            startTimer()
            return true
        } catch {
            errorMessage = error.localizedDescription
            try? FileManager.default.removeItem(at: url)
            restorePlaybackSession()
            return false
        }
    }

    func stopRecording() -> VoiceMemoRecording? {
        guard isRecording, let recorder, let recordingURL else { return nil }

        let duration = max(elapsedTime, recorder.currentTime)
        recorder.stop()
        stopTimer()
        resetRecordingState()
        restorePlaybackSession()

        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: recordingURL)
            errorMessage = "Recording is too short."
            return nil
        }

        return VoiceMemoRecording(fileURL: recordingURL, duration: duration)
    }

    func cancelRecording() {
        guard recorder != nil else { return }
        let url = recordingURL
        recorder?.stop()
        stopTimer()
        resetRecordingState()
        restorePlaybackSession()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func requestPermission() async -> Bool {
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsedTime = recorder.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetRecordingState() {
        recorder = nil
        recordingURL = nil
        isRecording = false
        elapsedTime = 0
    }

    private func restorePlaybackSession() {
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func voiceMemoDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Bounce/voice-memos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Canonical file URL for a voice note's audio. Used by both the recorder
    /// (to write) and the sync transport's voiceNoteProvider (to read).
    static func voiceMemoURL(for noteID: UUID) -> URL {
        voiceMemoDirectory().appendingPathComponent("\(noteID.uuidString).m4a")
    }

    /// Best-effort local lookup for a note's audio. Prefers the stored path when
    /// it still exists, then falls back to the canonical `<noteID>.m4a` location,
    /// then tries the stored filename inside the current voice-memo directory to
    /// recover from iOS container path changes.
    static func existingVoiceMemoURL(noteID: UUID, storedPath: String?) -> URL? {
        if let storedPath {
            let storedURL = URL(fileURLWithPath: storedPath)
            if FileManager.default.fileExists(atPath: storedURL.path) {
                return storedURL
            }
        }

        let canonicalURL = voiceMemoURL(for: noteID)
        if FileManager.default.fileExists(atPath: canonicalURL.path) {
            return canonicalURL
        }

        if let storedPath {
            let filename = URL(fileURLWithPath: storedPath).lastPathComponent
            let relocatedURL = voiceMemoDirectory().appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: relocatedURL.path) {
                return relocatedURL
            }
        }

        return nil
    }
}
