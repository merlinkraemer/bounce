import AppKit
import SwiftUI
import BounceKit

/// `NSScrollView` that keeps catalogue rows readable under the titlebar while
/// still letting them scroll behind it. The resting top clearance is carried by
/// a constant `contentInsets.top` (the top fade height) with no measured input,
/// so no layout-pass ordering can move the header. A bottom inset keeps the
/// last row reachable above the transport bar.
final class LibraryScrollView: NSScrollView {
    private var lastBottomInset: CGFloat = -1

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentInsets()
    }

    override func layout() {
        super.layout()
        applyContentInsets()
    }

    private func applyContentInsets() {
        // The resting top clearance is a constant with no measured input, so
        // the top inset cannot land in a different layout pass from a row
        // height that was meant to complement it. The inset shifts the whole
        // document as one; this scroll view still spans the titlebar band, so
        // rows keep travelling under the chrome while scrolling. The bottom
        // inset equals the bottom fade, so the last row ends at its
        // transparent edge.
        let bottom = BounceConstants.columnBottomFadeHeight

        guard abs(bottom - lastBottomInset) > 0.5 else { return }
        let isFirstApplication = lastBottomInset < 0
        lastBottomInset = bottom
        contentInsets = NSEdgeInsets(
            top: BounceConstants.columnTopFadeHeight,
            left: 0,
            bottom: bottom,
            right: 0
        )
        // Setting an inset does not move the clip origin: on first mount the
        // document sat at y = 0, i.e. under the top clearance, and rows
        // visibly scrolled into place once the first layout settled.
        if isFirstApplication {
            contentView.scroll(to: NSPoint(x: 0, y: -BounceConstants.columnTopFadeHeight))
            reflectScrolledClipView(contentView)
        }
    }
}

/// AppKit-backed table that drives the library list. Lives in its own
/// file so the SwiftUI orchestration in `LibraryListView` stays focused
/// on actions and routing.
struct LibraryTrackTableView: NSViewRepresentable {
    let header: AnyView
    /// Height of the header body itself, measured from the hosted header's own
    /// rendered size by the owning SwiftUI surface. Row 0 and the hosted
    /// content both use this exact value, so neither can clip or leave slack.
    let headerHeight: CGFloat
    /// Reports the hosted header's own rendered height so the parent's
    /// `headerHeight` is measured from the same view instance the table sizes
    /// row 0 from, at the same width.
    let onHeaderHeightChange: (CGFloat) -> Void
    let items: [LibraryListItem]
    let playlists: [LibraryPlaylistMenuItem]
    /// Lazy artwork loader for visible cells only — keeps list snapshots blob-free.
    let artworkForTrack: (UUID) -> Data?
    @Binding var selectedVersionID: UUID?
    @Binding var selectedVersionIDs: Set<UUID>
    let inspectedVersionID: UUID?
    let inspectedVersionLabel: String?
    let columns: LibraryColumnVisibility
    let onInspectVersion: (UUID) -> Void
    let onToggleTrackExpansion: (UUID) -> Void
    let loadedVersionID: UUID?
    let isPlaying: Bool
    let renameTarget: InlineRenameManager.Target?
    let renameManager: InlineRenameManager
    let onPlayFromStart: (UUID) -> Void
    let onTogglePlayback: (UUID) -> Void
    let onAddTrackToPlaylist: (UUID, UUID) -> Void
    let onCreatePlaylistWithTrack: (UUID) -> Void
    let onAddVersionToQueue: (UUID) -> Void
    let onDeleteVersion: (UUID, UUID) -> Void
    let onDeleteSelected: ([LibraryTrackRowSnapshot]) -> Void
    let onAddSelectedToPlaylist: ([LibraryTrackRowSnapshot], UUID) -> Void
    let onCreatePlaylistWithSelected: ([LibraryTrackRowSnapshot]) -> Void
    let onNameThisVersion: (UUID) -> Void
    let onToggleReleased: (UUID) -> Void
    let onEditTrack: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false

        let itemsChanged = context.coordinator.itemsChanged(newItems: items)
        let playlistsChanged = context.coordinator.playlistsChanged(newPlaylists: playlists)
        let playbackChanged = context.coordinator.playbackChanged(
            loadedVersionID: loadedVersionID,
            isPlaying: isPlaying
        )
        let renameChanged = context.coordinator.renameChanged(newTarget: renameTarget)
        let inspectionChanged = context.coordinator.inspectionChanged(newID: inspectedVersionID)
        let columnsChanged = context.coordinator.columnsChanged(newColumns: columns)

