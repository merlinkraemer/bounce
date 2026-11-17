import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit
import BounceKit
import Combine

// MARK: - Drag payloads

/// Pasteboard type used by `LibraryTrackTableView` when publishing version IDs.
/// Mirrored here so the sidebar can register the drop target.
private let libraryVersionPasteboardType = "com.merlinkraemer.bounce.library-version-item"

// MARK: - Sidebar

/// Unified sidebar: All Tracks (top, primary) + folders/playlists below.
/// Sticky sync footer pinned to the bottom.
struct MainSidebar: View {
    @Binding var selection: LibrarySelection
    @Binding var isSyncSheetPresented: Bool
    /// Shared with the wide split sidebar and the narrow drawer so folder
    /// expansion survives presentation changes instead of resetting or being
    /// force-expanded by each new sidebar instance.
    @Binding var expandedFolderIDs: Set<UUID>
    /// Invoked when a destination row is activated, including re-clicking the
    /// already-current destination (where AppKit sends no selection change).
    /// The narrow drawer uses it to dismiss itself.
    var onDestinationActivated: (() -> Void)? = nil

    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @Query(sort: \PlaylistFolder.createdAt) private var allFolders: [PlaylistFolder]
    @Query(sort: \Track.lastTouchedAt, order: .reverse) private var allTracks: [Track]

    @AppStorage(BouncePreferenceKey.showReleasesTab) private var showReleasesTab = BouncePreferenceDefault.showReleasesTab
    @AppStorage(BouncePreferenceKey.showSetsTab) private var showSetsTab = BouncePreferenceDefault.showSetsTab

    // Released playlists live only in the Releases tab, not the playlist sidebar.
    private var playlists: [Playlist] { allPlaylists.filter { !$0.isSoftDeleted && !$0.isReleased } }
    private var folders: [PlaylistFolder] { allFolders.filter { !$0.isSoftDeleted } }
    @Environment(\.modelContext) private var modelContext

    @State private var editingPlaylist: Playlist?
    @State private var editingFolder: PlaylistFolder?
    @State private var creatingPlaylistInFolder: PlaylistFolder?
    @State private var isCreatingNewPlaylist = false
    @State private var playlistToDelete: Playlist?
    @State private var folderToDelete: PlaylistFolder?

    @State private var cachedSnapshots: [SidebarRowSnapshot] = []
    @State private var lastContentRevision: Int?

    private var flatSnapshots: [SidebarRowSnapshot] {
        cachedSnapshots
    }

    /// Signature over the mutable playlist/folder fields the sidebar rows show,
    /// so renames and cover edits (in-place mutations that don't change the
    /// @Query array identity) refresh the cached snapshots.
    /// Uses stored `coverRevision` — never faults cover blobs.
    private var contentRevision: Int {
        var hasher = Hasher()
        for playlist in allPlaylists {
            hasher.combine(playlist.id)
            hasher.combine(playlist.name)
            hasher.combine(playlist.isSoftDeleted)
            hasher.combine(playlist.isReleased)
            hasher.combine(playlist.coverRevision ?? 0)
            hasher.combine(playlist.sortIndex ?? -1)
            hasher.combine(playlist.folder?.id)
        }
        for folder in allFolders {
            hasher.combine(folder.id)
            hasher.combine(folder.name)
            hasher.combine(folder.isSoftDeleted)
        }
        for track in allTracks {
            hasher.combine(track.id)
            hasher.combine(track.isSet)
            hasher.combine(track.lastTouchedAt)
        }
        return hasher.finalize()
    }

    /// Installs that never saved the setting but already hold long recordings keep them in the tab.
    private func migrateRecordingsSetting() {
        guard UserDefaults.standard.object(forKey: BouncePreferenceKey.showSetsTab) == nil,
              allTracks.contains(where: \.isSet) else { return }
        showSetsTab = true
    }

