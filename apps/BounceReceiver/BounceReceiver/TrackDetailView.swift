import SwiftUI
import SwiftData
import BounceKit

struct TrackDetailView: View {
    @Environment(AudioPlayer.self) private var audioPlayer

    let modelContext: ModelContext
    let downloadManager: DownloadManager

    var body: some View {
        Group {
            if let track = audioPlayer.currentTrack {
                TrackDetailContent(
                    track: track,
                    modelContext: modelContext,
                    downloadManager: downloadManager
                )
            }
        }
    }
}

private struct TrackDetailContent: View {
    let track: Track
    let modelContext: ModelContext
    let downloadManager: DownloadManager

    @Environment(AudioPlayer.self) private var audioPlayer
    @State private var voiceMemoPlayer = VoiceMemoPlayer()
    /// Cached so VoiceMemoPlayer ticks don't regroup + fault notes every 0.1 s.
    @State private var noteSections: [NoteDateSection] = []

    var body: some View {
        Group {
            if !noteSections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(noteSections) { section in
                        Text(NoteDateGrouping.sectionTitle(for: section.day))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 4)

                        ForEach(section.notes) { note in
                            if note.type == .voice {
                                VoiceMemoPlaybackRow(
                                    note: note,
                                    player: voiceMemoPlayer,
                                    isAvailable: isVoiceMemoAvailable(note),
                                    onTogglePlayback: {
                                        guard let voiceFilePath = resolvedVoiceFilePath(for: note) else { return }
                                        audioPlayer.pause()
                                        voiceMemoPlayer.toggle(noteID: note.id, filePath: voiceFilePath)
                                    },
                                    onPrepareSeek: {
                                        guard let voiceFilePath = resolvedVoiceFilePath(for: note) else { return }
                                        audioPlayer.pause()
                                        voiceMemoPlayer.toggle(noteID: note.id, filePath: voiceFilePath)
                                    },
                                    onSeek: { time in
                                        guard voiceMemoPlayer.playingNoteID == note.id else { return }
                                        voiceMemoPlayer.seek(to: time)
                                    },
                                    onSeekToTrackTime: {
                                        jumpToNoteTimestamp(note)
                                    }
                                )
                            } else {
                                TextNoteRow(
                                    note: note,
                                    onTap: {
                                        jumpToNoteTimestamp(note)
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
        }
        .onAppear { refreshNoteSections() }
        .onChange(of: track.id) { _, _ in
            voiceMemoPlayer.stop()
            refreshNoteSections()
        }
        .onChange(of: track.visibleNotes.count) { _, _ in refreshNoteSections() }
        .onChange(of: audioPlayer.currentVersion?.id) { _, _ in refreshNoteSections() }
        .onDisappear { voiceMemoPlayer.stop() }
    }

    private func refreshNoteSections() {
        let currentVersionID = audioPlayer.currentVersion?.id
        // Show notes attached to the active version, plus legacy notes that
        // were saved without a versionID so they remain reachable.
        let scoped = track.visibleNotes.filter { note in
            note.versionID == nil || note.versionID == currentVersionID
        }
        noteSections = NoteDateGrouping.grouped(scoped)
    }

    /// Jump playback to the note's timestamp. Switches mix first when the note
    /// belongs to a different version.
    private func jumpToNoteTimestamp(_ note: Note) {
        guard let timestamp = note.timestamp else { return }
        voiceMemoPlayer.stop()

        if let versionID = note.versionID,
           versionID != audioPlayer.currentVersion?.id,
           let version = track.versions.first(where: { $0.id == versionID }) {
            audioPlayer.load(
                track: track,
                version: version,
                startTime: timestamp
            )
            return
        }

        audioPlayer.seek(to: timestamp)
        if !audioPlayer.isPlaying {
            audioPlayer.play()
        }
    }

    private func isVoiceMemoAvailable(_ note: Note) -> Bool {
        resolvedVoiceFilePath(for: note) != nil
    }

    private func resolvedVoiceFilePath(for note: Note) -> String? {
        VoiceMemoRecorder.existingVoiceMemoURL(noteID: note.id, storedPath: note.voiceFilePath)?.path
    }
}

/// Leaf that alone observes VoiceMemoPlayer tick fields for the active memo.
/// Inactive rows only watch `playingNoteID`, so 10 Hz ticks don't rebuild the list.
private struct VoiceMemoPlaybackRow: View {
    let note: Note
    let player: VoiceMemoPlayer
    let isAvailable: Bool
    let onTogglePlayback: () -> Void
    let onPrepareSeek: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onSeekToTrackTime: () -> Void

    var body: some View {
        let isCurrent = player.playingNoteID == note.id
        VoiceMemoNoteRow(
            note: note,
            isCurrentMemo: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            currentTime: isCurrent ? player.currentTime : 0,
            duration: isCurrent ? player.duration : note.voiceDuration ?? 0,
            isAvailable: isAvailable,
            onTogglePlayback: onTogglePlayback,
            onPrepareSeek: onPrepareSeek,
            onSeek: onSeek,
            onSeekToTrackTime: onSeekToTrackTime
        )
    }
}
