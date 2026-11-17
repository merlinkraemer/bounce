import SwiftUI
import SwiftData
import UIKit
import BounceKit

private enum SongsListMetrics {
    static let horizontalInset: CGFloat = 8
}

private func trackMatchesSearch(_ track: Track, query: String) -> Bool {
    if track.name.localizedCaseInsensitiveContains(query) { return true }
    if let workingTitle = track.workingTitle,
       workingTitle.localizedCaseInsensitiveContains(query) { return true }
    if !track.artist.isEmpty, track.artist.localizedCaseInsensitiveContains(query) { return true }
    if track.latestVersionLabel.localizedCaseInsensitiveContains(query) { return true }
    return false
}

struct SongsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(iOSImportCoordinator.self) private var importCoordinator
    @Environment(UploadQueue.self) private var uploadQueue
    @AppStorage(BouncePreferenceKey.showSetsTab) private var showRecordings = BouncePreferenceDefault.showSetsTab
    @Query(sort: \Track.lastTouchedAt, order: .reverse) private var allQueriedTracks: [Track]

    private var tracks: [Track] { showRecordings ? allQueriedTracks.filter { !$0.isSet } : allQueriedTracks }

    @State private var isSelectingTracks = false
    @State private var showImportPicker = false
    @State private var selectedTrackIDs = Set<UUID>()
    @State private var showDeleteConfirmation = false
    @State private var selectionRemoval: DownloadManager.TrackRemoval = .delete
    @State private var selectionIncludesLocalOnly = false
    @State private var trackToRemove: Track?
    @State private var trackToRemoveRemoval: DownloadManager.TrackRemoval = .delete
    @State private var trackToEdit: Track?
    @State private var trackToAddToPlaylist: Track?
    @State private var showAddSelectedToPlaylist = false
    @State private var navigateToNewPlaylist: Playlist?
    @State private var sectionedMonths: [MonthSection] = []
    @State private var searchText = ""
    @State private var searchResultSections: [MonthSection] = []
    @State private var shareItem: ShareItem?
    @State private var queuedCount = 0

    private var sections: [MonthSection] {
        sectionedMonths
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedSections: [MonthSection] {
        searchQuery.isEmpty ? sections : searchResultSections
    }

    private func rebuildSearchResults() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard !searchQuery.isEmpty else {
                searchResultSections = []
                return
            }
            let filtered = tracks.filter { trackMatchesSearch($0, query: searchQuery) }
            let sorted = filtered.sorted {
                ($0.latestVersionDate ?? $0.createdAt) > ($1.latestVersionDate ?? $1.createdAt)
            }
            searchResultSections = LibrarySorting.sectionByMonth(LibrarySorting.groupBySiblings(sorted))
        }
    }

    private func rebuildSections() {
        let sorted = tracks.sorted {
            ($0.latestVersionDate ?? $0.createdAt) > ($1.latestVersionDate ?? $1.createdAt)
        }
        let groups = LibrarySorting.groupBySiblings(sorted)
        sectionedMonths = LibrarySorting.sectionByMonth(groups)
        rebuildSearchResults()
    }

    private var playbackQueue: [Track] {
        sections.flatMap { $0.groups.compactMap { $0.tracks.last } }
    }

    private func queueForTappedTrack(_ track: Track) -> [Track] {
        LibrarySorting.playbackContext(for: track, in: playbackQueue)
    }

    private var navigationTitle: String {
        guard isSelectingTracks else { return "Songs" }
        switch selectedTrackIDs.count {
        case 0: return "Select Tracks"
        case 1: return "1 Selected"
        default: return "\(selectedTrackIDs.count) Selected"
        }
    }

    private var selectedTrackRemovals: [DownloadManager.TrackRemoval] {
        tracks.filter { selectedTrackIDs.contains($0.id) }.compactMap { downloadManager.removal(for: $0) }
    }

    private var deleteConfirmationTitle: String {
        let single = selectedTrackIDs.count == 1
        switch selectionRemoval {
        case .delete:
            return single ? "Delete selected track?" : "Delete selected tracks?"
        case .removeDownload:
            return single ? "Remove download of selected track?" : "Remove downloads of selected tracks?"
        }
    }

    private var deleteConfirmationMessage: String {
        switch selectionRemoval {
        case .delete:
            return "This removes the selected tracks, their mixes, notes, and audio from this iPhone."
        case .removeDownload:
            let base = "The tracks stay in your library with their notes. Their audio is removed from this iPhone until you download it again."
            return selectionIncludesLocalOnly ? base + " Tracks that are only on this iPhone are deleted." : base
        }
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                EmptyStateBlock(
                    symbolName: "music.note",
                    symbolSize: 48,
                    title: "No Songs",
                    description: "Sync from your Mac or import audio from Files to fill this library."
                ) {
                    VStack(spacing: EmptyRecentLayout.stackSpacing) {
                        BouncePrimaryButton(
                            title: "Import from Files",
                            systemImage: "folder",
                            isDisabled: importCoordinator.isImporting
                        ) {
                            showImportPicker = true
                        }
                        ImportProgressIndicator(isImporting: importCoordinator.isImporting)
                        if let err = importCoordinator.importError, !err.isEmpty {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                songsList
            }
        }
        .sensoryFeedback(.success, trigger: queuedCount)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.currentTrack != nil {
                Color.clear.frame(height: 76)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelectingTracks {
                    Button("Done") { exitSelectionMode() }
                }
                if isSelectingTracks && !selectedTrackIDs.isEmpty {
                    Menu {
                        Button {
                            showAddSelectedToPlaylist = true
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                        }
                        let removals = selectedTrackRemovals
                        if !removals.isEmpty {
                            let removal: DownloadManager.TrackRemoval = removals.allSatisfy { $0 == .delete } ? .delete : .removeDownload
                            Button(role: .destructive) {
                                selectionRemoval = removal
                                selectionIncludesLocalOnly = removals.contains(.delete)
                                showDeleteConfirmation = true
                            } label: {
                                Label(TrackRemovalCopy.actionTitle(removal), systemImage: TrackRemovalCopy.systemImage(removal))
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert(deleteConfirmationTitle, isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(TrackRemovalCopy.actionTitle(selectionRemoval), role: .destructive) { removeSelectedTracks() }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            TrackRemovalCopy.confirmTitle(trackToRemoveRemoval, name: trackToRemove?.displayTitle ?? "track"),
            isPresented: Binding(
                get: { trackToRemove != nil },
                set: { if !$0 { trackToRemove = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { trackToRemove = nil }
            Button(TrackRemovalCopy.actionTitle(trackToRemoveRemoval), role: .destructive) {
                if let track = trackToRemove { removeTracks([track.id]) }
                trackToRemove = nil
            }
        } message: {
            Text(TrackRemovalCopy.message(trackToRemoveRemoval))
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(playlist: nil, tracks: tracks, preselectedTrackIDs: [track.id], createdPlaylist: $navigateToNewPlaylist)
        }
        .sheet(isPresented: $showAddSelectedToPlaylist) {
            AddTracksToPlaylistSheet(playlist: nil, tracks: tracks, preselectedTrackIDs: selectedTrackIDs, createdPlaylist: $navigateToNewPlaylist)
        }
        .navigationDestination(item: $navigateToNewPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .sheet(isPresented: $showImportPicker) {
            AudioDocumentPicker { urls in
                Task {
                    guard let url = urls.first else { return }
                    await importCoordinator.beginImportReview(for: url, context: modelContext)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .onChange(of: tracks, initial: true) {
            rebuildSections()
        }
        .onChange(of: workingTitleSignature) {
            rebuildSections()
        }
    }

    private var workingTitleSignature: [String?] {
        tracks.map(\.workingTitle)
    }

    private var songsList: some View {
        List {
            songsRows
        }
        .overlay {
            if !searchQuery.isEmpty && searchResultSections.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
        .transaction(value: searchQuery) { transaction in
            transaction.animation = nil
        }
        .onChange(of: searchText) {
            rebuildSearchResults()
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search Songs"
        )
    }

    @ViewBuilder
    private var songsRows: some View {
        ForEach(displayedSections) { section in
            ListSectionHeaderRow(title: section.label)

            ForEach(Array(section.groups.enumerated()), id: \.element.id) { index, group in
                ForEach(group.tracks) { track in
                    trackRow(for: track)
                }
                if shouldShowDivider(after: index, in: section.groups) {
                    siblingDivider
                }
            }
        }
    }

    private func shouldShowDivider(after index: Int, in groups: [SiblingGroup]) -> Bool {
        guard index < groups.count - 1 else { return false }
        let current = groups[index]
        let next = groups[index + 1]
        return current.tracks.count > 1 || next.tracks.count > 1
    }

    private func addToQueue(_ track: Track) {
        audioPlayer.addToQueue(track)
        queuedCount += 1
    }

    @ViewBuilder
    private func trackRow(for track: Track) -> some View {
        TrackRow(
            track: track,
            isSelecting: isSelectingTracks,
            isSelected: selectedTrackIDs.contains(track.id),
            onTapRow: { handleTrackTap(track) },
            onLongPress: {
                if !isSelectingTracks {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelectingTracks = true
                    }
                }
                toggleTrackSelection(track.id)
            },
            onAddToQueue: { addToQueue(track) },
            onAddToPlaylist: { trackToAddToPlaylist = track },
            onShare: {
                if let url = TrackShareURL.resolve(for: track) {
                    shareItem = ShareItem(url: url)
                }
            },
            onEdit: { trackToEdit = track },
            onDelete: {
                guard let removal = downloadManager.removal(for: track) else { return }
                trackToRemoveRemoval = removal
                trackToRemove = track
            }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelectingTracks {
                Button {
                    addToQueue(track)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                    .labelStyle(.iconOnly)
                }
                .tint(.blue)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: SongsListMetrics.horizontalInset,
            bottom: 0,
            trailing: SongsListMetrics.horizontalInset
        ))
    }

    private var siblingDivider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.5))
            .frame(height: 0.5)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: SongsListMetrics.horizontalInset + 52,
                bottom: 0,
                trailing: SongsListMetrics.horizontalInset
            ))
    }

    private func exitSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectingTracks = false
            selectedTrackIDs.removeAll()
        }
    }

    private func handleTrackTap(_ track: Track) {
        if isSelectingTracks {
            toggleTrackSelection(track.id)
            return
        }
        if audioPlayer.currentTrack?.id == track.id && audioPlayer.isPlaying {
            audioPlayer.openFullScreenPlayer()
            return
        }
        audioPlayer.load(track: track, queue: queueForTappedTrack(track), context: .autoplayLibrary)
        audioPlayer.openFullScreenPlayer()
    }

    private func toggleTrackSelection(_ trackID: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedTrackIDs.contains(trackID) {
                selectedTrackIDs.remove(trackID)
            } else {
                selectedTrackIDs.insert(trackID)
            }
        }
    }

    private func removeSelectedTracks() {
        removeTracks(selectedTrackIDs)
        selectedTrackIDs.removeAll()
        isSelectingTracks = false
    }

    private func removeTracks(_ trackIDs: Set<UUID>) {
        var localOnlyTracks: [Track] = []
        for track in tracks where trackIDs.contains(track.id) {
            switch downloadManager.removal(for: track) {
            case .removeDownload:
                downloadManager.removeDownloads(for: track)
            case .delete:
                localOnlyTracks.append(track)
            case nil:
                break
            }
        }
        downloadManager.deleteLocalTracks(localOnlyTracks)
    }
}