    private func rebuildSnapshots() {
        var list: [SidebarRowSnapshot] = []
        list.append(SidebarRowSnapshot(id: "all-tracks", type: .allTracks))
        if showReleasesTab {
            list.append(SidebarRowSnapshot(id: "releases", type: .releases))
        }
        if showSetsTab {
            list.append(SidebarRowSnapshot(
                id: "sets",
                type: .sets(count: allTracks.filter(\.isSet).count)
            ))
        }

        list.append(SidebarRowSnapshot(id: "header-playlists", type: .header("PLAYLISTS")))
        
        for playlist in unfiledPlaylists {
            list.append(SidebarRowSnapshot(
                id: "playlist-\(playlist.id.uuidString)",
                type: .playlist(id: playlist.id, name: playlist.name, parentFolderID: nil, coverRevision: playlist.coverRevision)
            ))
        }
        
        for folder in folders {
            let isExpanded = expandedFolderIDs.contains(folder.id)
            list.append(SidebarRowSnapshot(
                id: "folder-\(folder.id.uuidString)",
                type: .folder(id: folder.id, name: folder.name, isExpanded: isExpanded)
            ))
            if isExpanded {
                let sorted = folder.playlists
                    .filter { !$0.isSoftDeleted && !$0.isReleased }
                    .sorted { ($0.sortIndex ?? 0) < ($1.sortIndex ?? 0) }
                for playlist in sorted {
                    list.append(SidebarRowSnapshot(
                        id: "playlist-\(playlist.id.uuidString)",
                        type: .playlist(id: playlist.id, name: playlist.name, parentFolderID: folder.id, coverRevision: playlist.coverRevision)
                    ))
                }
            }
        }
        cachedSnapshots = list
        lastContentRevision = contentRevision
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarTableView(
                snapshots: flatSnapshots,
                selection: $selection,
                expandedFolderIDs: $expandedFolderIDs,
                onDestinationActivated: onDestinationActivated,
                allPlaylists: allPlaylists,
                folders: folders,
                unfiledPlaylists: unfiledPlaylists,
                orderedPlaylists: orderedPlaylists(in:),
                onReorder: handleReorder,
                onReorderFolder: moveFolder(_:destinationRow:),
                onAddVersionsToPlaylist: addVersionsToPlaylist,
                onBeginCreatePlaylist: beginCreatePlaylist(folderID:),
                onCreateFolder: createFolder,
                onDeleteFolder: deleteFolder(id:),
                onRenameFolder: beginRenameFolder,
                onDeletePlaylist: deletePlaylist(id:),
                onEditPlaylist: beginEditPlaylist,
                onTogglePlaylistRelease: togglePlaylistRelease
            )
            .background(Color.clear)

            Divider()

            SyncStatusFooter(
                onTap: { isSyncSheetPresented = true }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .columnBackground(.sidebar)
        .sheet(isPresented: $isCreatingNewPlaylist) {
            PlaylistEditSheet(
                playlist: nil,
                folder: creatingPlaylistInFolder,
                onSaved: { playlist in
                    selection = .playlist(playlist.id)
                }
            )
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditSheet(playlist: playlist, folder: nil)
        }
        .sheet(item: $editingFolder) { folder in
            PlaylistFolderEditSheet(folder: folder)
        }
        .alert(
            "Delete \u{201C}\(playlistToDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { playlistToDelete != nil },
                set: { if !$0 { playlistToDelete = nil } }
            ),
            presenting: playlistToDelete
        ) { playlist in
            Button("Delete", role: .destructive) { deletePlaylist(playlist) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The tracks stay in your library.")
        }
        .alert(
            "Delete \u{201C}\(folderToDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            presenting: folderToDelete
        ) { folder in
            Button("Delete", role: .destructive) { deleteFolder(folder) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The folder and its playlists are deleted. The tracks stay in your library.")
        }
        .onChange(of: allPlaylists, initial: true) {
            if contentRevision != lastContentRevision { rebuildSnapshots() }
        }
        .onChange(of: allFolders, initial: true) {
            if contentRevision != lastContentRevision { rebuildSnapshots() }
        }
        .onChange(of: allTracks, initial: true) {
            if contentRevision != lastContentRevision { rebuildSnapshots() }
        }
        .onChange(of: expandedFolderIDs, initial: true) { rebuildSnapshots() }
        .onChange(of: showReleasesTab) { _, isVisible in
            if !isVisible, case .releases = selection {
                selection = .allTracks
            }
            rebuildSnapshots()
        }
        .onAppear(perform: migrateRecordingsSetting)
        .onChange(of: allTracks.count) { migrateRecordingsSetting() }
        .onChange(of: showSetsTab) { _, isVisible in
            if !isVisible, case .sets = selection {
                selection = .allTracks
            }
            rebuildSnapshots()
        }
        // Renames and cover edits mutate playlists in place without changing the
        // @Query array identity, so refresh on save when the signature changes.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            if contentRevision != lastContentRevision { rebuildSnapshots() }
        }
    }

    // MARK: - Data

    private var unfiledPlaylists: [Playlist] {
        playlists
            .filter { $0.folder == nil }
            .sorted(by: comparePlaylists)
    }

    private func playlists(in folder: PlaylistFolder) -> [Playlist] {
        playlists
            .filter { $0.folder?.id == folder.id }
            .sorted(by: comparePlaylists)
    }

    private func comparePlaylists(_ lhs: Playlist, _ rhs: Playlist) -> Bool {
        let l = lhs.sortIndex ?? .max
        let r = rhs.sortIndex ?? .max
        if l != r { return l < r }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func orderedPlaylists(in folderID: UUID?) -> [Playlist] {
        playlists
            .filter { $0.folder?.id == folderID }
            .sorted(by: comparePlaylists)
    }

    // MARK: - Drag/drop handlers

    private func movePlaylist(_ playlistID: UUID, destinationFolderID: UUID?, destinationIndex: Int) {
        guard let playlist = allPlaylists.first(where: { $0.id == playlistID }) else { return }

        let sourceFolderID = playlist.folder?.id
        let destinationFolder = destinationFolderID.flatMap { id in
            folders.first(where: { $0.id == id })
        }

        if sourceFolderID == destinationFolderID {
            var items = orderedPlaylists(in: sourceFolderID)
            guard let sourceIndex = items.firstIndex(where: { $0.id == playlistID }) else { return }
            items.remove(at: sourceIndex)
            let adjusted = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
            items.insert(playlist, at: max(0, min(adjusted, items.count)))
            applyOrder(items)
        } else {
            var sourceItems = orderedPlaylists(in: sourceFolderID)
            sourceItems.removeAll { $0.id == playlistID }

            playlist.folder = destinationFolder

            var destinationItems = orderedPlaylists(in: destinationFolderID)
            destinationItems.removeAll { $0.id == playlistID }
            destinationItems.insert(playlist, at: max(0, min(destinationIndex, destinationItems.count)))

            applyOrder(sourceItems)
            applyOrder(destinationItems)
        }

        try? modelContext.save()
    }

    private func moveFolder(_ folderID: UUID, destinationRow: Int) {
        guard let draggedFolder = folders.first(where: { $0.id == folderID }) else { return }
        
        let sortedFolders = folders.sorted { $0.createdAt < $1.createdAt }
        let remaining = sortedFolders.filter { $0.id != folderID }
        
        if remaining.isEmpty {
            return
        }
        
        struct FolderRow {
            let folder: PlaylistFolder
            let row: Int
        }
        let remainingRows = remaining.compactMap { f -> FolderRow? in
            guard let row = flatSnapshots.firstIndex(where: { $0.id == "folder-\(f.id.uuidString)" }) else { return nil }
            return FolderRow(folder: f, row: row)
        }
        
        if remainingRows.isEmpty {
            return
        }
        
        var insertIndex = remainingRows.count
        for (index, item) in remainingRows.enumerated() {
            if destinationRow <= item.row {
                insertIndex = index
                break
            }
        }
        
        let newDate: Date
        if insertIndex == 0 {
            newDate = remainingRows[0].folder.createdAt.addingTimeInterval(-60)
        } else if insertIndex == remainingRows.count {
            newDate = remainingRows[remainingRows.count - 1].folder.createdAt.addingTimeInterval(60)
        } else {
            let beforeDate = remainingRows[insertIndex - 1].folder.createdAt
            let afterDate = remainingRows[insertIndex].folder.createdAt
            let midTime = beforeDate.timeIntervalSince1970 + (afterDate.timeIntervalSince1970 - beforeDate.timeIntervalSince1970) / 2.0
            newDate = Date(timeIntervalSince1970: midTime)
        }
        
        draggedFolder.createdAt = newDate
        try? modelContext.save()
    }

    private func applyOrder(_ list: [Playlist]) {
        for (i, playlist) in list.enumerated() {
            playlist.sortIndex = i
        }
    }

    // MARK: - Actions

    private func beginCreatePlaylist(folder: PlaylistFolder?) {
        creatingPlaylistInFolder = folder
        isCreatingNewPlaylist = true
    }

    private func beginRenameFolder(_ folderID: UUID) {
        if let folder = folders.first(where: { $0.id == folderID }) {
            editingFolder = folder
        }
    }

    private func handleReorder(_ playlistID: UUID, _ index: Int, _ folderID: UUID?) {
        movePlaylist(playlistID, destinationFolderID: folderID, destinationIndex: index)
    }

    private func addVersionsToPlaylist(_ versionIDs: [UUID], _ playlistID: UUID) {
        if let playlist = allPlaylists.first(where: { $0.id == playlistID }) {
            insertPlaylistEntries(versionIDs: versionIDs, into: playlist, context: modelContext)
        }
    }

    private func beginCreatePlaylist(folderID: UUID?) {
        let folder = folderID.flatMap { id in folders.first(where: { $0.id == id }) }
        beginCreatePlaylist(folder: folder)
    }

    private func deleteFolder(id: UUID) {
        folderToDelete = folders.first(where: { $0.id == id })
    }

    private func deletePlaylist(id: UUID) {
        playlistToDelete = allPlaylists.first(where: { $0.id == id })
    }

    private func beginEditPlaylist(_ playlistID: UUID) {
        if let playlist = allPlaylists.first(where: { $0.id == playlistID }) {
            editingPlaylist = playlist
        }
    }

    private func createFolder() {
        let folder = PlaylistFolder(name: "New Folder")
        modelContext.insert(folder)
        do {
            try modelContext.save()
            expandedFolderIDs.insert(folder.id)
        } catch {
            SyncLog.sender.error("Failed to create playlist folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        if case .playlist(let id) = selection, id == playlist.id {
            selection = .allTracks
        }
        modelContext.softDeletePlaylist(playlist)
        saveDeletion()
    }

    private func deleteFolder(_ folder: PlaylistFolder) {
        if case .playlist(let id) = selection,
           folder.playlists.contains(where: { $0.id == id }) {
            selection = .allTracks
        }
        modelContext.softDeleteFolder(folder)
        saveDeletion()
    }

    private func saveDeletion() {
        do {
            try modelContext.save()
        } catch {
            SyncLog.sender.error("Failed to delete playlist or folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func togglePlaylistRelease(_ playlistID: UUID) {
        guard let playlist = allPlaylists.first(where: { $0.id == playlistID }) else { return }
        playlist.isReleased.toggle()
        playlist.updatedAt = .now
        try? modelContext.save()
    }
}

// MARK: - NSTableView Sidebar components

struct SidebarRowSnapshot: Identifiable, Equatable {
    enum RowType: Equatable {
        case allTracks
        case releases
        case sets(count: Int)
        case header(String)
        case folder(id: UUID, name: String, isExpanded: Bool)
        case playlist(id: UUID, name: String, parentFolderID: UUID?, coverRevision: Int64?)
    }

    let id: String
    let type: RowType
}

struct SidebarTableView: NSViewRepresentable {
    let snapshots: [SidebarRowSnapshot]
    @Binding var selection: LibrarySelection
    @Binding var expandedFolderIDs: Set<UUID>
    let onDestinationActivated: (() -> Void)?

    let allPlaylists: [Playlist]
    let folders: [PlaylistFolder]
    let unfiledPlaylists: [Playlist]
    let orderedPlaylists: (UUID?) -> [Playlist]
    
    let onReorder: (UUID, Int, UUID?) -> Void
    let onReorderFolder: (UUID, Int) -> Void
    let onAddVersionsToPlaylist: ([UUID], UUID) -> Void
    let onBeginCreatePlaylist: (UUID?) -> Void
    let onCreateFolder: () -> Void
    let onDeleteFolder: (UUID) -> Void
    let onRenameFolder: (UUID) -> Void
    let onDeletePlaylist: (UUID) -> Void
    let onEditPlaylist: (UUID) -> Void
    let onTogglePlaylistRelease: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        context.coordinator.parent = self
        
        let snapshotsChanged = context.coordinator.lastSnapshots != snapshots
        if snapshotsChanged {
            context.coordinator.lastSnapshots = snapshots
            context.coordinator.tableView?.reloadData()
        }
        context.coordinator.setSelection(selection)
    }
}

extension SidebarTableView {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        fileprivate var parent: SidebarTableView
        private let pasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.playlist-row")
        private let folderPasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.folder-row")
        private let libraryVersionPasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.library-version-item")
        // Tracks dragged out of a playlist detail table arrive under this type
        // (comma-joined version UUIDs); a drop onto a sidebar playlist adds them.
        private let playlistEntryPasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.playlist-entry-item")

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        var lastSnapshots: [SidebarRowSnapshot] = []

        init(parent: SidebarTableView) {
            self.parent = parent
        }

        func makeView() -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            let tableView = SidebarNSTableView(frame: .zero)
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.rowHeight = 32
            tableView.intercellSpacing = NSSize(width: 0, height: 2)
            tableView.selectionHighlightStyle = .regular
            tableView.focusRingType = .none
            tableView.backgroundColor = .clear
            tableView.gridStyleMask = []
            tableView.dataSource = self
            tableView.delegate = self
            tableView.allowsEmptySelection = false
            tableView.allowsMultipleSelection = false
            tableView.style = .sourceList
            tableView.draggingDestinationFeedbackStyle = .gap
            
            tableView.registerForDraggedTypes([
                pasteboardType,
                folderPasteboardType,
                libraryVersionPasteboardType,
                playlistEntryPasteboardType
            ])
            tableView.setDraggingSourceOperationMask(.move, forLocal: true)
            tableView.setDraggingSourceOperationMask([], forLocal: false)
            tableView.onRowClick = { [weak self] row in
                self?.handleRowClick(row: row)
            }
            
            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu

            let scrollView = NSScrollView(frame: .zero)
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.documentView = tableView

            self.tableView = tableView
            self.scrollView = scrollView
            
            lastSnapshots = parent.snapshots
            tableView.reloadData()
            setSelection(parent.selection)
            
            return scrollView
        }

        func setSelection(_ selection: LibrarySelection) {
            guard let tableView else { return }
            
            let targetRow: Int?
            switch selection {
            case .allTracks:
                targetRow = parent.snapshots.firstIndex(where: { $0.id == "all-tracks" })
            case .releases:
                targetRow = parent.snapshots.firstIndex(where: { $0.id == "releases" })
            case .sets:
                targetRow = parent.snapshots.firstIndex(where: { $0.id == "sets" })
            case .playlist(let id):
                if let row = parent.snapshots.firstIndex(where: { $0.id == "playlist-\(id.uuidString)" }) {
                    targetRow = row
                } else if parent.allPlaylists.first(where: { $0.id == id })?.isReleased == true {
                    // Released playlists have no sidebar row; keep the Releases parent highlighted.
                    targetRow = parent.snapshots.firstIndex(where: { $0.id == "releases" })
                } else {
                    targetRow = nil
                }
            }
            
            if let row = targetRow, tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        /// First row index where playlist/folder content may appear (after All Tracks,
        /// Releases, and the PLAYLISTS header). Used by drag/drop destination math.
        private var playlistsContentStartRow: Int {
            if let headerIndex = parent.snapshots.firstIndex(where: {
                if case .header = $0.type { return true }
                return false
            }) {
                return headerIndex + 1
            }
            return 3
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.snapshots.count
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < parent.snapshots.count else { return nil }
            let snapshot = parent.snapshots[row]
            
            switch snapshot.type {
            case .playlist(let id, _, _, _):
                let item = NSPasteboardItem()
                item.setString(id.uuidString, forType: pasteboardType)
                return item
            case .folder(let id, _, _):
                let item = NSPasteboardItem()
                item.setString(id.uuidString, forType: folderPasteboardType)
                return item
            default:
                return nil
            }
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            // A real drag session has started. Row activation is suppressed for
            // the whole session, including a cancelled drag released over its
            // original row, so the narrow drawer stays open while dragging.
            (tableView as? SidebarNSTableView)?.didStartDragSession = true
            RowDragImage.apply(to: session, tableView: tableView, rowIndexes: rowIndexes)
        }


        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            
            // Case 1: Drop a library track version onto a playlist.
            // Use the plain highlight feedback — `.on` drops gain nothing from
            // `.gap`, and the gap style's row-shuffle bookkeeping makes the
            // target highlight lag behind the cursor.
            if info.draggingPasteboard.availableType(from: [libraryVersionPasteboardType, playlistEntryPasteboardType]) != nil {
                tableView.draggingDestinationFeedbackStyle = .regular
                // Trust the pointer's row, not AppKit's proposedRow — for `.on`
                // drops the proposed row snaps to insertion boundaries and can
                // highlight the neighbor instead of the row under the cursor.
                let point = tableView.convert(info.draggingLocation, from: nil)
                let hitRow = tableView.row(at: point)
                guard hitRow >= 0, hitRow < parent.snapshots.count else { return [] }
                let target = parent.snapshots[hitRow]
                if case .playlist = target.type {
                    tableView.setDropRow(hitRow, dropOperation: .on)
                    return .copy
                }
                return []
            }

            // Case 2: Drop a playlist row to reorder. Insertion reorders want
            // the animated gap indicator.
            if info.draggingPasteboard.availableType(from: [pasteboardType]) != nil {
                tableView.draggingDestinationFeedbackStyle = .gap
                let localPoint = tableView.convert(info.draggingLocation, from: nil)
                
                var targetRow = row
                var targetOp = dropOperation
                
                if targetOp == .on {
                    guard targetRow >= 0, targetRow < parent.snapshots.count else { return [] }
                    let target = parent.snapshots[targetRow]
                    switch target.type {
                    case .folder:
                        if localPoint.x < 28 {
                            targetRow = findNearestRootLevelRow(forRow: targetRow)
                            targetOp = .above
                        }
                    case .playlist:
                        if localPoint.x < 28 {
                            targetRow = findNearestRootLevelRow(forRow: targetRow)
                        }
                        targetOp = .above
                    default:
                        return []
                    }
                } else {
                    if localPoint.x < 28 {
                        targetRow = findNearestRootLevelRow(forRow: targetRow)
                        targetOp = .above
                    }
                }
                
                if targetRow != row || targetOp != dropOperation {
                    tableView.setDropRow(targetRow, dropOperation: targetOp)
                }
                
                if targetRow < playlistsContentStartRow {
                    return []
                }
                
                return .move
            }
            
            // Case 3: Drop a folder row to reorder
            if info.draggingPasteboard.availableType(from: [folderPasteboardType]) != nil {
                tableView.draggingDestinationFeedbackStyle = .gap
                if dropOperation == .on {
                    return []
                }
                
                let targetRow = findNearestRootLevelRow(forRow: row)
                if targetRow != row {
                    tableView.setDropRow(targetRow, dropOperation: .above)
                }
                
                if targetRow < playlistsContentStartRow {
                    return []
                }
                
                return .move
            }
            
            return []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            
            // Case 1: Drop track version(s) onto a playlist — from the library
            // list or from another playlist's detail table.
            if info.draggingPasteboard.availableType(from: [libraryVersionPasteboardType, playlistEntryPasteboardType]) != nil {
                guard row >= 0, row < parent.snapshots.count else { return false }
                let target = parent.snapshots[row]
                if case .playlist(let playlistID, _, _, _) = target.type {
                    let versionIDs = droppedVersionIDs(from: info.draggingPasteboard)
                    parent.onAddVersionsToPlaylist(versionIDs, playlistID)
                    return !versionIDs.isEmpty
                }
                return false
            }
            
            // Case 2: Drop a playlist row to reorder
            if let draggedIDString = info.draggingPasteboard.string(forType: pasteboardType),
               let draggedID = UUID(uuidString: draggedIDString) {
                
                let localPoint = tableView.convert(info.draggingLocation, from: nil)
                let (destFolderID, index) = calculateDestination(forRow: row, dropOperation: dropOperation, localPoint: localPoint)
                parent.onReorder(draggedID, index, destFolderID)
                return true
            }
            
            // Case 3: Drop a folder row to reorder
            if let draggedIDString = info.draggingPasteboard.string(forType: folderPasteboardType),
               let draggedID = UUID(uuidString: draggedIDString) {
                
                if dropOperation != .on {
                    let targetRow = findNearestRootLevelRow(forRow: row)
                    parent.onReorderFolder(draggedID, targetRow)
                    return true
                }
            }
            
            return false
        }

        /// Version IDs from a drop, decoding either encoding: the library list
        /// writes one pasteboard item per row (`library-version-item`); a
        /// playlist detail table writes a single comma-joined item
        /// (`playlist-entry-item`).
        private func droppedVersionIDs(from pasteboard: NSPasteboard) -> [UUID] {
            if pasteboard.availableType(from: [libraryVersionPasteboardType]) != nil {
                return pasteboard.pasteboardItems?.compactMap { item in
                    UUID(uuidString: item.string(forType: libraryVersionPasteboardType) ?? "")
                } ?? []
            }
            if let joined = pasteboard.string(forType: playlistEntryPasteboardType) {
                return joined.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            }
            return []
        }

        private func findNearestRootLevelRow(forRow row: Int) -> Int {
            let contentStart = playlistsContentStartRow
            var validRows: Set<Int> = [contentStart, parent.snapshots.count]
            for i in contentStart..<parent.snapshots.count {
                let snapshot = parent.snapshots[i]
                switch snapshot.type {
                case .playlist(_, _, let parentFolderID, _):
                    if parentFolderID == nil {
                        validRows.insert(i)
                    }
                case .folder:
                    validRows.insert(i)
                default:
                    break
                }
            }
            
            if validRows.contains(row) {
                return row
            }
            
            var distance = 1
            while true {
                let below = row + distance
                let above = row - distance
                if validRows.contains(below) {
                    return below
                }
                if validRows.contains(above) {
                    return above
                }
                if below >= parent.snapshots.count && above <= contentStart {
                    break
                }
                distance += 1
            }
            
            return parent.snapshots.count
        }

        private func calculateDestination(forRow targetRow: Int, dropOperation: NSTableView.DropOperation, localPoint: NSPoint?) -> (UUID?, Int) {
            let list = parent.snapshots
            let contentStart = playlistsContentStartRow
            
            // Case 1: Drop ON a row (only folders can accept this)
            if dropOperation == .on {
                guard targetRow >= 0, targetRow < list.count else { return (nil, 0) }
                if case .folder(let folderID, _, _) = list[targetRow].type {
                    return (folderID, 0)
                }
                return (nil, 0)
            }
            
            // Case 2: Drop ABOVE/between rows
            let isHoveringLeft = localPoint.flatMap { $0.x < 28 } ?? false
            
            // `targetRow == list.count` (drop below the last row) must also resolve
            // at root level: with an expanded folder at the bottom, `prevRow` is an
            // in-folder playlist and the folder branch below would re-append the
            // dragged playlist into the folder it was just dragged out of.
            if isHoveringLeft || targetRow <= contentStart || targetRow >= list.count {
                return calculateRootLevelDestination(forRow: targetRow)
            }
            
            let prevRow = targetRow - 1
            if prevRow >= contentStart, prevRow < list.count {
                let prevSnapshot = list[prevRow]
                switch prevSnapshot.type {
                case .playlist(_, _, let parentFolderID, _):
                    if let folderID = parentFolderID {
                        let siblings = parent.orderedPlaylists(folderID)
                        if targetRow < list.count,
                           case .playlist(let targetID, _, let targetFolderID, _) = list[targetRow].type,
                           targetFolderID == folderID {
                            let destIndex = siblings.firstIndex(where: { $0.id == targetID }) ?? 0
                            return (folderID, destIndex)
                        } else {
                            return (folderID, siblings.count)
                        }
                    }
                case .folder(let folderID, _, let isExpanded):
                    if isExpanded {
                        return (folderID, 0)
                    }
                default:
                    break
                }
            }
            
            return calculateRootLevelDestination(forRow: targetRow)
        }

        private func calculateRootLevelDestination(forRow targetRow: Int) -> (UUID?, Int) {
            let list = parent.snapshots
            let contentStart = playlistsContentStartRow
            var unfiledCountBefore = 0
            
            for i in contentStart..<min(targetRow, list.count) {
                if case .playlist(_, _, nil, _) = list[i].type {
                    unfiledCountBefore += 1
                }
            }
            
            return (nil, unfiledCountBefore)
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < parent.snapshots.count else { return 32 }
            let snapshot = parent.snapshots[row]
            if case .header = snapshot.type { return 28 }
            return rowHeight(for: snapshot, width: tableView.bounds.width)
        }

        /// Single-line names keep the existing 32pt row; a name that wraps
        /// gets 48pt so the second line is never clipped. Measured at the
        /// table's live width, with a few points of slack so SwiftUI wraps
        /// slightly before the measured limit.
        private func rowHeight(for snapshot: SidebarRowSnapshot, width: CGFloat) -> CGFloat {
            let name: String
            let font: NSFont
            let available: CGFloat
            switch snapshot.type {
            case .folder(_, let folderName, _):
                name = folderName
                font = .systemFont(ofSize: 13, weight: .semibold)
                // 10pt padding ×2 + 18pt icon + three 8pt gaps + 14pt disclosure.
                available = width - 78
            case .playlist(_, let playlistName, let parentFolderID, _):
                name = playlistName
                font = .systemFont(ofSize: 13)
                // 10pt padding ×2 + 18pt icon + two 8pt gaps + nested indent.
                let indent: CGFloat = parentFolderID != nil ? 18 : 0
                available = width - 58 - indent
            default:
                return 32
            }
            guard available > 0 else { return 32 }
            let measured = (name as NSString).boundingRect(
                with: NSSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height
            return measured > 18 ? 48 : 32
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard row >= 0, row < parent.snapshots.count else { return false }
            if case .header = parent.snapshots[row].type {
                return true
            }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0, row < parent.snapshots.count else { return false }
            let snapshot = parent.snapshots[row]
            switch snapshot.type {
            case .header, .folder:
                return false
            default:
                return true
            }
        }

        func tableView(_ tableView: NSTableView, canDragRowsWith rowIndexes: IndexSet, at point: NSPoint) -> Bool {
            for row in rowIndexes {
                guard row >= 0, row < parent.snapshots.count else { return false }
                let snapshot = parent.snapshots[row]
                switch snapshot.type {
                case .playlist, .folder:
                    continue
                default:
                    return false
                }
            }
            return true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            guard row >= 0, row < parent.snapshots.count else { return }
            let snapshot = parent.snapshots[row]
            
            switch snapshot.type {
            case .allTracks:
                parent.selection = .allTracks
            case .releases:
                parent.selection = .releases
            case .sets:
                parent.selection = .sets
            case .playlist(let id, _, _, _):
                parent.selection = .playlist(id)
            default:
                break
            }
        }

        /// Row-level click hook. `tableViewSelectionDidChange` never fires when
        /// the clicked row is already selected, so the narrow drawer relies on
        /// this to dismiss even when the current destination is re-selected.
        /// Folder rows are containers, not destinations: clicking one anywhere
        /// toggles its expanded state and never touches `parent.selection`, so
        /// the main surface stays where it is.
        func handleRowClick(row: Int) {
            guard row >= 0, row < parent.snapshots.count else { return }
            switch parent.snapshots[row].type {
            case .folder(let id, _, _):
                toggleFolder(folderID: id)
            case .allTracks, .releases, .sets, .playlist:
                parent.onDestinationActivated?()
            case .header:
                break
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let snapshot = parent.snapshots[row]
            let identifier = NSUserInterfaceItemIdentifier("SidebarCellView")
            
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCellView
                ?? SidebarCellView()
            
            let coverData: Data?
            switch snapshot.type {
            case .playlist(let id, _, _, _):
                coverData = parent.allPlaylists.first(where: { $0.id == id })?.coverImageData
            default:
                coverData = nil
            }

            cell.appearance = tableView.effectiveAppearance
            cell.configure(
                snapshot: snapshot,
                coverImageData: coverData,
                onToggleFolder: { [weak self] folderID in
                    self?.toggleFolder(folderID: folderID)
                }
            )
            return cell
        }

        func toggleFolder(folderID: UUID) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if parent.expandedFolderIDs.contains(folderID) {
                    parent.expandedFolderIDs.remove(folderID)
                } else {
                    parent.expandedFolderIDs.insert(folderID)
                }
            }
        }

        // MARK: - Context Menu (NSMenuDelegate)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView,
                  tableView.clickedRow >= 0,
                  tableView.clickedRow < parent.snapshots.count else {
                menu.addItem(NSMenuItem(title: "New Playlist…", symbol: "music.note.list", action: #selector(newPlaylistMenuAction), target: self))
                menu.addItem(NSMenuItem(title: "New Folder", symbol: "folder.badge.plus", action: #selector(newFolderMenuAction), target: self))
                return
            }
            let snapshot = parent.snapshots[tableView.clickedRow]
            switch snapshot.type {
            case .folder(let id, let name, _):
                let newPlaylistItem = NSMenuItem(title: "New Playlist in \"\(name)\"…", symbol: "music.note.list", action: #selector(newPlaylistInFolderAction(_:)), target: self)
                newPlaylistItem.representedObject = id
                menu.addItem(newPlaylistItem)
                menu.addItem(.separator())
                let renameItem = NSMenuItem(title: "Rename…", symbol: "pencil", action: #selector(renameFolderAction(_:)), target: self)
                renameItem.representedObject = id
                menu.addItem(renameItem)
                let deleteItem = NSMenuItem(title: "Delete Folder", symbol: "trash", action: #selector(deleteFolderAction(_:)), target: self)
                deleteItem.representedObject = id
                menu.addItem(deleteItem)
            case .playlist(let id, _, _, _):
                let playlist = parent.allPlaylists.first(where: { $0.id == id })
                let isReleased = playlist?.isReleased ?? false
                let releaseItem = NSMenuItem(
                    title: isReleased ? "Unmark as Released" : "Mark as Released",
                    symbol: isReleased ? "checkmark.seal.fill" : "checkmark.seal",
                    action: #selector(togglePlaylistReleaseAction(_:)),
                    target: self
                )
                releaseItem.representedObject = id
                menu.addItem(releaseItem)
                menu.addItem(.separator())
                let editItem = NSMenuItem(title: "Edit…", symbol: "pencil", action: #selector(editPlaylistAction(_:)), target: self)
                editItem.representedObject = id
                menu.addItem(editItem)
                let deleteItem = NSMenuItem(title: "Delete", symbol: "trash", action: #selector(deletePlaylistAction(_:)), target: self)
                deleteItem.representedObject = id
                menu.addItem(deleteItem)
            default:
                break
            }
        }

        @objc func newPlaylistMenuAction() {
            parent.onBeginCreatePlaylist(nil)
        }
        
        @objc func newFolderMenuAction() {
            parent.onCreateFolder()
        }
        
        @objc func newPlaylistInFolderAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                parent.onBeginCreatePlaylist(id)
            }
        }
        
        @objc func deleteFolderAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                parent.onDeleteFolder(id)
            }
        }
        
        @objc func renameFolderAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                parent.onRenameFolder(id)
            }
        }
        
        @objc func editPlaylistAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                parent.onEditPlaylist(id)
            }
        }

        @objc func togglePlaylistReleaseAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                parent.onTogglePlaylistRelease(id)
            }
        }
        
        @objc func deletePlaylistAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                parent.onDeletePlaylist(id)
            }
        }
    }
}

