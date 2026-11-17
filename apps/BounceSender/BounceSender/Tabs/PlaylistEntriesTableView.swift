import SwiftUI
import AppKit
import BounceKit

struct PlaylistEntryVersionOption: Identifiable, Equatable {
    let id: UUID
    let label: String
}

struct PlaylistEntryRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let trackID: UUID
    let trackName: String
    let versionID: UUID?
    let versionLabel: String?
    let availableVersions: [PlaylistEntryVersionOption]
    let addedAt: Date?
    let duration: TimeInterval?
    let filePath: String?
    let artworkRevision: Int64?
}

struct PlaylistEntriesTableView: NSViewRepresentable {
    /// The header (title strip) is table row 0 so it scrolls away under the
    /// top toolbar instead of pinning above the entries.
    static let headerRow = 0

    let header: AnyView
    let headerHeight: CGFloat
    /// Reports the hosted header's own rendered height so the parent's
    /// `headerHeight` is measured from the same view instance the table sizes
    /// row 0 from, at the same width.
    let onHeaderHeightChange: (CGFloat) -> Void
    let rows: [PlaylistEntryRowSnapshot]
    /// Lazy artwork loader for visible cells — keeps entry snapshots blob-free.
    let artworkForTrack: (UUID) -> Data?
    @Binding var selectedEntryID: UUID?
    let columns: LibraryColumnVisibility
    let allowsReordering: Bool
    let playbackEngine: PlaybackEngine
    let loadedVersionID: UUID?
    let isPlaying: Bool
    let renameTarget: InlineRenameManager.Target?
    let renameManager: InlineRenameManager
    let onPlayVersion: (UUID) -> Void
    let onToggleVersion: (UUID) -> Void
    let onInspectVersion: (UUID) -> Void
    let onChangeVersion: (UUID, UUID) -> Void
    let onRemove: (UUID) -> Void
    let onRemoveEntries: ([UUID]) -> Void
    let onAddToQueue: (UUID) -> Void
    let onEditTrack: (UUID) -> Void
    let onReorderEntries: ([UUID], Int) -> Void
    let onInsertVersions: ([UUID], Int) -> Void

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

        let rowsChanged = context.coordinator.rowsChanged(newRows: rows)
        let playbackChanged = context.coordinator.playbackChanged(
            loadedVersionID: loadedVersionID,
            isPlaying: isPlaying
        )
        let renameChanged = context.coordinator.renameChanged(newTarget: renameTarget)
        let columnsChanged = context.coordinator.columnsChanged(newColumns: columns)
        context.coordinator.parent = self
        context.coordinator.refreshHeader()
        if context.coordinator.headerGeometryChanged(headerHeight: headerHeight) {
            context.coordinator.noteHeaderHeightChanged()
        }
        if rowsChanged {
            if context.coordinator.isPurePermutation(of: rows) {
                context.coordinator.animateReorder(to: rows)
            } else {
                context.coordinator.reloadAll()
            }
        } else if renameChanged {
            context.coordinator.refreshRenameChange()
        } else if playbackChanged || columnsChanged {
            context.coordinator.refreshVisibleCells()
        }
        context.coordinator.setSelection(id: selectedEntryID)
    }
}

extension PlaylistEntriesTableView {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var parent: PlaylistEntriesTableView

        private let pasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.playlist-entry-item")
        // Same literal as LibraryTrackTableView's drag source (private there;
        // MainSidebar redeclares it the same way).
        private let libraryVersionPasteboardType = NSPasteboard.PasteboardType("com.merlinkraemer.bounce.library-version-item")

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var headerCell: LibraryTableHeaderCellView?
        private var lastHeaderHeight: CGFloat?
        private var lastRow0Height: CGFloat = -1
        private var lastRowsSnapshot: [PlaylistEntryRowSnapshot] = []
        private var lastLoadedVersionID: UUID?
        private var lastIsPlaying = false
        private var lastColumns: LibraryColumnVisibility
        private var lastRenameTarget: InlineRenameManager.Target?

        init(parent: PlaylistEntriesTableView) {
            self.parent = parent
            self.lastLoadedVersionID = parent.loadedVersionID
            self.lastIsPlaying = parent.isPlaying
            self.lastColumns = parent.columns
            self.lastRenameTarget = parent.renameTarget
        }

