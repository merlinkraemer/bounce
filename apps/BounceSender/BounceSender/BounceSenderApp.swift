import SwiftUI
import SwiftData
import Observation
import Combine
import BounceKit

@main
struct BounceSenderApp: App {
    @State private var transferManager = TransferManager()
    @State private var renameManager = InlineRenameManager()
    @State private var toastCenter = FooterToastCenter()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Launch-time work; idempotent (the library window can reappear).
    @MainActor private static var didStartServices = false
    @MainActor
    private func startServicesOnce() {
        guard !Self.didStartServices else { return }
        Self.didStartServices = true
        transferManager.setModelContext(modelContainer.mainContext)
        appDelegate.installMenuBar(transferManager: transferManager, modelContainer: modelContainer)
        SchemaBackfill.backfillLastTouchedAt(in: modelContainer.mainContext)
        // Off the launch critical path: legacy covers/artwork can be tens of MB
        // (uncompressed TIFF) and re-encoding runs against its own ModelContext.
        let container = modelContainer
        Task(priority: .utility) {
            await SchemaBackfill.backfillOversizedArtwork(container: container)
        }
        renameManager.onCommit = { target, newName in
            let modelContext = container.mainContext
            do {
                switch target.kind {
                case .track:
                    if let track = modelContext.fetchByID(Track.self, id: target.id) {
                        track.name = newName
                    }
                case .version:
                    if let version = modelContext.fetchByID(Version.self, id: target.id) {
                        version.label = newName
                    }
                case .playlist:
                    if let playlist = modelContext.fetchByID(Playlist.self, id: target.id) {
                        playlist.name = newName
                        playlist.updatedAt = .now
                    }
                case .playlistFolder:
                    if let folder = modelContext.fetchByID(PlaylistFolder.self, id: target.id) {
                        folder.name = newName
                        folder.updatedAt = .now
                    }
                }

                if modelContext.hasChanges {
                    try modelContext.save()
                }
            } catch {
                SyncLog.sender.error("Failed to commit rename for \(String(describing: target.kind)): \(error.localizedDescription, privacy: .public)")
            }
        }
        if OnboardingShot.isActive {
            // Screenshot mode: no sync transport. Capture/quit is driven from AppDelegate.
            OnboardingShot.log("services started (no transport)")
            #if DEBUG
            if OnboardingShot.step == .pairAlert { transferManager.debugPresentPairAlert() }
            #endif
        } else {
            let tm = transferManager
            Task {
                await tm.start()
            }
        }
    }

    private let modelContainer: ModelContainer = {
        let schema = Schema([
            Track.self,
            Version.self,
            Note.self,
            Playlist.self,
            PlaylistEntry.self,
            PlaylistFolder.self,
            PendingUpload.self,
            PendingVoiceUpload.self
        ])
        // Unsandboxed Mac apps default to ~/Library/Application Support/default.store,
        // which is shared across every SwiftData app on the system. Pin to a
        // Bounce-owned path so other apps can't stomp the schema.
        let config = ModelConfiguration(schema: schema, url: BounceSenderApp.storeURL())
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            SyncLog.sender.error("Library failed to open: \(String(describing: error), privacy: .public)")
            return BounceSenderApp.recoverContainer(schema: schema, config: config)
        }
    }()

    /// Store open failed: ask, then move the store files aside (never delete) and start fresh.
    private static func recoverContainer(schema: Schema, config: ModelConfiguration) -> ModelContainer {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Your library couldn't be opened"
        alert.informativeText = "You can start with a fresh library. The old one is kept in a separate folder, not deleted."
        alert.addButton(withTitle: "Start Fresh Library")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }

        let moved: URL
        do {
            moved = try moveBrokenStoreAside()
        } catch {
            SyncLog.sender.error("Could not move broken library aside: \(String(describing: error), privacy: .public)")
            failAndQuit("Couldn't move the old library aside. Nothing was changed.")
        }
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let done = NSAlert()
            done.messageText = "Fresh library created"
            done.informativeText = "The old library is in \(moved.lastPathComponent)."
            done.addButton(withTitle: "OK")
            done.addButton(withTitle: "Show in Finder")
            if done.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([moved])
            }
            return container
        } catch {
            SyncLog.sender.error("Fresh library failed to open: \(String(describing: error), privacy: .public)")
            failAndQuit("Couldn't create a fresh library.")
        }
    }

    private static func failAndQuit(_ message: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    /// Moves only the store files (`Bounce.store*`, `.Bounce_SUPPORT`) from this lane's data
    /// directory into a sibling `<dir>-broken-YYYYMMDD-HHMMSS` folder.
    private static func moveBrokenStoreAside() throws -> URL {
        let fm = FileManager.default
        let storeDir = storeURL().deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = storeDir.deletingLastPathComponent()
            .appendingPathComponent("\(storeDir.lastPathComponent)-broken-\(formatter.string(from: Date()))", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let names = try fm.contentsOfDirectory(atPath: storeDir.path)
            .filter { $0.hasPrefix("Bounce.store") || $0 == ".Bounce_SUPPORT" }
        for name in names {
            try fm.moveItem(at: storeDir.appendingPathComponent(name), to: target.appendingPathComponent(name))
        }
        return target
    }

    private static func storeURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var dir = appSupport.appendingPathComponent(BounceConstants.applicationSupportDirectoryName, isDirectory: true)
        // Screenshot mode (DEBUG): throwaway library, never the real one.
        if OnboardingShot.isActive {
            dir = fm.temporaryDirectory.appendingPathComponent("bounce-onboarding-shot", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Bounce.store")
    }

    var body: some Scene {
        // Single library window (`Window`, not `WindowGroup`) so `openWindow(id:)`
        // re-fronts it instead of spawning a second one. First-run setup is a
        // sheet on this window.
        Window("Bounce", id: LibraryWindow.id) {
            ContentView()
                .environment(transferManager)
                .environment(renameManager)
                .environment(toastCenter)
                .modelContainer(modelContainer)
                .modifier(WindowActionCapture())
                .onAppear {
                    // LSUIElement apps don't auto-activate — bring window to front explicitly.
                    NSApp.activate(ignoringOtherApps: true)
                    startServicesOnce()
                }
        }
        .defaultSize(width: 920, height: 750)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updater)
            }
            SetupCommands()
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .focusTitlebarSearchField, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(transferManager)
        }
    }
}

struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates\u{2026}") {
            updater.checkForUpdates()
        }
        .disabled(!updater.isStarted)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let minWindowSize = NSSize(width: 440, height: 560)
    private var windowObservation: Any?
    /// Captured from live scenes so AppKit callbacks can open SwiftUI windows.
    @MainActor static var openWindowAction: OpenWindowAction?
    @MainActor static var openSettingsAction: OpenSettingsAction?
    @MainActor lazy var updater = AppUpdater()
    @MainActor private var menuBar: MenuBarController?

    @MainActor
    func installMenuBar(transferManager: TransferManager, modelContainer: ModelContainer) {
        guard menuBar == nil else { return }
        menuBar = MenuBarController(transferManager: transferManager, modelContainer: modelContainer, updater: updater)
    }

    /// Dock click with no visible window: reopen the library.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let open = Self.openWindowAction else { return true }
        open(id: LibraryWindow.id)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if OnboardingShot.step == .setupSnapshots, let outDir = OnboardingShot.outDir {
            exit(SetupSnapshots.render(to: outDir) ? 0 : 1)
        }
        #endif
        if OnboardingShot.isActive {
            OnboardingShot.log("launched step=\(OnboardingShot.step?.rawValue ?? "?") out=\(OnboardingShot.outDir?.path ?? "nil")")
            NSApp.activate(ignoringOtherApps: true)
            OnboardingShot.captureWindows()
        }
        updater.startForProductionBuilds()
        // Try once after SwiftUI creates the window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.configureWindows()
        }

        // Re-apply whenever a window becomes key (full-screen, new windows, etc.)
        windowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.configureWindow(window)
        }
    }

    private func configureWindows() {
        for window in NSApp.windows {
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        // Target only the main WindowGroup window: sheets and panels are
        // excluded, and the title guard is backed by a marker check so a window
        // that momentarily has no title during scene setup is still recognised
        // once the main content view is attached.
        guard !(window is NSPanel), window.sheetParent == nil else { return }
        guard window.title == "Bounce" || window.contentView?.containsMainWindowChromeMarker == true else {
            return
        }
        window.minSize = Self.minWindowSize
        window.delegate = self
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.unifiedTitleAndToolbar)
        // Required for rows to stay visible under the chrome: an opaque
        // titlebar background occludes them outright, and macOS projects no
        // scroll edge effect over this AppKit table to replace it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillResize(_ sender: NSWindow, to proposedFrameSize: NSSize) -> NSSize {
        let minSize = Self.minWindowSize
        return NSSize(
            width: max(proposedFrameSize.width, minSize.width),
            height: max(proposedFrameSize.height, minSize.height)
        )
    }
}

