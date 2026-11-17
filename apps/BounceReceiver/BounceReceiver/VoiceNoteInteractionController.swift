import AVFoundation
import CoreGraphics
import Foundation
import SwiftData
import UIKit
import BounceKit

enum VoiceNoteRecordingState: Equatable {
    case idle
    case holding
    case locked
    case saving
    case error(String)

    var isHolding: Bool {
        if case .holding = self { return true }
        return false
    }

    var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }

    var isRecording: Bool {
        isHolding || isLocked || self == .saving
    }
}

@Observable
@MainActor
final class VoiceNoteInteractionController {
    var state: VoiceNoteRecordingState = .idle
    var startedAtTrackID: UUID?
    var startedAtVersionID: UUID?
    var startedAtTimestamp: TimeInterval?
    var verticalDragOffset: CGFloat = 0
    /// Negative-only horizontal drag — used by the capture chrome to follow the finger when
    /// the user is swiping left toward cancel.
    var horizontalDragOffset: CGFloat = 0
    /// Shown after holding briefly so the lock hint does not appear the instant recording starts.
    var showLockAffordance: Bool = false

    let lockThreshold: CGFloat = 56
    /// Left drag past this cancels while holding. Computed at the start of each hold so the
    /// user has to swipe their finger roughly to the middle of the screen before the recording
    /// is dropped — light brushes against the left side no longer cancel.
    private(set) var cancelSwipeThreshold: CGFloat = 180
    let lockAffordanceDelay: TimeInterval = 0.45
    let minimumDuration: TimeInterval = 0.5

    private var recorder = VoiceMemoRecorder()
    private var startedAtTrack: Track?
    private var startedAtVersion: Version?
    /// noteID generated up front so the recorder can name the file with it from the start.
    /// Lets the voiceNoteProvider resolve files by note ID with no rename hop.
    private var pendingNoteID: UUID?
    private var startRecordingTask: Task<Void, Never>?
    private var resetErrorTask: Task<Void, Never>?
    private var lockAffordanceTask: Task<Void, Never>?

    private weak var audioPlayer: AudioPlayer?
    private var wasPlayingBeforeRecording = false
    private var wasBuiltInSpeakerRoute = false

    private let startHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let cancelHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let lockHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let sendHaptic = UIImpactFeedbackGenerator(style: .light)

