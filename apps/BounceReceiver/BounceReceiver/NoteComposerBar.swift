import SwiftUI
import SwiftData
import BounceKit

struct ComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NoteComposerBar: View {
    @Environment(AudioPlayer.self) private var audioPlayer

    let track: Track
    @Bindable var voiceNoteController: VoiceNoteInteractionController
    let modelContext: ModelContext
    let downloadManager: DownloadManager
    let uploadQueue: UploadQueue
    var draftController: PlayerDraftController? = nil

    @State private var localDraftText = ""
    @State private var localDraftTimestamp: TimeInterval?
    @State private var localIsTimestampLocked = false
    @FocusState private var textFieldFocused: Bool

    private var textBinding: Binding<String> {
        if let draftController {
            return Binding(
                get: { draftController.draftText },
                set: { draftController.draftText = $0 }
            )
        } else {
            return $localDraftText
        }
    }

    private var isHolding: Bool { voiceNoteController.state.isHolding }
    private var isLocked: Bool { voiceNoteController.state.isLocked }
    private var isRecording: Bool { voiceNoteController.state.isRecording }

    private var hasText: Bool {
        !textBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Timestamp helpers

    private func currentDraftTimestamp() -> TimeInterval? {
        draftController?.draftTimestamp ?? localDraftTimestamp
    }

    private func setDraftTimestamp(_ value: TimeInterval?) {
        if let draftController {
            draftController.draftTimestamp = value
        } else {
            localDraftTimestamp = value
        }
    }

    private func currentIsTimestampLocked() -> Bool {
        draftController?.isTimestampLocked ?? localIsTimestampLocked
    }

    private func setIsTimestampLocked(_ value: Bool) {
        if let draftController {
            draftController.isTimestampLocked = value
        } else {
            localIsTimestampLocked = value
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            leadingContent
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingControl
        }
        .frame(minHeight: 36)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .modifier(LiquidGlassCapsule())
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ComposerHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isRecording)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isLocked)
    }

    // MARK: - Leading

    @ViewBuilder
    private var leadingContent: some View {
        if isLocked {
            lockedLeading
        } else if isHolding {
            holdingLeading
        } else {
            textField
        }
    }

    private var textField: some View {
        TextField("Add a note…", text: textBinding, axis: .vertical)
            .font(.body)
            .lineLimit(1...4)
            .textInputAutocapitalization(.sentences)
            .focused($textFieldFocused)
            .onChange(of: textBinding.wrappedValue) { _, newValue in
                if !currentIsTimestampLocked(),
                   !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    setIsTimestampLocked(true)
                    // Prefer the smooth clock while fullscreen is open — currentTime
                    // only ticks at ~10 Hz and can lag the playhead the user hears.
                    setDraftTimestamp(audioPlayer.playbackClock.time)
                }
            }
    }

    private var holdingLeading: some View {
        HStack(spacing: 0) {
            recordingTimer

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                Text("Slide to cancel")
                    .font(.subheadline)
            }
            .foregroundStyle(.white.opacity(0.5))
            .offset(x: voiceNoteController.horizontalDragOffset)
            .opacity(slideToCancelOpacity)

            Spacer(minLength: 8)
        }
    }

    private var lockedLeading: some View {
        HStack(spacing: 0) {
            Button(action: { voiceNoteController.cancel() }) {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            recordingTimer

            Spacer(minLength: 8)
        }
    }

    private var recordingTimer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(formatDuration(voiceNoteController.elapsedTime))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    /// Hint fades as the finger approaches the cancel threshold so the user gets
    /// a clear signal that releasing now would still send.
    private var slideToCancelOpacity: Double {
        let drag = -Double(voiceNoteController.horizontalDragOffset)
        let threshold = Double(voiceNoteController.cancelSwipeThreshold)
        guard threshold > 0 else { return 0.5 }
        let progress = max(0, min(1, drag / threshold))
        return 0.5 * (1 - progress)
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingControl: some View {
        if isLocked {
            sendButton(action: sendLockedVoiceNote)
                .frame(width: 32, height: 32)
        } else {
            ZStack {
                // Mic always present so the long-press gesture isn't dismantled
                // when transitioning idle → holding. Hidden visually when text
                // is being composed, but kept hit-testable while holding.
                VoiceNoteComposerMic(
                    controller: voiceNoteController,
                    track: track,
                    audioPlayer: audioPlayer,
                    modelContext: modelContext,
                    downloadManager: downloadManager,
                    uploadQueue: uploadQueue
                )
                .opacity(showSendIcon ? 0 : 1)
                .allowsHitTesting(!showSendIcon)

                if showSendIcon {
                    sendButton(action: sendTextNote)
                }

                if isHolding {
                    recordingMicHalo
                }
            }
            .frame(width: 32, height: 32)
            .overlay(alignment: .top) {
                if isHolding {
                    lockPopover
                        .offset(y: lockPopoverOffset)
                        .opacity(voiceNoteController.showLockAffordance ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var showSendIcon: Bool {
        hasText && !isRecording
    }

    private func sendButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// Subtle red glow drawn behind the mic while the user is holding so the
    /// recording state reads at a glance without moving the icon itself.
    private var recordingMicHalo: some View {
        Circle()
            .fill(Color.red.opacity(0.35))
            .frame(width: 32, height: 32)
            .scaleEffect(1.1)
            .allowsHitTesting(false)
    }

    /// Lock popover sits above the mic. As the user drags up, it eases toward
    /// the mic so the gesture maps onto the popover's position.
    private var lockPopover: some View {
        VStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption.weight(.semibold))
            Image(systemName: "chevron.up")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(width: 32, height: 44)
        .background(
            Capsule(style: .continuous)
                .fill(Color(white: 0.18))
        )
    }

    private var lockPopoverOffset: CGFloat {
        let base: CGFloat = -56
        let drag = voiceNoteController.verticalDragOffset
        let threshold = -voiceNoteController.lockThreshold
        guard threshold < 0 else { return base }
        let progress = max(0, min(1, drag / threshold))
        return base * (1 - progress * 0.6)
    }

    // MARK: - Actions

    private func clearDraft() {
        textBinding.wrappedValue = ""
        setDraftTimestamp(nil)
        setIsTimestampLocked(false)
    }

    private func sendTextNote() {
        let trimmed = textBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let note = Note(
            id: UUID(),
            trackID: track.id,
            versionID: audioPlayer.currentVersion?.id,
            timestamp: currentDraftTimestamp() ?? audioPlayer.playbackClock.time,
            type: .text,
            content: trimmed,
            createdAt: Date(),
            updatedAt: Date(),
            createdOn: .phone
        )
        modelContext.insert(note)
        track.notes.append(note)
        track.updatedAt = .now

        try? modelContext.save()
        downloadManager.notifyNoteMutated()
        clearDraft()
    }

    private func sendLockedVoiceNote() {
        voiceNoteController.sendLocked(
            modelContext: modelContext,
            downloadManager: downloadManager,
            uploadQueue: uploadQueue
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