/// True AppKit window-coordinate geometry shared with SwiftUI. The toolbar
/// toggle's right edge and the catalogue frame are both measured with
/// `NSView.convert(_:to: nil)`, so the centered toolbar band derives from one
/// coordinate space instead of subtracting SwiftUI `.global` frames that come
/// from different hosting roots.
@Observable
final class WindowChromeMetrics {
    var sidebarToggleTrailingEdge: CGFloat = 0
    var catalogueMinX: CGFloat = 0
    var catalogueWidth: CGFloat = 0
    /// Live titlebar/toolbar band from `contentLayoutRect`. `nil` means *not
    /// yet measured*; a measured 0 (full screen) is stored as 0 and never
    /// replaced by a fallback constant.
    var titlebarBandHeight: CGFloat?
    /// Height of the real native toolbar container view in window coordinates.
    /// The in-content control host aligns to this band, independent of any
    /// document clearance. `nil` when the toolbar/container is not visible.
    var nativeToolbarBandHeight: CGFloat?
}

/// Publishes the band metrics above from the live window. Called from the
/// main-window chrome host and from the catalogue reporter (which lays out on
/// every resize/full-screen transition), so neither value can go stale.
@MainActor
func reportBandMetrics(in window: NSWindow?, metrics: WindowChromeMetrics) {
    guard let window, let contentView = window.contentView else { return }

    let band = contentView.bounds.height - window.contentLayoutRect.height
    if band >= 0, band < 200, metrics.titlebarBandHeight != band {
        metrics.titlebarBandHeight = band
    }

    var nativeBand: CGFloat?
    if let itemView = window.toolbar?.items.first(where: { $0.itemIdentifier == .toggleSidebar })?.view {
        var container: NSView? = itemView
        while let candidate = container, !String(describing: type(of: candidate)).contains("Toolbar") {
            container = candidate.superview
        }
        if let frame = container.map({ $0.convert($0.bounds, to: nil) }),
           frame.height > 0, frame.height < 200 {
            nativeBand = frame.height
        }
    }
    if metrics.nativeToolbarBandHeight != nativeBand {
        metrics.nativeToolbarBandHeight = nativeBand
    }
}

/// Marks the window that hosts the main `WindowGroup` content. The view is
/// only inserted in `ContentView`, so configuration is applied to exactly that
/// window — unlike matching on `NSWindow.title`, which can be empty during
/// scene setup and let the previous implementation silently skip everything.
struct MainWindowChromeConfigurator: NSViewRepresentable {
    let metrics: WindowChromeMetrics

    func makeNSView(context: Context) -> MainWindowChromeHostView {
        MainWindowChromeHostView(metrics: metrics)
    }

    func updateNSView(_ nsView: MainWindowChromeHostView, context: Context) {
        nsView.metrics = metrics
        // SwiftUI toolbar rebuilds can reset `titleVisibility`; re-assert on
        // every update so the hidden title is idempotent, not one-shot.
        nsView.reassertChromeConfiguration()
    }
}

final class MainWindowChromeHostView: NSView {
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
        reassertChromeConfiguration()
    }

    func reassertChromeConfiguration() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.unifiedTitleAndToolbar)
        reportBandMetrics(in: window, metrics: metrics)
        reportSidebarToggleGeometry(in: window)
    }

    /// Read-only measurement of the automatic (sole) sidebar toggle using
    /// public toolbar item/view geometry, converted to window coordinates.
    private func reportSidebarToggleGeometry(in window: NSWindow) {
        guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier == .toggleSidebar }),
              let itemView = item.view else { return }
        let trailingEdge = itemView.convert(itemView.bounds, to: nil).maxX
        guard trailingEdge > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.metrics.sidebarToggleTrailingEdge - trailingEdge) > 0.5 else { return }
            self.metrics.sidebarToggleTrailingEdge = trailingEdge
        }
    }
}

extension NSView {
    /// True when this subtree contains the main-content marker view. Used by
    /// `AppDelegate` to identify the main window without matching on a title
    /// that SwiftUI may not have set yet.
    var containsMainWindowChromeMarker: Bool {
        if self is MainWindowChromeHostView { return true }
        return subviews.contains { $0.containsMainWindowChromeMarker }
    }
}

enum LibraryWindow {
    static let id = "library"
}

/// Hands the scene's `openWindow` action to the app delegate (Dock reopen).
struct WindowActionCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            AppDelegate.openWindowAction = openWindow
            AppDelegate.openSettingsAction = openSettings
        }
    }
}
