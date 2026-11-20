import SwiftUI
import SwiftData
import UIKit
import BounceKit

private enum LibraryRowMetrics {
    static let horizontalInset: CGFloat = 8
    static let iconWidth: CGFloat = 24
}

private func trackSubtitle(for track: Track) -> String {
    let versionLabel = track.latestVersion?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let addedDate = (track.latestVersion?.addedAt ?? track.createdAt)
        .formatted(.dateTime.month(.abbreviated).day())

    if versionLabel.isEmpty {
        return addedDate
    }
    return "\(versionLabel) \u{00b7} \(addedDate)"
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(iOSImportCoordinator.self) private var importCoordinator
    @Environment(UploadQueue.self) private var uploadQueue
    @Query private var allTracks: [Track]
    @Query private var recentVersionRecords: [Version]
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var allPlaylists: [Playlist]
    private var playlists: [Playlist] { allPlaylists.filter { !$0.isSoftDeleted } }

    init() {
        _allTracks = Query()
        var recentDescriptor = FetchDescriptor<Version>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        recentDescriptor.fetchLimit = 20
        _recentVersionRecords = Query(recentDescriptor)
        _allPlaylists = Query(sort: \Playlist.updatedAt, order: .reverse)
    }

    @AppStorage(BouncePreferenceKey.showSetsTab) private var showRecordings = BouncePreferenceDefault.showSetsTab
    @State private var showSettings = OnboardingShot.opensSettings
    @State private var showSync = OnboardingShot.opensSync
    @State private var showImportPicker = false
    @State private var trackToAddToPlaylist: Track?
    @State private var queuedCount = 0
    @State private var trackToEdit: Track?
    @State private var trackToDelete: Track?
    @State private var trackToDeleteRemoval: DownloadManager.TrackRemoval = .delete
    @State private var navigateToNewPlaylist: Playlist?
    @State private var shareItem: ShareItem?
    @State private var listHeight: CGFloat = 0
    @State private var recentHeaderBottom: CGFloat = 0
    private static let listSpace = "libraryHomeList"

    @State private var trackByIDCache: [UUID: Track] = [:]

    private var trackByID: [UUID: Track] {
        trackByIDCache
    }

    private var recentLatestVersions: [Version] {
        var seenTrackIDs = Set<UUID>()
        return recentVersionRecords.filter { seenTrackIDs.insert($0.trackID).inserted }
    }

    private var reviewGroupBinding: Binding<ImportPlanGroup?> {
        Binding(
            get: { importCoordinator.reviewGroup },
            set: { importCoordinator.reviewGroup = $0 }
        )
    }

    private func libraryQueueForTappedTrack(_ track: Track) -> [Track] {
        let songs = showRecordings ? allTracks.filter { !$0.isSet } : allTracks
        return LibrarySorting.playbackContext(for: track, in: LibrarySorting.allTracksOrder(songs))
    }

    var body: some View {
        NavigationStack {
            libraryHomeList
        }
        .sensoryFeedback(.success, trigger: queuedCount)
        .task {
            if OnboardingShot.opensPlaylistSheet, trackToAddToPlaylist == nil {
                trackToAddToPlaylist = allTracks.first { $0.displayTitle == "slow down v5" }
            }
        }
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(
                playlist: nil,
                tracks: allTracks,
                preselectedTrackIDs: [track.id],
                createdPlaylist: $navigateToNewPlaylist
            )
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(
            TrackRemovalCopy.confirmTitle(trackToDeleteRemoval, name: trackToDelete?.displayTitle ?? "track"),
            isPresented: Binding(
                get: { trackToDelete != nil },
                set: { if !$0 { trackToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { trackToDelete = nil }
            Button(TrackRemovalCopy.actionTitle(trackToDeleteRemoval), role: .destructive) {
                if let t = trackToDelete { removeTrack(t) }
                trackToDelete = nil
            }
        } message: {
            Text(TrackRemovalCopy.message(trackToDeleteRemoval))
        }
        .sheet(item: reviewGroupBinding) { group in
            iOSImportReviewSheet(
                group: group,
                availableTracks: importCoordinator.reviewAvailableTracks,
                onConfirm: { confirmedGroup in
                    Task {
                        await importCoordinator.confirmImport(group: confirmedGroup, context: modelContext)
                        uploadQueue.drainQueue()
                    }
                },
                onCancel: {
                    importCoordinator.cancelImport()
                }
            )
        }
        .onChange(of: allTracks.count, initial: true) {
            if UserDefaults.standard.object(forKey: BouncePreferenceKey.showSetsTab) == nil,
               allTracks.contains(where: \.isSet) {
                showRecordings = true
            }
        }
        .onChange(of: allTracks, initial: true) {
            trackByIDCache = Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private var releasesCount: Int {
        let trackCount = allTracks.filter(\.isReleased).count
        let playlistCount = allPlaylists.filter { $0.isReleased && !$0.isSoftDeleted }.count
        return trackCount + playlistCount
    }

    private var setsCount: Int {
        allTracks.filter(\.isSet).count
    }

    private var libraryHomeList: some View {
        List {
            libraryBrowseContent
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: Self.listSpace)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSync = true
                } label: {
                    LibraryToolbarSyncButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.currentTrack != nil {
                Color.clear.frame(height: 76)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSync) {
            NavigationStack {
                SyncDetailView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSync = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showImportPicker) {
            AudioDocumentPicker { urls in
                Task {
                    guard let url = urls.first else { return }
                    await importCoordinator.beginImportReview(for: url, context: modelContext)
                }
            }
        }
    }

    @ViewBuilder
    private var libraryBrowseContent: some View {
                    libraryRow(
                        title: "All Tracks",
                        systemImage: "music.note",
                        accessory: {
                            let count = showRecordings ? allTracks.filter { !$0.isSet }.count : allTracks.count
                            return count == 0 ? nil : "\(count)"
                        }()
                    ) {
                        SongsView()
                    }

                    if releasesCount > 0 {
                        libraryRow(
                            title: "Releases",
                            systemImage: "checkmark.seal",
                            accessory: "\(releasesCount)"
                        ) {
                            ReleasesView()
                        }
                    }

                    if showRecordings {
                        libraryRow(
                            title: RecordingsCopy.plural,
                            systemImage: "sdcard",
                            accessory: setsCount == 0 ? nil : "\(setsCount)"
                        ) {
                            SetsView()
                        }
                    }

                    libraryRow(
                        title: "Playlists",
                        systemImage: "music.note.list",
                        accessory: playlists.isEmpty ? nil : "\(playlists.count)"
                    ) {
                        PlaylistsView()
                    }

                    if allTracks.isEmpty {
                        ListSectionHeaderRow(title: "Recent")
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.listSpace)).maxY } action: { recentHeaderBottom = $0 }

                        VStack {
                            Spacer(minLength: 0)
                            Group {
                                EmptyLibraryActionCard(
                                    isImporting: importCoordinator.isImporting,
                                    importError: importCoordinator.importError,
                                    onImport: { showImportPicker = true }
                                )
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: max(200, listHeight - recentHeaderBottom))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: 16,
                            bottom: 0,
                            trailing: 16
                        ))
                    } else if !recentVersionRecords.isEmpty {
                        ListSectionHeaderRow(title: "Recent")

                        ForEach(recentLatestVersions) { version in
                                if let track = trackByID[version.trackID] {
                                    RecentBounceRow(
                                        track: track,
                                        version: version,
                                        isCurrentTrack: audioPlayer.currentTrack?.id == track.id,
                                        isPlaying: audioPlayer.currentTrack?.id == track.id && audioPlayer.isPlaying,
                                        onTap: { play(track: track, version: version) },
                                        onAddToQueue: { addToQueue(track) },
                                        onAddToPlaylist: { trackToAddToPlaylist = track },
                                        onShare: {
                                            if let url = TrackShareURL.resolve(version: version) {
                                                shareItem = ShareItem(url: url)
                                            }
                                        },
                                        onEdit: { trackToEdit = track },
                                        onDelete: { confirmRemoval(of: track) }
                                    )
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            addToQueue(track)
                                        } label: {
                                            Label("Add to Queue", systemImage: "text.append")
                                            .labelStyle(.iconOnly)
                                        }
                                        .tint(.blue)
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(
                                        top: 0,
                                        leading: LibraryRowMetrics.horizontalInset,
                                        bottom: 0,
                                        trailing: LibraryRowMetrics.horizontalInset
                                    ))
                                }
                            }
                    }
    }

    private func play(track: Track, version: Version) {
        if audioPlayer.currentVersion?.id == version.id && audioPlayer.isPlaying {
            audioPlayer.openFullScreenPlayer()
            return
        }
        audioPlayer.load(
            track: track,
            version: version,
            queue: libraryQueueForTappedTrack(track),
            context: .autoplayLibrary
        )
        audioPlayer.openFullScreenPlayer()
    }

    private func addToQueue(_ track: Track) {
        audioPlayer.addToQueue(track)
        queuedCount += 1
    }

    private func confirmRemoval(of track: Track) {
        guard let removal = downloadManager.removal(for: track) else { return }
        trackToDeleteRemoval = removal
        trackToDelete = track
    }

    private func removeTrack(_ track: Track) {
        switch trackToDeleteRemoval {
        case .removeDownload:
            downloadManager.removeDownloads(for: track)
        case .delete:
            downloadManager.deleteLocalTracks([track])
        }
    }

    @ViewBuilder
    private func libraryRow<Destination: View>(
        title: String,
        systemImage: String,
        accessory: String?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: LibraryRowMetrics.iconWidth, height: LibraryRowMetrics.iconWidth)

                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                if let accessory {
                    Text(accessory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            LibraryRowMetrics.horizontalInset + LibraryRowMetrics.iconWidth + 12
        }
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: LibraryRowMetrics.horizontalInset,
            bottom: 8,
            trailing: LibraryRowMetrics.horizontalInset
        ))
    }

}

