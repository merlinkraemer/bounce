import SwiftUI
import SwiftData
import BounceKit
import AppKit
import Combine

/// Top-level library tab content. Owns the @Query for tracks, builds the
/// flattened item list, and routes table callbacks (rename, delete, add
/// to playlist) back through SwiftData. The actual AppKit table lives in
/// `LibraryTrackTableView.swift`.
struct LibraryListView: View {
    private let listOuterHorizontalInset: CGFloat = 16

    let sectionHeader: AnyView
    let tracks: [Track]
    /// When true, only `isSet` tracks; when false, only non-set tracks (All Tracks).
    var showsSetsOnly: Bool = false
    /// All Tracks hides long recordings only while the Recordings tab is on.
    var excludesSets: Bool = true
    /// Measured header body height, owned by `LibraryContent` so it survives the
    /// unmount on a tab switch (local state reset to 0 and made row 0 ramp
    /// 1 -> 53 -> 123).
    @Binding var headerHeight: CGFloat
    let searchText: String
    @Binding var sortModeRaw: String
    @Binding var selectedVersionID: UUID?
    @Binding var selectedVersionIDs: Set<UUID>
    let inspectedVersionID: UUID?
    let onInspectVersion: (UUID) -> Void
    let onPlayVersion: (UUID) -> Void
    let onTogglePlayback: (UUID) -> Void
    let onCreatedPlaylist: (UUID) -> Void
    let onAddToQueue: (UUID) -> Void

    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]

    private var playlists: [Playlist] { allPlaylists.filter { !$0.isSoftDeleted } }
    @Environment(PlaybackEngine.self) private var playbackEngine
    @Environment(\.modelContext) private var modelContext
    @Environment(InlineRenameManager.self) private var renameManager

    @State private var workingTitleTrack: Track?
    @State private var trackToEdit: Track?
    @State private var expandedTrackIDs: Set<UUID> = []
    @State private var pendingDeletion: PendingMixDeletion?
    @State private var newPlaylistRequest: NewPlaylistRequest?

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sortMode: AllTracksSortMode {
        AllTracksSortMode(rawValue: sortModeRaw) ?? .dateAdded
    }

    private var playlistMenuItems: [LibraryPlaylistMenuItem] {
        playlists.map { LibraryPlaylistMenuItem(id: $0.id, name: $0.name) }
    }

    @State private var listItems: [LibraryListItem] = []
    @State private var lastContentRevision: Int?

    private var items: [LibraryListItem] {
        listItems
    }

    /// Cheap signature over the mutable fields the rows display. Used to rebuild
    /// after in-place edits (rename, artwork, released) that don't change the
    /// `tracks` array identity and so are missed by `.onChange(of: tracks)`.
    /// Uses stored `artworkRevision` — never faults artwork blobs.
    private var contentRevision: Int {
        var hasher = Hasher()
        for track in tracks {
            hasher.combine(track.id)
            hasher.combine(track.name)
            hasher.combine(track.displayTitle)
            hasher.combine(track.artist)
            hasher.combine(track.isReleased)
            hasher.combine(track.isSet)
            hasher.combine(track.artworkRevision ?? 0)
            for version in track.versions {
                hasher.combine(version.id)
                hasher.combine(version.label)
                hasher.combine(version.addedAt)
                hasher.combine(track.visibleNotes.filter { $0.versionID == version.id }.count)
            }
        }
        return hasher.finalize()
    }

    private func rebuildItems() {
        var result: [LibraryListItem] = []

        let visibleTracks = sortedTracksForDisplay().compactMap(filteredVersions(for:))
        let visibleTrackIDs = Set(visibleTracks.map(\.track.id))
        expandedTrackIDs = expandedTrackIDs.intersection(visibleTrackIDs)

        for (trackIndex, entry) in visibleTracks.enumerated() {
            let track = entry.track
            let hasOlderVersions = !track.isSet && entry.versions.count > 1
            let isExpanded = hasOlderVersions
                && (expandedTrackIDs.contains(track.id) || entry.expandForSearch)
            let latestVersionID = entry.versions.first?.id
            let count = track.isSet ? 1 : entry.versions.count

            guard let latest = entry.versions.first else { continue }
            result.append(.row(makeSnapshot(
                id: "parent-\(track.id.uuidString)",
                track: track,
                version: latest,
                count: count,
                latestVersionID: latestVersionID,
                hasOlderVersions: hasOlderVersions,
                isExpanded: isExpanded,
                rowKind: track.isSet ? .flat : .parent,
                showsExpansionControl: !showsSetsOnly
            )))

            if isExpanded && !track.isSet {
                for version in entry.versions {
                    result.append(.row(makeSnapshot(
                        id: "mix-\(version.id.uuidString)",
                        track: track,
                        version: version,
                        count: count,
                        latestVersionID: latestVersionID,
                        hasOlderVersions: hasOlderVersions,
                        isExpanded: true,
                        rowKind: .mix,
                        showsExpansionControl: false
                    )))
                }
            }

            if trackIndex != visibleTracks.count - 1 {
                result.append(.separator("separator-\(track.id.uuidString)"))
            }
        }

        listItems = result
        lastContentRevision = contentRevision
    }

    private func makeSnapshot(
        id: String,
        track: Track,
        version: Version,
        count: Int,
        latestVersionID: UUID?,
        hasOlderVersions: Bool,
        isExpanded: Bool,
        rowKind: LibraryRowKind,
        showsExpansionControl: Bool
    ) -> LibraryTrackRowSnapshot {
        LibraryTrackRowSnapshot(
            id: id,
            trackID: track.id,
            trackName: track.displayTitle,
            artworkRevision: track.artworkRevision,
            versionID: version.id,
            versionLabel: version.label,
            versionCountInGroup: count,
            isLatestVersion: version.id == latestVersionID,
            hasOlderVersions: hasOlderVersions,
            isExpanded: isExpanded,
            addedAt: version.addedAt,
            duration: version.duration,
            filePath: version.filePath,
            processingState: version.processingState,
            isReleased: track.isReleased,
            rowKind: rowKind,
            noteCount: track.visibleNotes.filter { $0.versionID == version.id }.count,
            isViewingOlderVersion: rowKind == .parent
                && inspectedVersionID != version.id
                && track.versions.contains(where: { $0.id == inspectedVersionID }),
            showsExpansionControl: showsExpansionControl
        )
    }

    private func sortedTracksForDisplay() -> [Track] {
        let filtered = tracks.filter { track in
            if showsSetsOnly != track.isSet, showsSetsOnly || excludesSets { return false }
            guard !trimmedSearchText.isEmpty else { return true }
            return matchesSearch(track)
        }

        return filtered.sorted {
            sortMode.precedes(
                lhsDate: $0.latestVersionDate ?? $0.createdAt,
                lhsName: $0.name,
                rhsDate: $1.latestVersionDate ?? $1.createdAt,
                rhsName: $1.name
            )
        }
    }

    private func matchesSearch(_ track: Track) -> Bool {
        if track.name.localizedCaseInsensitiveContains(trimmedSearchText) { return true }
        if track.artist.localizedCaseInsensitiveContains(trimmedSearchText) { return true }
        return track.versions.contains { version in
            version.label.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    var body: some View {
        // Evaluate once per render — `items` is a computed property that walks
        // every track/version, and body referenced it twice (empty check +
        // table), doubling the cost of each selection-driven re-render.
        let items = self.items
        Group {
            if items.isEmpty {
                if searchText.isEmpty {
                    if showsSetsOnly {
                        ContentUnavailableView(
                            RecordingsCopy.emptyTitle,
                            systemImage: "sdcard",
                            description: Text(RecordingsCopy.emptyDescription)
                        )
                    } else {
                        EmptyLibraryDropView()
                    }
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text(showsSetsOnly
                            ? "No recordings match \"\(searchText)\"."
                            : "No tracks match \"\(searchText)\".")
                    )
                }
            } else {
                GeometryReader { geometry in
                    let columns = LibraryColumnVisibility(width: geometry.size.width)
                    let headerBody = VStack(spacing: 0) {
                        sectionHeader
                        // No extra horizontal padding: the header is table row 0,
                        // so it already shares the rows' x-origin and width.
                        header(columns: columns)
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    VStack(spacing: 0) {
                        LibraryTrackTableView(
                            header: AnyView(headerBody),
                            headerHeight: headerHeight,
                            onHeaderHeightChange: updateHeaderHeight,
                            items: items,
                            playlists: playlistMenuItems,
                            artworkForTrack: { id in tracks.first(where: { $0.id == id })?.artwork },
                            selectedVersionID: $selectedVersionID,
                            selectedVersionIDs: $selectedVersionIDs,
                            inspectedVersionID: inspectedVersionID,
                            inspectedVersionLabel: inspectedVersionID.flatMap { id in
                                tracks.flatMap(\.versions).first(where: { $0.id == id })?.label
                            },
                            columns: columns,
                            onInspectVersion: onInspectVersion,
                            onToggleTrackExpansion: toggleTrackExpansion,
                            loadedVersionID: playbackEngine.loadedVersionID,
                            isPlaying: playbackEngine.isPlaying,
                            renameTarget: renameManager.activeTarget,
                            renameManager: renameManager,
                            onPlayFromStart: onPlayVersion,
                            onTogglePlayback: onTogglePlayback,
                            onAddTrackToPlaylist: addTrackToPlaylist,
                            onCreatePlaylistWithTrack: createPlaylistWithTrack,
                            onAddVersionToQueue: onAddToQueue,
                            onDeleteVersion: deleteVersion,
                            onDeleteSelected: deleteSelectedVersions,
                            onAddSelectedToPlaylist: addSelectedToPlaylist,
                            onCreatePlaylistWithSelected: createPlaylistWithSelected,
                            onNameThisVersion: presentWorkingTitleSheet,
                            onToggleReleased: toggleReleased,
                            onEditTrack: { trackID in
                                trackToEdit = tracks.first(where: { $0.id == trackID })
                            }
                        )
                        .padding(.horizontal, listOuterHorizontalInset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .columnBackground(.content)
        .sheet(item: $workingTitleTrack) { track in
            WorkingTitleSheet(track: track)
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $newPlaylistRequest) { request in
            PlaylistEditSheet(playlist: nil, folder: nil, onSaved: { playlist in
                fillNewPlaylist(playlist, with: request.picks)
            })
        }
        .alert(
            pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) { performDeletion(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
        .onChange(of: tracks, initial: true) { rebuildItems() }
        .onChange(of: searchText, initial: true) { rebuildItems() }
        .onChange(of: sortModeRaw) { _, _ in rebuildItems() }
        .onChange(of: showsSetsOnly) { _, _ in rebuildItems() }
        .onChange(of: inspectedVersionID) { _, _ in rebuildItems() }
        // In-place edits (rename, artwork, released) don't change the tracks
        // array identity, so refresh when the store saves if the display
        // signature actually changed.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            if contentRevision != lastContentRevision { rebuildItems() }
        }
    }

    /// Only a real change propagates: this height becomes row 0's height, so
    /// a redundant re-report would invalidate row height in response to its
    /// own result.
    private func updateHeaderHeight(_ height: CGFloat) {
        let accepted = abs(height - headerHeight) > 0.5
        guard accepted else { return }
        headerHeight = height
    }

    private func presentWorkingTitleSheet(for trackID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        workingTitleTrack = track
    }

    private func toggleReleased(for trackID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        track.isReleased.toggle()
        track.updatedAt = .now
        track.lastTouchedAt = .now
        try? modelContext.save()
    }

    private func filteredVersions(for track: Track) -> (track: Track, versions: [Version], expandForSearch: Bool)? {
        let allVersions = track.versions.sorted { $0.addedAt > $1.addedAt }
        guard !allVersions.isEmpty else { return nil }
        guard !trimmedSearchText.isEmpty else {
            return (track, allVersions, false)
        }

        let trackMatches = track.name.localizedCaseInsensitiveContains(trimmedSearchText)
            || track.artist.localizedCaseInsensitiveContains(trimmedSearchText)
        let matchingVersions = allVersions.filter { version in
            version.label.localizedCaseInsensitiveContains(trimmedSearchText)
        }

        guard trackMatches || !matchingVersions.isEmpty else { return nil }

        // A version-label match must expand the track so an older mix that
        // matched search is reachable instead of being hidden behind the
        // collapsed latest row.
        return (track, allVersions, !trackMatches && !matchingVersions.isEmpty)
    }

    private func toggleTrackExpansion(_ trackID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }),
              !track.isSet,
              track.versions.count > 1 else { return }

        if expandedTrackIDs.contains(trackID) {
            expandedTrackIDs.remove(trackID)

        } else {
            expandedTrackIDs.insert(trackID)
        }
        rebuildItems()
    }

    private func header(columns: LibraryColumnVisibility) -> some View {
        HStack(spacing: LibraryRowMetrics.spacing) {
            if !showsSetsOnly {
                Color.clear.frame(width: LibraryRowMetrics.expansionWidth)
            }
            Color.clear.frame(width: LibraryRowMetrics.artworkSide)
            Text(columns.foldsMixIntoSubtitle ? "Song / Mix" : "Song")
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: LibraryRowMetrics.contentGapMin)
            if columns.showsAdded {
                Text("Added")
                    .frame(width: LibraryRowMetrics.dateWidth, alignment: .trailing)
            }
            if columns.showsDuration {
                Text("Time")
                    .monospacedDigit()
                    .frame(width: LibraryRowMetrics.durationWidth, alignment: .trailing)
                    .overlay(alignment: .leading) {
                        // Overlay so the divider takes no layout width and
                        // cannot shift the columns relative to the cells.
                        Color.primary.opacity(0.08)
                            .frame(width: 0.5, height: 12)
                            .offset(x: -LibraryRowMetrics.spacing / 2)
                    }
            }
            Spacer().frame(width: LibraryRowMetrics.menuGap)
            Color.clear.frame(width: LibraryRowMetrics.menuWidth)
        }
        .padding(.leading, LibraryRowMetrics.leadingInset)
        .padding(.trailing, LibraryRowMetrics.trailingInset)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Playlists

    private func addTrackToPlaylist(trackID: UUID, playlistID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }),
              let playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        guard !playlist.entries.contains(where: { $0.trackID == track.id }) else { return }

        let entry = PlaylistEntry(
            playlistID: playlist.id,
            trackID: track.id,
            versionID: track.latestVersion?.id,
            position: nextPlaylistEntryPosition(in: playlist)
        )
        playlist.entries.append(entry)
        playlist.updatedAt = .now
        saveContext("add track to playlist")
    }

    private func createPlaylistWithTrack(trackID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        newPlaylistRequest = NewPlaylistRequest(picks: [
            NewPlaylistRequest.Pick(trackID: track.id, versionID: track.latestVersion?.id)
        ])
    }

    private func fillNewPlaylist(_ playlist: Playlist, with picks: [NewPlaylistRequest.Pick]) {
        var nextPosition = nextPlaylistEntryPosition(in: playlist)
        var seenTrackIDs = Set(playlist.entries.map(\.trackID))
        for pick in picks {
            guard seenTrackIDs.insert(pick.trackID).inserted else { continue }
            let entry = PlaylistEntry(
                playlistID: playlist.id,
                trackID: pick.trackID,
                versionID: pick.versionID,
                position: nextPosition
            )
            playlist.entries.append(entry)
            nextPosition += 1
        }
        playlist.updatedAt = .now
        saveContext("fill new playlist")
        onCreatedPlaylist(playlist.id)
    }

    private func nextPlaylistEntryPosition(in playlist: Playlist) -> Int {
        (playlist.entries.map(\.position).max() ?? -1) + 1
    }

    private func addSelectedToPlaylist(snapshots: [LibraryTrackRowSnapshot], playlistID: UUID) {
        guard let playlist = playlists.first(where: { $0.id == playlistID }) else { return }

        var nextPosition = nextPlaylistEntryPosition(in: playlist)
        var seenTrackIDs = Set(playlist.entries.map(\.trackID))
        for snapshot in snapshots {
            guard seenTrackIDs.insert(snapshot.trackID).inserted else { continue }
            let entry = PlaylistEntry(
                playlistID: playlist.id,
                trackID: snapshot.trackID,
                versionID: snapshot.versionID,
                position: nextPosition
            )
            playlist.entries.append(entry)
            nextPosition += 1
        }
        playlist.updatedAt = .now
        saveContext("add selected tracks to playlist")
    }

    private func createPlaylistWithSelected(snapshots: [LibraryTrackRowSnapshot]) {
        newPlaylistRequest = NewPlaylistRequest(
            picks: snapshots.map { NewPlaylistRequest.Pick(trackID: $0.trackID, versionID: $0.versionID) }
        )
    }

    // MARK: - Deletion

    private func deleteVersion(trackID: UUID, versionID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }),
              let version = track.versions.first(where: { $0.id == versionID }) else { return }
        let isLastMix = track.versions.count == 1
        let mixLabel = version.label.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDeletion = PendingMixDeletion(
            mixes: [PendingMixDeletion.Mix(trackID: trackID, versionID: versionID)],
            title: isLastMix || mixLabel.isEmpty
                ? "Delete \u{201C}\(track.displayTitle)\u{201D}?"
                : "Delete \u{201C}\(mixLabel)\u{201D}?",
            message: isLastMix
                ? "The track, its notes and its audio file are removed. This can\u{2019}t be undone."
                : "This mix and its audio file are removed. This can\u{2019}t be undone."
        )
    }

    private func deleteSelectedVersions(snapshots: [LibraryTrackRowSnapshot]) {
        guard snapshots.count > 1 else {
            if let snapshot = snapshots.first {
                deleteVersion(trackID: snapshot.trackID, versionID: snapshot.versionID)
            }
            return
        }
        pendingDeletion = PendingMixDeletion(
            mixes: snapshots.map { PendingMixDeletion.Mix(trackID: $0.trackID, versionID: $0.versionID) },
            title: "Delete \(snapshots.count) Mixes?",
            message: "The selected mixes and their audio files are removed. Tracks left without a mix are removed with their notes. This can\u{2019}t be undone."
        )
    }

    private func performDeletion(_ deletion: PendingMixDeletion) {
        let versionIDs = Set(deletion.mixes.map(\.versionID))
        if let loaded = playbackEngine.loadedVersionID, versionIDs.contains(loaded) {
            playbackEngine.stop()
        }

        var paths: [String] = []
        for mix in deletion.mixes {
            guard let track = tracks.first(where: { $0.id == mix.trackID }),
                  let version = track.versions.first(where: { $0.id == mix.versionID }) else { continue }
            paths += modelContext.deleteVersion(version, of: track)
        }

        do {
            try modelContext.save()
            modelContext.removeUnreferencedFiles(atPaths: paths)
        } catch {
            SyncLog.sender.error("Failed to delete mixes: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveContext(_ action: String) {
        do {
            try modelContext.save()
        } catch {
            SyncLog.sender.error("Failed to \(action): \(error.localizedDescription, privacy: .public)")
        }
    }
}


private struct PendingMixDeletion: Identifiable {
    struct Mix {
        let trackID: UUID
        let versionID: UUID
    }

    let id = UUID()
    let mixes: [Mix]
    let title: String
    let message: String
}

private struct NewPlaylistRequest: Identifiable {
    struct Pick {
        let trackID: UUID
        let versionID: UUID?
    }

    let id = UUID()
    let picks: [Pick]
}

/// Empty All Tracks: one quiet line plus a text link; the whole area is a drop
/// target. Imports go through `ImportHandoff` so they use the same pipeline
/// (drop handler, open panel, review sheet) as every other entry point.
private struct EmptyLibraryDropView: View {
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("Drop audio here to import")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("or choose files\u{2026}") { ImportHandoff.send(.picker) }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(isTargeted ? 0.06 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.45 : 0), lineWidth: 1)
                .padding(12)
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .contentShape(Rectangle())
        .externalFileDrop(isTargeted: $isTargeted) { urls in
            ImportHandoff.send(.drop(urls))
        }
    }
}