final class SidebarNSTableView: NSTableView {
    /// Fired after a row click, including when it is already the selected row
    /// (where AppKit sends no selection-change callback). Suppressed whenever a
    /// real drag session ran, so row activation only happens for true clicks.
    var onRowClick: ((Int) -> Void)?

    /// Set by the drag-session delegate when an `NSDraggingSession` begins and
    /// read when the mouse-down tracking returns. A drag released over its
    /// original row therefore still suppresses row activation.
    var didStartDragSession = false

    /// A name wraps to two lines when the sidebar narrows, so row heights are
    /// width-dependent. Re-measure them when the width changes; drag/drop hit
    /// testing reads the same updated row rects.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged, numberOfRows > 0 else { return }
        noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<numberOfRows))
    }

    override func mouseDown(with event: NSEvent) {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        // The second press of a double-click reports `clickCount == 2`; the
        // first press already toggled/activated, so repeating it here would
        // undo that toggle. Repeated clicks are therefore ignored.
        let isRepeatedClick = event.clickCount > 1
        didStartDragSession = false
        super.mouseDown(with: event)
        let didDrag = didStartDragSession
        didStartDragSession = false
        guard clickedRow >= 0, !didDrag, !isRepeatedClick else { return }
        let endPoint = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard row(at: endPoint) == clickedRow else { return }
        onRowClick?(clickedRow)
    }
}