private func playlistEntryDuration(_ entry: PlaylistEntry, trackByID: [UUID: Track]) -> TimeInterval {
    guard let track = trackByID[entry.trackID] else { return 0 }
    if let versionID = entry.versionID,
       let version = track.versions.first(where: { $0.id == versionID }),
       version.duration > 0 {
        return version.duration
    }
    return max(0, track.latestVersion?.duration ?? 0)
}

private func playlistTotalDuration(entries: [PlaylistEntry], trackByID: [UUID: Track]) -> TimeInterval {
    entries.reduce(0) { $0 + playlistEntryDuration($1, trackByID: trackByID) }
}

private func formatPlaylistDuration(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

private func playlistMetadataLabel(trackCount: Int, totalDuration: TimeInterval) -> String {
    let countLabel = trackCount == 1 ? "1 track" : "\(trackCount) tracks"
    let durationLabel = formatPlaylistDuration(totalDuration)
    guard !durationLabel.isEmpty else { return countLabel }
    return "\(countLabel) · \(durationLabel)"
}

enum PlaylistCoverStyle {
    case list
    case hero
    case sheet
}

enum TrackRemovalCopy {
    static func actionTitle(_ removal: DownloadManager.TrackRemoval) -> String {
        removal == .removeDownload ? "Remove Download" : "Delete"
    }

    static func systemImage(_ removal: DownloadManager.TrackRemoval) -> String {
        removal == .removeDownload ? "arrow.down.circle" : "trash"
    }

    static func confirmTitle(_ removal: DownloadManager.TrackRemoval, name: String) -> String {
        removal == .removeDownload ? "Remove download of \(name)?" : "Delete \(name)?"
    }

    static func message(_ removal: DownloadManager.TrackRemoval) -> String {
        removal == .removeDownload
            ? "The track stays in your library with its notes. Its audio is removed from this iPhone until you download it again."
            : "This removes the track, its mixes, notes, and audio from this iPhone."
    }
}

struct ListSectionHeaderRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.leading, 4)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }
}

