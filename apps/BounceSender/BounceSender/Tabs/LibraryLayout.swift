import SwiftUI
import AppKit
import SwiftData
import BounceKit

// MARK: - Selection model

enum LibrarySelection: Hashable {
    case allTracks
    case releases
    case sets
    case playlist(UUID)

    var playbackContext: PlaybackContext {
        switch self {
        case .allTracks, .releases: return .allTracks
        case .sets: return .sets
        case .playlist(let id): return .playlist(id)
        }
    }
}

enum PlaybackContext: Equatable {
    case allTracks
    case sets
    case playlist(UUID)
}

/// Live widths of the two side columns, published so the toolbar can reserve
/// the space it actually has instead of assuming maximum column widths.
struct SidebarColumnWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct InspectorColumnWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Whether the inspector is actually on screen. At narrow detail widths the
/// inspector is replaced by the notes workspace, so its column-width
/// preference can be stale; the toolbar must reserve zero in that state.
struct InspectorPresentationPreferenceKey: PreferenceKey {
    static let defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Leading titlebar chrome the catalogue control cluster must not intrude
/// into when the catalogue column reaches the window's leading edge: the
/// window traffic lights (88pt, matching the previous collapsed-sidebar
/// reserve) plus the automatic navigation sidebar toggle and its spacing.
/// The cluster is trailing-aligned, so this is a width budget, not padding.
private let catalogueLeadingChromeReserve: CGFloat = 134

/// Native library workspace. The catalogue remains the source of navigation;
/// the exact-mix details surface is an independent review target and becomes a
/// full-width notes workspace when the window is narrow.
struct MainLibraryLayout<TransportBar: View, CatalogueControls: View>: View {
    @Binding var selection: LibrarySelection
    @Binding var selectedVersionID: UUID?
    @Binding var selectedVersionIDs: Set<UUID>
    let inspectedVersionID: UUID?
    @Binding var isDetailsPresented: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isSyncSheetPresented: Bool
    @Binding var searchText: String
    /// Window-coordinate geometry measured in AppKit: the automatic sidebar
    /// toggle's right edge and the catalogue's frame.
    let chromeMetrics: WindowChromeMetrics

    let transportState: TransportState
    let tracks: [Track]
    let inspectedTrack: Track?
    let inspectedVersion: Version?
    let onInspectVersion: (UUID) -> Void
    let onPlayVersion: (UUID) -> Void
    let onTogglePlayback: (UUID) -> Void
    let onPlayPlaylist: (UUID) -> Void
    let onShufflePlaylist: (UUID) -> Void
    let onShowPlayingMix: () -> Void
    let onSaveNote: (Track, Version, String, TimeInterval) -> Bool
    let onReviewPosition: (TimeInterval) -> Void
    let onScrub: (TimeInterval) -> Void
    let onUpdateNote: (Note, Track, String) -> Bool
    let onDeleteNote: (Note) -> Void
    let onAddToQueue: (UUID) -> Void
    let onCreatedPlaylist: (UUID) -> Void
    @ViewBuilder let catalogueControls: (_ presentation: ToolbarPresentation) -> CatalogueControls
    @ViewBuilder let transportBar: TransportBar

    @Environment(PlaybackEngine.self) private var playbackEngine
    @AppStorage(BouncePreferenceKey.allTracksSortMode) private var sortModeRaw = AllTracksSortMode.dateAdded.rawValue
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @Query(sort: \PlaylistFolder.createdAt) private var allFolders: [PlaylistFolder]
    @State private var isBrowsePresented = false
    @State private var noteDrafts: [UUID: MixNoteDraft] = [:]
    @State private var sidebarWasAutoCollapsed = false
    @State private var catalogueWidth: CGFloat = 0
    @State private var detailWidth: CGFloat = 0
    /// Hoisted so sidebar expansion survives the native column being collapsed
    /// and reopened. Instance-local state was reset (and force-expanded) on
    /// every presentation change while two sidebar instances coexisted.
    @State private var expandedFolderIDs: Set<UUID> = []
    /// Folders already seeded once, so re-presenting the sidebar never
    /// re-expands a folder the user collapsed.
    @State private var knownFolderIDs: Set<UUID> = []

    private var releasePlaylists: [Playlist] {
        allPlaylists.filter { !$0.isSoftDeleted }
    }

    private var liveFolderIDs: Set<UUID> {
        Set(allFolders.filter { !$0.isSoftDeleted }.map(\.id))
    }

