import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import BounceKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TransferManager.self) private var transferManager
    @Environment(FooterToastCenter.self) private var toastCenter

    @Query(sort: \Track.createdAt, order: .reverse)
    private var tracks: [Track]

    @State private var librarySelection: LibrarySelection = .allTracks
    @State private var searchText = ""
    @State private var isImportPanelPending = false
    /// Catalogue selection is intentionally separate from the exact mix shown
    /// in the details surface. Navigation and table selection may change
    /// without replacing the user's current review target.
    @State private var selectedVersionID: UUID?
    @State private var selectedVersionIDs: Set<UUID> = []
    @State private var inspectedVersionID: UUID?
    @State private var inspectionFollowsPlayback = false
    @AppStorage(BouncePreferenceKey.inspectedVersionID) private var persistedInspectedVersionID = ""
    @AppStorage(BouncePreferenceKey.detailsVisible) private var isDetailsPresented = true
    @AppStorage(BouncePreferenceKey.detailsVisibleByDefault) private var detailsVisibleByDefault = BouncePreferenceDefault.detailsVisibleByDefault
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isSyncSheetPresented = OnboardingShot.step == .syncSheet
    @State private var isSetupPresented = false
    @State private var setupModel = SetupModel()
    @State private var isDragOver = false
    @State private var importCoordinator = ImportCoordinator()
    @State private var importPlan: ImportPlan?
    @State private var undoBanner: UndoBanner?
    @State private var undoBannerTask: Task<Void, Never>?
    @State private var transportState = TransportState()
    @State private var playbackEngine = PlaybackEngine()
    @State private var shuffleEnabled = false
    @State private var repeatMode: TransportRepeatMode = .off
    @State private var shuffleOrder: [UUID] = []
    @State private var manualQueue: [UUID] = [] // version IDs added via "Add to Queue"
    @State private var playbackContext: PlaybackContext = .allTracks
    @State private var isAutoAdvancing = false
    @State private var selectedTrackID: UUID?
    @State private var toolbarSelectedPlaylist: Playlist?
    @State private var editingPlaylist: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var isToolbarSearchPresented = false
    @State private var chromeMetrics = WindowChromeMetrics()

    /// The catalogue control host (search/actions plus the inspector toggle in
    /// its own trailing slot) lives in the catalogue column; see
    /// `CatalogueToolbarControls`. The sidebar affordance is the automatic
    /// `NavigationSplitView` toolbar item — exactly one, no custom item.
    /// `.toolbar(removing:)` drops SwiftUI's duplicate default and the
    /// automatic window-title item.

    private var inspectedTrack: Track? {
        guard let inspectedVersionID else { return nil }
        return tracks.first { track in
            track.versions.contains(where: { $0.id == inspectedVersionID })
        }
    }

    private var inspectedVersion: Version? {
        guard let inspectedVersionID else { return nil }
        return tracks.flatMap(\.versions).first(where: { $0.id == inspectedVersionID })
    }

    // MARK: - Body

    var body: some View {
        contentWithPlayback
            // The catalogue controls (including the inspector toggle) live in
            // the catalogue column; see `CatalogueToolbarControls`. The sidebar
            // toggle is the automatic `NavigationSplitView` toolbar item — no
            // custom toolbar item is added, so there is exactly one left
            // sidebar control, and it toggles the native sidebar column.
            .toolbar(removing: .sidebarToggle)
            // SwiftUI re-inserts the `WindowGroup` title as an automatic
            // window-title toolbar item; removing it at the SwiftUI layer is
            // what actually keeps "Bounce"/"Bounce Dev" out of the window
            // chrome. The WindowGroup title stays for app identity/Window menu.
            .toolbar(removing: .title)
            // The catalogue extends under the titlebar (see
            // `catalogueContent(extendsUnderTitlebar:)`), so the rows behind the
            // chrome are real pixels; `ColumnEdgeFade` blurs and dissolves them.
            // `titlebarAppearsTransparent` already suppresses the native
            // titlebar backing — this keeps SwiftUI from reinstating one.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .environment(importCoordinator)
            .containerBackground(Color(nsColor: .controlBackgroundColor), for: .window)
            .sheet(item: $editingPlaylist) { playlist in
                PlaylistEditSheet(playlist: playlist, folder: nil)
            }
            .alert(
                "Delete \u{201C}\(playlistToDelete?.name ?? "")\u{201D}?",
                isPresented: Binding(
                    get: { playlistToDelete != nil },
                    set: { if !$0 { playlistToDelete = nil } }
                ),
                presenting: playlistToDelete
            ) { playlist in
                Button("Delete", role: .destructive) { deletePlaylist(playlist.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The tracks stay in your library.")
            }
            .sheet(item: libraryImportPlan) { plan in
                ImportReviewSheet(
                    plan: binding(for: plan),
                    onCancel: { importPlan = nil },
                    onImport: commitImportPlan
                )
            }
            .sheet(isPresented: $isSetupPresented) {
                SetupSheet(
                    model: setupModel,
                    isPresented: $isSetupPresented,
                    importPlan: $importPlan,
                    onCancelImport: { importPlan = nil },
                    onCommitImport: commitImportPlan,
                    reviewBinding: binding(for:)
                )
                    .environment(transferManager)
            }
            .externalFileDrop(isTargeted: $isDragOver) { urls in
                handleDroppedURLs(urls)
            }
            .onReceive(NotificationCenter.default.publisher(for: .importRequestPending)) { _ in
                consumeImportRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .setupImportFinished)) { note in
                setupModel.importedCount += note.userInfo?["count"] as? Int ?? 0
            }
            .onReceive(NotificationCenter.default.publisher(for: .setupRequested)) { _ in
                presentRequestedSetup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pairingRequested)) { _ in
                presentRequestedPairing()
            }
            .onAppear {
                if SetupPrefs.isDue(transferManager: transferManager, container: modelContext.container) {
                    setupModel.reset()
                    isSetupPresented = true
                }
                presentRequestedSetup()
                presentRequestedPairing()
                consumeImportRequest()
                applyDetailsPaneDefault()
                transportState.shuffleEnabled = shuffleEnabled
                transportState.repeatMode = repeatMode
                restoreInspection()
                syncSelectionWithVisibleTracks()
                refreshSelectedTrackIDCache()
                loadToolbarSelectedPlaylist()
            }
            .onChange(of: tracks) { _, _ in
                syncSelectionWithVisibleTracks()
                validateInspection()
                refreshSelectedTrackIDCache()
                if let loadedID = playbackEngine.loadedVersionID {
                    updateWaveformAndNotes(for: loadedID)
                }
                refreshQueueItems()
                if shuffleEnabled {
                    rebuildShuffleOrder()
                }
            }
            .onChange(of: selectedVersionID) { _, _ in
                refreshSelectedTrackIDCache()
            }
            .onChange(of: librarySelection) { _, _ in
                // Destination changes are catalogue changes, not review
                // changes. Keep the exact inspected mix visible even when it
                // is absent from the new destination.
                selectedVersionID = nil
                selectedVersionIDs.removeAll()
                loadToolbarSelectedPlaylist()
            }
            .onChange(of: inspectedVersionID) { _, newID in
                persistInspectionChange(newID)
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                loadToolbarSelectedPlaylist()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusTitlebarSearchField)) { _ in
                // Handled by the in-content control host, which knows whether
                // the search field is full or collapsed.
            }
    }

    // MARK: - Content layers

    private var contentWithPlayback: some View {
        contentLayer
            .animation(.easeInOut(duration: 0.25), value: undoBanner != nil)
            .environment(playbackEngine)
            // Playback ticks (currentTime) fire 5×/sec. Reading them here would make
            // ContentView.body depend on the tick and re-render the entire 3-column
            // layout 5×/sec during playback. Isolate the observation in an empty
            // sibling view so only it — not the layout tree — invalidates per tick.
            .background(PlaybackMirror(engine: playbackEngine, transportState: transportState))
            // Configures exactly the window hosting the main content (the
            // marker view only exists in ContentView), so no title-string
            // matching and no risk of reconfiguring sheets or panels.
            .background(MainWindowChromeConfigurator(metrics: chromeMetrics))
            .onAppear {
                wireTransportCallbacks()
                playbackEngine.restoreLastPlayed(context: modelContext)
                if let loadedID = playbackEngine.loadedVersionID {
                    updateTransportIdentity(for: loadedID)
                    updateWaveformAndNotes(for: loadedID)
                }
                refreshQueueItems()
            }
            .onChange(of: playbackEngine.loadedVersionID) { _, loadedID in
                if loadedID != nil, !isAutoAdvancing {
                    playbackContext = librarySelection.playbackContext
                    if shuffleEnabled { rebuildShuffleOrder() }
                }
                isAutoAdvancing = false
                wireTransportCallbacks()
                updateTransportIdentity(for: loadedID)
                updateWaveformAndNotes(for: loadedID)
                refreshQueueItems()
            }
            .background(
                TransportKeyboardMonitor(
                    isEnabled: playbackEngine.loadedVersionID != nil,
                    onTogglePlayback: { transportState.onTogglePlayback?() },
                    onSkipBackward: { transportState.onSkipBackward?() },
                    onSkipForward: { transportState.onSkipForward?() },
                    onAllTracks: { librarySelection = .allTracks },
                    onAddNote: { transportState.onAddNote?() },
                    onEscape: {
                        // Escape clears search and resigns the focused editor;
                        // it must not close the native sidebar column.
                        searchText = ""
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                )
            )
    }

    private var contentLayer: some View {
        MainLibraryLayout(
            selection: $librarySelection,
            selectedVersionID: $selectedVersionID,
            selectedVersionIDs: $selectedVersionIDs,
            inspectedVersionID: inspectedVersionID,
            isDetailsPresented: $isDetailsPresented,
            columnVisibility: $columnVisibility,
            isSyncSheetPresented: $isSyncSheetPresented,
            searchText: $searchText,
            chromeMetrics: chromeMetrics,
            transportState: transportState,
            tracks: tracks,
            inspectedTrack: inspectedTrack,
            inspectedVersion: inspectedVersion,
            onInspectVersion: { id in inspectVersion(id) },
            onPlayVersion: playVersionFromUser,
            onTogglePlayback: toggleVersionFromUser,
            onPlayPlaylist: playPlaylistFromToolbar,
            onShufflePlaylist: shufflePlaylistFromToolbar,
            onShowPlayingMix: showPlayingMix,
            onSaveNote: saveNoteFromTransport,
            onReviewPosition: { _ in },
            onScrub: scrubInspectedVersion,
            onUpdateNote: updateNote,
            onDeleteNote: { note in
                guard let track = inspectedTrack else { return }
                transferManager.deleteNote(note, for: track)
                if let versionID = inspectedVersion?.id,
                   playbackEngine.loadedVersionID == versionID {
                    updateWaveformAndNotes(for: versionID)
                }
            },
            onAddToQueue: addToManualQueue,
            onCreatedPlaylist: openPlaylist,
            catalogueControls: { presentation in
                CatalogueToolbarControls(
                    searchText: $searchText,
                    selection: librarySelection,
                    selectedPlaylist: toolbarSelectedPlaylist,
                    onImport: openFilePicker,
                    isImportPanelPending: isImportPanelPending,
                    onEditPlaylist: editPlaylist,
                    onPlayPlaylist: playPlaylistFromToolbar,
                    onShufflePlaylist: shufflePlaylistFromToolbar,
                    onQueuePlaylist: queuePlaylistFromToolbar,
                    onDeletePlaylist: deletePlaylistFromToolbar,
                    presentation: presentation,
                    isSearchPopoverPresented: $isToolbarSearchPresented
                )
            }
        ) {
            TransportBar(transportState: transportState)
        }
        // Singleton sheet — no item to bind, so isPresented over .sheet(item:).
        .sheet(isPresented: $isSyncSheetPresented) {
            SyncSheet()
                .environment(transferManager)
        }
        .ignoresSafeArea(edges: .top)
        .background(Color.clear)
        .overlay {
            if isDragOver {
                DragOverlayView()
            }

            if let banner = undoBanner {
                VStack {
                    UndoBannerView(banner: banner, onDismiss: dismissUndoBanner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .padding(.top, 8)
                .allowsHitTesting(true)
            }
        }
    }

    // MARK: - Transport wiring

    private func wireTransportCallbacks() {
        transportState.onSkipBackward = { [self] in
            playAdjacentTrack(offset: -1, followsPlayback: true)
        }
        transportState.onSkipForward  = { [self] in
            if consumeManualQueueEntry(followsPlayback: true) { return }
            playAdjacentTrack(offset: 1, followsPlayback: true)
        }
        transportState.onSeek         = { [self] t in playbackEngine.seek(to: t) }
        transportState.onTogglePlayback = { [self] in
            if playbackEngine.isPlaying {
                playbackEngine.pause()
            } else {
                playbackEngine.resume()
            }
        }
        transportState.onAddNote = { [self] in
            transportState.requestNoteFocus = true
        }
        transportState.onToggleShuffle = { [self] in
            shuffleEnabled.toggle()
            transportState.shuffleEnabled = shuffleEnabled
            if shuffleEnabled {
                rebuildShuffleOrder()
            } else {
                shuffleOrder = []
            }
        }
        transportState.onCycleRepeatMode = { [self] in
            repeatMode = nextRepeatMode(after: repeatMode)
            transportState.repeatMode = repeatMode
        }
        transportState.onPlayQueueItem = { [self] versionID in
            guard tracks.flatMap(\.versions).contains(where: { $0.id == versionID }) else { return }
            if let index = manualQueue.firstIndex(of: versionID) {
                manualQueue.remove(at: index)
                refreshQueueItems()
            }
            playVersionFromUser(versionID)
        }
        playbackEngine.onPlaybackEnded = { [self] in
            handlePlaybackEnded()
        }
        transportState.onClearUpNextQueue = { [self] in
            clearManualQueue()
        }
        transportState.volume = playbackEngine.volume
        transportState.onSetVolume = { [self] value in
            playbackEngine.setVolume(value)
            transportState.volume = playbackEngine.volume
        }
        // refreshQueueItems() is owned by loadedVersionID / tracks / queue mutators —
        // not here — so a track switch does not rebuild the queue 2–3×.
    }

    private func editPlaylist(_ playlist: Playlist) {
        editingPlaylist = playlist
    }

    private func playPlaylistFromToolbar(_ playlistID: UUID) {
        playPlaylist(playlistID)
    }

    private func shufflePlaylistFromToolbar(_ playlistID: UUID) {
        shufflePlaylist(playlistID)
    }

    private func queuePlaylistFromToolbar(_ playlistID: UUID) {
        queuePlaylist(playlistID)
    }

    private func deletePlaylistFromToolbar(_ playlistID: UUID) {
        playlistToDelete = modelContext.fetchByID(Playlist.self, id: playlistID)
    }

    private func refreshSelectedTrackIDCache() {
        guard let id = selectedVersionID else {
            selectedTrackID = nil
            return
        }
        selectedTrackID = tracks.first(where: { $0.versions.contains(where: { $0.id == id }) })?.id
    }

    private func playAdjacentTrack(offset: Int, followsPlayback: Bool = false) {
        let playableTracks = playableTrackList()
        guard !playableTracks.isEmpty else { return }

        let currentIndex = currentPlayableIndex(in: playableTracks) ?? 0

        let targetIndex: Int
        if shuffleEnabled && offset > 0 {
            targetIndex = nextShuffleIndex(in: playableTracks, currentIndex: currentIndex)
        } else {
            let raw = currentIndex + offset
            if repeatMode == .all, !playableTracks.isEmpty {
                let count = playableTracks.count
                targetIndex = ((raw % count) + count) % count
            } else {
                targetIndex = min(max(raw, 0), playableTracks.count - 1)
            }
        }

        guard targetIndex != currentIndex || playbackEngine.loadedVersionID == nil else { return }

        let target = playableTracks[targetIndex]
        isAutoAdvancing = true
        playbackEngine.playFromStart(version: target.version)
        if followsPlayback || inspectionFollowsPlayback {
            inspectVersion(target.version.id, followsPlayback: true)
        }
    }

    // MARK: - Queue, shuffle, repeat helpers

    private func playableTrackList() -> [(trackID: UUID, version: Version)] {
        switch playbackContext {
        case .allTracks:
            return tracks.filter { !$0.isSet }.compactMap { track in
                guard let version = track.versions.sorted(by: { $0.addedAt > $1.addedAt }).first else { return nil }
                return (track.id, version)
            }
        case .sets:
            return tracks.filter(\.isSet).compactMap { track in
                guard let version = track.versions.sorted(by: { $0.addedAt > $1.addedAt }).first else { return nil }
                return (track.id, version)
            }
        case .playlist(let playlistID):
            let descriptor = FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate { $0.playlistID == playlistID },
                sortBy: [SortDescriptor(\.position)]
            )
            let entries = (try? modelContext.fetch(descriptor)) ?? []
            return entries.compactMap { entry in
                guard let track = tracks.first(where: { $0.id == entry.trackID }) else { return nil }
                let version: Version?
                if let versionID = entry.versionID {
                    version = track.versions.first(where: { $0.id == versionID })
                } else {
                    version = track.versions.sorted { $0.addedAt > $1.addedAt }.first
                }
                guard let version else { return nil }
                return (track.id, version)
            }
        }
    }

    private func currentPlayableIndex(in playable: [(trackID: UUID, version: Version)]) -> Int? {
        let currentTrackID = playbackEngine.loadedVersionID.flatMap { loadedID in
            playable.first(where: { track in
                tracks.first(where: { $0.id == track.trackID })?.versions.contains(where: { $0.id == loadedID }) == true
            })?.trackID
        } ?? selectedTrackID
        return currentTrackID.flatMap { id in playable.firstIndex(where: { $0.trackID == id }) }
    }

    private func nextRepeatMode(after mode: TransportRepeatMode) -> TransportRepeatMode {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func rebuildShuffleOrder() {
        let playable = playableTrackList()
        shuffleOrder = playable.map(\.trackID).shuffled()
    }

    private func nextShuffleIndex(in playable: [(trackID: UUID, version: Version)], currentIndex: Int) -> Int {
        guard !playable.isEmpty else { return currentIndex }
        if shuffleOrder.isEmpty { rebuildShuffleOrder() }

        let currentTrackID = playable[currentIndex].trackID
        let order = shuffleOrder.compactMap { id in playable.firstIndex(where: { $0.trackID == id }) }
        guard !order.isEmpty else { return currentIndex }

        if let pos = shuffleOrder.firstIndex(of: currentTrackID) {
            let next = pos + 1
            if next < shuffleOrder.count, let idx = playable.firstIndex(where: { $0.trackID == shuffleOrder[next] }) {
                return idx
            }
            // End of shuffle cycle — reshuffle and start fresh
            rebuildShuffleOrder()
            if let firstID = shuffleOrder.first,
               let idx = playable.firstIndex(where: { $0.trackID == firstID }) {
                return idx
            }
            return currentIndex
        }

        // Current track not in shuffle order (e.g., new track) — pick next randomly
        if let firstID = shuffleOrder.first,
           let idx = playable.firstIndex(where: { $0.trackID == firstID }) {
            return idx
        }
        return currentIndex
    }

    private func handlePlaybackEnded() {
        // Consume manual queue first, otherwise advance per repeat/shuffle.
        if consumeManualQueueEntry() { return }

        switch repeatMode {
        case .one:
            if let loadedID = playbackEngine.loadedVersionID,
               let version = tracks.flatMap(\.versions).first(where: { $0.id == loadedID }) {
                isAutoAdvancing = true
                playbackEngine.playFromStart(version: version)
            }
        case .all, .off:
            // Auto-advance; playAdjacentTrack clamps at end when repeat is off.
            playAdjacentTrack(offset: 1)
        }
    }

    private func refreshQueueItems() {
        let playable = playableTrackList()
        let currentID = playbackEngine.loadedVersionID.flatMap { loadedID in
            playable.first(where: { track in
                tracks.first(where: { $0.id == track.trackID })?.versions.contains(where: { $0.id == loadedID }) == true
            })?.trackID
        } ?? selectedTrackID

        // Drop manual queue entries that no longer resolve.
        manualQueue.removeAll { versionID in
            tracks.flatMap(\.versions).first(where: { $0.id == versionID }) == nil
        }

        var upNext: [TransportQueueItem] = []
        var continuePlaying: [TransportQueueItem] = []

        // Manual queue first (upcoming, not yet current).
        for versionID in manualQueue {
            guard let track = tracks.first(where: { $0.versions.contains(where: { $0.id == versionID }) }),
                  let version = track.versions.first(where: { $0.id == versionID }) else { continue }
            upNext.append(
                TransportQueueItem(
                    id: version.id,
                    trackID: track.id,
                    title: track.name,
                    subtitle: track.artist,
                    isCurrent: false
                )
            )
        }

        // Library continuation — skip versions already in the manual queue.
        let queuedVersionIDs = Set(manualQueue)
        continuePlaying.append(
            contentsOf: playable
                .filter { !queuedVersionIDs.contains($0.version.id) }
                .map { entry in
                let track = tracks.first(where: { $0.id == entry.trackID })
                let title = track?.name ?? entry.version.label
                let subtitle = track?.artist ?? ""
                return TransportQueueItem(
                    id: entry.version.id,
                    trackID: entry.trackID,
                    title: title,
                    subtitle: subtitle,
                    isCurrent: entry.trackID == currentID
                )
            }
        )

        transportState.upNextQueueItems = upNext
        transportState.continueQueueItems = continuePlaying
        transportState.queueItems = upNext + continuePlaying
    }

    private func addToManualQueue(versionID: UUID) {
        guard tracks.flatMap(\.versions).contains(where: { $0.id == versionID }) else { return }
        guard !manualQueue.contains(versionID) else { return }
        manualQueue.append(versionID)
        refreshQueueItems()
    }

    private func clearManualQueue() {
        manualQueue.removeAll()
        refreshQueueItems()
    }

    /// Attempts to start the next manual-queue entry. Returns true if something was started.
    @discardableResult
    private func consumeManualQueueEntry(followsPlayback: Bool = false) -> Bool {
        while !manualQueue.isEmpty {
            let versionID = manualQueue.removeFirst()
            guard let version = tracks.flatMap(\.versions).first(where: { $0.id == versionID }) else { continue }
            isAutoAdvancing = true
            playbackEngine.playFromStart(version: version)
            if followsPlayback || inspectionFollowsPlayback {
                inspectVersion(versionID, followsPlayback: true)
            }
            refreshQueueItems()
            return true
        }
        return false
    }

    private func updateWaveformAndNotes(for versionID: UUID?) {
        guard let versionID else {
            transportState.waveformSamples = nil
            transportState.noteTimestamps = []
            return
        }
        let version = tracks.flatMap(\.versions).first(where: { $0.id == versionID })
        if let data = version?.waveformData, !data.isEmpty {
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            transportState.waveformSamples = samples.isEmpty ? nil : samples
        } else {
            transportState.waveformSamples = nil
        }
        if let version {
            let track = tracks.first(where: { $0.versions.contains(where: { $0.id == versionID }) })
            transportState.noteTimestamps = (track?.visibleNotes(forVersion: version.id) ?? [])
                .compactMap(\.timestamp)
            refreshSparseWaveformIfNeeded(version)
        } else {
            transportState.noteTimestamps = []
        }
    }

    private func updateTransportIdentity(for versionID: UUID?) {
        transportState.loadedVersionID = versionID
        guard let versionID,
              let track = tracks.first(where: { $0.versions.contains(where: { $0.id == versionID }) }),
              let version = track.versions.first(where: { $0.id == versionID }) else {
            transportState.loadedTitle = ""
            transportState.loadedMixLabel = ""
            return
        }
        transportState.loadedTitle = track.name
        transportState.loadedMixLabel = version.label
    }

    /// Legacy ~300-peak blobs make long-set scrubbers look like a solid smear.
    private func refreshSparseWaveformIfNeeded(_ version: Version) {
        let sampleCount = WaveformMetrics.floatCount(in: version.waveformData)
        guard WaveformMetrics.needsDenserWaveform(
            sampleCount: sampleCount,
            duration: version.duration
        ) else { return }
        let path = version.filePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        let versionID = version.id
        Task {
            let processor = WaveformProcessor()
            guard let data = try? await processor.process(fileURL: URL(fileURLWithPath: path)) else {
                return
            }
            await MainActor.run {
                guard let live = tracks.flatMap(\.versions).first(where: { $0.id == versionID }) else {
                    return
                }
                live.waveformData = data
                try? modelContext.save()
                if selectedVersionID == versionID || playbackEngine.loadedVersionID == versionID {
                    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    transportState.waveformSamples = samples.isEmpty ? nil : samples
                }
            }
        }
    }

    private func saveNoteFromTransport(
        track: Track,
        version: Version,
        content: String,
        timestamp: TimeInterval
    ) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let note = Note(
            id: UUID(),
            trackID: track.id,
            versionID: version.id,
            timestamp: timestamp,
            type: .text,
            content: trimmed,
            createdAt: .now,
            updatedAt: .now,
            createdOn: .mac
        )
        track.notes.append(note)
        track.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            toastCenter.show(.error, "Couldn't save note. Try again.")
            SyncLog.sender.error("Failed to save Mac note: \(error.localizedDescription, privacy: .public)")
            return false
        }
        transferManager.pushManifestIfConnected()
        if playbackEngine.loadedVersionID == version.id {
            updateWaveformAndNotes(for: version.id)
        }
        return true
    }

    private func updateNote(_ note: Note, track: Track, content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        note.content = trimmed
        note.updatedAt = .now
        track.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            toastCenter.show(.error, "Couldn't save note edit. Try again.")
            SyncLog.sender.error("Failed to edit Mac note: \(error.localizedDescription, privacy: .public)")
            return false
        }
        transferManager.pushManifestIfConnected()
        return true
    }

    private func applyDetailsPaneDefault() {
        // The live `detailsVisible` key is the inspector state for this window;
        // `detailsVisibleByDefault` decides what that state is at launch. On the
        // first launch after this preference shipped, adopt the existing live
        // value as the user's default so an already-hidden pane is not reset.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: BouncePreferenceKey.detailsVisibleByDefault) == nil {
            let existing = defaults.object(forKey: BouncePreferenceKey.detailsVisible) as? Bool
                ?? BouncePreferenceDefault.detailsVisible
            defaults.set(existing, forKey: BouncePreferenceKey.detailsVisibleByDefault)
        }
        isDetailsPresented = detailsVisibleByDefault
    }

    private func restoreInspection() {
        guard let id = UUID(uuidString: persistedInspectedVersionID),
              tracks.flatMap(\.versions).contains(where: { $0.id == id }) else {
            persistedInspectedVersionID = ""
            inspectedVersionID = nil
            isDetailsPresented = false
            return
        }
        inspectedVersionID = id
    }

    private func persistInspectionChange(_ newID: UUID?) {
        persistedInspectedVersionID = newID?.uuidString ?? ""
        guard newID == nil else { return }
        isDetailsPresented = false
        inspectionFollowsPlayback = false
    }

    private func validateInspection() {
        guard let id = inspectedVersionID else { return }
        if !tracks.flatMap(\.versions).contains(where: { $0.id == id }) {
            inspectedVersionID = nil
        }
    }

    private func inspectVersion(_ versionID: UUID, followsPlayback: Bool = false) {
        guard tracks.flatMap(\.versions).contains(where: { $0.id == versionID }) else { return }
        let hasPriorInspection = inspectedVersionID != nil || !persistedInspectedVersionID.isEmpty
        inspectedVersionID = versionID
        inspectionFollowsPlayback = followsPlayback
        if !hasPriorInspection {
            isDetailsPresented = true
        }
    }

    private func playVersionFromUser(_ versionID: UUID) {
        guard let version = tracks.flatMap(\.versions).first(where: { $0.id == versionID }),
              version.processingState == .complete else { return }
        selectedVersionID = versionID
        selectedVersionIDs = [versionID]
        inspectVersion(versionID, followsPlayback: true)
        isAutoAdvancing = false
        playbackEngine.playFromStart(version: version)
    }

    private func toggleVersionFromUser(_ versionID: UUID) {
        guard let version = tracks.flatMap(\.versions).first(where: { $0.id == versionID }),
              version.processingState == .complete else { return }
        inspectVersion(versionID, followsPlayback: true)
        playbackEngine.togglePlayback(version: version)
    }

    private func showPlayingMix() {
        guard let loadedID = playbackEngine.loadedVersionID else { return }
        inspectVersion(loadedID, followsPlayback: true)
    }

    /// Direct waveform scrub in the detail pane. Seeks the inspected exact mix
    /// without ever briefly playing from zero and without touching another
    /// loaded mix's position.
    private func scrubInspectedVersion(_ time: TimeInterval) {
        guard let version = inspectedVersion,
              version.processingState == .complete else { return }

        if playbackEngine.loadedVersionID == version.id {
            // Already the loaded mix: seek in place, preserving play/paused.
            playbackEngine.seek(to: time)
            return
        }

        // A different mix (or nothing) is loaded. Load the inspected mix with
        // playback suppressed, confirm it actually loaded, seek, then resume
        // only if audio was already running. A failed load leaves the old mix
        // untouched and performs no seek.
        let wasPlaying = playbackEngine.isPlaying
        inspectVersion(version.id, followsPlayback: true)
        playbackEngine.load(version: version, play: false)
        guard playbackEngine.loadedVersionID == version.id else { return }
        playbackEngine.seek(to: time)
        if wasPlaying { playbackEngine.resume() }
    }

    private func syncSelectionWithVisibleTracks() {
        let allVersionIDs = Set(tracks.flatMap(\.versions).map(\.id))
        guard !allVersionIDs.isEmpty else {
            selectedVersionID = nil
            selectedVersionIDs = []
            return
        }
        if let id = selectedVersionID, allVersionIDs.contains(id) {
            return
        }
        selectedVersionID = nil
        selectedVersionIDs.removeAll()
    }

    private func openPlaylist(_ playlistID: UUID) {
        librarySelection = .playlist(playlistID)
    }

    private func loadToolbarSelectedPlaylist() {
        guard case .playlist(let id) = librarySelection else {
            toolbarSelectedPlaylist = nil
            return
        }
        let query = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        toolbarSelectedPlaylist = (try? modelContext.fetch(query))?.first
    }

    private func playPlaylist(_ playlistID: UUID) {
        playbackContext = .playlist(playlistID)
        let list = playableTrackList()
        guard let first = list.first else { return }
        playVersionFromUser(first.version.id)
        refreshQueueItems()
    }

    private func shufflePlaylist(_ playlistID: UUID) {
        playbackContext = .playlist(playlistID)
        shuffleEnabled = true
        transportState.shuffleEnabled = true
        rebuildShuffleOrder()

        let list = playableTrackList()
        guard !list.isEmpty else { return }

        let target: (trackID: UUID, version: Version)?
        if let firstShuffleID = shuffleOrder.first {
            target = list.first(where: { $0.trackID == firstShuffleID })
        } else {
            target = list.first
        }

        guard let target else { return }
        playVersionFromUser(target.version.id)
        refreshQueueItems()
    }

    private func queuePlaylist(_ playlistID: UUID) {
        playbackContext = .playlist(playlistID)
        for entry in playableTrackList() {
            addToManualQueue(versionID: entry.version.id)
        }
    }

    private func deletePlaylist(_ playlistID: UUID) {
        let query = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
        guard let playlist = try? modelContext.fetch(query).first else { return }

        if case .playlist(let id) = librarySelection, id == playlistID {
            librarySelection = .allTracks
        }

        modelContext.softDeletePlaylist(playlist)
        try? modelContext.save()
    }

    // MARK: - Import actions

    @MainActor
    private func consumeImportRequest() {
        switch ImportHandoff.take() {
        case .picker: openFilePicker()
        case .drop(let urls): handleDroppedURLs(urls)
        case nil: break
        }
    }

    @MainActor
    private func presentRequestedSetup() {
        guard SetupPrefs.takeRequest() else { return }
        setupModel.reset()
        isSetupPresented = true
    }

    @MainActor
    private func presentRequestedPairing() {
        guard PairingRequest.take() else { return }
        isSyncSheetPresented = true
    }

    private func openFilePicker() {
        guard !isImportPanelPending else { return }
        isImportPanelPending = true
        let forceReview = NSEvent.modifierFlags.contains(.option)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ImportableAudio.types + [.folder]

        panel.begin { response in
            isImportPanelPending = false
            guard response == .OK else { return }
            let audioURLs = ImportableAudio.expandedAudioURLs(panel.urls)
            guard !audioURLs.isEmpty else { return }
            Task {
                let plan = await importCoordinator.prepareImportPlan(audioURLs, context: modelContext)
                await routeImport(plan: plan, forceReview: forceReview)
            }
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        let forceReview = NSEvent.modifierFlags.contains(.option)
        let audioURLs = ImportableAudio.expandedAudioURLs(DragExportFile.excludingOwnExports(urls))
        guard !audioURLs.isEmpty else { return }
        Task {
            let plan = await importCoordinator.prepareImportPlan(audioURLs, context: modelContext)
            await routeImport(plan: plan, forceReview: forceReview)
        }
    }

    @MainActor
    private func routeImport(plan: ImportPlan, forceReview: Bool) async {
        dismissUndoBanner()

        let isFastPath = !forceReview
            && plan.groups.count == 1
            && plan.groups[0].items.count == 1
            && plan.groups[0].items[0].isHighConfidence
            && !plan.groups[0].items[0].skip

        if isFastPath, let group = plan.groups.first {
            executeFastPathImport(group: group)
        } else {
            importPlan = plan
        }
    }

    @MainActor
    private func executeFastPathImport(group: ImportPlanGroup) {
        guard let item = group.items.first else { return }
        let trackName: String
        if let trackID = group.target.resolvedTrackID,
           let found = modelContext.fetchByID(Track.self, id: trackID) {
            trackName = found.name
        } else {
            trackName = item.detectedTrackName
        }

        guard let scheduled = importCoordinator.scheduleSingle(
            group: group, context: modelContext, transferManager: transferManager
        ) else { return }

        importCoordinator.armSuccessToast("Imported 1 track", using: toastCenter)
        NotificationCenter.default.post(name: .setupImportFinished, object: nil, userInfo: ["count": 1])

        let versionLabel: String
        if let version = modelContext.fetchByID(Version.self, id: scheduled.versionID) {
            versionLabel = version.label
        } else {
            versionLabel = item.editableVersionLabel
        }

        let message = "Added \u{201C}\(item.originalTitle)\u{201D} as \(versionLabel) of \u{201C}\(trackName)\u{201D}"

        showUndoBanner(message: message) { [modelContext = self.modelContext, importCoordinator = self.importCoordinator, versionID = scheduled.versionID] in
            importCoordinator.cancelImport(versionID: versionID)
            guard let version = modelContext.fetchByID(Version.self, id: versionID),
                  let track = modelContext.fetchByID(Track.self, id: version.trackID) else { return }
            let paths = modelContext.deleteVersion(version, of: track)
            do {
                try modelContext.save()
                modelContext.removeUnreferencedFiles(atPaths: paths)
            } catch {
                SyncLog.importer.error("Undo import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showUndoBanner(message: String, onUndo: @escaping () -> Void) {
        undoBannerTask?.cancel()
        undoBanner = UndoBanner(message: message, onUndo: onUndo)
        undoBannerTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { dismissUndoBanner() }
            }
        }
    }

    private func dismissUndoBanner() {
        undoBannerTask?.cancel()
        undoBannerTask = nil
        undoBanner = nil
    }

    private func commitImportPlan() {
        guard let importPlan else { return }
        let activeCount = importPlan.allItems.filter { !$0.skip }.count
        let groupCount = importPlan.groups.filter { !$0.activeItems.isEmpty }.count
        importCoordinator.scheduleImport(
            importPlan,
            context: modelContext,
            transferManager: transferManager
        )
        self.importPlan = nil

        if let error = importCoordinator.importError {
            toastCenter.show(.error, error)
            return
        }

        let message: String
        if groupCount <= 1 {
            message = activeCount == 1 ? "Imported 1 track" : "Imported \(activeCount) versions"
        } else {
            message = "Imported \(activeCount) files into \(groupCount) tracks"
        }
        importCoordinator.armSuccessToast(message, using: toastCenter)
        NotificationCenter.default.post(name: .setupImportFinished, object: nil, userInfo: ["count": activeCount])
    }

    private func refreshManifest() {
        guard let tracks = try? modelContext.fetch(FetchDescriptor<Track>()) else { return }
        transferManager.pushManifest(tracks: tracks)
    }

    /// The review sheet for the library window. While setup is up, the setup sheet
    /// presents the review itself (nested), so this one stays empty.
    private var libraryImportPlan: Binding<ImportPlan?> {
        Binding(
            get: { isSetupPresented ? nil : importPlan },
            set: { importPlan = $0 }
        )
    }

    private func binding(for presentedPlan: ImportPlan) -> Binding<ImportPlan> {
        Binding(
            get: { importPlan ?? presentedPlan },
            set: { importPlan = $0 }
        )
    }
}

/// Isolates high-frequency PlaybackEngine observation so the main layout tree
/// doesn't re-render on every 0.2s playback tick. Only this empty view is
/// invalidated when currentTime/isPlaying/duration change; it mirrors them into
/// the shared TransportState that the transport bar and scrubber read.
private struct PlaybackMirror: View {
    let engine: PlaybackEngine
    let transportState: TransportState

    var body: some View {
        Color.clear
            .onChange(of: engine.isPlaying, initial: true) { _, v in transportState.isPlaying = v }
            .onChange(of: engine.currentTime, initial: true) { _, v in transportState.currentTime = v }
            .onChange(of: engine.duration, initial: true) { _, v in transportState.duration = v }
            .onChange(of: engine.volume, initial: true) { _, v in transportState.volume = v }
    }
}
