import SwiftUI
import AppKit
import BounceKit

struct MixNoteDraft: Equatable {
    var text = ""
    /// Captured when the first character is entered, so a moving playhead does
    /// not change the location of a note that is already being written.
    var timestamp: TimeInterval?
}

/// Exact-mix feedback surface. It observes the inspected version rather than
/// the loaded player, so notes and waveform samples remain useful while
/// another mix is playing or while this mix is stopped.
struct NowPlayingPaneView: View {
    let track: Track?
    let version: Version?
    let playbackEngine: PlaybackEngine
    let transportState: TransportState
    let reservesTransportSpace: Bool
    let onSaveNote: (Track, Version, String, TimeInterval) -> Bool
    let onReviewPosition: (TimeInterval) -> Void
    let onScrub: (TimeInterval) -> Void
    let onUpdateNote: (Note, Track, String) -> Bool
    let onDeleteNote: (Note) -> Void
    @Binding var drafts: [UUID: MixNoteDraft]

    @State private var noteText = ""
    @State private var draftTimestamp: TimeInterval?
    @FocusState private var isNoteInputFocused: Bool
    @State private var selectedNoteID: UUID?
    @State private var editingNoteID: UUID?
    @State private var cachedVersionNotes: [Note] = []
    @State private var activeNoteIDs: Set<UUID> = []
    @State private var reviewPosition: TimeInterval?
    @State private var waveformSamples: [Float]?
    @State private var waveformVersionID: UUID?
    @State private var errorMessage: String?

    private static let waveformHeight: CGFloat = 48
    private var isInspectedVersionLoaded: Bool {
        guard let version else { return false }
        return playbackEngine.loadedVersionID == version.id
    }

    private var timedNotes: [Note] {
        cachedVersionNotes.filter { $0.timestamp != nil }
    }