    var elapsedTime: TimeInterval { recorder.elapsedTime }
    var isLocked: Bool { state.isLocked }
    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return recorder.errorMessage
    }

    func beginHold(track: Track, version: Version?, timestamp: TimeInterval, audioPlayer: AudioPlayer) {
        guard !state.isRecording else { return }

        resetErrorTask?.cancel()
        self.audioPlayer = audioPlayer
        wasPlayingBeforeRecording = audioPlayer.isPlaying
        wasBuiltInSpeakerRoute = isBuiltInSpeakerRoute()
        if wasBuiltInSpeakerRoute {
            audioPlayer.pause()
        }
        startedAtTrack = track
        startedAtVersion = version
        startedAtTrackID = track.id
        startedAtVersionID = version?.id
        startedAtTimestamp = timestamp
        let noteID = UUID()
        pendingNoteID = noteID
        verticalDragOffset = 0
        horizontalDragOffset = 0
        cancelSwipeThreshold = max(140, UIScreen.main.bounds.width / 2)
        startHaptic.prepare()
        cancelHaptic.prepare()
        lockHaptic.prepare()
        sendHaptic.prepare()
        resetLockAffordanceScheduling()
        state = .holding
        startHaptic.impactOccurred()
        scheduleLockAffordance()

        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor in
            let didStart = await recorder.startRecording(noteID: noteID)
            if Task.isCancelled || !state.isRecording {
                if didStart {
                    recorder.cancelRecording()
                }
                return
            }
            guard !didStart else { return }
            fail(recorder.errorMessage ?? "Could not start recording.")
        }
    }

    func updateDrag(translation: CGSize) {
        guard state.isHolding || state.isLocked else { return }

        if state.isHolding {
            let w = translation.width
            let h = translation.height
            let absW = abs(w)
            let absH = abs(h)

            // Left = cancel (negative width). Up = lock (negative height). Do not require a
            // perfect axis gesture; diagonal drags resolve by whichever threshold is exceeded more.
            let wantsCancel = w <= -cancelSwipeThreshold
            let wantsLock = h <= -lockThreshold

            if wantsCancel && wantsLock {
                let cancelExcess = absW - cancelSwipeThreshold
                let lockExcess = absH - lockThreshold
                if cancelExcess >= lockExcess {
                    cancelHaptic.impactOccurred()
                    cancel()
                    return
                } else {
                    lockHaptic.impactOccurred()
                    lock()
                    return
                }
            }
            if wantsCancel {
                cancelHaptic.impactOccurred()
                cancel()
                return
            }
            if wantsLock {
                lockHaptic.impactOccurred()
                lock()
                return
            }
        }

        verticalDragOffset = min(0, translation.height)
        horizontalDragOffset = state.isHolding ? min(0, translation.width) : 0
    }

    func endHold(modelContext: ModelContext, downloadManager: DownloadManager, uploadQueue: UploadQueue) {
        guard state.isHolding else { return }
        sendRecording(modelContext: modelContext, downloadManager: downloadManager, uploadQueue: uploadQueue)
    }

    func sendLocked(modelContext: ModelContext, downloadManager: DownloadManager, uploadQueue: UploadQueue) {
        guard state.isLocked else { return }
        sendRecording(modelContext: modelContext, downloadManager: downloadManager, uploadQueue: uploadQueue)
    }

    func cancel() {
        resetErrorTask?.cancel()
        startRecordingTask?.cancel()
        recorder.cancelRecording()
        resumePlaybackIfNeeded()
        resetContext()
        verticalDragOffset = 0
        horizontalDragOffset = 0
        state = .idle
    }

    private func lock() {
        guard state.isHolding else { return }
        verticalDragOffset = -lockThreshold
        resetLockAffordanceScheduling()
        state = .locked
    }

    private func scheduleLockAffordance() {
        lockAffordanceTask?.cancel()
        let delayNs = UInt64(lockAffordanceDelay * 1_000_000_000)
        lockAffordanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, state.isHolding else { return }
            showLockAffordance = true
        }
    }

    private func resetLockAffordanceScheduling() {
        lockAffordanceTask?.cancel()
        lockAffordanceTask = nil
        showLockAffordance = false
    }

    private func sendRecording(modelContext: ModelContext, downloadManager: DownloadManager, uploadQueue: UploadQueue) {
        guard let track = startedAtTrack, let noteID = pendingNoteID else {
            recorder.cancelRecording()
            fail("Recording context is unavailable.")
            return
        }

        let version = startedAtVersion
        let timestamp = startedAtTimestamp
        let previousUpdatedAt = track.updatedAt
        resetLockAffordanceScheduling()
        state = .saving

        guard recorder.isRecording else {
            startRecordingTask?.cancel()
            recorder.cancelRecording()
            silentlyDiscard()
            return
        }

        guard let recording = recorder.stopRecording() else {
            if let message = recorder.errorMessage {
                fail(message)
            } else {
                silentlyDiscard()
            }
            return
        }

        guard recording.duration >= minimumDuration else {
            VoiceMemoRecorder.deleteRecording(at: recording.fileURL)
            silentlyDiscard()
            return
        }

        // Hash the recording so the manifest entry can advertise availability and
        // peers can verify what they download. Files are tiny (a few hundred KB)
        // so this is fine on the main actor.
        let sha256: String
        let fileSize: Int64
        do {
            sha256 = try FileIntegrity.sha256Hex(for: recording.fileURL)
            fileSize = try FileIntegrity.fileSize(for: recording.fileURL)
        } catch {
            VoiceMemoRecorder.deleteRecording(at: recording.fileURL)
            fail("Could not hash recording: \(error.localizedDescription)")
            return
        }

        let note = Note(
            id: noteID,
            trackID: track.id,
            versionID: version?.id,
            timestamp: timestamp,
            type: .voice,
            voiceFilePath: recording.fileURL.path,
            voiceDuration: recording.duration,
            voiceFileSHA256: sha256,
            voiceFileSize: fileSize,
            createdAt: Date(),
            updatedAt: Date(),
            createdOn: .phone
        )

        modelContext.insert(note)
        track.notes.append(note)
        track.updatedAt = .now

        do {
            try modelContext.save()
            uploadQueue.enqueueVoiceNote(noteID: note.id, fileURL: recording.fileURL, sha256: sha256, fileSize: fileSize)
            downloadManager.notifyNoteMutated()
            sendHaptic.impactOccurred()
            startRecordingTask = nil
            resumePlaybackIfNeeded()
            resetContext()
            verticalDragOffset = 0
            horizontalDragOffset = 0
            state = .idle
        } catch {
            if let noteIndex = track.notes.firstIndex(where: { $0.id == note.id }) {
                track.notes.remove(at: noteIndex)
            }
            track.updatedAt = previousUpdatedAt
            modelContext.delete(note)
            VoiceMemoRecorder.deleteRecording(at: recording.fileURL)
            fail(error.localizedDescription)
        }
    }

    private func resetContext() {
        startedAtTrack = nil
        startedAtVersion = nil
        startedAtTrackID = nil
        startedAtVersionID = nil
        startedAtTimestamp = nil
        pendingNoteID = nil
        resetLockAffordanceScheduling()
    }

    private func isBuiltInSpeakerRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    private func resumePlaybackIfNeeded() {
        guard let audioPlayer else { return }
        if wasPlayingBeforeRecording && wasBuiltInSpeakerRoute {
            audioPlayer.play()
        }
        wasPlayingBeforeRecording = false
        wasBuiltInSpeakerRoute = false
        self.audioPlayer = nil
    }

    private func fail(_ message: String) {
        startRecordingTask = nil
        resumePlaybackIfNeeded()
        resetContext()
        verticalDragOffset = 0
        horizontalDragOffset = 0
        state = .error(message)
        resetErrorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .error = state {
                state = .idle
            }
        }
    }

    /// Tear down the recording without surfacing an error — used for "too short" presses
    /// where there is nothing useful to save and an error would feel out of place.
    private func silentlyDiscard() {
        resetErrorTask?.cancel()
        startRecordingTask = nil
        resumePlaybackIfNeeded()
        resetContext()
        verticalDragOffset = 0
        horizontalDragOffset = 0
        state = .idle
    }
}