    /// Leading space the control cluster must clear so full search cannot
    /// collide with the traffic lights or the automatic navigation sidebar
    /// toggle. The catalogue starts at the window's leading edge when the
    /// sidebar is collapsed; a visible sidebar column already occupies it, so
    /// nothing is reserved.
    private var catalogueLeadingReserve: CGFloat {
        columnVisibility == .detailOnly ? catalogueLeadingChromeReserve : 0
    }

    /// Visible native toolbar band the in-content control host aligns to. This
    /// is deliberately independent of any document clearance: a stale or wrong
    /// value here can no longer shift the tracklist header, and vice versa.
    /// A measured 0 (full screen) is a real document value, but the host still
    /// has to lay out its controls, so it falls back to the titlebar constant.
    private var controlHostBandHeight: CGFloat {
        let band = chromeMetrics.nativeToolbarBandHeight
            ?? chromeMetrics.titlebarBandHeight
            ?? BounceConstants.titlebarChromeHeight
        let resolved = band > 0 ? band : BounceConstants.titlebarChromeHeight
        return resolved
    }

    private var isReleasesSelected: Bool {
        if case .releases = selection { return true }
        return false
    }

    var body: some View {
        GeometryReader { windowGeometry in
            let geometryWidth = windowGeometry.size.width
            let shouldAutoCollapseSidebar = geometryWidth < 1120

            NavigationSplitView(columnVisibility: $columnVisibility) {
                MainSidebar(
                    selection: $selection,
                    isSyncSheetPresented: $isSyncSheetPresented,
                    expandedFolderIDs: $expandedFolderIDs
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarColumnWidthPreferenceKey.self,
                            value: proxy.size.width
                        )
                    }
                }
                .navigationSplitViewColumnWidth(min: 176, ideal: 200, max: 240)
            } detail: {
                NavigationStack {
                    GeometryReader { geometry in
                        let isNarrow = geometry.size.width < 760
                        let hasInspection = inspectedVersion != nil
                        let showsNotes = isNarrow && isDetailsPresented && hasInspection && !isBrowsePresented
                        let showsBrowse = isNarrow && isDetailsPresented && hasInspection && isBrowsePresented

                        workspaceContent(
                            isNarrow: isNarrow,
                            showsNotes: showsNotes,
                            showsBrowse: showsBrowse
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            detailWidth = width
                        }
                        .onChange(of: isNarrow) { _, narrow in
                            if !narrow {
                                isBrowsePresented = false
                            }
                        }
                    }
                }
            }
            .onChange(of: shouldAutoCollapseSidebar, initial: true) { _, shouldCollapse in
                if shouldCollapse {
                    if columnVisibility == .all {
                        columnVisibility = .detailOnly
                        sidebarWasAutoCollapsed = true
                    }
                } else if sidebarWasAutoCollapsed {
                    columnVisibility = .all
                    sidebarWasAutoCollapsed = false
                }
            }
        }
        .task(id: liveFolderIDs) {
            // Seed newly appearing folders once, tracked outside the sidebar,
            // so collapsing and reopening the native column never resets or
            // force-expands the user's folder state.
            for id in liveFolderIDs where !knownFolderIDs.contains(id) {
                knownFolderIDs.insert(id)
                expandedFolderIDs.insert(id)
            }
            knownFolderIDs.formIntersection(liveFolderIDs)
            expandedFolderIDs.formIntersection(liveFolderIDs)
        }
        .onChange(of: inspectedVersion?.id) { oldID, newID in
            // A deleted inspected version has no valid draft target anymore.
            // Selection changes between two live versions deliberately retain
            // both drafts for later restoration.
            if newID == nil, let oldID {
                noteDrafts.removeValue(forKey: oldID)
            }
        }
    }

    @ViewBuilder
    private func workspaceContent(
        isNarrow: Bool,
        showsNotes: Bool,
        showsBrowse: Bool
    ) -> some View {
        if showsNotes {
            narrowDetails
        } else if showsBrowse {
            narrowBrowse
        } else {
            catalogueContent(extendsUnderTitlebar: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    transportBar
                        .frame(maxWidth: BounceConstants.transportBarMaxWidth)
                        .zIndex(1)
                }
                .inspector(isPresented: Binding(
                    get: { !isNarrow && isDetailsPresented },
                    set: { newValue in
                        if !isNarrow { isDetailsPresented = newValue }
                    }
                )) {
                    detailPane
                }
                .overlay(alignment: .topLeading) {
                    if !isDetailsPresented {
                        InspectorToggleButton(
                            canInspect: inspectedVersion != nil,
                            isInspectorPresented: $isDetailsPresented
                        )
                        .frame(height: controlHostBandHeight)
                        .padding(.leading, max(catalogueWidth - 42, 0))
                        .ignoresSafeArea(.container, edges: .top)
                    }
                }
                .preference(
                    key: InspectorPresentationPreferenceKey.self,
                    value: !isNarrow && isDetailsPresented
                )
        }
    }

    /// `extendsUnderTitlebar` is what actually lets rows travel behind the
    /// window chrome. Without it SwiftUI lays the catalogue out inside the
    /// window's top safe area, so the scroll view stops at `contentLayoutRect`
    /// and no row pixels ever exist in the titlebar band — no amount of toolbar
    /// background hiding can reveal rows that were never drawn there.
    /// `LibraryScrollView` then measures the resulting overlap and insets its
    /// content by it, keeping the header readable at rest.
    /// `showsTopFade` restores the top edge fade without taking ownership of
    /// the control host: narrow browse already renders its own `titlebarHost`,
    /// so it must opt into the fade without `extendsUnderTitlebar` (which would
    /// inject a second host and a second safe-area opt-out).
    @ViewBuilder
    private func catalogueContent(
        onInspectVersion override: ((UUID) -> Void)? = nil,
        extendsUnderTitlebar: Bool = false,
        showsTopFade: Bool = false
    ) -> some View {
        let inspectVersion = override ?? onInspectVersion

        // One safe-area opt-out owns the whole column so the controls, the
        // fades, and the rows share a single coordinate space. The controls no
        // longer need a second opt-out on a fixed-size overlay child.
        ZStack(alignment: .top) {
            Group {
                if isReleasesSelected {
                ReleasesContentView(
                    tracks: tracks,
                    playlists: releasePlaylists,
                    sortModeRaw: sortModeRaw,
                    selectedVersionID: $selectedVersionID,
                    onSelectVersion: inspectVersion,
                    onSelectPlaylist: { id in selection = .playlist(id) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryContent(
                    selection: $selection,
                    selectedVersionID: $selectedVersionID,
                    selectedVersionIDs: $selectedVersionIDs,
                    inspectedVersionID: inspectedVersionID,
                    onInspectVersion: inspectVersion,
                    onPlayVersion: onPlayVersion,
                    onTogglePlayback: onTogglePlayback,
                    onPlayPlaylist: onPlayPlaylist,
                    onShufflePlaylist: onShufflePlaylist,
                    searchText: $searchText,
                    sortModeRaw: $sortModeRaw,
                    tracks: tracks,
                    onCreatedPlaylist: onCreatedPlaylist,
                    onAddToQueue: onAddToQueue
                )
            }
            }
            .overlay(alignment: .bottom) {
                ColumnEdgeFade(
                    edge: .bottom,
                    height: BounceConstants.columnBottomFadeHeight
                )
            }
            .overlay(alignment: .top) {
                if extendsUnderTitlebar || showsTopFade {
                    ColumnEdgeFade(edge: .top, height: BounceConstants.columnTopFadeHeight)
                }
            }

            if extendsUnderTitlebar {
                // Catalogue-owned control host: the cluster is aligned to the
                // visible tracklist column and the inspector toggle owns an
                // independent trailing slot. It lives in content, never in
                // `NSToolbar`, so AppKit cannot move it into `>>`.
                titlebarHost(
                    identity: "catalogue",
                    extendsUnderTitlebar: extendsUnderTitlebar,
                    showsTopFade: showsTopFade,
                    rawColumnWidth: catalogueWidth,
                    forcedPresentation: nil
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if width > 0 { catalogueWidth = width }
        }
        .background(CatalogueBoundsReporter(metrics: chromeMetrics))
        .ignoresSafeArea(.container, edges: extendsUnderTitlebar ? .top : [])
    }

    private var detailPane: some View {
        NowPlayingPaneView(
            track: inspectedTrack,
            version: inspectedVersion,
            playbackEngine: playbackEngine,
            transportState: transportState,
            reservesTransportSpace: false,
            onSaveNote: onSaveNote,
            onReviewPosition: onReviewPosition,
            onScrub: onScrub,
            onUpdateNote: onUpdateNote,
            onDeleteNote: onDeleteNote,
            drafts: $noteDrafts
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InspectorColumnWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        // SwiftUI's inspector draws its perimeter in an outer AppKit glass
        // container, outside this content view. Install the edge cleanup there
        // so it cannot draw a second line across the header artwork.
        .background(InspectorChromeMaskInstaller())
        .inspectorColumnWidth(min: 288, ideal: 300, max: 440)
    }

    /// One coherent top-row host shared by the wide catalogue and the narrow
    /// notes/browse workspaces. It renders in the titlebar band above the
    /// content, aligns the control cluster to the visible tracklist column
    /// (capped at `catalogueContentMaxWidth` and centered exactly like
    /// `LibraryListView`), and keeps the inspector toggle in an independent
    /// trailing slot. Full presentation centers the cluster; compact trails it
    /// before the toggle slot. No offsets, no native toolbar items.
    @ViewBuilder
    private func titlebarHost(
        identity: String,
        extendsUnderTitlebar: Bool,
        showsTopFade: Bool,
        rawColumnWidth: CGFloat,
        forcedPresentation: ToolbarPresentation?,
        @ViewBuilder leading: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        let columnWidth = min(rawColumnWidth, BounceConstants.catalogueContentMaxWidth)
        let centeringInset = max((rawColumnWidth - columnWidth) / 2, 0)
        let effectiveReserve = max(catalogueLeadingReserve - centeringInset, 0)
        // Boundaries from true AppKit window coordinates: the automatic
        // sidebar toggle's measured right edge and the catalogue's measured
        // frame. The plausibility guard keeps a stale or invalid measurement
        // from moving the cluster left of the chrome budget.
        let measuredWidth = chromeMetrics.catalogueWidth > 0 ? chromeMetrics.catalogueWidth : rawColumnWidth
        let measuredReserve = chromeMetrics.sidebarToggleTrailingEdge - chromeMetrics.catalogueMinX
        let leadingBoundary = (measuredReserve > 0 && measuredReserve < measuredWidth)
            ? measuredReserve
            : catalogueLeadingReserve
        let reservesInspectorToggle = inspectedVersion != nil && !isDetailsPresented
        let presentation = ToolbarPresentation.resolve(
            columnWidth: columnWidth,
            leadingReserve: effectiveReserve,
            reservesInspectorToggle: reservesInspectorToggle,
            forced: forcedPresentation
        )

        ZStack {
            if presentation == .full {
                // Centered between the automatic sidebar toggle's actual right
                // edge and the catalogue's actual right usable edge (the
                // inspector's left edge when open; the catalogue frame is
                // measured inside the `.inspector` modifier, so nothing is
                // subtracted twice). 12pt host padding is part of the math.
                let fullLeadingInset = max(leadingBoundary - 12, 0)
                HStack(spacing: 0) {
                    Color.clear.frame(width: fullLeadingInset)
                    Spacer(minLength: 0)
                    catalogueControls(presentation)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 0)
                if presentation == .compact {
                    catalogueControls(presentation)
                }
                trailing()
            }
            .padding(.leading, presentation == .compact ? effectiveReserve : 0)
            .padding(.trailing, reservesInspectorToggle ? ToolbarPresentation.inspectorSlotWidth : 0)
            .frame(maxWidth: BounceConstants.catalogueContentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)

            // Narrow workspaces have no split, so their host owns the toggle
            // at the trailing edge. Wide layouts use the overlay in
            // `workspaceContent`.
            if forcedPresentation != nil {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    InspectorToggleButton(
                        canInspect: reservesInspectorToggle,
                        isInspectorPresented: $isDetailsPresented
                    )
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: controlHostBandHeight)
    }

    private var narrowDetails: some View {
        ZStack(alignment: .top) {
            NowPlayingPaneView(
                track: inspectedTrack,
                version: inspectedVersion,
                playbackEngine: playbackEngine,
                transportState: transportState,
                reservesTransportSpace: true,
                onSaveNote: onSaveNote,
                onReviewPosition: onReviewPosition,
                onScrub: onScrub,
                onUpdateNote: onUpdateNote,
                onDeleteNote: onDeleteNote,
                drafts: $noteDrafts
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The whole narrow workspace opts out of the top safe area, so the
            // notes content clears the visible native toolbar band once.
            .padding(.top, controlHostBandHeight)

            titlebarHost(
                identity: "narrowDetails",
                extendsUnderTitlebar: true,
                showsTopFade: false,
                rawColumnWidth: detailWidth,
                forcedPresentation: .compact
            ) {
                browseButton
            } trailing: {
                playingMixButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            transportBar
                .frame(maxWidth: BounceConstants.transportBarMaxWidth)
                .zIndex(1)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var browseButton: some View {
        Button {
            isBrowsePresented = true
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(.clear)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .help("Browse Mixes")
        .accessibilityLabel("Browse Mixes")
    }

    /// Restored narrow-notes affordance: only offered while a different mix is
    /// loaded, and icon-budgeted so it cannot crowd the compact cluster at the
    /// 440 minimum.
    @ViewBuilder
    private var playingMixButton: some View {
        if let loadedID = transportState.loadedVersionID, loadedID != inspectedVersionID {
            Button(action: onShowPlayingMix) {
                Image(systemName: "play.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Show Playing Mix")
            .accessibilityLabel("Show Playing Mix")
        }
    }

    private var narrowBrowse: some View {
        ZStack(alignment: .top) {
            // Tracks travel behind the top toolbar as one document, with the
            // existing top fade restored independently of host ownership:
            // narrow browse keeps its own single `titlebarHost` below.
            catalogueContent(
                onInspectVersion: { id in
                    onInspectVersion(id)
                    isBrowsePresented = false
                },
                showsTopFade: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            titlebarHost(
                identity: "narrowBrowse",
                extendsUnderTitlebar: true,
                showsTopFade: true,
                rawColumnWidth: detailWidth,
                forcedPresentation: .compact
            ) {
                narrowBrowseLeading
            } trailing: {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            transportBar
                .frame(maxWidth: BounceConstants.transportBarMaxWidth)
                .zIndex(1)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var narrowBrowseLeading: some View {
        // Icon-only at narrow widths so the leading navigation fits the 440
        // minimum alongside the compact cluster and the inspector toggle;
        // labels stay available through help and accessibility. Destination
        // switching lives in the native sidebar, so this is Back only.
        Button {
            isBrowsePresented = false
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(.clear)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .help("Back to Notes")
        .accessibilityLabel("Back to Notes")
    }
}

/// The SwiftUI inspector has no public modifier for hiding only three sides of
/// its native concentric-glass perimeter. This marker reaches the containing
/// AppKit glass view and places an opaque mask above its chrome while leaving
/// the leading split divider untouched.
private struct InspectorChromeMaskInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InspectorChromeMaskHostView {
        InspectorChromeMaskHostView()
    }

    func updateNSView(_ nsView: InspectorChromeMaskHostView, context: Context) {
        nsView.scheduleInstallation()
    }
}

private final class InspectorChromeMaskHostView: NSView {
    private weak var installedOn: NSView?
    private var maskView: InspectorChromeMaskView?
    private var installAttempts = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInstallation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleInstallation()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            maskView?.removeFromSuperview()
            maskView = nil
            installedOn = nil
            installAttempts = 0
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func scheduleInstallation() {
        guard window != nil else { return }

        DispatchQueue.main.async { [weak self] in
            self?.installIfNeeded()
        }
    }

    private func installIfNeeded() {
        guard let glassView = nearestInspectorGlassView() else {
            guard installAttempts < 20 else { return }
            installAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.installIfNeeded()
            }
            return
        }

        installAttempts = 0
        guard installedOn !== glassView else {
            maskView?.needsDisplay = true
            return
        }

        maskView?.removeFromSuperview()

        let mask = InspectorChromeMaskView()
        mask.translatesAutoresizingMaskIntoConstraints = false
        glassView.addSubview(mask, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            mask.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            mask.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            mask.topAnchor.constraint(equalTo: glassView.topAnchor),
            mask.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])

        installedOn = glassView
        maskView = mask
    }

    private func nearestInspectorGlassView() -> NSView? {
        var candidate = superview
        while let view = candidate {
            let typeName = String(describing: type(of: view))
            if typeName.contains("NSContainerConcentricGlassEffectView") {
                return view
            }
            candidate = view.superview
        }
        return nil
    }
}

private final class InspectorChromeMaskView: NSView {
    private let edgeThickness: CGFloat = 1

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // This view only paints the inspector perimeter. Let all clicks pass
        // through to the waveform, notes, and other controls underneath it.
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()

        NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: edgeThickness)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: bounds.width - edgeThickness,
                y: 0,
                width: edgeThickness,
                height: bounds.height
            )
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: 0,
                y: bounds.height - edgeThickness,
                width: bounds.width,
                height: edgeThickness
            )
        ).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Reusable top/bottom edge treatment: a native `NSVisualEffectView` material
/// (`underPageBackground`, `withinWindow`) that blurs the catalogue rows
/// physically beneath the fade, masked by a progressive gradient so the blur
/// and surface ramp out without a hard chrome line.
///
/// Why this is hand-built rather than the macOS 26 scroll edge effect: that
/// effect is projected by chrome that owns the scroll view — its only knobs are
/// `NSTitlebarAccessoryViewController`/`NSSplitViewItemAccessoryViewController`'s
/// `preferredScrollEdgeEffectStyle`, and SwiftUI's `scrollEdgeEffectStyle`
/// applies to SwiftUI `ScrollView`/`List`. The catalogue is an `NSTableView` in
/// an `NSViewRepresentable`, nested inside SwiftUI's own `NavigationSplitView`,
/// so AppKit has no registered relationship to it and projects nothing. Runtime
/// inspection confirmed this: with an opaque titlebar the rows are simply cut
/// off, with no dissolve or blur of any kind.
///
/// Native Liquid Glass (`glassEffect`) is also not used here: the macOS 26
/// `Glass` type only exposes `regular`/`clear`/`identity` plus `tint` and
/// `interactive` — no opacity, blur-radius, or intensity control — and a glass
/// surface is a discrete, edge-highlighted shape that fuses with neighbouring
/// glass. This fade needs a continuous alpha ramp over a backdrop blur.
///
/// The material choice is measured, not assumed. Against the `controlBackgroundColor`
/// column (luma 30.0 in dark mode) the candidates shifted the empty band by:
/// `hudWindow` +2.0, `sidebar` +4.7, `titlebar` +7.9, `underWindowBackground`
/// +3.4, `contentBackground`/`windowBackground` +1.9, `headerView` +1.5,
/// `underPageBackground` −0.8. Everything except `underPageBackground` paints a
/// band that reads lighter than the column it sits on, which is exactly the
/// artefact this treatment must not produce. `.withinWindow` is what makes the
/// material sample in-window rows rather than only content behind the window.
///
/// `edge` is the window edge being faded toward: the material is strongest at
/// that edge and dissolves into the content.
struct ColumnEdgeFade: View {
    let edge: VerticalEdge
    let height: CGFloat

    private var isTop: Bool { edge == .top }
    private var startPoint: UnitPoint { isTop ? .bottom : .top }
    private var endPoint: UnitPoint { isTop ? .top : .bottom }

    private var blurMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.72), location: 0.52),
                .init(color: .black, location: 1)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    private var surfaceGradient: LinearGradient {
        // The top edge stays below full opacity so row pixels remain partly
        // visible at the window edge; the bottom keeps the existing surface.
        let peak: CGFloat = isTop ? 0.82 : 1
        return LinearGradient(
            stops: [
                .init(color: Color(nsColor: .controlBackgroundColor).opacity(0), location: 0),
                .init(color: Color(nsColor: .controlBackgroundColor).opacity(peak * 0.72), location: 0.52),
                .init(color: Color(nsColor: .controlBackgroundColor).opacity(peak), location: 1)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .underPageBackground, blendingMode: .withinWindow)
                .mask(blurMask)

            surfaceGradient
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// Reports the catalogue content frame in true AppKit window coordinates.
/// SwiftUI `.global` is per hosting root, so bridging through a real `NSView`
/// lets the toolbar host compare the catalogue bounds with the toolbar
/// toggle's bounds in one coordinate space.
private struct CatalogueBoundsReporter: NSViewRepresentable {
    let metrics: WindowChromeMetrics

    func makeNSView(context: Context) -> CatalogueBoundsReporterView {
        CatalogueBoundsReporterView(metrics: metrics)
    }

    func updateNSView(_ nsView: CatalogueBoundsReporterView, context: Context) {
        nsView.metrics = metrics
        nsView.scheduleReport()
    }
}

private final class CatalogueBoundsReporterView: NSView {
    var metrics: WindowChromeMetrics

    init(metrics: WindowChromeMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReport()
    }

    override func layout() {
        super.layout()
        reportBandMetrics(in: window, metrics: metrics)
        scheduleReport()
    }

    func scheduleReport() {
        guard let window else { return }
        reportBandMetrics(in: window, metrics: metrics)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.bounds.width > 0 else { return }
            let frame = self.convert(self.bounds, to: nil)
            guard abs(self.metrics.catalogueMinX - frame.minX) > 0.5
                    || abs(self.metrics.catalogueWidth - frame.width) > 0.5 else { return }
            self.metrics.catalogueMinX = frame.minX
            self.metrics.catalogueWidth = frame.width
        }
    }
}