        func makeView() -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            let tableView = PlaylistEntriesNSTableView(frame: .zero)
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.rowHeight = 52
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.selectionHighlightStyle = .none
            tableView.focusRingType = .none
            tableView.backgroundColor = .clear
            tableView.gridStyleMask = []
            tableView.dataSource = self
            tableView.delegate = self
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = true
            tableView.style = .plain
            tableView.draggingDestinationFeedbackStyle = .gap
            tableView.registerForDraggedTypes([pasteboardType, libraryVersionPasteboardType])
            tableView.setDraggingSourceOperationMask(.move, forLocal: true)
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
            tableView.target = self
            tableView.doubleAction = #selector(doubleClickedRow(_:))
            tableView.onPlay = { [weak self] in
                self?.playSelectedRow()
            }
            tableView.onDelete = { [weak self] in
                self?.removeSelectedRows()
            }

            let scrollView = LibraryScrollView(frame: .zero)
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.documentView = tableView

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

        func rowsChanged(newRows: [PlaylistEntryRowSnapshot]) -> Bool {
            newRows != lastRowsSnapshot
        }

        func playbackChanged(loadedVersionID: UUID?, isPlaying: Bool) -> Bool {
            loadedVersionID != lastLoadedVersionID || isPlaying != lastIsPlaying
        }

        func renameChanged(newTarget: InlineRenameManager.Target?) -> Bool {
            newTarget != lastRenameTarget
        }

        func columnsChanged(newColumns: LibraryColumnVisibility) -> Bool {
            newColumns != lastColumns
        }

        func refreshRenameChange() {
            lastRenameTarget = parent.renameTarget
            refreshVisibleCells()
        }

