import SwiftUI
import AppKit

struct LibraryPlaylistMenuItem: Identifiable, Equatable {
    let id: UUID
    let name: String
}

struct LibraryRowView: View {
    let snapshot: LibraryTrackRowSnapshot
    /// Loaded lazily for visible cells — not part of the list snapshot.
    let artworkData: Data?
    let playlists: [LibraryPlaylistMenuItem]
    let isSelected: Bool
    let isHovered: Bool
    let isLoaded: Bool
    let isPlaying: Bool
    let inspectedVersionID: UUID?
    let inspectedVersionLabel: String?
    let columns: LibraryColumnVisibility
    @Bindable var renameManager: InlineRenameManager
    let onTogglePlayback: () -> Void
    let onToggleExpansion: () -> Void
    let onAddToPlaylist: (UUID) -> Void
    let onCreatePlaylist: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void
    let onNameThisVersion: () -> Void
    let isReleased: Bool
    let onToggleReleased: () -> Void
    let onEditTrack: () -> Void

    private static let artworkBG = Color(.secondarySystemFill)
    private static let artworkBGActive = Color(.tertiarySystemFill)
    private static let noteIconColor = Color(nsColor: .tertiaryLabelColor)
    private static let labelColor = Color(nsColor: .labelColor)
    private static let secondaryLabelColor = Color(nsColor: .secondaryLabelColor)

    private var isPending: Bool { snapshot.processingState == .pending }
    private var isFailed: Bool { snapshot.processingState == .failed }
    private var isParent: Bool { snapshot.rowKind == .parent }
    private var isMix: Bool { snapshot.rowKind == .mix }

    /// `artworkData` can be present but non-decodable; the placeholder must
    /// cover that case too, not only `nil`.
    private var hasDecodableArtwork: Bool {
        guard let artworkData else { return false }
        return ArtworkThumbnailCache.thumbnail(
            artworkData,
            id: snapshot.trackID,
            side: 40,
            revision: snapshot.artworkRevision
        ) != nil
    }