struct PlaylistCoverThumb: View {
    let playlistID: UUID
    let coverData: Data?
    let size: CGFloat
    let cornerRadius: CGFloat
    var style: PlaylistCoverStyle = .list

    var body: some View {
        Group {
            if let image = ArtworkImageCache.shared.image(
                for: playlistID,
                data: coverData,
                pointSize: size
            ) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var placeholder: some View {
        switch style {
        case .list:
            ZStack {
                Color(.systemGray5)
                Image(systemName: "music.note.list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .hero:
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGray4), Color(.systemGray5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note.list")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .sheet:
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: "music.note.list")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var allPlaylists: [Playlist]
    private var playlists: [Playlist] { allPlaylists.filter { !$0.isSoftDeleted && !$0.isReleased } }

    @State private var showCreatePrompt = false
    @State private var createNameDraft = ""
    @State private var playlistToRename: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var renameDraft = ""
    @State private var navigateToPlaylist: Playlist?
    /// Blocks row taps for 500 ms after onAppear so a rapid pop→push
    /// never overlaps the Liquid Glass nav bar morph.
    @State private var navigationReadyAt: Date = .now

    var body: some View {
        Group {
            if playlists.isEmpty {
                EmptyStateBlock(
                    symbolName: "music.note.list",
                    symbolSize: 48,
                    title: "No Playlists",
                    description: "Build a set of tracks for focused listening, A/B sessions, or a release shortlist."
                ) {
                    BouncePrimaryButton(title: "Create Playlist", systemImage: "plus") {
                        createNameDraft = ""
                        showCreatePrompt = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                playlistsList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.currentTrack != nil {
                Color.clear.frame(height: 76)
            }
        }
        .navigationTitle("Playlists")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createNameDraft = ""
                    showCreatePrompt = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Playlist")
            }
        }
        .navigationDestination(item: $navigateToPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .onAppear {
            print("[DEBUG] \(Date().timeIntervalSince1970) PlaylistsView onAppear")
            navigationReadyAt = Date().addingTimeInterval(0.5)
        }
        .onDisappear { print("[DEBUG] \(Date().timeIntervalSince1970) PlaylistsView onDisappear") }
        .alert("New Playlist", isPresented: $showCreatePrompt) {
            TextField("Name", text: $createNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                createPlaylist()
            }
        } message: {
            Text("Give this playlist a name.")
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { playlistToRename != nil },
            set: { if !$0 { playlistToRename = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                playlistToRename = nil
            }
            Button("Save") {
                renameSelectedPlaylist()
            }
        } message: {
            Text("Update the playlist name.")
        }
        .alert(
            "Delete \(playlistToDelete?.name ?? "playlist")?",
            isPresented: Binding(
                get: { playlistToDelete != nil },
                set: { if !$0 { playlistToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
            Button("Delete", role: .destructive) {
                if let playlist = playlistToDelete { deletePlaylist(playlist) }
                playlistToDelete = nil
            }
        }
    }

    private var playlistsList: some View {
        List {
            ForEach(playlists) { playlist in
                    Button {
                        guard Date() >= navigationReadyAt else { return }
                        navigateToPlaylist = playlist
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistCoverThumb(
                                playlistID: playlist.id,
                                coverData: playlist.coverImageData,
                                size: 44,
                                cornerRadius: 8
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                    .font(.body)
                                    .lineLimit(1)
                                if let artist = playlist.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !artist.isEmpty {
                                    Text(artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: LibraryRowMetrics.horizontalInset,
                        bottom: 0,
                        trailing: LibraryRowMetrics.horizontalInset
                    ))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            playlistToDelete = playlist
                        } label: {
                            Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                        }
                    }
                    .contextMenu {
                        Button {
                            renameDraft = playlist.name
                            playlistToRename = playlist
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            markAsReleased(playlist)
                        } label: {
                            Label("Mark as Released", systemImage: "checkmark.seal")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func createPlaylist() {
        let name = createNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let nextSortIndex = (playlists.compactMap(\.sortIndex).max() ?? -1) + 1
        let playlist = Playlist(name: name, sortIndex: nextSortIndex)
        modelContext.insert(playlist)
        saveContext("create playlist")
        navigateToPlaylist = playlist
    }

    private func renameSelectedPlaylist() {
        guard let playlistToRename else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        playlistToRename.name = name
        playlistToRename.updatedAt = .now
        saveContext("rename playlist")
        self.playlistToRename = nil
    }

    private func deletePlaylist(_ playlist: Playlist) {
        for entry in playlist.entries {
            modelContext.delete(entry)
        }
        playlist.entries.removeAll()
        playlist.setCoverImage(nil)
        playlist.coverImagePath = nil
        playlist.folder = nil
        playlist.isSoftDeleted = true
        playlist.updatedAt = .now
        saveContext("delete playlist")
    }

    private func markAsReleased(_ playlist: Playlist) {
        playlist.isReleased = true
        playlist.updatedAt = .now
        saveContext("mark as released")
    }

    private func saveContext(_ action: String) {
        do {
            try modelContext.save()
            downloadManager.notifyLocalManifestMutated()
        } catch {
            print("[PlaylistsView] ERROR: Failed to \(action): \(error)")
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.editMode) private var editMode

    let playlist: Playlist

    @Query(sort: \Track.createdAt, order: .reverse) private var tracks: [Track]
    @State private var showAddTracksSheet = false
    @State private var showEditPlaylist = false
    @State private var trackToEdit: Track?
    @State private var trackToAddToPlaylist: Track?
    @State private var queuedCount = 0
    @State private var navigateToNewPlaylist: Playlist?
    @State private var shareItem: ShareItem?

    // Cached, not computed: `playlist.entries.sorted` and the duration reduce
    // both fault every track's `versions` array (and its inline waveform blobs)
    // through SQLite. As computed props they re-ran on every body pass — the
    // main cause of the ~1s playlist open. Rebuilt only when inputs change.
    @State private var entriesCache: [PlaylistEntry] = []
    @State private var totalDurationCache: TimeInterval = 0
    @State private var trackByIDCache: [UUID: Track] = [:]

    private var entries: [PlaylistEntry] { entriesCache }

    private var trackByID: [UUID: Track] {
        trackByIDCache
    }

    private func rebuildCaches() {
        trackByIDCache = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entriesCache = playlist.entries.sorted { $0.position < $1.position }
        totalDurationCache = playlistTotalDuration(entries: entriesCache, trackByID: trackByIDCache)
    }

    var body: some View {
        List {
            PlaylistCoverHeader(
                playlist: playlist,
                metadataLabel: playlistMetadataLabel(
                    trackCount: entriesCache.count,
                    totalDuration: totalDurationCache
                )
            ) {
                showEditPlaylist = true
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())

            if entries.isEmpty {
                EmptyStateBlock(
                    symbolName: "plus.circle",
                    symbolSize: 40,
                    title: "Empty Playlist",
                    description: "Add tracks from your library to start listening.",
                    maxContentWidth: 280
                ) {
                    BouncePrimaryButton(title: "Add Tracks", systemImage: "plus") {
                        showAddTracksSheet = true
                    }
                }
                .padding(.vertical, 32)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(entries) { entry in
                    if let track = trackByID[entry.trackID] {
                        TrackRow(
                            track: track,
                            isSelecting: false,
                            isSelected: false,
                            onTapRow: {
                                let version = entry.versionID.flatMap { versionID in
                                    track.versions.first(where: { $0.id == versionID })
                                }
                                play(track, version: version)
                            },
                            onLongPress: {},
                            preferredVersion: entry.versionID.flatMap { versionID in
                                track.versions.first(where: { $0.id == versionID })
                            },
                            showCover: false,
                            onAddToQueue: { addToQueue(track) },
                            onAddToPlaylist: { trackToAddToPlaylist = track },
                            onShare: {
                                if let url = TrackShareURL.resolve(for: track, versionID: entry.versionID) {
                                    shareItem = ShareItem(url: url)
                                }
                            },
                            onEdit: { trackToEdit = track }
                        )
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                addToQueue(track)
                            } label: {
                                Label("Add to Queue", systemImage: "text.append")
                                .labelStyle(.iconOnly)
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeEntry(entry)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: LibraryRowMetrics.horizontalInset,
                            bottom: 0,
                            trailing: LibraryRowMetrics.horizontalInset
                        ))
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Text("Missing track")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: LibraryRowMetrics.horizontalInset,
                            bottom: 0,
                            trailing: LibraryRowMetrics.horizontalInset
                        ))
                    }
                }
                .onDelete(perform: deleteEntries)
                .onMove(perform: moveEntries)
                .moveDisabled(editMode?.wrappedValue.isEditing != true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.currentTrack != nil {
                Color.clear.frame(height: 76)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddTracksSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showAddTracksSheet) {
            AddTracksToPlaylistSheet(playlist: playlist, tracks: tracks)
        }
        .sheet(isPresented: $showEditPlaylist) {
            EditPlaylistSheet(playlist: playlist)
        }
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(
                playlist: nil,
                tracks: tracks,
                preselectedTrackIDs: [track.id],
                createdPlaylist: $navigateToNewPlaylist
            )
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .navigationDestination(item: $navigateToNewPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .onAppear { DebugLog.log("PlaylistDetailView onAppear") }
        .onDisappear { DebugLog.log("PlaylistDetailView onDisappear") }
        .onChange(of: tracks, initial: true) { rebuildCaches() }
        .sensoryFeedback(.success, trigger: queuedCount)
        .onChange(of: playlist.entries.count) { rebuildCaches() }
        .onChange(of: playlist.id) { rebuildCaches() }
    }

    private func play(_ track: Track, version: Version? = nil) {
        let queue = entries.compactMap { trackByID[$0.trackID] }
        let alreadyInContext = audioPlayer.queueContext == .playlist
            && Set(audioPlayer.queue.map(\.id)) == Set(queue.map(\.id))
        if alreadyInContext && audioPlayer.currentTrack?.id == track.id && audioPlayer.isPlaying {
            audioPlayer.openFullScreenPlayer()
            return
        }
        let pinnedVersions = Dictionary(
            entries.compactMap { entry in entry.versionID.map { (entry.trackID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        audioPlayer.load(track: track, version: version, queue: queue, queueVersions: pinnedVersions, context: .playlist)
        audioPlayer.openFullScreenPlayer()
    }

    private func addToQueue(_ track: Track) {
        audioPlayer.addToQueue(track)
        queuedCount += 1
    }

    private func removeEntry(_ entry: PlaylistEntry) {
        guard let offset = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        deleteEntries(at: IndexSet(integer: offset))
    }

    private func deleteEntries(at offsets: IndexSet) {
        let currentEntries = entries
        let toDelete = offsets.map { currentEntries[$0] }
        let idsToDelete = Set(toDelete.map(\.id))
        let remaining = currentEntries.filter { !idsToDelete.contains($0.id) }

        playlist.entries.removeAll { idsToDelete.contains($0.id) }
        for entry in toDelete {
            modelContext.delete(entry)
        }
        for (index, entry) in remaining.enumerated() {
            entry.position = index
        }
        entriesCache = remaining
        totalDurationCache = playlistTotalDuration(entries: remaining, trackByID: trackByIDCache)
        playlist.updatedAt = .now
        saveContext("delete playlist entries")
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        var reordered = entries
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in reordered.enumerated() {
            entry.position = index
        }
        // A same-count reorder trips none of the onChange rebuild triggers, so
        // push the new order into the cache directly or the list snaps back.
        entriesCache = reordered
        playlist.updatedAt = .now
        saveContext("reorder playlist entries")
    }

    private func saveContext(_ action: String) {
        do {
            try modelContext.save()
            downloadManager.notifyLocalManifestMutated()
        } catch {
            print("[PlaylistDetailView] ERROR: Failed to \(action): \(error)")
        }
    }
}

private struct PlaylistCoverHeader: View {
    @Environment(\.editMode) private var editMode

    let playlist: Playlist
    let metadataLabel: String
    let onEdit: () -> Void

    private var isReordering: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    var body: some View {
        VStack(spacing: 16) {
            Button(action: onEdit) {
                coverArt
            }
            .buttonStyle(.plain)
            .disabled(isReordering)
            .accessibilityLabel("Edit playlist cover")

            Group {
                if isReordering {
                    Button(action: onEdit) {
                        titleBlock(showPencil: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit playlist info")
                } else {
                    titleBlock(showPencil: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func titleBlock(showPencil: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(playlist.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if showPencil {
                    Image(systemName: "pencil")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            if let artist = playlist.artist, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(metadataLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var coverArt: some View {
        PlaylistCoverThumb(
            playlistID: playlist.id,
            coverData: playlist.coverImageData,
            size: 200,
            cornerRadius: 12,
            style: .hero
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

struct AddTracksToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DownloadManager.self) private var downloadManager
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var fetchedPlaylists: [Playlist]
    private var allPlaylists: [Playlist] { fetchedPlaylists.filter { !$0.isSoftDeleted } }

    let playlist: Playlist?
    let tracks: [Track]
    let preselectedTrackIDs: Set<UUID>?
    @Binding var createdPlaylist: Playlist?

    private var targetPlaylist: Playlist? { playlist }

    private var existingTrackIDs: Set<UUID> {
        guard let playlist else { return [] }
        return Set(playlist.entries.map(\.trackID))
    }

    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var searchText = ""

    init(playlist: Playlist?, tracks: [Track], preselectedTrackIDs: Set<UUID>? = nil, createdPlaylist: Binding<Playlist?>? = nil) {
        self.playlist = playlist
        self.tracks = tracks
        self.preselectedTrackIDs = preselectedTrackIDs
        self._createdPlaylist = createdPlaylist ?? .constant(nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let playlist {
                    trackPicker(for: playlist)
                } else {
                    playlistPicker
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents(playlist == nil ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
    }

    private var playlistPicker: some View {
        List {
            Button {
                newPlaylistName = ""
                showCreatePlaylist = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 40, height: 40)

                    Text("New Playlist\u{2026}")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if allPlaylists.isEmpty {
                EmptyStateBlock(
                    symbolName: "music.note.list",
                    symbolSize: 40,
                    title: "No Playlists",
                    description: "Create a playlist first, then add these tracks.",
                    maxContentWidth: 280
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(allPlaylists) { pl in
                    let isMember = containsPreselected(pl)
                    Button {
                        togglePreselected(in: pl)
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistCoverThumb(
                                playlistID: pl.id,
                                coverData: pl.coverImageData,
                                size: 40,
                                cornerRadius: 8,
                                style: .sheet
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(pl.entries.count == 1 ? "1 track" : "\(pl.entries.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if isMember {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isMember ? .isSelected : [])
                }
            }
        }
        .alert("New Playlist", isPresented: $showCreatePlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                createAndAddPlaylist()
            }
        }
        .navigationTitle("Add to Playlist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func trackPicker(for playlist: Playlist) -> some View {
        let available = tracks.filter { !existingTrackIDs.contains($0.id) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = query.isEmpty
            ? available
            : available.filter { $0.name.localizedCaseInsensitiveContains(query) }

        return List {
            if available.isEmpty {
                EmptyStateBlock(
                    symbolName: "checkmark.circle",
                    symbolSize: 40,
                    title: "All Caught Up",
                    description: "Every track in your library is already in this playlist.",
                    maxContentWidth: 280
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { track in
                    let isSelected = selectedTrackIDs.contains(track.id)
                    Button {
                        if isSelected {
                            selectedTrackIDs.remove(track.id)
                        } else {
                            selectedTrackIDs.insert(track.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                                if let data = track.artwork, let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayTitle)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(trackSubtitle(for: track))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0, leading: 16,
                        bottom: 0, trailing: 16
                    ))
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tracks")
        .navigationTitle("Add Tracks")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(selectedTrackIDs.isEmpty ? "Add" : "Add (\(selectedTrackIDs.count))") {
                    addSelectedTracks(to: playlist)
                }
                .disabled(selectedTrackIDs.isEmpty)
            }
        }
    }

    private func createAndAddPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = Playlist(name: name)
        modelContext.insert(playlist)
        let ids = preselectedTrackIDs ?? []
        var nextPos = 0
        for track in tracks where ids.contains(track.id) {
            let entry = PlaylistEntry(
                playlistID: playlist.id,
                trackID: track.id,
                position: nextPos
            )
            modelContext.insert(entry)
            playlist.entries.append(entry)
            nextPos += 1
        }
        playlist.updatedAt = .now
        saveContext("create playlist with tracks")
    }

    private func containsPreselected(_ playlist: Playlist) -> Bool {
        let ids = preselectedTrackIDs ?? []
        guard !ids.isEmpty else { return false }
        let existing = Set(playlist.entries.map(\.trackID))
        return ids.isSubset(of: existing)
    }

    private func togglePreselected(in playlist: Playlist) {
        let ids = preselectedTrackIDs ?? []
        if containsPreselected(playlist) {
            let toRemove = playlist.entries.filter { ids.contains($0.trackID) }
            let removedIDs = Set(toRemove.map(\.id))
            playlist.entries.removeAll { removedIDs.contains($0.id) }
            for entry in toRemove { modelContext.delete(entry) }
            for (index, entry) in playlist.entries.sorted(by: { $0.position < $1.position }).enumerated() {
                entry.position = index
            }
        } else {
            let existing = Set(playlist.entries.map(\.trackID))
            var nextPos = (playlist.entries.map(\.position).max() ?? -1) + 1
            for track in tracks where ids.contains(track.id) && !existing.contains(track.id) {
                let entry = PlaylistEntry(
                    playlistID: playlist.id,
                    trackID: track.id,
                    position: nextPos
                )
                modelContext.insert(entry)
                playlist.entries.append(entry)
                nextPos += 1
            }
        }
        playlist.updatedAt = .now
        saveContext("toggle tracks in playlist")
    }

    private func addSelectedTracks(to playlist: Playlist) {
        let existing = Set(playlist.entries.map(\.trackID))
        var nextPosition = (playlist.entries.map(\.position).max() ?? -1) + 1

        for track in tracks where selectedTrackIDs.contains(track.id) && !existing.contains(track.id) {
            let entry = PlaylistEntry(
                playlistID: playlist.id,
                trackID: track.id,
                position: nextPosition
            )
            modelContext.insert(entry)
            playlist.entries.append(entry)
            nextPosition += 1
        }
        playlist.updatedAt = .now
        saveContext("add tracks to playlist")
        dismiss()
    }

    private func saveContext(_ action: String) {
        do {
            try modelContext.save()
            downloadManager.notifyLocalManifestMutated()
        } catch {
            print("[AddTracksToPlaylistSheet] ERROR: Failed to \(action): \(error)")
        }
    }
}
