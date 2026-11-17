import AppKit
import SwiftUI
import BounceKit

extension Notification.Name {
    static let focusTitlebarSearchField = Notification.Name("focusTitlebarSearchField")
}

// MARK: - Toolbar content

/// Control density states. `full` shows the search field inline; `compact`
/// collapses search to a glass icon that opens a focused popover while keeping
/// the sort/playlist and import buttons. Both states render inside the
/// catalogue column, so there is no `>>` overflow state at all: compact is the
/// minimum and AppKit never measures the cluster.
enum ToolbarPresentation: Equatable {
    case full
    case compact

    /// Width of the inline search cluster (260pt field + two 30pt glass pills
    /// + 8pt gaps).
    static let fullClusterWidth: CGFloat = 260 + 30 + 30 + 2 * 8
    /// Width a visible inspector toggle occupies at the trailing edge,
    /// including its 8pt gap to the cluster.
    static let inspectorSlotWidth: CGFloat = 30 + 8

    /// Presentation for a column of `columnWidth`. A centered full cluster
    /// must clear both the leading window chrome and the trailing inspector
    /// toggle slot, so the threshold requires the larger reserved side rather
    /// than merely fitting the total width.
    static func resolve(
        columnWidth: CGFloat,
        leadingReserve: CGFloat,
        reservesInspectorToggle: Bool,
        forced: ToolbarPresentation?
    ) -> ToolbarPresentation {
        if let forced { return forced }
        let trailingReserve = reservesInspectorToggle ? inspectorSlotWidth : 0
        let required = fullClusterWidth + 2 * max(leadingReserve, trailingReserve)
        return columnWidth >= required ? .full : .compact
    }
}

/// Catalogue-column-owned control host. It lives inside the catalogue column
/// as content rather than in `NSToolbar`, so AppKit never measures it for
/// system overflow and its trailing edge is the catalogue column's trailing
/// edge by construction — not a window-width guess or a render-only offset.
/// Presentation is chosen from the measured column width, and the inspector
/// toggle is part of the cluster so no native toolbar band is reserved.
struct CatalogueToolbarControls: View {
    @Binding var searchText: String
    let selection: LibrarySelection
    let selectedPlaylist: Playlist?
    let onImport: () -> Void
    /// True from the Import click until the open panel is dismissed; the panel
    /// can appear late, so the button shows a spinner instead of feeling dead.
    let isImportPanelPending: Bool
    let onEditPlaylist: (Playlist) -> Void
    let onPlayPlaylist: (UUID) -> Void
    let onShufflePlaylist: (UUID) -> Void
    let onQueuePlaylist: (UUID) -> Void
    let onDeletePlaylist: (UUID) -> Void
    /// Presentation resolved by the shared top-row host from the tracklist
    /// column width, the leading chrome reserve, and whether the inspector
    /// toggle occupies the trailing slot.
    let presentation: ToolbarPresentation
    @Binding var isSearchPopoverPresented: Bool

    var body: some View {
        cluster
            .onReceive(NotificationCenter.default.publisher(for: .focusTitlebarSearchField)) { _ in
                // Cmd-F: the full field focuses itself via the same
                // notification; compact opens the focused popover anchored to
                // the search icon.
                if presentation != .full {
                    isSearchPopoverPresented = true
                }
            }
            .onChange(of: presentation) { _, newValue in
                if newValue == .full {
                    isSearchPopoverPresented = false
                }
            }
    }

    @ViewBuilder
    private var cluster: some View {
        HStack(spacing: 8) {
            switch presentation {
            case .full:
                ToolbarSearchField(searchText: $searchText)
                selectionControls
                importButton
            case .compact:
                searchIconButton
                selectionControls
                importButton
            }
        }
    }

    /// Sort (All Tracks) or playlist actions sit beside the search control in
    /// both the full and compact states.
    @ViewBuilder
    private var selectionControls: some View {
        if selection == .allTracks || selection == .sets || selection == .releases {
            AllTracksSortMenu()
        } else if case .playlist(let id) = selection,
                  let playlist = selectedPlaylist,
                  playlist.id == id {
            playlistActionsMenu(playlist: playlist)
        }
    }

