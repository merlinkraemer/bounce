import AppKit
import SwiftUI
import BounceKit

/// NSTableView subclass that lets the SwiftUI side handle ⌘A and
/// delete via callback closures.
final class LibraryTableView: NSTableView {
    var onSelectAll: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if modifiers == .command, event.charactersIgnoringModifiers == "a" {
            onSelectAll?()
            return
        }

        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }

        super.keyDown(with: event)
    }
}

/// The tracklist header is a regular table row so it scrolls away with the
/// catalogue instead of remaining pinned above the AppKit table.
final class LibraryTableHeaderRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibraryTableHeaderRowView")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
    }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class LibraryTableHeaderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibraryTableHeaderCellView")

    private var hostingView: NSHostingView<AnyView>?
    private var lastReportedHeight: CGFloat = -1
    private var pendingHeight: CGFloat = -1
    /// False until one measurement has been applied. The first reading is a
    /// cold-start layout, not an animation ramp, so it needs no confirmation.
    private var hasAppliedMeasurement = false
    private var onHeaderHeightChange: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
    }

    func configure(
        rootView: AnyView,
        appearance: NSAppearance?,
        onHeaderHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.onHeaderHeightChange = onHeaderHeightChange
        // New configuration means new content (and possibly a new width), so
        // the next layout pass must re-measure and re-report.
        lastReportedHeight = -1
        pendingHeight = -1
        // The header is table row 0 and scrolls with the rows. The resting
        // clearance under the transparent titlebar band is the scroll view's
        // constant top content inset, so the hosted content is only the body
        // and row 0 is exactly its measured height.
        let documentContent = AnyView(
            rootView
                .frame(maxWidth: .infinity, alignment: .top)
        )
        if let hostingView {
            hostingView.rootView = documentContent
            // Without this, the hosting view inherits the window's top
            // safe-area inset for the transparent titlebar band and adds it
            // to `fittingSize`, on top of the scroll view's constant inset.
            // `safeAreaRegions = []` keeps the cell's content the only thing
            // measured and the scroll inset the single clearance.
            hostingView.safeAreaRegions = []
        } else {
            let host = NSHostingView(rootView: documentContent)
            host.safeAreaRegions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingView = host
        }
        hostingView?.appearance = appearance
    }

    /// Reports the displayed hosting view's own ideal height during layout,
    /// before the table reads `heightOfRow`.
    ///
    /// The displayed copy is laid out inside whatever height the table handed
    /// the cell, so its *frame* reports the constrained value (the old wrong
    /// fixed point: 71). Its `fittingSize`, however, is the hosted content's
    /// ideal size — the body's real height — which is exactly what row 0 needs.
    ///
    /// Guards: a measurement is only trusted while the host has a real frame.
    /// Any move — up or down — must be seen twice in a row before it is
    /// applied, so a 1 pt/pass animation ramp (which never repeats a value)
    /// cannot ratchet row 0 up to the top of the band and leave a gap under
    /// the top-aligned header body. A stable value (the rest height, or a
    /// settled resize result) still lands one layout pass later.
    private func reportMeasuredHeaderHeight() {
        guard let hostingView else { return }
        let fitting = hostingView.fittingSize.height
        let hostFrameHeight = hostingView.frame.height
        let ideal = fitting
        guard bounds.width > 0.5, bounds.height > 0.5, hostFrameHeight > 0.5, ideal > 0 else { return }
        if lastReportedHeight >= 0, abs(ideal - lastReportedHeight) <= 0.5 {
            pendingHeight = -1
            return
        }
        if !hasAppliedMeasurement {
            // Cold start (empty height cache, row 0 is the 1 pt placeholder):
            // nothing triggers a second layout pass, so waiting for a repeat
            // never completed and the header stayed collapsed until a tab
            // switch re-mounted it with a cached height.
            hasAppliedMeasurement = true
            lastReportedHeight = ideal
            onHeaderHeightChange?(ideal)
            return
        }
        // Symmetric confirmation: apply only a candidate that repeats. A 1 pt
        // animation step is never re-proposed, so transient frame- or
        // content-animation readings cannot grow row 0.
        guard abs(pendingHeight - ideal) <= 0.5 else {
            pendingHeight = ideal
            return
        }
        pendingHeight = -1
        lastReportedHeight = ideal
        onHeaderHeightChange?(ideal)
    }

    override func layout() {
        super.layout()
        reportMeasuredHeaderHeight()
    }
}

