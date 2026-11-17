import AppKit
import SwiftUI
import SwiftData
import Observation
import BounceKit

extension Notification.Name {
    static let pairingRequested = Notification.Name("bounce.pairingRequested")
}

@MainActor
enum PairingRequest {
    private static var requested = false

    static func send() {
        requested = true
        NotificationCenter.default.post(name: .pairingRequested, object: nil)
    }

    static func take() -> Bool {
        defer { requested = false }
        return requested
    }
}

enum Feedback {
    static let repositoryOwner = "merlinkraemer"

    static var newIssueURL: URL? {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = """


        ---
        Bounce \(version) (\(build))
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        """
        var components = URLComponents(string: "https://github.com/\(repositoryOwner)/bounce/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Feedback"),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url
    }

    @MainActor
    static func open() {
        guard let url = newIssueURL else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private struct RecentImport {
        let title: String
        let status: String
    }

    private let transferManager: TransferManager
    private let modelContainer: ModelContainer
    private let updater: AppUpdater
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    private var isUnpaired: Bool {
        transferManager.bondedPeerStore.peers.isEmpty && transferManager.connectedDeviceID == nil
    }

    private var isConnected: Bool {
        transferManager.connectionState == .connected || transferManager.connectionState == .syncing
    }

    private var presentation: SyncStatusPresentation {
        SyncStatusMapper.presentation(
            state: transferManager.connectionState,
            isUnpaired: isUnpaired,
            isSyncing: transferManager.connectionState == .syncing,
            role: .sender
        )
    }

    private var isItemPreferred: Bool {
        UserDefaults.standard.object(forKey: BouncePreferenceKey.showMenuBarItem) as? Bool
            ?? BouncePreferenceDefault.showMenuBarItem
    }

    private var statusLine: String {
        if isUnpaired { return "Not paired" }
        let name = transferManager.connectedDeviceName
            ?? transferManager.bondedPeerStore.peers.max(by: { $0.lastSeenAt < $1.lastSeenAt })?.name
            ?? "iPhone"
        let queued = transferManager.undeliveredVersionIDs.count
        let tracks = queued == 1 ? "1 track" : "\(queued) tracks"
        let detail: String
        switch (isConnected, queued) {
        case (true, 0): detail = "up to date"
        case (true, _): detail = "sending \(tracks)"
        case (false, 0): detail = presentation.label.lowercased()
        case (false, _): detail = "\(tracks) waiting"
        }
        return "\(name) - \(detail)"
    }

    init(transferManager: TransferManager, modelContainer: ModelContainer, updater: AppUpdater) {
        self.transferManager = transferManager
        self.modelContainer = modelContainer
        self.updater = updater
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibilityPreference() }
        }
        applyVisibilityPreference()
        observeGlyphState()
    }

    // MARK: - Status item

    private func applyVisibilityPreference() {
        if isItemPreferred, statusItem == nil {
            installStatusItem()
        } else if !isItemPreferred, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.setAccessibilityLabel("Bounce")
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        statusItem = item
        updateGlyph()
    }

    private func updateGlyph() {
        let image = NSImage(named: isUnpaired ? "MenubarIconUnpaired" : "MenubarIcon")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private func observeGlyphState() {
        withObservationTracking {
            _ = isUnpaired
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateGlyph()
                self?.observeGlyphState()
            }
        }
    }

    // MARK: - Drop target

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              !DragExportFile.isInternalDrag(sender.draggingPasteboard),
              !importableURLs(from: sender).isEmpty else { return [] }
        statusItem?.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem?.button?.highlight(false)
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        statusItem?.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem?.button?.highlight(false)
        let urls = importableURLs(from: sender)
        guard !urls.isEmpty else { return false }
        ImportHandoff.send(.drop(urls))
        openBounce()
        return true
    }

    private func importableURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return DragExportFile.excludingOwnExports(urls).filter { ImportableAudio.isDirectory($0) || ImportableAudio.isAudioFile($0) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let version = updater.availableVersion {
            menu.addItem(actionItem("Update available: Bounce \(version)", #selector(showUpdate)))
            menu.addItem(.separator())
        }

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.image = dotImage(NSColor(presentation.color))
        menu.addItem(status)

        if isUnpaired {
            menu.addItem(actionItem("Pair iPhone\u{2026}", #selector(pairIPhone)))
        }

        let recent = recentImports()
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent"))
            for entry in recent {
                let item = actionItem(entry.title, #selector(openBounce))
                item.badge = NSMenuItemBadge(string: entry.status)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Open Bounce", #selector(openBounce)))
        menu.addItem(actionItem("Send Feedback\u{2026}", #selector(sendFeedback)))
        menu.addItem(actionItem("Settings\u{2026}", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Bounce", #selector(quit), key: "q"))
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func dotImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    private func recentImports() -> [RecentImport] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<Version>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        descriptor.fetchLimit = 20
        guard let versions = try? context.fetch(descriptor) else { return [] }

        var seenTrackIDs = Set<UUID>()
        var result: [RecentImport] = []
        for version in versions where seenTrackIDs.insert(version.trackID).inserted {
            guard let track = context.fetchByID(Track.self, id: version.trackID),
                  track.origin == .mac else { continue }
            result.append(RecentImport(title: track.displayTitle, status: deliveryStatus(of: version)))
            if result.count == 3 { break }
        }
        return result
    }

    private func deliveryStatus(of version: Version) -> String {
        if isUnpaired { return "Waiting for iPhone" }
        if transferManager.undeliveredVersionIDs.contains(version.id) {
            return isConnected ? "Sending" : "Waiting for iPhone"
        }
        return "On iPhone"
    }

    // MARK: - Actions

    @objc private func showUpdate() {
        updater.checkForUpdates()
    }

    @objc private func pairIPhone() {
        PairingRequest.send()
        openBounce()
    }

    @objc private func openBounce() {
        AppDelegate.openWindowAction?(id: LibraryWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sendFeedback() {
        Feedback.open()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.openSettingsAction?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
