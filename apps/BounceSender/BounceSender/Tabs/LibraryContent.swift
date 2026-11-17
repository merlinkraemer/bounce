import SwiftUI
import SwiftData
import BounceKit
import Combine

/// Middle column — switches between "All Tracks" sectioned list and a single
/// playlist's entries.
struct LibraryContent: View {
    @Binding var selection: LibrarySelection
    @Binding var selectedVersionID: UUID?
    @Binding var selectedVersionIDs: Set<UUID>
    let inspectedVersionID: UUID?
    let onInspectVersion: (UUID) -> Void
    let onPlayVersion: (UUID) -> Void
    let onTogglePlayback: (UUID) -> Void
    let onPlayPlaylist: (UUID) -> Void
    let onShufflePlaylist: (UUID) -> Void
    @Binding var searchText: String
    @Binding var sortModeRaw: String
    let tracks: [Track]
    let onCreatedPlaylist: (UUID) -> Void
    let onAddToQueue: (UUID) -> Void

    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]

    private var playlists: [Playlist] { allPlaylists.filter { !$0.isSoftDeleted } }

    /// Measured header body heights, hoisted above the conditionally-mounted
    /// surfaces. Each surface is destroyed and recreated on a tab switch, which
    /// reset the local state to 0 and then grew row 0 1 -> 53 -> 123 while the
    /// clip origin stayed pinned — the "lists ramp into place" defect. Keyed per
    /// surface: the header height differs per surface and per column width.
    @State private var allTracksHeaderHeight = HeaderHeightCache.shared.height(for: HeaderHeightCache.libraryKey)
    @State private var setsHeaderHeight = HeaderHeightCache.shared.height(for: HeaderHeightCache.setsKey)
    @State private var playlistHeaderHeights: [UUID: CGFloat] = [:]

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @AppStorage(BouncePreferenceKey.showSetsTab) private var showRecordings = BouncePreferenceDefault.showSetsTab

    /// All Tracks excludes long recordings only while the Recordings tab is on.
    private var libraryTracks: [Track] { showRecordings ? tracks.filter { !$0.isSet } : tracks }

    private var filteredTracks: [Track] {
        guard !trimmedSearchText.isEmpty else { return libraryTracks }
        return libraryTracks.filter(matchesSearch(_:))
    }

    private var isSetsSelected: Bool {
        if case .sets = selection { return true }
        return false
    }

    var body: some View {
        Group {
            // Never opacity-stack playlist NSTableViews under All Tracks/Sets —
            // hidden AppKit tables still participate in layout/resize and cause
            // sideways jump plus a false left inset. Mount only the active surface.
            if selection == .allTracks || isSetsSelected {
                tracksLibraryContent
            } else {
                HStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        ForEach(playlists, id: \.id) { playlist in
                            PlaylistContentView(
                                playlist: playlist,
                                headerHeight: playlistHeaderHeightBinding(for: playlist.id),
                                tracks: tracks,
                                searchText: trimmedSearchText,
                                onInspectVersion: onInspectVersion,
                                onPlayVersion: onPlayVersion,
                                onTogglePlayback: onTogglePlayback,
                                onPlayPlaylist: onPlayPlaylist,
                                onShufflePlaylist: onShufflePlaylist,
                                onAddToQueue: onAddToQueue
                            )
                            .opacity(isPlaylistSelected(playlist.id) ? 1 : 0)
                            .allowsHitTesting(isPlaylistSelected(playlist.id))
                            .accessibilityHidden(!isPlaylistSelected(playlist.id))
                            .zIndex(isPlaylistSelected(playlist.id) ? 1 : 0)
                        }

                        if case .playlist(let id) = selection, !playlists.contains(where: { $0.id == id }) {
                            ContentUnavailableView(
                                "Playlist Not Found",
                                systemImage: "music.note.list"
                            )
                            .columnBackground(.content)
                        }
                    }
                    .frame(maxWidth: BounceConstants.catalogueContentMaxWidth, maxHeight: .infinity)
                    // The list owns the column width up to the cap; the flexible
                    // frame centres the capped column at wide widths, replacing
                    // the two greedy Spacers that let the list be laid out at a
                    // fraction of the column.
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func isPlaylistSelected(_ id: UUID) -> Bool {
        if case .playlist(let selectedID) = selection {
            return selectedID == id
        }
        return false
    }

    /// All Tracks / Sets bindings that mirror every accepted measurement into
    /// the process-level cache, keyed per surface.
    private var allTracksHeaderHeightBinding: Binding<CGFloat> {
        Binding(
            get: { firstMeasured(allTracksHeaderHeight, HeaderHeightCache.shared.height(for: HeaderHeightCache.libraryKey), setsHeaderHeight) },
            set: { newValue in
                allTracksHeaderHeight = newValue
                HeaderHeightCache.shared.store(newValue, for: HeaderHeightCache.libraryKey)
            }
        )
    }

    /// The `@State` seeds above are read once, when `LibraryContent` is first
    /// created, so a surface first visited later (e.g. Recordings after launching
    /// on All Tracks) kept a 0 slot, mounted with a 1 pt row 0 and ramped to its
    /// measured height while the rows slid into place. Resolve the slot lazily:
    /// own measurement, then the process cache, then the sibling catalogue
    /// surface (same section-header layout, so the same height).
    private func firstMeasured(_ candidates: CGFloat...) -> CGFloat {
        candidates.first { $0 > 0 } ?? 0
    }

    private var setsHeaderHeightBinding: Binding<CGFloat> {
        Binding(
            get: { firstMeasured(setsHeaderHeight, HeaderHeightCache.shared.height(for: HeaderHeightCache.setsKey), allTracksHeaderHeight) },
            set: { newValue in
                setsHeaderHeight = newValue
                HeaderHeightCache.shared.store(newValue, for: HeaderHeightCache.setsKey)
            }
        )
    }

    /// Per-playlist binding into the hoisted `playlistHeaderHeights` store.
    /// Reads fall back to the process-level cache until the surface measures
    /// itself again; writes keep both in sync.
    private func playlistHeaderHeightBinding(for id: UUID) -> Binding<CGFloat> {
        let key = HeaderHeightCache.playlistKey(id)
        return Binding(
            get: { playlistHeaderHeights[id] ?? HeaderHeightCache.shared.height(for: key) },
            set: { newValue in
                playlistHeaderHeights[id] = newValue
                HeaderHeightCache.shared.store(newValue, for: key)
            }
        )
    }

    private var tracksLibraryContent: some View {
        let showingSets = isSetsSelected
        let headerCount = showingSets ? filteredSetCount : filteredTracks.count

        return HStack(spacing: 0) {
            LibraryListView(
                sectionHeader: AnyView(sectionHeader(
                    title: showingSets ? RecordingsCopy.plural : "All Tracks",
                    count: headerCount,
                    unitSingular: showingSets ? RecordingsCopy.singularLowercase : "track",
                    unitPlural: showingSets ? RecordingsCopy.pluralLowercase : "tracks"
                )),
                tracks: tracks,
                showsSetsOnly: showingSets,
                excludesSets: showRecordings,
                headerHeight: showingSets ? setsHeaderHeightBinding : allTracksHeaderHeightBinding,
                searchText: trimmedSearchText,
                sortModeRaw: $sortModeRaw,
                selectedVersionID: $selectedVersionID,
                selectedVersionIDs: $selectedVersionIDs,
                inspectedVersionID: inspectedVersionID,
                onInspectVersion: onInspectVersion,
                onPlayVersion: onPlayVersion,
                onTogglePlayback: onTogglePlayback,
                onCreatedPlaylist: onCreatedPlaylist,
                onAddToQueue: onAddToQueue
            )
            .frame(maxWidth: BounceConstants.catalogueContentMaxWidth, maxHeight: .infinity)
            // Same row-0 header mechanism as All Tracks, but a distinct view
            // identity: All Tracks and Sets previously shared one
            // `LibraryListView`/AppKit table, so the Sets surface could be
            // laid out against the other surface's measured row-0 height
            // before its own slot settled (the header read as pinned while
            // its row grew). Keying by surface makes each catalogue list own
            // its table and its own hoisted `headerHeight` slot for its whole
            // lifetime.
            .id(showingSets)
            // Same as the playlist wrapper: the list owns the column width up
            // to the cap, centred when the column is wider than 1040pt.
            .frame(maxWidth: .infinity)
        }
        .columnBackground(.content)
    }

    private var filteredSetCount: Int {
        let setTracks = tracks.filter(\.isSet)
        guard !trimmedSearchText.isEmpty else { return setTracks.count }
        return setTracks.filter(matchesSearch(_:)).count
    }

    private func sectionHeader(
        title: String,
        count: Int,
        unitSingular: String,
        unitPlural: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text("\(count) \(count == 1 ? unitSingular : unitPlural)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func matchesSearch(_ track: Track) -> Bool {
        let query = trimmedSearchText
        guard !query.isEmpty else { return true }

        if track.name.localizedCaseInsensitiveContains(query) {
            return true
        }

        if track.artist.localizedCaseInsensitiveContains(query) {
            return true
        }

        return track.versions.contains { version in
            version.label.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Header layout for a playlist/album title strip: the square cover is exactly
/// as tall as the information stack (title, metadata, description, and the
/// Play/Shuffle row), measured at the text width that will actually be used.
///
/// Cover side and info height are mutually dependent (a wider cover leaves
/// less text width, which can wrap taller). The resolver iterates with a
/// monotonic max — so the candidate can only grow — then takes one final
/// measurement at the settled width. The pair is cached from `sizeThatFits`
/// and reused by `placeSubviews`, so placement and sizing always describe the
/// same geometry and there is no cross-frame feedback loop. There is no height
/// cap: the cover grows with the stack, so the Play/Shuffle row can never
/// protrude past it.
private struct TitleStripLayout: Layout {
    var spacing: CGFloat = 16
    var minSide: CGFloat = 72

    struct Cache {
        var width: CGFloat = -1
        var side: CGFloat = 72
        var infoHeight: CGFloat = 72
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 600
        let pair = resolvedPair(in: width, subviews: subviews)
        cache = Cache(width: width, side: pair.side, infoHeight: pair.infoHeight)
        // Report the taller of the cover and the info stack. Reporting only the
        // cover side under-measured the strip when the title/meta/description/
        // actions exceeded it, so the row reserved less than the content drew
        // and the bottom of the strip was clipped.
        return CGSize(width: width, height: max(pair.side, pair.infoHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        if abs(cache.width - bounds.width) > 0.5 {
            let pair = resolvedPair(in: bounds.width, subviews: subviews)
            cache = Cache(width: bounds.width, side: pair.side, infoHeight: pair.infoHeight)
        }

        let infoWidth = max(40, bounds.width - spacing - cache.side)
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: cache.side, height: cache.side)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + cache.side + spacing, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: infoWidth, height: nil)
        )
    }

    private func resolvedPair(in width: CGFloat, subviews: Subviews) -> (side: CGFloat, infoHeight: CGFloat) {
        let pair = TitleStripSizing(spacing: spacing, minSide: minSide).resolvedPair(width: width) { infoWidth in
            subviews[1]
                .sizeThatFits(ProposedViewSize(width: infoWidth, height: nil))
                .height
        }
        return (pair.side, pair.height)
    }
}

/// Playlist middle-column content: header with cover/metadata + entries table.
struct PlaylistContentView: View {
    let playlist: Playlist
    /// Hoisted into `LibraryContent` so the measured header height survives the
    /// unmount on a tab switch; local state reset to 0 and made row 0 ramp.
    @Binding private var headerHeight: CGFloat
    // Passed from the parent's existing @Query instead of a second full Track table
    // scan on every playlist switch. Order is irrelevant here (by-ID lookups only).
    let tracks: [Track]
    let searchText: String
    let onInspectVersion: (UUID) -> Void
    let onPlayVersion: (UUID) -> Void
    let onTogglePlayback: (UUID) -> Void
    let onPlayPlaylist: (UUID) -> Void
    let onShufflePlaylist: (UUID) -> Void
    let onAddToQueue: (UUID) -> Void

    @Query private var playlistEntries: [PlaylistEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackEngine.self) private var playbackEngine
    @Environment(InlineRenameManager.self) private var renameManager

    @State private var selectedEntryID: UUID?
    @State private var trackToEdit: Track?

    init(
        playlist: Playlist,
        headerHeight: Binding<CGFloat>,
        tracks: [Track],
        searchText: String,
        onInspectVersion: @escaping (UUID) -> Void,
        onPlayVersion: @escaping (UUID) -> Void,
        onTogglePlayback: @escaping (UUID) -> Void,
        onPlayPlaylist: @escaping (UUID) -> Void,
        onShufflePlaylist: @escaping (UUID) -> Void,
        onAddToQueue: @escaping (UUID) -> Void
    ) {
        self.playlist = playlist
        _headerHeight = headerHeight
        self.tracks = tracks
        self.searchText = searchText
        self.onInspectVersion = onInspectVersion
        self.onPlayVersion = onPlayVersion
        self.onTogglePlayback = onTogglePlayback
        self.onPlayPlaylist = onPlayPlaylist
        self.onShufflePlaylist = onShufflePlaylist
        self.onAddToQueue = onAddToQueue
        let playlistID = playlist.id
        _playlistEntries = Query(
            filter: #Predicate<PlaylistEntry> { $0.playlistID == playlistID },
            sort: [SortDescriptor(\.position)]
        )
    }

    private var sortedEntries: [PlaylistEntry] {
        playlistEntries.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @State private var cachedRows: [PlaylistEntryRowSnapshot] = []
    @State private var lastContentRevision: Int?

    private var entryRows: [PlaylistEntryRowSnapshot] {
        cachedRows
    }

    /// Signature over mutable fields the rows display (entry membership/order +
    /// track name/version/artwork), so in-place edits that don't change the
    /// entry array identity still trigger a rebuild.
    /// Uses stored `artworkRevision` — never faults artwork blobs.
    private var contentRevision: Int {
        var hasher = Hasher()
        for entry in playlistEntries {
            hasher.combine(entry.id)
            hasher.combine(entry.position)
            hasher.combine(entry.versionID)
        }
        let trackIDs = Set(playlistEntries.map(\.trackID))
        for track in tracks where trackIDs.contains(track.id) {
            hasher.combine(track.id)
            hasher.combine(track.name)
            hasher.combine(track.displayTitle)
            hasher.combine(track.artworkRevision ?? 0)
            for version in track.versions {
                hasher.combine(version.id)
                hasher.combine(version.label)
            }
        }
        return hasher.finalize()
    }

    private func rebuildRows() {
        let sortedEntries = self.sortedEntries

        // Dictionary lookup instead of allTracks.first(where:) per entry —
        // the linear scans made every render O(entries × tracks).
        let trackByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let versionsByTrackID = Dictionary(
            uniqueKeysWithValues: tracks.map { track in
                (track.id, track.versions.sorted { $0.addedAt > $1.addedAt })
            }
        )

        cachedRows = sortedEntries.compactMap { entry -> PlaylistEntryRowSnapshot? in
            guard let track = trackByID[entry.trackID] else { return nil }

            let versionsNewestFirst = versionsByTrackID[entry.trackID] ?? []
            let selectedVersion: Version?
            if let versionID = entry.versionID {
                selectedVersion = versionsNewestFirst.first(where: { $0.id == versionID })
            } else {
                selectedVersion = versionsNewestFirst.first
            }

            if !searchText.isEmpty {
                let matches = track.displayTitle.localizedCaseInsensitiveContains(searchText)
                    || track.name.localizedCaseInsensitiveContains(searchText)
                    || track.artist.localizedCaseInsensitiveContains(searchText)
                    || selectedVersion?.label.localizedCaseInsensitiveContains(searchText) == true
                guard matches else { return nil }
            }

            return PlaylistEntryRowSnapshot(
                id: entry.id,
                trackID: track.id,
                trackName: track.displayTitle,
                versionID: selectedVersion?.id,
                versionLabel: entry.versionID == nil ? nil : selectedVersion?.label,
                availableVersions: versionsNewestFirst
                    .map { PlaylistEntryVersionOption(id: $0.id, label: $0.label) },
                addedAt: selectedVersion?.addedAt,
                duration: selectedVersion?.duration,
                filePath: selectedVersion?.filePath,
                artworkRevision: track.artworkRevision
            )
        }
        lastContentRevision = contentRevision
    }

    var body: some View {
        // Evaluate once — body previously computed entryRows four times per
        // render (empty check, table, song count, total duration).
        let rows = entryRows
        // The header is table row 0 so it scrolls under the top toolbar with
        // the entries instead of pinning above them. The hosted header cell
        // measures itself at the live column width and reports that height
        // back, so row 0 is sized from the rendered instance.
        ZStack {
            GeometryReader { geometry in
                entriesTable(rows: rows, columns: LibraryColumnVisibility(width: geometry.size.width))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if rows.isEmpty {
                emptyStateReservation
            }
        }
        .columnBackground(.content)
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        // Only one initial build — the other two previously rebuilt 3× on first render.
        .onChange(of: tracks, initial: true) { rebuildRows() }
        .onChange(of: playlistEntries) { rebuildRows() }
        .onChange(of: searchText) { rebuildRows() }
        // Catch in-place edits (track rename, artwork) that don't change the
        // array identities the onChanges above compare.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            if contentRevision != lastContentRevision { rebuildRows() }
        }
    }

    /// Empty state sits below the same measured header + constant top
    /// clearance as row 0, so it can never draw over the cover, title, or
    /// actions.
    private var emptyStateReservation: some View {
        GeometryReader { proxy in
            let reserved = max(headerHeight, 1) + BounceConstants.columnTopFadeHeight
            let remaining = max(0, proxy.size.height - reserved)
            VStack(spacing: 0) {
                Color.clear.frame(height: min(reserved, proxy.size.height))
                emptyState
                    .frame(width: proxy.size.width, height: remaining, alignment: .center)
            }
        }
        .allowsHitTesting(false)
    }

    /// Only a real change propagates: this height becomes row 0's height, so
    /// a redundant re-report would invalidate row height in response to its
    /// own result.
    private func updateHeaderHeight(_ height: CGFloat) {
        let accepted = abs(height - headerHeight) > 0.5
        guard accepted else { return }
        headerHeight = height
    }

    private func entriesTable(rows: [PlaylistEntryRowSnapshot], columns: LibraryColumnVisibility) -> some View {
        PlaylistEntriesTableView(
            header: AnyView(titleStrip),
            headerHeight: headerHeight,
            onHeaderHeightChange: updateHeaderHeight,
            rows: rows,
            artworkForTrack: { id in tracks.first(where: { $0.id == id })?.artwork },
            selectedEntryID: $selectedEntryID,
            columns: columns,
            allowsReordering: true,
            playbackEngine: playbackEngine,
            loadedVersionID: playbackEngine.loadedVersionID,
            isPlaying: playbackEngine.isPlaying,
            renameTarget: renameManager.activeTarget,
            renameManager: renameManager,
            onPlayVersion: playVersion,
            onToggleVersion: onTogglePlayback,
            onInspectVersion: onInspectVersion,
            onChangeVersion: changeVersion,
            onRemove: removeEntry,
            onRemoveEntries: removeEntries,
            onAddToQueue: onAddToQueue,
            onEditTrack: { trackID in
                trackToEdit = tracks.first(where: { $0.id == trackID })
            },
            onReorderEntries: reorderEntries,
            onInsertVersions: insertVersions
        )
    }

    /// True when the loaded track belongs to this playlist (by track
    /// membership, not playback origin) and audio is actually playing.
    private var isPlayingCollection: Bool {
        guard playbackEngine.isPlaying, let loadedVersionID = playbackEngine.loadedVersionID else {
            return false
        }
        let memberTrackIDs = Set(playlistEntries.map(\.trackID))
        return tracks.contains { track in
            memberTrackIDs.contains(track.id) && track.versions.contains { $0.id == loadedVersionID }
        }
    }

    private var titleStrip: some View {
        let stats = entryStats
        let created = playlist.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
        let songs = stats.count == 1 ? "1 song" : "\(stats.count) songs"
        let metaLine = "\(songs) • \(formatDuration(stats.duration)) • created \(created)"

        return VStack(spacing: 0) {
            TitleStripLayout {
                coverArt()

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)

                    if let artist = playlist.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let description = playlist.playlistDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        if isPlayingCollection {
                            playlistActionButton(
                                "Pause",
                                systemImage: "pause.fill",
                                action: { playbackEngine.pause() }
                            )
                        } else {
                            playlistActionButton(
                                "Play",
                                systemImage: "play.fill",
                                action: { onPlayPlaylist(playlist.id) }
                            )
                        }
                        playlistActionButton(
                            "Shuffle",
                            systemImage: "shuffle",
                            action: { onShufflePlaylist(playlist.id) }
                        )
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)

            // The divider carries its own 8pt below so the first track row
            // clears it; both paddings are inside the measured header height.
            Divider()
                .padding(.bottom, 8)
        }
    }

    private func playlistActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                // Fixed floor so Play and Pause keep the capsule the same
                // width; the header must not reflow when the state flips.
                .frame(minWidth: 92, minHeight: 32)
                .background(Color.primary.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func coverArt() -> some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)
            // Decode at the exact rendered side (never upscaled); the cache
            // makes the first-pass decode cheap after the header height settles.
            let decodeSide = max(side, 72).rounded(.up)
            ZStack {
                if let data = playlist.coverImageData,
                   let nsImage = ArtworkThumbnailCache.thumbnail(data, id: playlist.id, side: decodeSide) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemFill))

                    Image("MusicNoteIcon").renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: min(40, side * 0.5), height: min(40, side * 0.5))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    /// Full-playlist track count + duration (pinned version or newest by addedAt).
    private var entryStats: (count: Int, duration: TimeInterval) {
        let trackByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var count = 0
        var duration: TimeInterval = 0

        for entry in sortedEntries {
            guard let track = trackByID[entry.trackID] else { continue }

            let version: Version?
            if let versionID = entry.versionID {
                version = track.versions.first(where: { $0.id == versionID })
            } else {
                version = track.versions.max(by: { $0.addedAt < $1.addedAt })
            }

            guard let version else { continue }
            count += 1
            duration += version.duration
        }

        return (count, duration)
    }

    private var emptyState: some View {
        Group {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note.list",
                    description: Text("Drag tracks from All Tracks into this playlist.")
                )
            } else {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No tracks in this playlist match \"\(searchText)\".")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(max(0, duration).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    private func playVersion(_ versionID: UUID) {
        onPlayVersion(versionID)
    }

    private func changeVersion(_ entryID: UUID, _ versionID: UUID) {
        guard let entry = playlistEntries.first(where: { $0.id == entryID }) else { return }
        entry.versionID = versionID
        playlist.updatedAt = .now
        try? modelContext.save()
        onInspectVersion(versionID)
    }

    private func removeEntry(_ entryID: UUID) {
        removeEntries([entryID])
    }

    private func removeEntries(_ entryIDs: [UUID]) {
        guard !entryIDs.isEmpty else { return }
        let idSet = Set(entryIDs)
        let toDelete = playlistEntries.filter { idSet.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        for entry in toDelete {
            modelContext.delete(entry)
        }
        playlist.updatedAt = .now
        try? modelContext.save()
    }

    private func insertVersions(_ versionIDs: [UUID], at visibleIndex: Int) {
        insertPlaylistEntries(
            versionIDs: versionIDs,
            into: playlist,
            at: entryIndex(forVisibleRow: visibleIndex, in: sortedEntries),
            context: modelContext
        )
    }

    private func entryIndex(forVisibleRow visibleIndex: Int, in entries: [PlaylistEntry]) -> Int {
        if visibleIndex < cachedRows.count,
           let index = entries.firstIndex(where: { $0.id == cachedRows[visibleIndex].id }) {
            return index
        }
        if let lastRow = cachedRows.last,
           let index = entries.firstIndex(where: { $0.id == lastRow.id }) {
            return index + 1
        }
        return entries.count
    }

    private func reorderEntries(_ entryIDs: [UUID], _ visibleIndex: Int) {
        guard !entryIDs.isEmpty else { return }
        var entries = sortedEntries
        let destinationIndex = entryIndex(forVisibleRow: visibleIndex, in: entries)
        let idSet = Set(entryIDs)
        let dragged = entries.filter { idSet.contains($0.id) }
        guard dragged.count == entryIDs.count else { return }

        let sourceIndices = entries.enumerated()
            .filter { idSet.contains($0.element.id) }
            .map(\.offset)
        entries.removeAll { idSet.contains($0.id) }

        let removedBeforeDestination = sourceIndices.filter { $0 < destinationIndex }.count
        let adjusted = destinationIndex - removedBeforeDestination
        let insertIndex = max(0, min(adjusted, entries.count))
        entries.insert(contentsOf: dragged, at: insertIndex)

        for (i, entry) in entries.enumerated() {
            entry.position = i
        }
        playlist.updatedAt = .now
        try? modelContext.save()

        // A same-count reorder doesn't reliably trip .onChange(of: playlistEntries)
        // (same objects, same array identity), and the didSave fallback can fire
        // against a transiently-inconsistent @Query and latch cachedRows to [].
        // Rebuild synchronously from the just-mutated positions instead of waiting
        // on reactivity — mirrors the iOS I13 reorder-cache fix.
        rebuildRows()
    }
}