        context.coordinator.parent = self

        if itemsChanged || playlistsChanged {
            context.coordinator.reloadAll()
        } else if renameChanged {
            context.coordinator.refreshRenameChange()
        } else if playbackChanged || inspectionChanged || columnsChanged {
            context.coordinator.refreshVisibleCells()
        }

        if context.coordinator.currentAnchorFromTable() != selectedVersionID {
            context.coordinator.setSelection(id: selectedVersionID)
        }

        let headerGeometryChanged = context.coordinator.headerGeometryChanged(headerHeight: headerHeight)
        if headerGeometryChanged {
            context.coordinator.noteHeaderGeometryChanged()
        }
        context.coordinator.refreshHeader()
    }
}

extension LibraryTrackTableView {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let libraryVersionPasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.library-version-item")
        private static let headerRow = 0
        fileprivate var parent: LibraryTrackTableView

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var headerCell: LibraryTableHeaderCellView?
        private var lastHeaderHeight: CGFloat?
        private var lastRow0Height: CGFloat = -1
        private var lastItemsSnapshot: [LibraryListItem] = []
        private var lastPlaylistsSnapshot: [LibraryPlaylistMenuItem] = []
        private var lastLoadedVersionID: UUID?
        private var lastIsPlaying = false
        private var lastRenameTarget: InlineRenameManager.Target?
        private var lastInspectedVersionID: UUID?
        private var lastColumns: LibraryColumnVisibility

        init(parent: LibraryTrackTableView) {
            self.parent = parent
            self.lastLoadedVersionID = parent.loadedVersionID
            self.lastIsPlaying = parent.isPlaying
            self.lastRenameTarget = parent.renameTarget
            self.lastInspectedVersionID = parent.inspectedVersionID
            self.lastColumns = parent.columns
        }

        func makeView() -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            let tableView = LibraryTableView(frame: .zero)
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.selectionHighlightStyle = .none
            tableView.focusRingType = .none
            tableView.backgroundColor = .clear
            tableView.gridStyleMask = []
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = true
            tableView.style = .plain
            tableView.dataSource = self
            tableView.delegate = self
            tableView.target = self
            tableView.doubleAction = #selector(doubleClickedRow(_:))
            tableView.onSelectAll = { [weak self] in
                self?.selectAllSelectableRows()
            }
            tableView.onDelete = { [weak self] in
                self?.deleteSelectedRows()
            }

            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu

            let scrollView = LibraryScrollView(frame: .zero)
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.borderType = .noBorder
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.documentView = tableView

            tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