        func reloadAll() {
            guard let tableView else { return }
            lastRowsSnapshot = parent.rows
            lastLoadedVersionID = parent.loadedVersionID
            lastIsPlaying = parent.isPlaying
            lastColumns = parent.columns
            lastRenameTarget = parent.renameTarget
            lastHeaderHeight = parent.headerHeight
            let previousSelection = selectedEntryID
            tableView.reloadData()
            setSelection(id: previousSelection)
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

        func noteHeaderHeightChanged() {
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
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: PlaylistEntriesTableView.headerRow)
            )
            tableView.tile()
            tableView.layoutSubtreeIfNeeded()
        }

        /// True when `newRows` is the same set of rows in a different order,
        /// with every row's content unchanged (full Equatable per id). Content
        /// changes — rename, artwork, version — must go through reloadAll().
        func isPurePermutation(of newRows: [PlaylistEntryRowSnapshot]) -> Bool {
            guard lastRowsSnapshot.count == newRows.count else { return false }
            // Never trap on duplicate entry IDs (a dirty-data / sync-merge symptom):
            // collapse dupes with uniquingKeysWith, and let the count guard below
            // fall back to reloadAll() when the IDs aren't actually unique.
            let oldByID = Dictionary(lastRowsSnapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard oldByID.count == newRows.count else { return false }
            for row in newRows {
                guard let old = oldByID[row.id], old == row else { return false }
            }
            return lastRowsSnapshot.map(\.id) != newRows.map(\.id)
        }

        /// Reorder-only update: slide rows with moveRow(at:to:) instead of
        /// flashing the whole list through reloadData. Cell views travel with
        /// their rows, so no reconfiguration is needed.
        ///
        /// The IDs are entry-space; the table has the title strip as row 0, so
        /// the move indices are offset past it and the header never moves.
        func animateReorder(to newRows: [PlaylistEntryRowSnapshot]) {
            guard let tableView else { return }
            let oldIDs = lastRowsSnapshot.map(\.id)
            let previousSelection = selectedEntryID
            lastRowsSnapshot = newRows
            lastLoadedVersionID = parent.loadedVersionID
            lastIsPlaying = parent.isPlaying
            lastColumns = parent.columns
            lastRenameTarget = parent.renameTarget
            tableView.applyMoves(
                from: oldIDs,
                to: newRows.map(\.id),
                offset: PlaylistEntriesTableView.headerRow + 1
            )
            setSelection(id: previousSelection)
        }

        /// Pushes selection change into visible cells so their isSelected state updates
        /// without requiring a full reloadData.
        func refreshVisibleCells() {
            guard let tableView else { return }
            lastLoadedVersionID = parent.loadedVersionID
            lastIsPlaying = parent.isPlaying
            lastColumns = parent.columns
            let visible = tableView.rows(in: tableView.visibleRect)
            for row in visible.lowerBound..<visible.upperBound {
                guard rowSnapshot(at: row) != nil,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistEntryCellView else { continue }
                configure(cell: cell, for: row)
            }
        }

        private var selectedEntryID: UUID? {
            guard let tableView, tableView.selectedRow >= 0 else { return nil }
            return rowSnapshot(at: tableView.selectedRow)?.id
        }

        private func draggedEntryIDs(from pasteboard: NSPasteboard) -> [UUID] {
            guard let raw = pasteboard.string(forType: pasteboardType) else { return [] }
            return raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }

        /// Version IDs from a drag that originated in the library table —
        /// one pasteboard item per dragged row.
        private func libraryVersionIDs(from pasteboard: NSPasteboard) -> [UUID] {
            guard pasteboard.availableType(from: [libraryVersionPasteboardType]) != nil else { return [] }
            return (pasteboard.pasteboardItems ?? []).compactMap { item in
                item.string(forType: libraryVersionPasteboardType).flatMap(UUID.init(uuidString:))
            }
        }

        private func rowSnapshot(at row: Int) -> PlaylistEntryRowSnapshot? {
            let index = row - PlaylistEntriesTableView.headerRow - 1
            guard index >= 0, index < parent.rows.count else { return nil }
            return parent.rows[index]
        }

        /// Entry-space insertion index for a table drop row.
        private func entryIndex(forDropRow row: Int) -> Int {
            min(max(row - PlaylistEntriesTableView.headerRow - 1, 0), parent.rows.count)
        }

        @objc private func doubleClickedRow(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard let snapshot = rowSnapshot(at: row),
                  let versionID = snapshot.versionID else { return }
            parent.onPlayVersion(versionID)
        }

        private func playSelectedRow() {
            guard let versionID = rowSnapshot(at: tableView?.selectedRow ?? -1)?.versionID else { return }
            parent.onToggleVersion(versionID)
        }

        private func removeSelectedRows() {
            guard let tableView else { return }
            let entryIDs = tableView.selectedRowIndexes
                .sorted()
                .compactMap { rowSnapshot(at: $0)?.id }
            guard !entryIDs.isEmpty else { return }
            parent.onRemoveEntries(entryIDs)
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count + 1
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let draggedSnapshot = rowSnapshot(at: row) else { return nil }

            let item = NSPasteboardItem()
            DragExportFile.add(to: item, filePath: draggedSnapshot.filePath, trackName: draggedSnapshot.trackName, versionLabel: draggedSnapshot.versionLabel)
            guard parent.allowsReordering else {
                return item.types.isEmpty ? nil : item
            }

            let selectedIndexes = tableView.selectedRowIndexes
            let ids: [UUID]
            if selectedIndexes.contains(row), selectedIndexes.count > 1 {
                ids = selectedIndexes.sorted().compactMap { rowSnapshot(at: $0)?.id }
            } else if let snapshot = rowSnapshot(at: row) {
                ids = [snapshot.id]
            } else {
                return nil
            }

            item.setString(ids.map(\.uuidString).joined(separator: ","), forType: pasteboardType)
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            RowDragImage.apply(to: session, tableView: tableView, rowIndexes: rowIndexes)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Tracks dragged in from the library table: insert between rows.
            if info.draggingPasteboard.availableType(from: [libraryVersionPasteboardType]) != nil {
                guard parent.allowsReordering else { return [] }
                var targetRow = row
                if dropOperation == .on {
                    let point = tableView.convert(info.draggingLocation, from: nil)
                    let rowRect = tableView.rect(ofRow: row)
                    targetRow = row + (point.y > rowRect.midY ? 1 : 0)
                }
                targetRow = max(targetRow, PlaylistEntriesTableView.headerRow + 1)
                tableView.setDropRow(targetRow, dropOperation: .above)
                return .copy
            }

            let draggedIDs = draggedEntryIDs(from: info.draggingPasteboard)
            guard parent.allowsReordering, !draggedIDs.isEmpty else { return [] }

            let sourceIndices = parent.rows.enumerated()
                .filter { draggedIDs.contains($0.element.id) }
                .map(\.offset)
            guard sourceIndices.count == draggedIDs.count,
                  let minSource = sourceIndices.min(),
                  let maxSource = sourceIndices.max() else {
                return []
            }

            var targetRow = row
            if dropOperation == .on {
                let point = tableView.convert(info.draggingLocation, from: nil)
                let rowRect = tableView.rect(ofRow: row)
                let isBelowMidpoint = point.y > rowRect.midY
                targetRow = row + (isBelowMidpoint ? 1 : 0)
            }

            targetRow = max(targetRow, PlaylistEntriesTableView.headerRow + 1)
            tableView.setDropRow(targetRow, dropOperation: .above)

            // Entry-space insertion index (header is table row 0).
            let entryTarget = targetRow - PlaylistEntriesTableView.headerRow - 1
            if entryTarget >= minSource, entryTarget <= maxSource + 1 {
                return []
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let versionIDs = libraryVersionIDs(from: info.draggingPasteboard)
            if !versionIDs.isEmpty {
                parent.onInsertVersions(versionIDs, entryIndex(forDropRow: row))
                return true
            }

            let draggedIDs = draggedEntryIDs(from: info.draggingPasteboard)
            guard !draggedIDs.isEmpty else { return false }
            parent.onReorderEntries(draggedIDs, entryIndex(forDropRow: row))
            return true
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Mirrors the library table: the shared header cell is only the
            // header body, and the scroll view's constant top content inset
            // carries the clearance (the empty state reserves the same pair).
            row == PlaylistEntriesTableView.headerRow
                ? max(parent.headerHeight, 1)
                : 52
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            row != PlaylistEntriesTableView.headerRow
        }

        private var lastSelectedRowIndexes = IndexSet()

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            let selectedID = rowSnapshot(at: row)?.id
            if parent.selectedEntryID != selectedID {
                parent.selectedEntryID = selectedID
            }
            if let versionID = rowSnapshot(at: row)?.versionID {
                parent.onInspectVersion(versionID)
            }

            let indexes = tableView.selectedRowIndexes
            let changed = lastSelectedRowIndexes.symmetricDifference(indexes)
            lastSelectedRowIndexes = indexes
            for changedRow in changed {
                refreshCell(at: changedRow)
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row != PlaylistEntriesTableView.headerRow else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("PlaylistEntryRowView")
            let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? HoverableSelectionRowView
                ?? HoverableSelectionRowView()
            rowView.identifier = identifier
            rowView.hoverDidChange = { [weak self, weak tableView, weak rowView] _ in
                guard let self, let tableView, let rowView else { return }
                let row = tableView.row(for: rowView)
                guard row >= 0 else { return }
                self.refreshCell(at: row)
            }
            rowView.syncHoverState()
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == PlaylistEntriesTableView.headerRow {
                let headerView = tableView.makeView(
                    withIdentifier: LibraryTableHeaderCellView.reuseIdentifier,
                    owner: nil
                ) as? LibraryTableHeaderCellView ?? LibraryTableHeaderCellView()
                headerView.identifier = LibraryTableHeaderCellView.reuseIdentifier
                headerCell = headerView
                headerView.configure(
                    rootView: parent.header,
                    appearance: tableView.effectiveAppearance,
                    onHeaderHeightChange: parent.onHeaderHeightChange
                )
                return headerView
            }

            let view = tableView.makeView(withIdentifier: PlaylistEntryCellView.reuseIdentifier, owner: nil) as? PlaylistEntryCellView
                ?? PlaylistEntryCellView()
            view.appearance = tableView.effectiveAppearance
            configure(cell: view, for: row)
            return view
        }

        private func configure(cell: PlaylistEntryCellView, for row: Int) {
            guard let snapshot = rowSnapshot(at: row) else { return }
            cell.configure(
                snapshot: snapshot,
                artworkData: parent.artworkForTrack(snapshot.trackID),
                columns: parent.columns,
                playbackEngine: parent.playbackEngine,
                renameManager: parent.renameManager,
                onPlayToggle: { [weak self] in
                    guard let versionID = snapshot.versionID else { return }
                    self?.parent.onToggleVersion(versionID)
                },
                onChangeVersion: { [weak self] versionID in
                    self?.parent.onChangeVersion(snapshot.id, versionID)
                },
                onAddToQueue: { [weak self] in
                    guard let versionID = snapshot.versionID else { return }
                    self?.parent.onAddToQueue(versionID)
                },
                onEditTrack: { [weak self] in
                    self?.parent.onEditTrack(snapshot.trackID)
                },
                onRemove: { [weak self] in
                    self?.parent.onRemove(snapshot.id)
                }
            )
        }

        private func refreshCell(at row: Int) {
            guard let tableView,
                  rowSnapshot(at: row) != nil,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistEntryCellView else {
                return
            }
            configure(cell: cell, for: row)
        }

        private func refresh(target: InlineRenameManager.Target) {
            lastRenameTarget = target
            guard let row = parent.rows.firstIndex(where: { snapshot in
                switch target.kind {
                case .track:
                    return snapshot.trackID == target.id
                case .version:
                    return snapshot.versionID == target.id
                case .playlist, .playlistFolder:
                    return false
                }
            }) else { return }
            refreshCell(at: row + PlaylistEntriesTableView.headerRow + 1)
        }

        func setSelection(id: UUID?) {
            guard let tableView else { return }
            guard let id else {
                tableView.selectRowIndexes([], byExtendingSelection: false)
                return
            }

            guard let index = parent.rows.firstIndex(where: { $0.id == id }) else {
                tableView.selectRowIndexes([], byExtendingSelection: false)
                return
            }

            let row = index + PlaylistEntriesTableView.headerRow + 1
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }
}

final class PlaylistEntriesNSTableView: NSTableView {
    var onPlay: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if modifiers.isEmpty, event.keyCode == 49 {
            onPlay?()
            return
        }

        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }

        super.keyDown(with: event)
    }
}