final class SidebarCellView: NSTableCellView, DragSnapshotPreparable {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarCellView")
    
    private var hostingView: NSHostingView<SidebarRowContent>?
    private var currentSnapshot: SidebarRowSnapshot?
    private var coverImageData: Data?
    private var onToggleFolder: ((UUID) -> Void)?
    private var suppressSelectionForDrag = false
    
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateConfiguration()
        }
    }
    
    override var appearance: NSAppearance? {
        didSet {
            hostingView?.appearance = appearance
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
    }
    
    func configure(
        snapshot: SidebarRowSnapshot,
        coverImageData: Data? = nil,
        onToggleFolder: @escaping (UUID) -> Void
    ) {
        self.currentSnapshot = snapshot
        self.coverImageData = coverImageData
        self.onToggleFolder = onToggleFolder
        updateConfiguration()
    }
    
    func beginDragSnapshot() {
        suppressSelectionForDrag = true
        updateConfiguration()
    }

    func endDragSnapshot() {
        suppressSelectionForDrag = false
        updateConfiguration()
    }

    private func updateConfiguration() {
        guard let snapshot = currentSnapshot,
              let onToggleFolder = onToggleFolder else { return }
        let isSelected = (backgroundStyle == .emphasized) && !suppressSelectionForDrag

        let view = SidebarRowContent(
            snapshot: snapshot,
            coverImageData: coverImageData,
            isSelected: isSelected,
            isHovered: false,
            onToggleFolder: onToggleFolder
        )
        
        if let hostingView {
            hostingView.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            self.hostingView = host
        }
        hostingView?.appearance = appearance
    }
}