            self.tableView = tableView
            self.scrollView = scrollView
            parent.renameManager.onDidBegin = { [weak self] target in
                self?.refresh(target: target)
            }
            parent.renameManager.onDidEnd = { [weak self] in
                self?.refreshVisibleCells()
            }
            reloadAll()
            return scrollView
        }

        func itemsChanged(newItems: [LibraryListItem]) -> Bool {
            newItems != lastItemsSnapshot
        }

        func playlistsChanged(newPlaylists: [LibraryPlaylistMenuItem]) -> Bool {
            newPlaylists != lastPlaylistsSnapshot
        }

        func playbackChanged(loadedVersionID: UUID?, isPlaying: Bool) -> Bool {
            loadedVersionID != lastLoadedVersionID || isPlaying != lastIsPlaying
        }

        func renameChanged(newTarget: InlineRenameManager.Target?) -> Bool {
            newTarget != lastRenameTarget
        }

        func inspectionChanged(newID: UUID?) -> Bool {
            newID != lastInspectedVersionID
        }

        func columnsChanged(newColumns: LibraryColumnVisibility) -> Bool {
            newColumns != lastColumns
        }

        func refreshRenameChange() {
            lastRenameTarget = parent.renameTarget
            lastInspectedVersionID = parent.inspectedVersionID
            lastColumns = parent.columns
            refreshVisibleCells()
        }

        func reloadAll() {
            guard let tableView else { return }
            lastItemsSnapshot = parent.items
            lastPlaylistsSnapshot = parent.playlists
            lastLoadedVersionID = parent.loadedVersionID
            lastIsPlaying = parent.isPlaying
            lastColumns = parent.columns
            lastInspectedVersionID = parent.inspectedVersionID
            lastRenameTarget = parent.renameTarget

            let previousSelection = selectedVersionID
            tableView.reloadData()
            setSelection(id: previousSelection)
            lastHeaderHeight = parent.headerHeight
        }

        func refreshVisibleCells() {
            guard let tableView else { return }
            lastLoadedVersionID = parent.loadedVersionID
            lastIsPlaying = parent.isPlaying
            lastInspectedVersionID = parent.inspectedVersionID
            lastColumns = parent.columns

            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.lowerBound..<visibleRows.upperBound {
                refreshCell(at: row)
            }
        }

        func refreshHeader() {
            guard let headerCell else { return }
            headerCell.configure(
                rootView: parent.header,
                appearance: tableView?.effectiveAppearance,
                onHeaderHeightChange: parent.onHeaderHeightChange
            )
        }

        func headerGeometryChanged(headerHeight: CGFloat) -> Bool {
            guard lastHeaderHeight != headerHeight else { return false }
            lastHeaderHeight = headerHeight
            return true
        }

        func noteHeaderGeometryChanged() {
            refreshRow0Layout()
        }

        /// Forces a coherent pass after row 0's height changes.
        /// `noteHeightOfRows(withIndexesChanged:)` refreshes row rects but
        /// leaves sibling row views at their previous frames, which then paint
        /// over the header; `tile()` + `layoutSubtreeIfNeeded()` repositions
        /// them. Guarded so it only runs when row 0's height actually changed.
        func refreshRow0Layout() {
            guard let tableView else { return }
            let row0Height = max(parent.headerHeight, 1)
            guard lastRow0Height != row0Height else { return }
            lastRow0Height = row0Height
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: Self.headerRow))
            tableView.tile()
            tableView.layoutSubtreeIfNeeded()
        }

        private func tableRow(forItemIndex index: Int) -> Int {
            index + 1
        }

        private func itemIndex(forTableRow row: Int) -> Int? {
            let index = row - 1
            guard index >= 0, index < parent.items.count else { return nil }
            return index
        }

        func refreshCell(at tableRow: Int) {
            guard let itemIndex = itemIndex(forTableRow: tableRow),
                  let tableView,
                  let snapshot = parent.items[itemIndex].rowSnapshot,
                  let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? LibraryTrackCellView else {
                return
            }

            configure(cell: cell, snapshot: snapshot)
        }

        private func refreshCell(forItemIndex itemIndex: Int) {
            refreshCell(at: tableRow(forItemIndex: itemIndex))
        }

        private func item(at tableRow: Int) -> LibraryListItem? {
            guard let itemIndex = itemIndex(forTableRow: tableRow) else { return nil }
            return parent.items[itemIndex]
        }

        private func refresh(target: InlineRenameManager.Target) {
            lastRenameTarget = target
            guard let row = parent.items.firstIndex(where: { item in
                guard let snapshot = item.rowSnapshot else { return false }
                switch target.kind {
                case .track:
                    return snapshot.trackID == target.id
                case .version:
                    return snapshot.versionID == target.id
                case .playlist, .playlistFolder:
                    return false
                }
            }) else { return }
            refreshCell(forItemIndex: row)
        }

        private var selectedVersionID: UUID? {
            guard let tableView else { return nil }
            return item(at: tableView.selectedRow)?.rowSnapshot?.versionID
        }

        @objc private func doubleClickedRow(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard let snapshot = item(at: row)?.rowSnapshot, snapshot.processingState == .complete else { return }
            parent.onPlayFromStart(snapshot.versionID)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count + 1
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let snapshot = item(at: row)?.rowSnapshot else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(snapshot.versionID.uuidString, forType: Coordinator.libraryVersionPasteboardType)
            DragExportFile.add(to: pbItem, filePath: snapshot.filePath, trackName: snapshot.trackName, versionLabel: snapshot.versionLabel)
            return pbItem
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            RowDragImage.apply(to: session, tableView: tableView, rowIndexes: rowIndexes)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            item(at: row)?.rowSnapshot != nil
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Row 0 is only the scrolling header body: the resting clearance
            // is the scroll view's constant top content inset, so the row
            // height and the hosted content are the same measured value.
            if row == Self.headerRow {
                let height = max(parent.headerHeight, 1)
                return height
            }
            guard let snapshot = item(at: row)?.rowSnapshot else { return 1 }
            return snapshot.rowKind == .mix ? 40 : 52
        }

        private var lastSelectedRowIndexes = IndexSet()
        private var isUpdatingSelection = false

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let indexes = tableView.selectedRowIndexes

            var ids = Set<UUID>()
            for tableRow in indexes {
                guard let versionID = item(at: tableRow)?.rowSnapshot?.versionID else { continue }
                ids.insert(versionID)
            }
            // Only write to the bindings on real changes — every write
            // invalidates the SwiftUI parent and re-derives the item list.
            if parent.selectedVersionIDs != ids {
                parent.selectedVersionIDs = ids
            }

            let anchor: UUID?
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0, indexes.contains(selectedRow) {
                anchor = item(at: selectedRow)?.rowSnapshot?.versionID
            } else if let first = indexes.first {
                anchor = item(at: first)?.rowSnapshot?.versionID
            } else {
                anchor = nil
            }
            if parent.selectedVersionID != anchor {
                parent.selectedVersionID = anchor
            }
            if let anchor, !isUpdatingSelection {
                parent.onInspectVersion(anchor)
            }

            // Refresh only rows whose selection state actually flipped,
            // not every visible cell.
            let changed = lastSelectedRowIndexes.symmetricDifference(indexes)
            lastSelectedRowIndexes = indexes
            for row in changed {
                refreshCell(at: row)
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            if row == Self.headerRow {
                let identifier = LibraryTableHeaderRowView.reuseIdentifier
                let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? LibraryTableHeaderRowView
                    ?? LibraryTableHeaderRowView()
                rowView.identifier = identifier
                return rowView
            }

            guard item(at: row)?.rowSnapshot != nil else {
                let identifier = NSUserInterfaceItemIdentifier("LibrarySeparatorRowView")
                let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableRowView
                    ?? NSTableRowView()
                rowView.identifier = identifier
                rowView.isEmphasized = false
                return rowView
            }

            let identifier = NSUserInterfaceItemIdentifier("LibraryTrackRowView")
            let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? HoverableSelectionRowView
                ?? HoverableSelectionRowView()
            rowView.identifier = identifier
            rowView.hoverDidChange = { [weak self, weak tableView, weak rowView] _ in
                guard let self, let tableView, let rowView else { return }
                self.refreshCell(at: tableView.row(for: rowView))
            }
            rowView.syncHoverState()
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == Self.headerRow {
                let view = tableView.makeView(
                    withIdentifier: LibraryTableHeaderCellView.reuseIdentifier,
                    owner: nil
                ) as? LibraryTableHeaderCellView ?? LibraryTableHeaderCellView()
                view.appearance = tableView.effectiveAppearance
                view.configure(
                    rootView: parent.header,
                    appearance: tableView.effectiveAppearance,
                    onHeaderHeightChange: parent.onHeaderHeightChange
                )
                headerCell = view
                return view
            }

            guard let item = item(at: row) else { return nil }

            if let snapshot = item.rowSnapshot {
                let view = tableView.makeView(
                    withIdentifier: LibraryTrackCellView.reuseIdentifier,
                    owner: nil
                ) as? LibraryTrackCellView ?? LibraryTrackCellView()
                view.appearance = tableView.effectiveAppearance
                configure(cell: view, snapshot: snapshot)
                return view
            }

            let view = tableView.makeView(
                withIdentifier: LibrarySeparatorCellView.reuseIdentifier,
                owner: nil
            ) as? LibrarySeparatorCellView ?? LibrarySeparatorCellView()
            return view
        }

        private func configure(cell: LibraryTrackCellView, snapshot: LibraryTrackRowSnapshot) {
            let isLoaded = parent.loadedVersionID == snapshot.versionID
            let isPlaying = isLoaded && parent.isPlaying

            cell.configure(
                snapshot: snapshot,
                artworkData: parent.artworkForTrack(snapshot.trackID),
                playlists: parent.playlists,
                isLoaded: isLoaded,
                isPlaying: isPlaying,
                inspectedVersionID: parent.inspectedVersionID,
                inspectedVersionLabel: parent.inspectedVersionLabel,
                columns: parent.columns,
                renameManager: parent.renameManager,
                onTogglePlayback: { [weak self] in
                    guard let self else { return }
                    self.parent.onTogglePlayback(snapshot.versionID)
                },
                onToggleExpansion: { [weak self] in
                    guard let self else { return }
                    self.parent.onToggleTrackExpansion(snapshot.trackID)
                },
                onAddToPlaylist: { [weak self] playlistID in
                    guard let self else { return }
                    self.parent.onAddTrackToPlaylist(snapshot.trackID, playlistID)
                },
                onCreatePlaylist: { [weak self] in
                    guard let self else { return }
                    self.parent.onCreatePlaylistWithTrack(snapshot.trackID)
                },
                onAddToQueue: { [weak self] in
                    guard let self else { return }
                    self.parent.onAddVersionToQueue(snapshot.versionID)
                },
                onDelete: { [weak self] in
                    guard let self else { return }
                    self.parent.onDeleteVersion(snapshot.trackID, snapshot.versionID)
                },
                onNameThisVersion: { [weak self] in
                    guard let self else { return }
                    self.parent.onNameThisVersion(snapshot.trackID)
                },
                isReleased: snapshot.isReleased,
                onToggleReleased: { [weak self] in
                    guard let self else { return }
                    self.parent.onToggleReleased(snapshot.trackID)
                },
                onEditTrack: { [weak self] in
                    guard let self else { return }
                    self.parent.onEditTrack(snapshot.trackID)
                }
            )
        }

        func setSelection(id: UUID?) {
            guard let tableView else { return }

            guard let id,
                  let itemIndex = parent.items.firstIndex(where: { $0.rowSnapshot?.versionID == id }) else {
                if !tableView.selectedRowIndexes.isEmpty {
                    isUpdatingSelection = true
                    tableView.selectRowIndexes([], byExtendingSelection: false)
                    isUpdatingSelection = false
                }
                return
            }

            let tableRow = tableRow(forItemIndex: itemIndex)
            if tableView.selectedRowIndexes != IndexSet(integer: tableRow) {
                isUpdatingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
                isUpdatingSelection = false
            }
        }

        func currentAnchorFromTable() -> UUID? {
            guard let tableView else { return nil }
            let indexes = tableView.selectedRowIndexes
            if indexes.isEmpty { return nil }

            let selectedRow = tableView.selectedRow
            if selectedRow >= 0, indexes.contains(selectedRow) {
                return item(at: selectedRow)?.rowSnapshot?.versionID
            }

            if let first = indexes.first {
                return item(at: first)?.rowSnapshot?.versionID
            }

            return nil
        }

        private func selectAllSelectableRows() {
            guard let tableView else { return }
            let selectable = parent.items.indices
                .filter { parent.items[$0].rowSnapshot != nil }
                .map(tableRow(forItemIndex:))
            tableView.selectRowIndexes(IndexSet(selectable), byExtendingSelection: false)
        }

        private func deleteSelectedRows() {
            let snapshots = selectedSnapshots()
            guard !snapshots.isEmpty else { return }
            parent.onDeleteSelected(snapshots)
        }

        // MARK: - NSMenuDelegate

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }

            let clickedRow = tableView.clickedRow

            guard clickedRow >= 0,
                  item(at: clickedRow)?.rowSnapshot != nil else {
                menu.removeAllItems()
                return
            }

            if !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            let snapshots = selectedSnapshots()
            guard !snapshots.isEmpty else {
                menu.removeAllItems()
                return
            }

            menu.removeAllItems()

            let addToPlaylistItem = NSMenuItem(title: "Add to Playlist", symbol: "text.badge.plus", action: nil, target: nil)
            let submenu = NSMenu()
            for playlist in parent.playlists {
                let item = NSMenuItem(title: playlist.name, action: #selector(addSelectedToPlaylist(_:)), keyEquivalent: "")
                item.representedObject = playlist.id
                item.target = self
                submenu.addItem(item)
            }
            if !parent.playlists.isEmpty {
                submenu.addItem(.separator())
            }
            let newPlaylistItem = NSMenuItem(title: "New Playlist…", action: #selector(createPlaylistWithSelected(_:)), keyEquivalent: "")
            newPlaylistItem.target = self
            submenu.addItem(newPlaylistItem)
            addToPlaylistItem.submenu = submenu
            menu.addItem(addToPlaylistItem)

            guard snapshots.count == 1, let snapshot = snapshots.first else {
                menu.addItem(NSMenuItem(title: "Add \(snapshots.count) to Queue", symbol: "list.bullet",
                                        action: #selector(addSelectedToQueue(_:)), target: self))
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Delete \(snapshots.count) Selected", symbol: "trash",
                                        action: #selector(deleteSelected(_:)), target: self))
                return
            }

            let playItem = NSMenuItem(title: "Play", symbol: "play.fill", action: #selector(playSelected(_:)), target: self)
            playItem.isEnabled = snapshot.processingState == .complete
            menu.addItem(playItem)
            menu.addItem(NSMenuItem(title: "Add to Queue", symbol: "list.bullet", action: #selector(addSelectedToQueue(_:)), target: self))

            menu.addItem(.separator())

            menu.addItem(NSMenuItem(title: "Edit Track…", symbol: "pencil", action: #selector(editTrack(_:)), target: self))
            menu.addItem(NSMenuItem(title: "Rename Track", symbol: "character.cursor.ibeam", action: #selector(renameTrack(_:)), target: self))
            menu.addItem(NSMenuItem(title: "Name This Version…", symbol: "tag", action: #selector(nameThisVersion(_:)), target: self))
            menu.addItem(NSMenuItem(
                title: snapshot.isReleased ? "Unmark as Released" : "Mark as Released",
                symbol: snapshot.isReleased ? "checkmark.seal.fill" : "checkmark.seal",
                action: #selector(toggleReleased(_:)),
                target: self
            ))
            if snapshot.versionCountInGroup > 1 {
                menu.addItem(NSMenuItem(title: "Rename Version", symbol: "pencil", action: #selector(renameVersion(_:)), target: self))
            }

            menu.addItem(.separator())

            menu.addItem(NSMenuItem(title: "Show in Finder", symbol: "doc", action: #selector(showInFinder(_:)), target: self))

            menu.addItem(.separator())

            menu.addItem(NSMenuItem(title: "Delete", symbol: "trash", action: #selector(deleteSelected(_:)), target: self))
        }

        private func selectedSnapshots() -> [LibraryTrackRowSnapshot] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { tableRow -> LibraryTrackRowSnapshot? in
                item(at: tableRow)?.rowSnapshot
            }
        }

        @objc private func addSelectedToPlaylist(_ sender: NSMenuItem) {
            guard let playlistID = sender.representedObject as? UUID else { return }
            let snapshots = selectedSnapshots()
            guard !snapshots.isEmpty else { return }
            parent.onAddSelectedToPlaylist(snapshots, playlistID)
        }

        @objc private func createPlaylistWithSelected(_ sender: NSMenuItem) {
            let snapshots = selectedSnapshots()
            guard !snapshots.isEmpty else { return }
            parent.onCreatePlaylistWithSelected(snapshots)
        }


        @objc private func addSelectedToQueue(_ sender: NSMenuItem) {
            for snapshot in selectedSnapshots() {
                parent.onAddVersionToQueue(snapshot.versionID)
            }
        }

        @objc private func editTrack(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            parent.onEditTrack(snapshot.trackID)
        }

        @objc private func playSelected(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            parent.onTogglePlayback(snapshot.versionID)
        }

        @objc private func renameTrack(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            parent.renameManager.begin(
                target: .init(kind: .track, id: snapshot.trackID),
                initialText: snapshot.trackName
            )
        }

        @objc private func renameVersion(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            parent.renameManager.begin(
                target: .init(kind: .version, id: snapshot.versionID),
                initialText: snapshot.versionLabel
            )
        }

        @objc private func nameThisVersion(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            parent.onNameThisVersion(snapshot.trackID)
        }

        @objc private func toggleReleased(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            parent.onToggleReleased(snapshot.trackID)
        }


        @objc private func showInFinder(_ sender: NSMenuItem) {
            guard let snapshot = selectedSnapshots().first else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: snapshot.filePath)])
        }

        @objc private func deleteSelected(_ sender: NSMenuItem) {
            let snapshots = selectedSnapshots()
            guard !snapshots.isEmpty else { return }

            if snapshots.count == 1, let snapshot = snapshots.first {
                parent.onDeleteVersion(snapshot.trackID, snapshot.versionID)
            } else {
                parent.onDeleteSelected(snapshots)
            }
        }
    }
}

extension NSMenuItem {
    convenience init(title: String, symbol: String, action: Selector?, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: "")
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.target = target
    }
}