    var body: some View {
        HStack(spacing: LibraryRowMetrics.spacing) {
            if snapshot.showsExpansionControl {
                if isParent && snapshot.hasOlderVersions {
                    Button(action: onToggleExpansion) {
                        Image(systemName: snapshot.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: LibraryRowMetrics.expansionWidth, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(snapshot.isExpanded ? "Hide older mixes" : "Show older mixes")
                } else {
                    Color.clear.frame(width: LibraryRowMetrics.expansionWidth)
                }
            }

            if isMix {
                // Mix rows are denser than parent rows. Keep the hidden
                // artwork slot only as tall as the text block so the row's
                // 40pt table height is not forced to clip its content.
                Color.clear.frame(width: LibraryRowMetrics.artworkSide, height: 40)
                mixContent
            } else {
                artwork
                    .frame(width: LibraryRowMetrics.artworkSide, height: 40)
                parentContent
            }

            Spacer(minLength: LibraryRowMetrics.contentGapMin)

            if columns.showsAdded {
                Text(formatDate(snapshot.addedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Self.secondaryLabelColor)
                    .frame(width: LibraryRowMetrics.dateWidth, alignment: .trailing)
                    .opacity(isPending ? 0.4 : 1)
            }

            if columns.showsDuration || isPending || isFailed {
                trailingStatus
                    .frame(width: LibraryRowMetrics.durationWidth, alignment: .trailing)
            }

            Spacer().frame(width: LibraryRowMetrics.menuGap)

            Menu { contextMenuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isLoaded ? Color.accentColor : Color.secondary)
                    .frame(width: LibraryRowMetrics.menuWidth, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered || isLoaded ? 1 : 0)
            .allowsHitTesting(isHovered || isLoaded)
        }
        .padding(.leading, LibraryRowMetrics.leadingInset)
        .padding(.trailing, LibraryRowMetrics.trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The enclosing `HoverableSelectionRowView` (AppKit) owns the row
        // highlight for both hover and selection, drawn as a single inset
        // rounded path. A SwiftUI fill here layered a second, full-width
        // rectangular highlight on top of it. `isSelected`/`isHovered` are
        // still consumed above for the ellipsis menu, artwork, and text
        // treatment — only the competing background is removed.
        .contentShape(Rectangle())
    }

    private var parentContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if renameManager.activeTarget?.id == snapshot.trackID && renameManager.activeTarget?.kind == .track {
                FocusableTextField(
                    text: renameManager.editTextBinding,
                    onCommit: { renameManager.commit() },
                    onCancel: { renameManager.cancel() }
                )
                .font(.system(size: 14, weight: .semibold))
            } else {
                Text(snapshot.trackName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(2)
            }

            Text(parentSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Click the song to inspect its latest mix")
        }
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .opacity(isPending ? 0.4 : 1)
    }

    private var mixContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if renameManager.activeTarget?.id == snapshot.versionID && renameManager.activeTarget?.kind == .version {
                FocusableTextField(
                    text: renameManager.editTextBinding,
                    onCommit: { renameManager.commit() },
                    onCancel: { renameManager.cancel() }
                )
                .font(.system(size: 13))
            } else {
                Text(mixLabel(snapshot.versionLabel))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(1)
            }
            // Tags, not a separator string: "Latest" is a quiet capsule and
            // the facts around it are plain secondary text, so nothing renders
            // a leading separator dot when there is no element before it.
            HStack(spacing: 6) {
                if snapshot.isLatestVersion {
                    latestTag
                }
                if !columns.showsAdded {
                    Text(formatDate(snapshot.addedAt))
                        .foregroundStyle(.secondary)
                }
                if snapshot.noteCount > 0 {
                    Text(snapshot.noteCount == 1 ? "1 note" : "\(snapshot.noteCount) notes")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        }
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    /// Small caption-weight capsule for the newest mix. Same quiet fill
    /// vocabulary as the hover rows and the header action capsules
    /// (`Color.primary.opacity(...)` over a plain `Capsule`) with no stroke, so
    /// it adapts to light and dark appearance and stays lighter than a badge.
    private var latestTag: some View {
        Text("Latest")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var parentSummary: String {
        if snapshot.isViewingOlderVersion {
            return inspectedVersionLabel.map { "Viewing \(mixLabel($0))" } ?? "Viewing another mix"
        }
        if snapshot.versionCountInGroup > 1 {
            return "\(snapshot.versionCountInGroup) mixes · Latest: \(mixLabel(snapshot.versionLabel))"
        }
        return "\(mixLabel(snapshot.versionLabel))"
    }

    private func mixLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("mix ") ? trimmed : "Mix \(trimmed)"
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isPending {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        } else {
            Text(formatDuration(snapshot.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Self.secondaryLabelColor)
                .lineLimit(1)
        }
    }

    private var artwork: some View {
        ZStack {
            if let data = artworkData,
               let nsImage = ArtworkThumbnailCache.thumbnail(
                data,
                id: snapshot.trackID,
                side: 40,
                revision: snapshot.artworkRevision
               ) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                // Dim overlay when an action affordance is on top, so the
                // white play / pause / bars icon stays readable.
                if isPlaying || isHovered || isLoaded {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected || isLoaded ? Self.artworkBGActive : Self.artworkBG)
            }

            if isPending || isFailed {
                // No play affordance until processing completes. The
                // ghost/error state is communicated by the dim title +
                // trailing spinner / warning icon.
                EmptyView()
            } else if isPlaying && !isHovered {
                Button(action: onTogglePlayback) {
                    PlayingBarsIndicator()
                        .frame(width: 18, height: 18)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if isHovered || isLoaded {
                Button(action: onTogglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: isPlaying ? 14 : 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if artworkData == nil || !hasDecodableArtwork {
                Image("MusicNoteIcon").renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Self.noteIconColor)
            }
        }
        .frame(width: 40, height: 40)
        .opacity(isPending ? 0.4 : 1)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Menu {
            ForEach(playlists) { playlist in
                Button(playlist.name) { onAddToPlaylist(playlist.id) }
            }
            if !playlists.isEmpty { Divider() }
            Button("New Playlist…") { onCreatePlaylist() }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Button(action: onTogglePlayback) {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(isPending || isFailed)

        Button(action: onAddToQueue) {
            Label("Add to Queue", systemImage: "list.bullet")
        }

        Divider()

        Button(action: onEditTrack) {
            Label("Edit Track\u{2026}", systemImage: "pencil")
        }

        Button {
            renameManager.begin(
                target: .init(kind: .track, id: snapshot.trackID),
                initialText: snapshot.trackName
            )
        } label: {
            Label("Rename Track", systemImage: "character.cursor.ibeam")
        }

        Button(action: onNameThisVersion) {
            Label("Name This Version…", systemImage: "tag")
        }

        Button(action: onToggleReleased) {
            Label(isReleased ? "Unmark as Released" : "Mark as Released",
                  systemImage: isReleased ? "checkmark.seal.fill" : "checkmark.seal")
        }

        if snapshot.versionCountInGroup > 1 {
            Button {
                renameManager.begin(
                    target: .init(kind: .version, id: snapshot.versionID),
                    initialText: snapshot.versionLabel
                )
            } label: {
                Label("Rename Version", systemImage: "pencil")
            }
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: snapshot.filePath)])
        } label: {
            Label("Show in Finder", systemImage: "doc")
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}

// MARK: - Inline rename text field (AppKit-backed for reliable first-responder)

/// An NSTextField wrapper that auto-focuses on appear and commits on Enter / cancels on Escape.
/// Required because `@FocusState` doesn't work reliably inside NSHostingView table cells.
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.stringValue = text

        focus(field)
        DispatchQueue.main.async {
            focus(field)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focus(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    private func focus(_ field: NSTextField) {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        let onCommit: () -> Void
        let onCancel: () -> Void
        private var didCancel = false
        private var didFinish = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !didFinish else { return }
            didFinish = true
            if !didCancel {
                onCommit()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didCancel = true
                didFinish = true
                onCancel()
                return true
            }
            return false
        }
    }
}

struct PlayingBarsIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                bar(height: heightFor(t: t, offset: 0.0))
                bar(height: heightFor(t: t, offset: 0.6))
                bar(height: heightFor(t: t, offset: 1.2))
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 3, height: height)
    }

    private func heightFor(t: TimeInterval, offset: TimeInterval) -> CGFloat {
        let phase = (sin((t * 5) + offset) + 1) / 2
        return 4 + (phase * 8)
    }
}