struct SidebarRowContent: View {
    let snapshot: SidebarRowSnapshot
    /// Lazy cover bytes for playlist rows — not stored in the sidebar snapshot.
    var coverImageData: Data? = nil
    let isSelected: Bool
    let isHovered: Bool
    let onToggleFolder: (UUID) -> Void

    // AppKit drag snapshots resolve semantic SwiftUI colors in the wrong
    // appearance; NSColor label colors respect the hosting view's appearance.
    private var labelColor: Color { Color(nsColor: .labelColor) }
    private var secondaryLabelColor: Color { Color(nsColor: .secondaryLabelColor) }
    private var tintColor: Color { Color(nsColor: .controlAccentColor) }

    private enum Layout {
        static let rowHorizontalPadding: CGFloat = 10
        static let iconSize: CGFloat = 18
        static let disclosureSlotWidth: CGFloat = 14
        static let iconLabelSpacing: CGFloat = 8
        static let nestedPlaylistIndent: CGFloat = 18

        // Align section titles with row labels, after the shared icon slot.
        // Folder disclosure now lives at the trailing edge, so no leading
        // slot is reserved.
        static let labelLeadingInset = rowHorizontalPadding
            + iconSize
            + iconLabelSpacing
    }

    private var primaryLabelColor: Color {
        isSelected ? .white : labelColor
    }