    private var searchIconButton: some View {
        Button {
            isSearchPopoverPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
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
        .popover(isPresented: $isSearchPopoverPresented, arrowEdge: .bottom) {
            ToolbarSearchField(
                searchText: $searchText,
                autoFocus: true,
                onExit: { isSearchPopoverPresented = false }
            )
            .padding(12)
        }
        .help("Search")
        .accessibilityLabel("Search")
    }

    private var importButton: some View {
        Button(action: onImport) {
            ZStack {
                if isImportPanelPending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isImportPanelPending)
        .background {
            Circle()
                .fill(.clear)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .help("Import Audio")
    }

    private func playlistActionsMenu(playlist: Playlist) -> some View {
        ToolbarGlassMenu(systemImage: "ellipsis", help: "Playlist Actions") {
            Button("Edit Playlist") {
                onEditPlaylist(playlist)
            }

            Divider()

            Button("Play") {
                onPlayPlaylist(playlist.id)
            }

            Button("Shuffle") {
                onShufflePlaylist(playlist.id)
            }

            Button("Play Next") {
                onQueuePlaylist(playlist.id)
            }

            Divider()

            Button("Delete", role: .destructive) {
                onDeletePlaylist(playlist.id)
            }
        }
    }
}

/// Inspector toggle. Closed: pinned to the window's top-right corner (shown
/// only when inspection is available). Open: hosted at the top-left of the
/// inspector pane (see LibraryLayout) so it tracks the sidebar edge.
struct InspectorToggleButton: View {
    let canInspect: Bool
    @Binding var isInspectorPresented: Bool

    var body: some View {
        if canInspect || isInspectorPresented {
            let title = isInspectorPresented ? "Hide Inspector" : "Show Inspector"
            Button {
                isInspectorPresented.toggle()
            } label: {
                Image(systemName: "rectangle.trailingthird.inset.filled")
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
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue(isInspectorPresented ? "Shown" : "Hidden")
        }
    }
}

/// Circular glass pill hosting a Menu. Glass is drawn behind the Menu —
/// applying `.glassEffect` on the Menu itself often paints nothing.
private struct ToolbarGlassMenu<Content: View>: View {
    let systemImage: String
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(.clear)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .help(help)
    }
}

private struct ToolbarSearchField: View {
    @Binding var searchText: String
    var autoFocus: Bool = false
    /// Called after Escape has cleared the text and resigned focus. The compact
    /// popover passes its dismissal so one Escape closes the whole surface.
    var onExit: (() -> Void)? = nil
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            // Custom leading-aligned placeholder. The native TextField
            // placeholder re-draws at a slightly different origin once the
            // field becomes first responder, which read as a horizontal jump
            // on activation. An overlay anchored to the same leading edge as
            // the text never moves; it is hidden as soon as text is entered.
            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .font(.system(size: 13))
                .onExitCommand(perform: handleExit)
                .overlay(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: 30)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTitlebarSearchField)) { _ in
            isSearchFocused = true
        }
        .onAppear {
            guard autoFocus else { return }
            // Popover content is inserted before the hosting window finishes
            // its layout pass; defer one runloop turn so focus sticks.
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    /// Explicit Escape handling. `TransportKeyboardMonitor` deliberately lets
    /// focused text inputs own Escape first (inline note/rename editors keep
    /// their cancellation), so the search field implements its own dismissal:
    /// clear the query, resign focus, then let the compact popover close.
    private func handleExit() {
        searchText = ""
        isSearchFocused = false
        onExit?()
    }
}

private struct AllTracksSortMenu: View {
    var body: some View {
        ToolbarGlassMenu(systemImage: "line.3.horizontal.decrease", help: "Sort") {
            SortMenuButtons()
        }
    }
}

/// Sort options shared by the sort pill and the overflow menu.
private struct SortMenuButtons: View {
    @AppStorage(BouncePreferenceKey.allTracksSortMode) private var sortModeRaw = AllTracksSortMode.dateAdded.rawValue

    var body: some View {
        Button {
            sortModeRaw = AllTracksSortMode.dateAdded.rawValue
        } label: {
            Label("Date Added", systemImage: sortModeRaw == AllTracksSortMode.dateAdded.rawValue ? "checkmark" : "")
        }

        Button {
            sortModeRaw = AllTracksSortMode.name.rawValue
        } label: {
            Label("Name", systemImage: sortModeRaw == AllTracksSortMode.name.rawValue ? "checkmark" : "")
        }
    }
}

// MARK: - Undo banner data

struct UndoBanner {
    let message: String
    let onUndo: () -> Void
}

// MARK: - Undo banner view

struct UndoBannerView: View {
    let banner: UndoBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)

            Text(banner.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)

            Button("Undo") {
                banner.onUndo()
                onDismiss()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
    }
}

// MARK: - Drag overlay

struct DragOverlayView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.16)

            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [10]))
                }
                .padding(24)

            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.primary)
                Text("Drop Audio to Import")
                    .font(.headline)
                Text("Add new tracks or versions to the library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