    /// Notes created before timestamped entry was mandatory. Keep them visible
    /// rather than silently moving them to an invented audio position.
    private var legacyNotes: [Note] {
        cachedVersionNotes
            .filter { $0.timestamp == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var previousVersionNoteTimestamps: [TimeInterval] {
        guard let track, let version else { return [] }
        let previous = track.versions
            .filter { $0.id != version.id && $0.addedAt < version.addedAt }
            .max { $0.addedAt < $1.addedAt }
        return previous.map { sortedVersionNotes(from: track, versionID: $0.id).compactMap(\.timestamp) } ?? []
    }

    var body: some View {
        Group {
            if let track, let version {
                detailContent(track: track, version: version)
            } else {
                ContentUnavailableView(
                    "No Mix Selected",
                    systemImage: "music.note",
                    description: Text("Select a mix to read its notes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The inspector is the only column that never opted into width
        // negotiation. Without a flexible root the pane lays out at the
        // children's ideal width and the composer can spill past the column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ActiveNotesTracker(
                playbackEngine: playbackEngine,
                versionNotes: isInspectedVersionLoaded ? cachedVersionNotes : [],
                activeNoteIDs: $activeNoteIDs
            )
        }
        .columnBackground(.detail)
        .disableWindowDrag()
        .onChange(of: version?.id, initial: true) { oldID, newID in
            if let oldID, oldID != newID { stashDraft(for: oldID) }
            editingNoteID = nil
            loadVersionState()
        }
        .onChange(of: track?.notes, initial: true) { _, _ in
            rebuildNotes()
        }
        .onChange(of: transportState.requestNoteFocus) { _, requested in
            guard requested else { return }
            transportState.requestNoteFocus = false
            guard version != nil else { return }
            isNoteInputFocused = true
        }
        .onChange(of: noteText) { _, newValue in
            let hasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText, draftTimestamp == nil, let version {
                draftTimestamp = timestampForNewNote(in: version)
            } else if !hasText {
                draftTimestamp = nil
            }
            persistCurrentDraft()
        }
        .onChange(of: draftTimestamp) { _, _ in persistCurrentDraft() }
        .task(id: version?.id) {
            await loadWaveform(for: version)
        }
    }

    @ViewBuilder
    private func detailContent(track: Track, version: Version) -> some View {
        VStack(spacing: 0) {
            detailHeader(track: track, version: version)

            WaveformScrubber(
                transportState: transportState,
                samples: waveformVersionID == version.id ? waveformSamples : nil,
                duration: version.duration,
                noteTimestamps: timedNotes.compactMap(\.timestamp),
                ghostNoteTimestamps: previousVersionNoteTimestamps,
                onSeek: nil,
                onPositionSelected: { time in
                    // Direct scrub seeks the inspected exact mix. Marker and
                    // nearest-note highlight accompany the seek; they no longer
                    // substitute for it.
                    reviewPosition = time
                    selectedNoteID = timedNotes.min {
                        abs(($0.timestamp ?? 0) - time) < abs(($1.timestamp ?? 0) - time)
                    }.flatMap { note in
                        guard abs((note.timestamp ?? 0) - time) <= 0.5 else { return nil }
                        return note.id
                    }
                    onScrub(time)
                },
                playheadTime: isInspectedVersionLoaded ? transportState.currentTime : nil,
                selectedPosition: reviewPosition
            )
            .frame(height: Self.waveformHeight)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .overlay(alignment: .center) {
                if waveformVersionID != version.id || waveformSamples == nil {
                    Text("Waveform unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }

            PaneWaveformTimeLabels(
                transportState: transportState,
                duration: version.duration,
                isLoaded: isInspectedVersionLoaded
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Divider()
                .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BounceConstants.noteCardSpacing) {
                        ForEach(timedNotes) { note in
                            MixNoteRow(
                                note: note,
                                timestamp: note.timestamp,
                                isActive: activeNoteIDs.contains(note.id),
                                isSelected: selectedNoteID == note.id,
                                editingNoteID: $editingNoteID,
                                onSelect: {
                                    selectedNoteID = note.id
                                    if let timestamp = note.timestamp {
                                        reviewPosition = timestamp
                                        onReviewPosition(timestamp)
                                    }
                                },
                                onSave: { content in
                                    onUpdateNote(note, track, content)
                                },
                                onDelete: {
                                    onDeleteNote(note)
                                    rebuildNotes()
                                }
                            )
                            .id(note.id)
                        }

                        if !legacyNotes.isEmpty {
                            Text("Older notes")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 4)

                            ForEach(legacyNotes) { note in
                                MixNoteRow(
                                    note: note,
                                    timestamp: nil,
                                    isActive: false,
                                    isSelected: selectedNoteID == note.id,
                                    editingNoteID: $editingNoteID,
                                    onSelect: { selectedNoteID = note.id },
                                    onSave: { content in
                                        onUpdateNote(note, track, content)
                                    },
                                    onDelete: {
                                        onDeleteNote(note)
                                        rebuildNotes()
                                    }
                                )
                                .id(note.id)
                            }
                        }

                        if cachedVersionNotes.isEmpty {
                            Text("No notes yet. Type below to add a note.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 24)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .onChange(of: selectedNoteID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }

            composer(track: track, version: version)
                .padding(.horizontal, 16)
                // The transport is overlaid by MainLibraryLayout. Keep the
                // notes composer just above the pill without reserving a
                // footer in the surrounding workspace.
                .padding(.bottom, reservesTransportSpace
                    ? BounceConstants.transportBarHeight + BounceConstants.transportBarBottomPadding + 8
                    : 12)
        }
    }

    private func detailHeader(track: Track, version: Version) -> some View {
        HStack(alignment: .center, spacing: 12) {
            artwork(for: track)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                MarqueeTitle(
                    text: track.displayTitle,
                    font: .system(size: 16, weight: .semibold)
                )
                Text(mixLabel(version.label))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Mix \(version.label)")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // No per-header fill: the root `.columnBackground(.detail)` already paints
        // the whole detail column the same `controlBackgroundColor`. A second box
        // here only layered an identical fill and read as a separate header slab.
    }

    private func composer(track: Track, version: Version) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NotesInputBar(
                text: $noteText,
                placeholder: "Write a note…",
                isFocused: $isNoteInputFocused,
                onSubmit: { submitNote(track: track, version: version) }
            )
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func artwork(for track: Track) -> some View {
        Group {
            if let data = track.artwork,
               let nsImage = ArtworkThumbnailCache.thumbnail(data, id: track.id, side: 96) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                    Image("MusicNoteIcon").renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func loadVersionState() {
        guard let version else {
            cachedVersionNotes = []
            activeNoteIDs = []
            waveformSamples = nil
            waveformVersionID = nil
            noteText = ""
            draftTimestamp = nil
            reviewPosition = nil
            return
        }
        let draft = drafts[version.id] ?? MixNoteDraft()
        noteText = draft.text
        draftTimestamp = draft.timestamp
        selectedNoteID = nil
        reviewPosition = nil
        errorMessage = nil
        rebuildNotes()
    }

    private func rebuildNotes() {
        guard let version else {
            cachedVersionNotes = []
            activeNoteIDs = []
            return
        }
        let notes = sortedVersionNotes(from: track, versionID: version.id)
        cachedVersionNotes = notes
        activeNoteIDs = computeActiveNoteIDs(
            notes: notes,
            time: isInspectedVersionLoaded ? playbackEngine.currentTime : -1
        )
    }

    private func loadWaveform(for version: Version?) async {
        guard let version else {
            waveformSamples = nil
            waveformVersionID = nil
            return
        }
        let id = version.id
        let data = version.waveformData
        let samples = data?.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !Task.isCancelled, self.version?.id == id else { return }
        waveformSamples = samples?.isEmpty == true ? nil : samples
        waveformVersionID = id
    }

    private func stashDraft(for versionID: UUID) {
        drafts[versionID] = MixNoteDraft(
            text: noteText,
            timestamp: draftTimestamp
        )
    }

    private func persistCurrentDraft() {
        guard let versionID = version?.id else { return }
        stashDraft(for: versionID)
    }

    private func submitNote(track: Track, version: Version) {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timestamp = timestampForNewNote(in: version)

        guard onSaveNote(track, version, trimmed, timestamp) else {
            errorMessage = "Couldn't save note. Your draft is still here."
            return
        }
        drafts[version.id] = MixNoteDraft()
        noteText = ""
        draftTimestamp = nil
        errorMessage = nil
        rebuildNotes()
    }

    private func timestampForNewNote(in version: Version) -> TimeInterval {
        let candidate = draftTimestamp
            ?? reviewPosition
            ?? (isInspectedVersionLoaded ? playbackEngine.currentTime : 0)
        guard candidate.isFinite else { return 0 }
        guard version.duration > 0 else { return max(0, candidate) }
        return min(max(0, candidate), version.duration)
    }

    private func mixLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("mix ") ? trimmed : "Mix \(trimmed)"
    }
}

private struct NotesInputBar: View {
    @Binding var text: String
    let placeholder: String
    let isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit(onSubmit)
                .padding(.leading, 12)
                .padding(.vertical, 8)
                // Negotiate the field's width from the composer's proposal
                // before intrinsic height is resolved, so 1–4 line growth can
                // never exceed the inspector column.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep the empty field at one line. The vertical text field
                // grows from its intrinsic height as the text wraps.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)

            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return)
            .accessibilityLabel("Send note")
            // Keep the button centered in a 36pt control slot. The slot also
            // keeps the same 4pt inset above and below when the field grows.
            .frame(width: 36, height: 36)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .simultaneousGesture(
            TapGesture().onEnded {
                isFocused.wrappedValue = true
            }
        )
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}

/// Single-line title that scrolls horizontally when it overflows its frame,
/// holding briefly at each end. When the text fits it is laid out statically
/// with no animation at all. Timeline-driven so the hold/slide phases repeat
/// without the abrupt reversal of an autoreversing animation.
private struct MarqueeTitle: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0

    private static let hold: TimeInterval = 1.2
    private static let speed: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let overflow = max(0, textWidth - proxy.size.width)
            Group {
                if overflow > 1 {
                    TimelineView(.animation) { timeline in
                        label
                            .offset(x: offset(at: timeline.date, overflow: overflow))
                    }
                } else {
                    label
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
        }
        .frame(height: 20)
        .background(measurement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
    }

    /// Offscreen copy measured at its natural width; the result drives both the
    /// overflow computation and the switch between static and scrolling.
    private var measurement: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in textWidth = width }
                }
            }
    }

    /// hold → slide left → hold → slide right → repeat.
    private func offset(at date: Date, overflow: CGFloat) -> CGFloat {
        let travel = max(Double(overflow) / Double(Self.speed), 1.0)
        let hold = Self.hold
        let cycle = 2 * (hold + travel)
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        if t < hold { return 0 }
        if t < hold + travel { return -overflow * ease((t - hold) / travel) }
        if t < 2 * hold + travel { return -overflow }
        return -overflow * (1 - ease((t - 2 * hold - travel) / travel))
    }

    private func ease(_ x: Double) -> CGFloat {
        let clamped = min(max(x, 0), 1)
        return CGFloat(clamped * clamped * (3 - 2 * clamped))
    }
}

private struct PaneWaveformTimeLabels: View {
    let transportState: TransportState
    let duration: TimeInterval
    let isLoaded: Bool

    private var labelWidth: CGFloat {
        duration >= 3600 ? 56 : 42
    }

    var body: some View {
        let currentTime = isLoaded ? transportState.currentTime : 0

        HStack {
            Text(formatClock(currentTime))
                .frame(width: labelWidth, alignment: .trailing)

            Spacer(minLength: 0)

            Text(formatClock(duration))
                .frame(width: labelWidth, alignment: .leading)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct MixNoteRow: View {
    let note: Note
    let timestamp: TimeInterval?
    let isActive: Bool
    let isSelected: Bool
    let isPreviousMix: Bool
    @Binding var editingNoteID: UUID?
    let onSelect: () -> Void
    let onSave: (String) -> Bool
    let onDelete: () -> Void

    @State private var draft = ""
    @State private var saveError = false
    @FocusState private var isInputFocused: Bool

    init(
        note: Note,
        timestamp: TimeInterval?,
        isActive: Bool,
        isSelected: Bool,
        isPreviousMix: Bool = false,
        editingNoteID: Binding<UUID?>,
        onSelect: @escaping () -> Void,
        onSave: @escaping (String) -> Bool,
        onDelete: @escaping () -> Void
    ) {
        self.note = note
        self.timestamp = timestamp
        self.isActive = isActive
        self.isSelected = isSelected
        self.isPreviousMix = isPreviousMix
        self._editingNoteID = editingNoteID
        self.onSelect = onSelect
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var isEditing: Bool {
        editingNoteID == note.id
    }

    var body: some View {
        Group {
            if isEditing {
                if timestamp == nil {
                    HStack(alignment: .center, spacing: 8) {
                        editingField
                        saveButton
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        topRow
                        editingField
                    }
                }
            } else if timestamp == nil {
                // No timestamp → no chip → collapse to a single line.
                HStack(alignment: .center, spacing: 8) {
                    noteText
                    Spacer(minLength: 8)
                    noteMenu
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    topRow
                    noteText
                }
            }
        }
        .padding(BounceConstants.noteCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(
                cornerRadius: BounceConstants.noteCardCornerRadius,
                style: .continuous
            )
            .strokeBorder(cardBorder, lineWidth: 0.5)
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: BounceConstants.noteCardCornerRadius,
                style: .continuous
            )
        )
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: beginEditing)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .onChange(of: note.content, initial: true) { _, newValue in
            if !isEditing { draft = newValue ?? "" }
        }
        .onChange(of: isEditing) { _, editing in
            isInputFocused = editing
        }
        .onChange(of: isInputFocused) { _, focused in
            guard !focused, isEditing else { return }
            finishEditingFromFocusLoss()
        }
        .padding(.horizontal, BounceConstants.noteCardInset)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 8) {
            timestampChip

            Spacer(minLength: 8)

            // Reserved for a future mix/device badge. It must keep its
            // width without introducing a visual placeholder today.
            Color.clear
                .frame(width: BounceConstants.noteBadgeSlotWidth, height: 24)

            if isEditing { saveButton } else { noteMenu }
        }
    }

    private var noteText: some View {
        Text(note.content ?? "Voice note")
            .font(.system(size: 12))
            .foregroundStyle(isPreviousMix ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 20, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: beginEditing)
            .onTapGesture(perform: onSelect)
    }

    private var timestampChip: some View {
        Group {
            if let timestamp {
                Button(action: onSelect) {
                    Text(formatTimestamp(timestamp))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(isPreviousMix ? .secondary : .primary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .help("Review at \(formatTimestamp(timestamp))")
                .accessibilityLabel("Review at \(formatTimestamp(timestamp))")
            } else {
                Color.clear.frame(width: BounceConstants.noteBadgeSlotWidth, height: 24)
            }
        }
    }

    private var noteMenu: some View {
        Button {
            NoteActionsMenu(onEdit: beginEditing, onDelete: onDelete).popUpAtMouse()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isPreviousMix ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: .secondaryLabelColor))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Note actions")
        .accessibilityLabel("Note actions")
    }

    /// Same font, line height and zero insets as `noteText`, so the card keeps
    /// its height when toggling between display and edit.
    private var editingField: some View {
        TextField("Edit note…", text: $draft, axis: .vertical)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .focused($isInputFocused)
            .submitLabel(.send)
            .onSubmit(submitEdit)
            .onExitCommand(perform: cancelEditing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 20, alignment: .leading)
    }

    /// Takes the menu's 24pt layout slot; the 28pt hit target overflows the
    /// slot instead of growing the row. A failed save tints it red (no extra row).
    private var saveButton: some View {
        Button(action: submitEdit) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(saveError ? Color.red : (draftIsEmpty ? Color.secondary : Color.accentColor))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .disabled(draftIsEmpty)
        .help(saveError ? "Not saved" : "Save note")
        .accessibilityLabel("Save note")
    }

    /// Flat semantic card surface that reuses the exact tracklist tokens from
    /// `HoverableSelectionRowView` over the same neutral column base: a normal
    /// card matches the row hover fill (`labelColor` 4%) and an active note
    /// matches the row selection fill (`labelColor` 10%). The active fill
    /// replaces the hover fill rather than stacking on it, and the flat base
    /// removes the material vibrancy that leaked a blue backdrop tint.
    @ViewBuilder
    private var cardBackground: some View {
        if isPreviousMix {
            RoundedRectangle(
                cornerRadius: BounceConstants.noteCardCornerRadius,
                style: .continuous
            )
            .fill(Color.clear)
        } else {
            ZStack {
                RoundedRectangle(
                    cornerRadius: BounceConstants.noteCardCornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .controlBackgroundColor))

                RoundedRectangle(
                    cornerRadius: BounceConstants.noteCardCornerRadius,
                    style: .continuous
                )
                .fill(isActive ? BounceSelectionPalette.selectionColor : BounceSelectionPalette.hoverColor)
            }
        }
    }

    private var cardBorder: Color {
        if isPreviousMix {
            return Color(nsColor: .quaternaryLabelColor)
        }
        return isSelected ? Color.primary.opacity(0.12) : .clear
    }

    private func beginEditing() {
        draft = note.content ?? ""
        editingNoteID = note.id
    }

    private func submitEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if onSave(trimmed) {
            editingNoteID = nil
            saveError = false
        } else {
            saveError = true
        }
    }

    private func finishEditingFromFocusLoss() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingNoteID = nil
            saveError = false
            return
        }

        if onSave(trimmed) {
            editingNoteID = nil
            saveError = false
        } else {
            saveError = true
        }
    }

    private func cancelEditing() {
        editingNoteID = nil
        saveError = false
    }

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
private final class NoteActionsMenu: NSObject {
    private let onEdit: () -> Void
    private let onDelete: () -> Void

    init(onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    func popUpAtMouse() {
        let menu = NSMenu()
        for item in [
            NSMenuItem(title: "Edit", symbol: "pencil", action: #selector(editNote), target: self),
            NSMenuItem(title: "Delete", symbol: "trash", action: #selector(deleteNote), target: self)
        ] {
            item.representedObject = self
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func editNote() { onEdit() }
    @objc private func deleteNote() { onDelete() }
}