    private var secondaryRowColor: Color {
        isSelected ? .white : secondaryLabelColor
    }

    private func symbolIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .frame(width: Layout.iconSize, height: Layout.iconSize)
    }

    var body: some View {
        switch snapshot.type {
        case .allTracks:
            HStack(spacing: Layout.iconLabelSpacing) {
                symbolIcon("music.note.list", color: isSelected ? .white : tintColor)
                Text("All Tracks")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryLabelColor)
                Spacer()
            }
            .padding(.horizontal, Layout.rowHorizontalPadding)

        case .releases:
            HStack(spacing: Layout.iconLabelSpacing) {
                symbolIcon(
                    isSelected ? "checkmark.seal.fill" : "checkmark.seal",
                    color: isSelected ? .white : tintColor
                )
                Text("Releases")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryLabelColor)
                Spacer()
            }
            .padding(.horizontal, Layout.rowHorizontalPadding)

        case .sets(let count):
            HStack(spacing: Layout.iconLabelSpacing) {
                symbolIcon(
                    isSelected ? "sdcard.fill" : "sdcard",
                    color: isSelected ? .white : tintColor
                )
                Text(RecordingsCopy.plural)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryLabelColor)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : secondaryLabelColor)
                }
            }
            .padding(.horizontal, Layout.rowHorizontalPadding)

        case .header(let title):
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(secondaryLabelColor)
                    .kerning(0.5)
                Spacer()
            }
            .padding(.leading, Layout.labelLeadingInset)
            .padding(.trailing, Layout.rowHorizontalPadding)
            
        case .folder(let id, let name, let isExpanded):
            HStack(spacing: Layout.iconLabelSpacing) {
                symbolIcon("folder", color: secondaryRowColor)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(secondaryRowColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                // Visual only. The row itself is the click target (the table's
                // row-click hook), so a button here would fire a second toggle
                // for the same click.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(isSelected ? .white : secondaryLabelColor)
                    .frame(width: Layout.disclosureSlotWidth, height: Layout.iconSize)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Layout.rowHorizontalPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isExpanded ? "\(name), expanded" : "\(name), collapsed")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggleFolder(id) }
            
        case .playlist(let id, let name, let parentFolderID, let coverRevision):
            HStack(spacing: Layout.iconLabelSpacing) {
                playlistIcon(id: id, coverRevision: coverRevision)
                Text(name)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 13))
                    .foregroundStyle(primaryLabelColor)
                Spacer()
            }
            .padding(.leading, parentFolderID != nil ? Layout.nestedPlaylistIndent : 0)
            .padding(.horizontal, Layout.rowHorizontalPadding)
        }
    }

    @ViewBuilder
    private func playlistIcon(id: UUID, coverRevision: Int64?) -> some View {
        if let data = coverImageData,
           let nsImage = ArtworkThumbnailCache.thumbnail(
            data,
            id: id,
            side: Layout.iconSize,
            revision: coverRevision
           ) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: Layout.iconSize, height: Layout.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            symbolIcon("music.note.list", color: isSelected ? .white : secondaryLabelColor)
        }
    }
}

/// Modal for renaming a playlist folder. Folders carry only a name, so this is
/// the minimal counterpart to `PlaylistEditSheet`'s name field.
private struct PlaylistFolderEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let folder: PlaylistFolder

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Folder")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    GetInfoLabel("Name:")
                    TextField("Folder name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = folder.name }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        folder.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            SyncLog.sender.error("Failed to rename folder: \(error.localizedDescription, privacy: .public)")
        }
        dismiss()
    }
}