final class PlaylistEntryCellView: NSTableCellView, DragSnapshotPreparable {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PlaylistEntryCellView")

    private var hostingView: NSHostingView<PlaylistEntryRow>?
    private var suppressSelectionForDrag = false

    private var snapshot: PlaylistEntryRowSnapshot?
    private var artworkData: Data?
    private var playbackEngine: PlaybackEngine?
    private var columns = LibraryColumnVisibility(width: 600)
    private var renameManager: InlineRenameManager?
    private var onPlayToggle: (() -> Void)?
    private var onChangeVersion: ((UUID) -> Void)?
    private var onAddToQueue: (() -> Void)?
    private var onEditTrack: (() -> Void)?
    private var onRemove: (() -> Void)?

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
        snapshot: PlaylistEntryRowSnapshot,
        artworkData: Data?,
        columns: LibraryColumnVisibility,
        playbackEngine: PlaybackEngine,
        renameManager: InlineRenameManager,
        onPlayToggle: @escaping () -> Void,
        onChangeVersion: @escaping (UUID) -> Void,
        onAddToQueue: @escaping () -> Void,
        onEditTrack: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.artworkData = artworkData
        self.columns = columns
        self.playbackEngine = playbackEngine
        self.renameManager = renameManager
        self.onPlayToggle = onPlayToggle
        self.onChangeVersion = onChangeVersion
        self.onAddToQueue = onAddToQueue
        self.onEditTrack = onEditTrack
        self.onRemove = onRemove

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
        guard let snapshot = snapshot, let playbackEngine = playbackEngine, let renameManager = renameManager else { return }
        let isSelected = (backgroundStyle == .emphasized) && !suppressSelectionForDrag
        let isHovered = (superview as? HoverableSelectionRowView)?.isHovered ?? false

        let root = PlaylistEntryRow(
            snapshot: snapshot,
            artworkData: artworkData,
            columns: columns,
            isSelected: isSelected,
            isHovered: isHovered,
            playbackEngine: playbackEngine,
            renameManager: renameManager,
            onPlayToggle: onPlayToggle ?? {},
            onChangeVersion: onChangeVersion ?? { _ in },
            onAddToQueue: onAddToQueue ?? {},
            onEditTrack: onEditTrack ?? {},
            onRemove: onRemove ?? {}
        )

        if let hostingView {
            hostingView.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
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