/// Reusable cell that hosts a SwiftUI `LibraryRowView`.
final class LibraryTrackCellView: NSTableCellView, DragSnapshotPreparable {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibraryTrackCellView")

    private var hostingView: NSHostingView<LibraryRowView>?
    private var suppressSelectionForDrag = false
    
    private var snapshot: LibraryTrackRowSnapshot?
    private var artworkData: Data?
    private var playlists: [LibraryPlaylistMenuItem] = []
    private var isLoaded = false
    private var isPlaying = false
    private var inspectedVersionID: UUID?
    private var inspectedVersionLabel: String?
    private var columns = LibraryColumnVisibility(width: 600)
    private var renameManager: InlineRenameManager?
    private var onTogglePlayback: (() -> Void)?
    private var onToggleExpansion: (() -> Void)?
    private var onAddToPlaylist: ((UUID) -> Void)?
    private var onCreatePlaylist: (() -> Void)?
    private var onAddToQueue: (() -> Void)?
    private var onDelete: (() -> Void)?
    private var onNameThisVersion: (() -> Void)?
    private var isReleased = false
    private var onToggleReleased: (() -> Void)?
    private var onEditTrack: (() -> Void)?

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
        snapshot: LibraryTrackRowSnapshot,
        artworkData: Data?,
        playlists: [LibraryPlaylistMenuItem],
        isLoaded: Bool,
        isPlaying: Bool,
        inspectedVersionID: UUID?,
        inspectedVersionLabel: String?,
        columns: LibraryColumnVisibility,
        renameManager: InlineRenameManager,
        onTogglePlayback: @escaping () -> Void,
        onToggleExpansion: @escaping () -> Void,
        onAddToPlaylist: @escaping (UUID) -> Void,
        onCreatePlaylist: @escaping () -> Void,
        onAddToQueue: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onNameThisVersion: @escaping () -> Void,
        isReleased: Bool,
        onToggleReleased: @escaping () -> Void,
        onEditTrack: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.artworkData = artworkData
        self.playlists = playlists
        self.isLoaded = isLoaded
        self.isPlaying = isPlaying
        self.inspectedVersionID = inspectedVersionID
        self.inspectedVersionLabel = inspectedVersionLabel
        self.columns = columns
        self.renameManager = renameManager
        self.onTogglePlayback = onTogglePlayback
        self.onToggleExpansion = onToggleExpansion
        self.onAddToPlaylist = onAddToPlaylist
        self.onCreatePlaylist = onCreatePlaylist
        self.onAddToQueue = onAddToQueue
        self.onDelete = onDelete
        self.onNameThisVersion = onNameThisVersion
        self.isReleased = isReleased
        self.onToggleReleased = onToggleReleased
        self.onEditTrack = onEditTrack

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
        guard let snapshot = snapshot, let renameManager = renameManager else { return }
        let isSelected = (backgroundStyle == .emphasized) && !suppressSelectionForDrag
        let isHovered = (superview as? HoverableSelectionRowView)?.isHovered ?? false
        
        let root = LibraryRowView(
            snapshot: snapshot,
            artworkData: artworkData,
            playlists: playlists,
            isSelected: isSelected,
            isHovered: isHovered,
            isLoaded: isLoaded,
            isPlaying: isPlaying,
            inspectedVersionID: inspectedVersionID,
            inspectedVersionLabel: inspectedVersionLabel,
            columns: columns,
            renameManager: renameManager,
            onTogglePlayback: onTogglePlayback ?? {},
            onToggleExpansion: onToggleExpansion ?? {},
            onAddToPlaylist: onAddToPlaylist ?? { _ in },
            onCreatePlaylist: onCreatePlaylist ?? {},
            onAddToQueue: onAddToQueue ?? {},
            onDelete: onDelete ?? {},
            onNameThisVersion: onNameThisVersion ?? {},
            isReleased: isReleased,
            onToggleReleased: onToggleReleased ?? {},
            onEditTrack: onEditTrack ?? {}
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

/// Slim divider row that sits between version groups.
final class LibrarySeparatorCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibrarySeparatorCellView")

    private let divider = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
        setup()
    }

    private func setup() {
        wantsLayer = true

        divider.boxType = .custom
        divider.borderColor = .clear
        divider.fillColor = .separatorColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 72),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }
}
