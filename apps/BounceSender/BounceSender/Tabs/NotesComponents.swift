import AVFoundation
import SwiftUI
import BounceKit

// MARK: - Note grouping

struct NoteGroup: Identifiable {
    let id: UUID
    let timestamp: TimeInterval
    var notes: [Note]
}

/// Groups notes by timestamp — within 0.5 s clusters share a row.
/// Untimed notes each become their own group; the group's `id` is the
/// first note's UUID so `ForEach` keeps a stable identity.
func groupNotesByTimestamp(_ notes: [Note]) -> [NoteGroup] {
    var groups: [NoteGroup] = []
    for note in notes {
        if let ts = note.timestamp {
            if let idx = groups.lastIndex(where: { abs(ts - $0.timestamp) <= 0.5 }) {
                groups[idx].notes.append(note)
            } else {
                groups.append(NoteGroup(id: note.id, timestamp: ts, notes: [note]))
            }
        } else {
            groups.append(NoteGroup(id: note.id, timestamp: -1, notes: [note]))
        }
    }
    return groups
}

func sortedVersionNotes(from track: Track?, versionID: UUID) -> [Note] {
    (track?.visibleNotes ?? [])
        .filter { $0.versionID == versionID }
        .sorted { lhs, rhs in
            let lt = lhs.timestamp ?? .infinity
            let rt = rhs.timestamp ?? .infinity
            if lt != rt { return lt < rt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
}

func computeActiveNoteIDs(notes: [Note], time: TimeInterval) -> Set<UUID> {
    let timed = notes.filter { $0.timestamp != nil }
    guard !timed.isEmpty else { return [] }
    return Set(timed.filter { abs(($0.timestamp ?? 0) - time) <= 0.5 }.map(\.id))
}

/// Observes playback ticks in isolation; writes `activeNoteIDs` only when the
/// 0.5 s time bucket (or note list) can change membership.
struct ActiveNotesTracker: View {
    let playbackEngine: PlaybackEngine
    let versionNotes: [Note]
    @Binding var activeNoteIDs: Set<UUID>
    @State private var lastBucket: TimeInterval = .nan

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: playbackEngine.currentTime, initial: true) { _, time in
                refresh(at: time)
            }
            .onChange(of: versionNotes.map(\.id)) { _, _ in
                lastBucket = .nan
                refresh(at: playbackEngine.currentTime)
            }
    }

    private func refresh(at time: TimeInterval) {
        let bucket = (time / 0.5).rounded(.towardZero) * 0.5
        guard bucket != lastBucket else { return }
        lastBucket = bucket
        let next = computeActiveNoteIDs(notes: versionNotes, time: time)
        if next != activeNoteIDs {
            activeNoteIDs = next
        }
    }
}

// MARK: - Composer

struct NotesComposerBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding?
    let onSubmit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if let isFocused {
                TextField("Add a note…", text: $text, axis: .vertical)
                    .focused(isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...5)
                    .onSubmit(onSubmit)
            } else {
                TextField("Add a note…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...5)
                    .onSubmit(onSubmit)
            }

            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }
}

// MARK: - Note group row

struct NoteGroupRow: View {
    let group: NoteGroup
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onSeek: () -> Void
    let onDelete: (Note) -> Void

    @State private var isHovered = false

    var body: some View {
        let highlighted = isSelected || isActive

        HStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(group.notes.enumerated()), id: \.element.id) { index, note in
                    Group {
                        if note.type == .voice {
                            VoiceNoteRowContent(
                                note: note,
                                showTimestamp: index == 0 && group.timestamp >= 0,
                                timestamp: group.timestamp,
                                isActive: isActive
                            )
                        } else if index == 0, group.timestamp >= 0 {
                            (
                                Text(formatTimestamp(group.timestamp))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(isActive ? .accentColor : .secondary)
                                + Text("  ")
                                + Text(note.content ?? "")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                            )
                            .lineLimit(highlighted ? nil : 2)
                            .fixedSize(horizontal: false, vertical: highlighted)
                        } else {
                            Text(note.content ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(highlighted ? nil : 2)
                                .fixedSize(horizontal: false, vertical: highlighted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                Color.primary.opacity(0.08)
            } else if isHovered {
                Color.primary.opacity(0.04)
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onSelect()
            onSeek()
        }
        .contextMenu {
            ForEach(Array(group.notes.enumerated()), id: \.element.id) { _, note in
                let label = note.type == .voice ? "Voice note" : (note.content ?? "")
                Button("Delete \"\(label)\"", systemImage: "trash", role: .destructive) {
                    onDelete(note)
                }
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Voice note inline player

struct VoiceNoteRowContent: View {
    let note: Note
    let showTimestamp: Bool
    let timestamp: TimeInterval
    let isActive: Bool

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var displayTime: TimeInterval = 0
    @State private var tickTimer: Timer?
    @State private var hasFile = false

    var body: some View {
        HStack(spacing: 8) {
            if showTimestamp {
                Text(formatTime(timestamp))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(isActive ? .accentColor : .secondary)
            }

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(.quinary, in: Circle())
                    .foregroundStyle(hasFile ? Color.primary : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!hasFile)

            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(hasFile ? .secondary : .tertiary)

            Text(durationLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if !hasFile {
                Text("syncing…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .task(id: note.voiceFilePath) {
            hasFile = fileExists(at: note.voiceFilePath)
        }
        .onDisappear { stopPlayback() }
    }

    private var durationLabel: String {
        let total = note.voiceDuration ?? player?.duration ?? 0
        if isPlaying {
            return "\(formatTime(displayTime)) / \(formatTime(total))"
        }
        return formatTime(total)
    }

    private func fileExists(at path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let path = note.voiceFilePath else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            guard p.play() else { return }
            player = p
            isPlaying = true
            displayTime = 0
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in
                    guard let player else { return }
                    displayTime = player.currentTime
                    if !player.isPlaying {
                        stopPlayback()
                    }
                }
            }
        } catch {
            SyncLog.player.error("failed to play voice note: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        tickTimer?.invalidate()
        tickTimer = nil
        isPlaying = false
        displayTime = 0
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
